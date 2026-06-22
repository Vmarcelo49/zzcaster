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

    // Lockstep wait for the remote's input. Skipped entirely while still
    // connecting (the lazy-reconnect block above handles that). After connect,
    // force-exit after 10s (matches CCCaster's MAX_WAIT_INPUTS_INTERVAL).
    if (!n.enet_connected) {
        n.writeGameInputs();
        return;
    }

    if (!n.isRemoteInputReady()) {
        const wait_start = std.Io.Clock.now(.real, state.app_io_backend.io()).toMilliseconds();
        var last_resend = wait_start;
        var warned = false;
        while (!n.isRemoteInputReady()) {
            n.pollAndDispatch(10);
            const now = std.Io.Clock.now(.real, state.app_io_backend.io()).toMilliseconds();

            if (now - last_resend > 100) {
                n.sendLocalInputs();
                last_resend = now;
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
                state.log.?.warn("Waiting for remote input... (5s elapsed)", .{});
                warned = true;
            }

            // TIMEOUT after 10s — force exit (matches CCCaster)
            if (now - wait_start > 10000) {
                state.log.?.err("Timed out waiting for remote input (10s) — forcing exit", .{});
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
