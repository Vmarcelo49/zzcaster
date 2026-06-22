// frame_step.zig — in-game / chara-select frame dispatch helpers, extracted
// from dllmain.zig (task 2b).
//
// The DLL's per-frame callback `frameStep` lives in dllmain.zig and handles
// the early-out / pre-game / SFX-clear logic. Once those early checks pass
// (the game is in `mode_in_game` or `mode_main`/chara-select), control
// routes here via `frameStepInGame`, which:
//
//   1. performs the lazy ENet reconnect poll (deferred from DllMain so the
//      game's main thread keeps ticking during connect);
//   2. lets the host drain spectator events;
//   3. dispatches to one of:
//        - frameStepSpectator — both players' inputs come from the host.
//        - frameStepNetplay   — local player reads input, lockstep-waits
//                               for remote input, runs rollback check.
//        - frameStepOffline   — both players' inputs read locally (no nm).
//
// All shared state (log, nm, reader, reader2, app_io_backend, alive_flag,
// skip_frames, input_log_frame) lives in dll_state.zig and is reached via
// `@import("dll_state.zig")` — one-directional, no circular import.
const std = @import("std");
const netman = @import("netplay_manager.zig");
const keyboard = @import("keyboard.zig");
const gamepad = @import("gamepad.zig");
const state = @import("dll_state.zig");

// === In-game dispatch (called from dllmain.frameStep at end) ===
//
// Sets skip_frames=0, runs the lazy ENet reconnect + host-side spectator
// drain, then routes to spectator / netplay / offline helpers. All
// early-`return`s inside the helpers are equivalent to the original
// inline `return`s from frameStep — frameStep has no code after this
// helper returns, so exiting the helper == exiting frameStep.
pub fn frameStepInGame(world_timer: u32, game_mode: u32) void {
    state.skip_frames_addr.* = 0;

    if (state.nm) |*n| {
        // If ENet isn't connected yet (connection setup was deferred from
        // DllMain so the main thread can keep ticking), poll for the
        // connect event here with a short timeout.
        //
        // The launcher already validated the peer via its own handshake
        // before opening the game, so this reconnect should succeed in
        // well under a second. We cap at ~15s (300 × 50ms) — if the peer
        // doesn't reconnect by then something is genuinely wrong (firewall
        // killed the post-launch UDP path, or the peer's game crashed).
        if (!n.enet_connected and !n.connect_attempts_exhausted) {
            if (n.connect_attempts == 0) {
                state.log.?.info("ENet reconnecting (peer already confirmed by launcher)...", .{});
            }
            n.connect_attempts += 1;
            n.pollAndDispatch(50);
            if (!n.enet_connected and n.connect_attempts > 300) {
                // Stage-0 diag (netcode-test-plan.md Stage 0.3): distinguish
                // "no peer ever responded" (silent timeout) from "the peer
                // actively refused us" (disconnects observed) from "we
                // received unexpected packets instead of a CONNECT". The
                // diag_* counters are maintained in pollEnet and reset
                // only on a successful connect — so their values here are
                // exactly what we saw across the ~15s connect window.
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

        // === HOST: drain spectator events (accept new spectators, timeouts) ===
        if (n.config.is_host and n.enet_connected) {
            n.drainSpectatorEvents();
        }

        if (n.config.is_spectator) {
            frameStepSpectator(n);
            return;
        }

        // === NORMAL NETPLAY MODE (player 1 host or player 2 client) ===
        frameStepNetplay(n, world_timer);
        return;
    } else {
        // === OFFLINE MODE ===
        frameStepOffline(game_mode);
        return;
    }
}

// === SPECTATOR MODE ===
// No local input reading — both players' inputs come from the host.
fn frameStepSpectator(n: *netman.NetplayManager) void {
    n.updateFrame();

    // Poll for BothInputs packet from host via pollAndDispatch,
    // which routes type 0x20 to applyBothInputsPacket internally.
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

// === NORMAL NETPLAY MODE (player 1 host or player 2 client) ===
fn frameStepNetplay(n: *netman.NetplayManager, world_timer: u32) void {
    // Read local input
    const raw_input: u16 = blk: {
        if (state.reader) |*r| {
            r.update();
            if (r.hasGamepad()) break :blk r.readInput();
        }
        break :blk keyboard.readInput();
    };

    // Apply per-state input filtering (catch-up mash, mask Cancel in
    // chara-select, only Confirm/Cancel in loading/intro/skippable).
    // This is the Zig equivalent of CCCaster's getInput(player) dispatch.
    var local_input: u16 = n.getNetplayInput(raw_input);

    // Air Dash Macro: runs AFTER state filtering and BEFORE setLocalInput, so
    // the expanded jump→dash sequence is what enters the InputBuffer, gets sent
    // to the peer, and is replayed by rollback re-runs (design doc §3, §5).
    // Only active in-game; outside of in-game we reset so a pending dash can't
    // fire on the first frame of the next round.
    if (n.state == .in_game) {
        const r = n.air_dash_macro.step(local_input);
        if (r.triggered) {
            // r.output is the bare jump diagonal (9 or 7); dash_dir (6 or 4)
            // is what the macro will inject next frame. Log both for debugging
            // desync reports (design doc §5.5).
            state.log.?.info("AirDashMacro: {d}AB -> jump {d} + dash {d}AB at frame {d}", .{
                r.output, r.output, n.air_dash_macro.dash_dir, n.indexed_frame.frame,
            });
        }
        local_input = r.output;
    } else {
        n.air_dash_macro.reset();
    }

    n.updateFrame();

    // Set local input (with delay)
    n.setLocalInput(local_input);

    // Send local inputs to peer
    n.sendLocalInputs();

    // Sync RNG (host only, once per round — onStateTransition resets
    // rng_synced so the host re-sends at the start of each round).
    n.syncRngState();

    // Poll for remote messages (inputs, RNG, TransitionIndex)
    n.pollAndDispatch(3);

    // SyncHash desync detection. Snapshot + send on the legacy cadence,
    // then compare any paired local/remote hashes. If a mismatch is
    // found, the game force-exits (matches legacy delayedStop).
    // Additive only — does not affect input/state handling.
    n.maybeSendSyncHash();
    n.checkSyncHashDesync();
    if (n.desync_detected) {
        state.log.?.err("Desync detected — force-exiting match", .{});
        state.alive_flag_addr.* = 0;
        return;
    }

    // Check for disconnect — only if we WERE connected and now aren't.
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

    // Wait for remote inputs. This is the lockstep gate: the game
    // frame cannot advance until we have the remote's input for
    // (our_index, our_frame + delay). While waiting, we keep polling
    // and periodically resend our inputs (in case of packet loss).
    //
    // This blocks the game's main thread — that's intentional and
    // correct for lockstep netcode. On localhost the wait is
    // sub-frame; over the internet it introduces jitter equal to the
    // ping.
    //
    // CONNECTING: if ENet isn't connected yet, skip the input-wait
    // entirely. The lazy-reconnect block above (with its own 15s
    // timeout) handles the connect phase. Without this guard, the
    // 10s input-wait timeout fires while we're still waiting for the
    // peer's DLL to load+bind, force-exiting the game before the
    // reconnect ever completes. frameStep will loop back and do
    // another 50ms reconnect poll next frame.
    //
    // TIMEOUT: once connected, if the remote doesn't respond within
    // 10s (matching CCCaster's MAX_WAIT_INPUTS_INTERVAL), we force-exit
    // instead of hanging forever.
    if (!n.enet_connected) {
        // Still connecting — don't enter the input-wait loop. Just
        // write our (zeroed) inputs and return so the next frameStep
        // iteration does another reconnect poll.
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

            // Resend inputs every 100ms while waiting (matches
            // legacy RESEND_INPUTS_INTERVAL).
            if (now - last_resend > 100) {
                n.sendLocalInputs();
                last_resend = now;
            }

            // Check for disconnect during wait
            if (n.was_connected and !n.enet_connected) {
                state.log.?.err("Peer disconnected while waiting for input!", .{});
                state.alive_flag_addr.* = 0;
                return;
            }

            // Heartbeat check during wait
            if (n.enet_connected and n.checkHeartbeat()) {
                state.log.?.err("Peer heartbeat timeout during input wait", .{});
                n.enet_connected = false;
                state.alive_flag_addr.* = 0;
                return;
            }

            // Log after 5s but keep waiting
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

    // Check rollback
    if (n.checkRollback()) {
        state.skip_frames_addr.* = 1;
        return;
    }

    // Check rerun completion
    if (n.isRerunning()) {
        _ = n.checkRerunComplete();
        return;
    }

    // Decrement rollback timer
    if (n.rollback_timer < n.min_rollback_spacing) {
        n.rollback_timer +%= 1;
        if (n.rollback_timer == 0) n.rollback_timer = n.min_rollback_spacing;
    }

    // Save state for this frame
    _ = n.state_pool.saveState(n.indexed_frame.frame, n.indexed_frame.index);
    // Snapshot SFX filter into history ring (for future rollback dedup).
    if (n.sfx_dedup) |*sd| sd.snapshotToHistory(n.indexed_frame.frame);

    // Write both players' inputs
    n.writeGameInputs();

    // === HOST: broadcast BothInputs to spectators ===
    if (n.config.is_host and n.spectators != null) {
        n.spectators.?.frameStepSpectators(
            n.indexed_frame.index,
            n.indexed_frame.frame,
            world_timer,
            state.fillBothInputsCallback,
        );
    }
}

// === OFFLINE MODE ===
// P1 input — uses reader (with custom_mapping from [Player1]),
// falling back to the legacy keyboard reader only if reader is
// null/uninitialized. The legacy keyboard.readInput() polls
// MBAA.exe's built-in config at offset 0x14D2C0 — it's a
// last-resort fallback, not the primary path.
//
// P2 input — uses reader2 (with custom_mapping from [Player2]).
// reader2 is null in netplay/spectator modes (P2 input comes
// from the network there) and may be null if the user never
// saved a [Player2] section in mapping.ini. When null, P2 stays
// at neutral (0) — there's no legacy keyboard reader for P2
// because MBAA.exe's config table is single-player.
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

    // Air Dash Macro (offline): transform each local player's input before it
    // reaches the game. Only in gameplay; outside of in-game we reset the
    // state machines so a pending dash can't leak into the next round/match.
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

    // Periodic diagnostic: log P1/P2 input values every 300 frames
    // (~5s at 60fps). If p1_input is always 0 even when the user
    // presses keys, the binding poll is failing — check whether
    // reader.custom_mapping loaded correctly (see InputDiag above).
    // If p1_input is non-zero but the game still doesn't respond,
    // the issue is in writeInput (wrong base ptr, wrong offsets, or
    // MBAA's own polling clobbering our writes).
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
