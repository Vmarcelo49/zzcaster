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

    n.setLocalInput(local_input);

    n.sendLocalInputs();

    n.syncRngState();

    n.pollAndDispatch(3);

    n.maybeSendSyncHash();
    n.checkSyncHashDesync();
    if (n.desync_detected) {
        state.log.?.err("Desync detected — force-exiting match", .{});
        state.alive_flag_addr.* = 0;
        return;
    }

    if (n.was_connected and !n.enet_connected and n.config.is_netplay) {
        state.log.?.err("Peer disconnected during game!", .{});
        state.alive_flag_addr.* = 0; // force exit
        return;
    }

    // Heartbeat check: if no packet received in 20s, the peer is dead.
    // This catches crashes/kills that don't generate a DISCONNECT event.
    if (n.enet_connected and n.checkHeartbeat()) {
        state.log.?.err("Peer heartbeat timeout (20s no packets) — forcing disconnect", .{});
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
    // establishes the connection. The 10s hard timeout only starts counting
    // AFTER ENet connects — before that, the wait is bounded by the 15s
    // lazy-reconnect cap (frame_step.zig:24). This matches CCCaster's
    // behavior: the 10s `MAX_WAIT_INPUTS_INTERVAL` is a timeout on remote
    // INPUT, not on socket connectivity.
    if (!n.isRemoteInputReady()) {
        const wait_start = std.Io.Clock.now(.real, state.app_io_backend.io()).toMilliseconds();
        var connected_since: i64 = 0; // 0 = not yet connected
        var last_resend = wait_start;
        var warned = false;
        while (!n.isRemoteInputReady()) {
            n.pollAndDispatch(10);
            const now = std.Io.Clock.now(.real, state.app_io_backend.io()).toMilliseconds();

            // Track when ENet first connected so the 10s input-wait timeout
            // only counts time AFTER connectivity is established. This prevents
            // the timeout from firing while the lazy reconnect is still in
            // progress (up to 15s), which would kill the match before the peer
            // even has a chance to connect.
            if (connected_since == 0 and n.enet_connected) {
                connected_since = now;
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
            //      send the RNG and both sides would deadlock until the
            //      10s timeout fires.
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
                state.log.?.warn("Waiting for remote input... (5s elapsed, enet_connected={})", .{
                    n.enet_connected,
                });
                warned = true;
            }

            // TIMEOUT after 10s of ENet connectivity without remote input —
            // force exit (matches CCCaster's MAX_WAIT_INPUTS_INTERVAL).
            //
            // The timeout only fires AFTER ENet has connected. If ENet is
            // still in the lazy-reconnect window (up to 15s), we keep waiting
            // — the reconnect cap (frame_step.zig:24) will eventually either
            // connect or exhaust attempts, at which point the next iteration
            // will either get remote input or hit this timeout.
            if (connected_since != 0 and now - connected_since > 10000) {
                state.log.?.err("Timed out waiting for remote input (10s after connect) — forcing exit", .{});
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
    }

    if (n.checkRollback()) {
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
        _ = n.checkRerunComplete();
        return;
    }

    if (n.rollback_timer < n.min_rollback_spacing) {
        n.rollback_timer +%= 1;
        if (n.rollback_timer == 0) n.rollback_timer = n.min_rollback_spacing;
    }

    _ = n.state_pool.saveState(n.indexed_frame.frame, n.indexed_frame.index);
    // Snapshot SFX filter into history ring (for future rollback dedup).
    if (n.sfx_dedup) |*sd| sd.snapshotToHistory(n.indexed_frame.frame);

    n.writeGameInputs();

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
