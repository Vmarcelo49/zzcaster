// In-game / chara-select frame dispatch. dllmain.frameStep handles the
// early-out / pre-game / SFX-clear logic and routes here once the game is
// past those: lazy ENet reconnect, host-side spectator drain, then dispatch
// to frameStepSpectator / frameStepNetplay / frameStepOffline.
const std = @import("std");
const netman = @import("netplay_manager.zig");
const keyboard = @import("keyboard.zig");
const gamepad = @import("gamepad.zig");
const state = @import("dll_state.zig");

pub fn frameStepInGame(world_timer: u32, game_mode: u32) void {
    state.skip_frames_addr.* = 0;

    if (state.nm) |*n| {
        // Lazy ENet reconnect: connection setup was deferred from DllMain so
        // the main thread keeps ticking. The launcher already validated the
        // peer, so this usually succeeds quickly; cap at ~15s (300 × 50ms).
        if (!n.enet_connected and !n.connect_attempts_exhausted) {
            if (n.connect_attempts == 0) {
                state.log.?.info("ENet reconnecting (peer already confirmed by launcher)...", .{});
            }
            n.connect_attempts += 1;
            n.pollAndDispatch(50);
            if (!n.enet_connected and n.connect_attempts > 300) {
                if (n.diag_connect_disconnects > 0) {
                    state.log.?.err("No opponent reconnected after ~15s — peer REFUSED/disconnected (disconnects={d}, stray_packets={d})", .{
                        n.diag_connect_disconnects, n.diag_connect_receives,
                    });
                } else {
                    state.log.?.err("No opponent reconnected after ~15s — silent timeout (no CONNECT/REFUSE event; stray_packets={d})", .{
                        n.diag_connect_receives,
                    });
                }
                n.connect_attempts_exhausted = true;
            }
        }

        if (n.config.is_host and n.enet_connected) {
            n.drainSpectatorEvents();
        }

        if (n.config.is_spectator) {
            frameStepSpectator(n);
            return;
        }

        frameStepNetplay(n, world_timer);
        return;
    } else {
        frameStepOffline(game_mode);
        return;
    }
}

fn frameStepSpectator(n: *netman.NetplayManager) void {
    n.updateFrame();

    n.pollAndDispatch(3);

    // Check for disconnect
    if (!n.enet_connected) {
        state.log.?.err("Host disconnected — spectator exiting", .{});
        state.alive_flag_addr.* = 0;
        return;
    }

    // Spectator never rolls back — just write both inputs.
    n.writeGameInputs();
}

fn frameStepNetplay(n: *netman.NetplayManager, world_timer: u32) void {
    // DIAGNOSTIC: log entry to frameStepNetplay at index/frame transitions
    // and the first few frames of in_game. This catches crashes that happen
    // between log lines (the desync investigation showed both peers' logs
    // ending silently after RNG sync at in_game entry).
    const is_first_frame_of_in_game = (n.state == .in_game and n.indexed_frame.frame < 3);
    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] frameStepNetplay ENTER state={s} index={d} frame={d} world_timer={d}", .{
            @tagName(n.state), n.indexed_frame.index, n.indexed_frame.frame, world_timer,
        });
    }

    // Read local input
    const raw_input: u16 = blk: {
        if (state.reader) |*r| {
            r.update();
            if (r.hasGamepad()) break :blk r.readInput();
        }
        break :blk keyboard.readInput();
    };

    var local_input: u16 = n.getNetplayInput(raw_input);

    // Air Dash Macro runs after state filtering and before setLocalInput, so
    // the expanded sequence is what enters the InputBuffer / goes to the peer.
    if (n.state == .in_game) {
        const r = n.air_dash_macro.step(local_input);
        if (r.triggered) {
            state.log.?.info("AirDashMacro: {d}AB -> jump {d} + dash {d}AB at frame {d}", .{
                r.output, r.output, n.air_dash_macro.dash_dir, n.indexed_frame.frame,
            });
        }
        local_input = r.output;
    } else {
        n.air_dash_macro.reset();
    }

    n.updateFrame();

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] after updateFrame: indexed_frame.frame={d}", .{n.indexed_frame.frame});
    }

    n.setLocalInput(local_input);

    n.sendLocalInputs();

    n.syncRngState();

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] after syncRngState: rng_synced={} rng_acked={}", .{
            n.rng_synced, n.rng_acked,
        });
    }

    n.pollAndDispatch(3);

    // Update RTT EMA every frame (reads ENet's peer.roundTripTime).
    // Feeds the time-sync recommendation below.
    n.updateRttEma();

    // Diagnostic: log time-sync state every 120 frames.
    if (n.indexed_frame.frame > 0 and n.indexed_frame.frame % 120 == 0) {
        const wait_ms = n.recommendFrameWaitMs();
        const advantage = n.localFrameAdvantage();
        const rtt = n.rttMs();
        const remote_est = n.remoteFrameEstimate();
        state.log.?.info("TimeSync: frame={d} rtt_ema={d:.1}ms remote_est={d:.1} advantage={d:.2} recommend_sleep={d}ms", .{
            n.indexed_frame.frame, rtt, remote_est, advantage, wait_ms,
        });
    }

    n.maybeSendSyncHash();
    n.checkSyncHashDesync();
    // Per-frame checksum desync check (ported from ggpo-x). Runs every
    // frame, catches divergences in ~16 frames vs the 300-frame SyncHash.
    // Either detector can force-exit; both are checked here.
    //
    // NOTE: The per-frame checksum hashes ONLY the RNG state (see
    // StatePool.computeDeterministicChecksum). This mirrors CCCaster's
    // SyncHash approach and eliminates false positives from non-deterministic
    // regions (world_timer, graphics array, effect pointers, etc.). If this
    // detector fires, the RNG has genuinely diverged — NOT a false positive.
    n.checkChecksumDesync();
    if (n.desync_detected or n.checksum_desync_detected) {
        state.log.?.err("Desync detected (synchash={} checksum={}) at index={d} frame={d} — force-exiting match", .{
            n.desync_detected, n.checksum_desync_detected,
            n.indexed_frame.index, n.indexed_frame.frame,
        });
        if (n.checksum_desync_detected) {
            state.log.?.err("  -> per-frame checksum: frame={d} local=0x{x:0>4} remote=0x{x:0>4} (RNG-only hash)", .{
                n.checksum_desync_frame, n.checksum_desync_local, n.checksum_desync_remote,
            });
        }
        if (n.desync_detected) {
            state.log.?.err("  -> SyncHash: see prior 'Desync between' log for MD5/timer/camera/chara details", .{});
        }
        state.alive_flag_addr.* = 0;
        return;
    }

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] after desync checks: isRemoteInputReady={}", .{n.isRemoteInputReady()});
    }

    // Surface network errors (10+ consecutive send failures). Don't
    // force-exit — ENet will recover if the connection is just congested.
    // The heartbeat timeout (120s) handles true disconnects.
    //
    // Throttle to once per 60 frames (1/sec) to avoid log flooding (M2 fix).
    // Without throttling, a degraded connection would log 60 warnings/sec.
    if (n.network_error and n.indexed_frame.frame % 60 == 0) {
        state.log.?.warn("Network send failures detected ({d} consecutive) — connection may be degraded", .{
            n.consecutive_send_failures,
        });
    }

    if (n.was_connected and !n.enet_connected and n.config.is_netplay) {
        state.log.?.err("Peer disconnected during game!", .{});
        state.alive_flag_addr.* = 0; // force exit
        return;
    }

    // Heartbeat check: if no packet received in 120s, the peer is dead.
    // This catches crashes/kills that don't generate a DISCONNECT event.
    if (n.enet_connected and n.checkHeartbeat()) {
        state.log.?.err("Peer heartbeat timeout (120s no packets) — forcing disconnect", .{});
        n.enet_connected = false;
        state.alive_flag_addr.* = 0;
        return;
    }

    // Lockstep wait for the remote's input.
    //
    // CCCaster's wait loop (DllMain.cpp:540-581) runs unconditionally inside
    // `frameStepNormal()` — it does NOT skip when the socket is disconnected.
    // When the remote hasn't connected yet, `isRemoteInputReady()` returns
    // false (the remote input container is empty), so the loop blocks the
    // game's main thread until the remote connects AND sends its first
    // `PlayerInputs` for the current transition index. This is the mechanism
    // that prevents the "fast peer enters gameplay before slow peer" desync:
    // the faster peer's game freezes on InGame frame 0.
    //
    // The previous zzcaster code short-circuited this with:
    //   if (!n.enet_connected) { n.writeGameInputs(); return; }
    // which let the game run at FULL SPEED with no synchronization whenever
    // ENet hadn't connected yet. This was the root cause of the user's bug:
    // the lazy ENet reconnect (frame_step.zig:18-36) takes up to 15s, and if
    // either peer reached InGame frame 0 during that window, the game would
    // advance without waiting for the remote peer — causing the match to
    // terminate or desync immediately.
    //
    // The fix: enter the wait loop unconditionally. The loop already polls
    // ENet via `pollAndDispatch(10)`, which processes CONNECT events and
    // establishes the connection.
    //
    // TIMEOUT POLICY:
    // The 10s hard timeout (matching CCCaster's MAX_WAIT_INPUTS_INTERVAL)
    // only fires when the remote peer has ALREADY reached the same transition
    // index as the local peer but isn't sending frames — this indicates a
    // real connectivity problem (peer crashed, packet loss, etc.).
    //
    // If the remote peer is still in an EARLIER transition index (i.e., still
    // loading while the local peer has already reached InGame), the timeout
    // does NOT fire. The faster peer's game simply freezes on InGame frame 0
    // and waits for the slower peer to finish loading and catch up. This is
    // the behavior the user described: "the player that loaded first should
    // have their thread paused until the other catches up". A slow machine
    // can take 15-30s to load, and terminating the session in that window
    // would be incorrect — the slower peer is still making progress, just
    // hasn't reached InGame yet.
    //
    // We detect "remote is still in an earlier state" by checking whether
    // `remote_inputs.getEndIndex()` (which reflects the highest transition
    // index the remote has sent inputs for) is less than the local peer's
    // current `indexed_frame.index`. When the remote sends its
    // `TransitionIndex` for InGame, `setRemoteIndex` → `resizeOuter` bumps
    // `end_index` to InGame+1, so this check correctly transitions from
    // "still loading" to "at InGame, awaiting frames" when the remote
    // finishes loading.
    if (!n.isRemoteInputReady()) {
        if (is_first_frame_of_in_game) {
            state.log.?.info("[DIAG] entering lockstep wait loop (isRemoteInputReady=false)", .{});
        }
        const wait_start = std.Io.Clock.now(.real, state.app_io_backend.io()).toMilliseconds();
        var connected_since: i64 = 0; // 0 = not yet connected
        var remote_at_index_since: i64 = 0; // 0 = remote hasn't reached our index yet
        var last_resend = wait_start;
        var warned = false;
        while (!n.isRemoteInputReady()) {
            n.pollAndDispatch(10);
            const now = std.Io.Clock.now(.real, state.app_io_backend.io()).toMilliseconds();

            // Track when ENet first connected so timeouts that depend on
            // connectivity don't fire during the lazy-reconnect window.
            if (connected_since == 0 and n.enet_connected) {
                connected_since = now;
            }

            // Track when the remote peer first reached our transition index.
            // The 10s input-wait timeout only starts counting from this point.
            // Before this, the remote is still in an earlier state (Loading,
            // CharaIntro, etc.) and we wait for them to catch up without a
            // hard timeout — a slow machine can take 30s+ to load.
            const remote_end_index = if (n.remote_inputs.getEndIndex() > 0)
                n.remote_inputs.getEndIndex() - 1
            else
                0;
            if (remote_at_index_since == 0 and remote_end_index >= n.indexed_frame.index) {
                remote_at_index_since = now;
                state.log.?.info("Remote reached transition index {d} — starting 10s input-wait countdown", .{
                    n.indexed_frame.index,
                });
            }

            if (now - last_resend > 100) {
                n.sendLocalInputs();
                last_resend = now;
            }

            // Re-attempt RNG sync inside the wait loop. Two reasons:
            //   1. The host's first `syncRngState()` (called earlier in
            //      frameStepNetplay) may have bailed because ENet wasn't
            //      connected yet. By the time we're in this wait loop,
            //      `pollAndDispatch(10)` may have just established the
            //      connection — without this call the host would never
            //      send the RNG and both sides would deadlock.
            //   2. The client is now blocking on `rng_synced` (see
            //      `isRemoteInputReady`), so the host MUST be able to
            //      (re-)send the RNG packet from inside this loop.
            // `syncRngState` is idempotent: it no-ops once `rng_acked`
            // is set, and `applyRemoteRng` is idempotent once
            // `rng_synced` is set, so calling it on every loop iteration
            // is safe. The internal `rng_send_cooldown` (30 frames)
            // throttles re-sends to ~300ms intervals inside this loop.
            n.syncRngState();

            if (n.was_connected and !n.enet_connected) {
                state.log.?.err("Peer disconnected while waiting for input!", .{});
                state.alive_flag_addr.* = 0;
                return;
            }

            if (n.enet_connected and n.checkHeartbeat()) {
                state.log.?.err("Peer heartbeat timeout during input wait", .{});
                n.enet_connected = false;
                state.alive_flag_addr.* = 0;
                return;
            }

            if (!warned and now - wait_start > 5000) {
                state.log.?.warn("Waiting for remote input... (5s elapsed, enet_connected={}, remote_end_index={d}, local_index={d})", .{
                    n.enet_connected, remote_end_index, n.indexed_frame.index,
                });
                warned = true;
            }

            // TIMEOUT: 10s after the remote peer reached our transition index
            // without sending any inputs for the current frame. This matches
            // CCCaster's MAX_WAIT_INPUTS_INTERVAL (10s).
            //
            // This timeout ONLY fires when the remote has confirmed it reached
            // our index (via TransitionIndex → resizeOuter) but hasn't sent any
            // PlayerInputs for this frame. That indicates a real problem:
            //   - The remote's game crashed after entering InGame
            //   - Severe packet loss preventing PlayerInputs from arriving
            //   - The remote is stuck in a bad state
            //
            // If the remote is STILL LOADING (remote_end_index < local_index),
            // this timeout does NOT fire — we keep waiting. The slower peer
            // will eventually finish loading, send TransitionIndex for InGame,
            // and then the 10s countdown begins.
            if (remote_at_index_since != 0 and now - remote_at_index_since > 10000) {
                state.log.?.err("Timed out waiting for remote input (10s after remote reached index {d}) — forcing exit", .{
                    n.indexed_frame.index,
                });
                state.alive_flag_addr.* = 0;
                return;
            }

            // If the lazy reconnect gave up (connect_attempts_exhausted) and
            // we still don't have a connection, the peer is unreachable. Don't
            // block the game forever — force-exit so the user sees a clean
            // termination instead of a permanent hang.
            if (n.connect_attempts_exhausted and !n.enet_connected) {
                state.log.?.err("ENet reconnect exhausted and peer unreachable — forcing exit", .{});
                state.alive_flag_addr.* = 0;
                return;
            }
        }
        if (is_first_frame_of_in_game) {
            state.log.?.info("[DIAG] exited lockstep wait loop", .{});
        }
    }

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] before checkRollback: isInRollback={} rollback_timer={d} min_spacing={d}", .{
            n.isInRollback(), n.rollback_timer, n.min_rollback_spacing,
        });
    }

    // Cooperative time-sync: if we're ahead of the remote peer, sleep a
    // small amount to slow the game down. This lets the remote catch up.
    //
    // The game's frame loop is synchronous — frameStepNetplay is called once
    // per frame and the game waits for it to return. Sleeping here delays
    // the game's frame, which slows world_timer (the game's internal frame
    // counter at 0x55D1D4), which slows our indexed_frame.frame. The remote
    // peer (running at full 60fps) simulates faster, catches up, and the
    // advantage decreases.
    //
    // The sleep is capped at 4ms/frame (~24% of the 16.6ms budget) to stay
    // safely within vsync. We only sleep when:
    //   - We're in-game (not during loading/menus)
    //   - Not during a rollback re-run (we're catching up, not slowing down)
    //   - RTT is initialized (advantage is meaningful)
    //   - We're significantly ahead (advantage < -min_frame_advantage)
    //
    // This is the same mechanism as the lockstep wait above — both block the
    // game thread. The difference: lockstep waits for a specific remote input,
    // time-sync sleeps a small fixed amount to drift toward alignment.
    if (n.state == .in_game and !n.isRerunning()) {
        const sleep_ms = n.recommendPerFrameSleepMs();
        if (sleep_ms > 0) {
            std.Io.sleep(state.app_io_backend.io(), .{
                .nanoseconds = sleep_ms * std.time.ns_per_ms,
            }, .real) catch {};
        }
    }

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] calling checkRollback...", .{});
    }
    const rollback_triggered = n.checkRollback();
    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] checkRollback returned {} fast_fwd_stop_frame={d}", .{
            rollback_triggered, n.fast_fwd_stop_frame,
        });
    }

    if (rollback_triggered) {
        state.skip_frames_addr.* = 1;
        return;
    }

    if (n.isRerunning()) {
        // During a rollback re-run, the game still reads inputs from its
        // input buffer each frame. We MUST write the corrected local +
        // remote inputs to the game's input struct so the re-run replays
        // with the actual inputs (not the stale predicted ones that were
        // saved into the StatePool snapshot). Without this, the entire
        // point of rollback — re-simulating with corrected inputs — is
        // defeated.
        //
        // The legacy CCCaster calls writeGameInputs at the end of every
        // frame, including re-run frames (DllMain.cpp's `frameStep` calls
        // either `frameStepRerun` or `frameStepNormal` based on
        // `fastFwdStopFrame`, then unconditionally writes inputs at lines
        // 988-989). The Zig port's early `return` here was a regression
        // that broke rollback correctness.
        n.writeGameInputs();
        if (n.checkRerunComplete()) {
            // Rerun completed on this frame. Fall through to normal frame logic so the frame
            // is saved, spectator packets are sent, etc.
        } else {
            // Rerun still in progress. Save state for this re-simulated frame so we have
            // correct intermediate checkpoints.
            const save_ok = n.state_pool.saveState(n.indexed_frame.frame, n.indexed_frame.index, n.start_world_time);
            // Record the re-simulated frame's checksum ONLY if the save succeeded.
            // saveState returns null on overflow/OOM; in that case saved_states[len-1]
            // is the PREVIOUS state (wrong frame), and recording its checksum would
            // cause a false desync. This OVERWRITES the wrong (pre-rollback) checksum
            // in pending_checksums for this frame — the re-run produces the authoritative
            // state, so its checksum is the one we want to send and compare.
            if (save_ok != null and n.state_pool.saved_states.items.len > 0) {
                const last_state = n.state_pool.saved_states.items[n.state_pool.saved_states.items.len - 1];
                n.recordLocalChecksum(n.indexed_frame.frame, last_state.checksum);
            }
            return;
        }
    }

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] after rerun check: isRerunning={} rollback_timer={d}", .{
            n.isRerunning(), n.rollback_timer,
        });
    }

    if (n.rollback_timer < n.min_rollback_spacing) {
        n.rollback_timer +%= 1;
        if (n.rollback_timer == 0) n.rollback_timer = n.min_rollback_spacing;
    }

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] before saveState: state_size={d} pool_len={d} coalesced_regions={d}", .{
            n.state_pool.state_size, n.state_pool.pool.len, n.state_pool.coalesced_regions.items.len,
        });
    }

    const save_ok = n.state_pool.saveState(n.indexed_frame.frame, n.indexed_frame.index, n.start_world_time);

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] after saveState: save_ok={} saved_states_len={d}", .{
            save_ok != null, n.state_pool.saved_states.items.len,
        });
    }
    // Record the per-frame checksum ONLY if the save succeeded (H2 fix).
    // saveState returns null on overflow/OOM; reading saved_states[len-1]
    // in that case would give us the PREVIOUS frame's checksum, causing a
    // false desync when the remote compares against it.
    if (save_ok != null and n.state_pool.saved_states.items.len > 0) {
        const last_state = n.state_pool.saved_states.items[n.state_pool.saved_states.items.len - 1];
        n.recordLocalChecksum(n.indexed_frame.frame, last_state.checksum);
    }
    // Snapshot SFX filter into history ring (for future rollback dedup).
    if (n.sfx_dedup) |*sd| sd.snapshotToHistory(n.indexed_frame.frame);

    // Garbage-collect old checksums every 30 frames to bound memory.
    if (n.indexed_frame.frame % 30 == 0) {
        n.discardOldChecksums();
    }

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] before writeGameInputs", .{});
    }
    n.writeGameInputs();

    if (is_first_frame_of_in_game) {
        state.log.?.info("[DIAG] after writeGameInputs — frame complete", .{});
    }

    if (n.config.is_host and n.spectators != null) {
        n.spectators.?.frameStepSpectators(
            n.indexed_frame.index,
            n.indexed_frame.frame,
            world_timer,
            state.fillBothInputsCallback,
            state.getCachedRngCallback,
        );
    }
}

// P2 input falls back to 0 when reader2 is null (netplay/spectator modes, or
// no [Player2] mapping saved). MBAA's config table is single-player, so there
// is no legacy keyboard reader for P2.
fn frameStepOffline(game_mode: u32) void {
    const p1_input: u16 = blk: {
        if (state.reader) |*r| {
            r.update();
            if (r.hasGamepad()) break :blk r.readInput();
        }
        break :blk keyboard.readInput();
    };
    const p2_input: u16 = blk: {
        if (state.reader2) |*r| {
            r.update();
            if (r.hasGamepad()) break :blk r.readInput();
        }
        break :blk 0;
    };

    var p1_out = p1_input;
    var p2_out = p2_input;
    if (game_mode == mode_in_game) {
        const r1 = state.air_dash_macro_p1.step(p1_input);
        if (r1.triggered) {
            state.log.?.info("AirDashMacro(P1): {d}AB -> jump {d} + dash {d}AB", .{
                r1.output, r1.output, state.air_dash_macro_p1.dash_dir,
            });
        }
        const r2 = state.air_dash_macro_p2.step(p2_input);
        if (r2.triggered) {
            state.log.?.info("AirDashMacro(P2): {d}AB -> jump {d} + dash {d}AB", .{
                r2.output, r2.output, state.air_dash_macro_p2.dash_dir,
            });
        }
        p1_out = r1.output;
        p2_out = r2.output;
    } else {
        state.air_dash_macro_p1.reset();
        state.air_dash_macro_p2.reset();
    }

    state.writeInput(1, p1_out);
    state.writeInput(2, p2_out);

    state.input_log_frame +%= 1;
    if (state.input_log_frame % 300 == 0) {
        state.log.?.info("InputFrame {d}: P1=0x{x:0>4} P2=0x{x:0>4} mode={d}", .{
            state.input_log_frame, p1_out, p2_out, game_mode,
        });
    }
}

// Suppress unused-import warning for gamepad — the type is referenced
// indirectly through `state.reader` (which is `?gamepad.GamepadReader`), but
// Zig's import graph still wants to see a direct use when the module is
// pulled in via `@import`. Keep the import alive with a comptime noop.
comptime {
    _ = gamepad;
}

// Game mode code for "in-game" (matches mode_in_game in dllmain.zig /
// netplay_manager.zig). The offline macro only runs during actual gameplay —
// in chara-select/menus a 9AB press means nothing and would just corrupt
// menu navigation if rewritten.
const mode_in_game: u32 = 1;
