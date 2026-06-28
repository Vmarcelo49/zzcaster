// In-game / chara-select frame dispatch. dllmain.frameStep handles the
// early-out / pre-game / SFX-clear logic and routes here once the game is
// past those: lazy ENet reconnect, host-side spectator drain, then dispatch
// to frameStepSpectator / frameStepNetplay / frameStepOffline.
const std = @import("std");
const netman = @import("netplay_manager.zig");
const keyboard = @import("keyboard.zig");
const gamepad = @import("gamepad.zig");
const state = @import("dll_state.zig");
const builtin = @import("builtin");

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

    // Per-frame clearLastChangedFrame (matches CCCaster's behavior).
    // CCCaster clears lastChangedFrame every frame when the rollback timer
    // allows, BEFORE receiving new inputs. This prevents a stale lcf from a
    // previous frame's setRemote from triggering a late spurious rollback.
    // zzcaster only cleared lcf inside checkRollback, so stale lcfs persisted.
    if (n.rollback_timer == n.min_rollback_spacing) {
        n.remote_inputs.clearLastChanged();
    }

    n.pollAndDispatch(3);

    // Update RTT EMA every frame (reads ENet's peer.roundTripTime).
    // Feeds the time-sync recommendation below.
    n.updateRttEma();

    // Cooperative time-sync: if we're ahead of the remote peer, sleep a
    // small amount to slow the game down. This lets the remote catch up
    // and reduces the frequency of rollbacks. The sleep is capped at 4ms
    // (~24% of the 16.6ms frame budget) to stay within vsync.
    //
    // Only applies during in_game (not during loading/menus) and not during
    // a rollback re-run (we're catching up, not slowing down).
    if (n.state == .in_game and !n.isRerunning()) {
        const sleep_ms = n.recommendPerFrameSleepMs();
        if (sleep_ms > 0) {
            std.Io.sleep(state.app_io_backend.io(), .{
                .nanoseconds = sleep_ms * std.time.ns_per_ms,
            }, .real) catch {};
        }
    }

    n.maybeSendSyncHash();
    n.checkSyncHashDesync();
    if (n.desync_detected) {
        state.log.?.err("Desync detected — force-exiting match", .{});
        state.alive_flag_addr.* = 0;
        return;
    }

    if (n.was_connected and !n.enet_connected and n.config.is_netplay) {
        if (n.version_mismatch) {
            state.log.?.err("Protocol version mismatch — force-exiting", .{});
        } else {
            state.log.?.err("Peer disconnected during game!", .{});
        }
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

    // Lockstep wait: block until the remote peer has sent input for the
    // current frame. The faster peer's game freezes here until the slower
    // peer catches up. 30s timeout only fires after the remote reaches our
    // transition index but stops sending frames (crash/packet loss).
    if (!n.isRemoteInputReady()) {
        const wait_start = std.Io.Clock.now(.real, state.app_io_backend.io()).toMilliseconds();
        var connected_since: i64 = 0; // 0 = not yet connected
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
            //
            // The timestamp lives on the manager (not as a loop local) so it
            // survives wait-loop re-entries: isRemoteInputReady() can flip
            // true when a packet arrives, exiting this loop for one frame,
            // then re-entering it next frame. A loop-local would reset to 0
            // each re-entry, spamming the log and never accumulating the
            // timeout. markRemoteReachedIndex returns non-null only on the
            // first arm per transition index, so the log fires exactly once.
            const remote_end_index = if (n.remote_inputs.getEndIndex() > 0)
                n.remote_inputs.getEndIndex() - 1
            else
                0;
            if (remote_end_index >= n.indexed_frame.index) {
                if (n.markRemoteReachedIndex(now)) |_| {
                    state.log.?.info("Remote reached transition index {d} — starting 10s input-wait countdown", .{
                        n.indexed_frame.index,
                    });
                }
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

            // Pump Windows messages to keep the window responsive and prevent OS hang detection
            if (builtin.os.tag == .windows) {
                var msg: win32.MSG = undefined;
                while (win32.PeekMessageA(&msg, null, 0, 0, 1) != 0) {
                    _ = win32.TranslateMessage(&msg);
                    _ = win32.DispatchMessageA(&msg);
                }
            }

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

            // TIMEOUT: 10s during active gameplay, 30s during loading screens.
            // Helps prevent indefinite freezes when the remote peer crashes/terminates
            // without sending a disconnect packet, while still allowing generous load times.
            const is_in_game_active = (n.state == .in_game and n.indexed_frame.frame > 0);
            const timeout_limit: i64 = if (is_in_game_active) 10000 else 30000;

            if (is_in_game_active) {
                if (now - wait_start > timeout_limit) {
                    state.log.?.err("Timed out waiting for remote input ({}s elapsed in-game) — forcing exit", .{
                        @divTrunc(timeout_limit, 1000),
                    });
                    state.alive_flag_addr.* = 0;
                    return;
                }
            } else {
                const remote_at_index_since = n.inputWaitRemoteAtIndexSinceMs();
                if (remote_at_index_since != 0 and now - remote_at_index_since > timeout_limit) {
                    state.log.?.err("Timed out waiting for remote input ({}s after remote reached index {d}) — forcing exit", .{
                        @divTrunc(timeout_limit, 1000),
                        n.indexed_frame.index,
                    });
                    state.alive_flag_addr.* = 0;
                    return;
                }
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
        n.writeGameInputs();
        if (n.checkRerunComplete()) {
            // Rerun completed on this frame. Fall through to normal frame logic so the frame
            // is saved, spectator packets are sent, etc.
        } else {
            // Rerun still in progress. Do NOT save state here — CCCaster
            // deliberately does NOT save re-run states ("the inputs are
            // faked" — DllMain.cpp:923). Saving potentially-wrong re-run
            // states poisons the pool; a second rollback loading a poisoned
            // state propagates the error. Just return and let the next
            // frame continue the re-run.
            return;
        }
    }

    if (n.rollback_timer < n.min_rollback_spacing) {
        n.rollback_timer +%= 1;
        if (n.rollback_timer == 0) n.rollback_timer = n.min_rollback_spacing;
    }

    // Only save rollback states in-game — matches CCCaster (DllMain.cpp:206-207,
    // "Only save rollback states in-game").
    if (n.state == .in_game) {
        _ = n.state_pool.saveState(n.indexed_frame.frame, n.indexed_frame.index, @intFromEnum(n.state), n.start_world_time);
        // Snapshot SFX filter into history ring (for future rollback dedup).
        if (n.sfx_dedup) |*sd| sd.snapshotToHistory(n.indexed_frame.frame);
    }

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

const win32 = struct {
    const HWND = ?*anyopaque;
    const UINT = u32;
    const WPARAM = usize;
    const LPARAM = usize;
    const POINT = struct {
        x: i32,
        y: i32,
    };
    const MSG = struct {
        hwnd: HWND,
        message: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
        time: u32,
        pt: POINT,
    };

    extern "user32" fn PeekMessageA(lpMsg: *MSG, hWnd: HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT, wRemoveMsg: UINT) callconv(.winapi) i32;
    extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) i32;
    extern "user32" fn DispatchMessageA(lpMsg: *const MSG) callconv(.winapi) isize;
};
