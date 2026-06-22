// ui_waiting_for_peer.zig — Netplay handshake UI + session lifecycle helpers,
// extracted from ui.zig.
//
// Contains:
//   - cleanupSession     : tear down an in-progress NetplaySession
//   - startHostSession   : begin the host-side handshake
//   - startJoinSession   : begin the client-side handshake
//   - drawWaitingForPeer : the .waiting_for_peer UI screen — drives
//                          session.step() each frame, shows progress / ping /
//                          delay override / Start button, and dispatches to
//                          launchGameAfterHandshake() once both sides agree.
//   - setClipboardZ      : helper used by drawWaitingForPeer to copy the
//                          host's IP:port to the clipboard via ImGui
//
// The UiState type is re-imported from ui.zig (circular import is fine in
// Zig — both modules see the same enum value at compile time).

const std = @import("std");
const config = @import("common").config;
const logging = @import("common").logging;
const launcher = @import("launcher.zig");
const ipc = @import("common").ipc;
const session = @import("session.zig");
const game_launcher = @import("game_launcher.zig");
const ui = @import("ui.zig");

const UiState = ui.UiState;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_opengl.h");
    @cInclude("cimgui_shim.h");
});

/// Tear down any in-progress netplay session. Since the session now runs
/// entirely on the main thread (no background thread), this just cancels
/// + deinits the session. Safe to call at any point.
pub fn cleanupSession(
    np_session: *?session.NetplaySession,
) void {
    if (np_session.*) |*s| {
        s.cancel();
        s.deinit();
    }
    np_session.* = null;
}

/// Start the host-side handshake session. Runs on the main thread — the UI
/// calls session.step() each frame to drive the handshake forward.
pub fn startHostSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    port: u16,
    np_session: *?session.NetplaySession,
) void {
    cleanupSession(np_session);

    var s = session.NetplaySession.init(allocator, io, log);
    s.config.rollback = cfg.default_rollback;
    s.config.win_count = cfg.versus_win_count;
    s.setLocalName(cfg.display_name);
    s.detectConnectionType();
    s.lookupHostAddresses();
    np_session.* = s;

    np_session.*.?.startHost(port, false) catch |err| {
        log.err("startHost failed: {s}", .{@errorName(err)});
        cleanupSession(np_session);
        return;
    };
    log.info("Host session started on port {d} (pub={s} local={s} name='{s}')", .{
        port,
        np_session.*.?.publicIp() orelse "?",
        np_session.*.?.localIp() orelse "?",
        np_session.*.?.localName(),
    });
}

/// Start the client-side handshake session. Runs on the main thread.
pub fn startJoinSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    addr_str: []const u8,
    np_session: *?session.NetplaySession,
) void {
    cleanupSession(np_session);

    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse {
        log.err("Invalid address (no colon): {s}", .{addr_str});
        return;
    };
    const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch {
        log.err("Invalid port in: {s}", .{addr_str});
        return;
    };
    const host_part = addr_str[0..colon];

    var s = session.NetplaySession.init(allocator, io, log);
    s.config.rollback = cfg.default_rollback;
    s.config.win_count = cfg.versus_win_count;
    s.setLocalName(cfg.display_name);
    s.detectConnectionType();
    np_session.* = s;

    np_session.*.?.startJoin(host_part, port, false) catch |err| {
        log.err("startJoin failed: {s}", .{@errorName(err)});
        cleanupSession(np_session);
        return;
    };
    log.info("Join session started -> {s}:{d} (name='{s}')", .{ host_part, port, np_session.*.?.localName() });
}

/// Draw the waiting-for-peer screen. Calls session.step() each frame to
/// drive the handshake forward, then shows progress / confirmation / launch.
pub fn drawWaitingForPeer(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    pipe_name: []const u8,
    np_session: *?session.NetplaySession,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    ui_state: *UiState,
    error_msg: *[256]u8,
    error_msg_len: *usize,
    host_start_clicked: *bool,
    delay_buf: *[4]u8,
    delay_override_active: *bool,
) void {
    if (np_session.* == null) {
        ui_state.* = .idle;
        return;
    }
    const s = &np_session.*.?;

    // Drive the handshake forward by one step each frame. This is non-blocking
    // (ENet poll timeout=0) and runs entirely on the main thread.
    s.step();

    const is_host = s.config.is_host;

    c.igText("%s", @as([*:0]const u8, @ptrCast(if (is_host) "Hosting — waiting for opponent" else "Connecting to host")));
    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    switch (s.state) {
        .idle, .listening, .connecting, .handshaking, .ping_exchanging => {
            // In-progress: show address info + a spinner-ish message.
            if (is_host) {
                if (s.publicIp()) |pub_ip| {
                    var addr_buf: [80]u8 = undefined;
                    const addr_z = std.fmt.bufPrintZ(&addr_buf, "{s}:{d}", .{ pub_ip, s.config.peer_port }) catch "?:?";
                    c.igText("Give your opponent this address:");
                    c.igSameLine(0, 8);
                    c.igTextColored(.{ .x = 0.4, .y = 0.8, .z = 1.0, .w = 1.0 }, "%s", @as([*:0]const u8, @ptrCast(addr_z.ptr)));
                    c.igSameLine(0, 8);
                    if (c.igButton("Copy", .{ .x = 60, .y = 0 })) {
                        setClipboardZ(addr_z);
                    }
                } else {
                    c.igText("Looking up public IP...");
                }
                if (s.localIp()) |loc_ip| {
                    var addr_buf: [80]u8 = undefined;
                    const addr_z = std.fmt.bufPrintZ(&addr_buf, "Local IP: {s}:{d}", .{ loc_ip, s.config.peer_port }) catch "";
                    c.igText("%s", @as([*:0]const u8, @ptrCast(addr_z.ptr)));
                }
            } else {
                var addr_buf: [80]u8 = undefined;
                const peer_z = std.mem.sliceTo(&s.config.peer_addr, 0);
                const addr_z = std.fmt.bufPrintZ(&addr_buf, "{s}:{d}", .{ peer_z, s.config.peer_port }) catch "?:?";
                c.igText("Connecting to %s...", @as([*:0]const u8, @ptrCast(addr_z.ptr)));
            }
            c.igSpacing();
            c.igText("(make sure the port is open / forwarded on the host's router)");

            // Show remaining time for the current phase's timeout.
            if (s.remainingSeconds()) |remaining| {
                var timer_buf: [64]u8 = undefined;
                if (remaining >= 60) {
                    const mins = remaining / 60;
                    const secs = remaining % 60;
                    const timer_z = std.fmt.bufPrintZ(&timer_buf, "Timeout in: {d}m {d:0>2}s", .{ mins, secs }) catch "Timeout in: ...";
                    c.igText("%s", @as([*:0]const u8, @ptrCast(timer_z.ptr)));
                } else {
                    const timer_z = std.fmt.bufPrintZ(&timer_buf, "Timeout in: {d}s", .{remaining}) catch "Timeout in: ...";
                    c.igText("%s", @as([*:0]const u8, @ptrCast(timer_z.ptr)));
                }
            }

            c.igSpacing();
            c.igSeparator();
            c.igSpacing();
            if (c.igButton("Cancel", .{ .x = 120, .y = 30 })) {
                cleanupSession(np_session);
                ui_state.* = .idle;
            }
        },

        .waiting_confirmation => {
            // Host: handshake done, show ping + delay override + Start button.
            const remote = s.remoteName();
            if (remote.len > 0) {
                c.igText("%.*s connected!", @as(c_int, @intCast(remote.len)), remote.ptr);
            } else {
                c.igText("Opponent connected!");
            }
            c.igSpacing();
            // Show connection type for both players.
            const local_ct = s.localConnectionType();
            const remote_ct = s.remoteConnectionType();
            if (remote_ct.len > 0) {
                c.igText("Opponent connection: %.*s", @as(c_int, @intCast(remote_ct.len)), remote_ct.ptr);
            }
            if (local_ct.len > 0) {
                c.igText("Your connection: %.*s", @as(c_int, @intCast(local_ct.len)), local_ct.ptr);
            }
            c.igSpacing();
            c.igText("Ping: avg=%.0fms  min=%.0fms  max=%.0fms", s.stats.avg_ms, s.stats.min_ms, s.stats.max_ms);
            c.igText("Auto input delay: %d", s.config.delay);
            c.igSpacing();

            // Delay override: the host can manually set the input delay
            // instead of using the auto-computed value. The override is
            // applied to s.config.delay before hostConfirm() sends the
            // config to the client.
            c.igText("Override delay:");
            c.igSameLine(0, 8);
            _ = c.igInputText("##delay_override", delay_buf, delay_buf.len, 0, null, null);
            c.igSameLine(0, 8);
            if (c.igButton("Apply##delay", .{ .x = 60, .y = 0 })) {
                const delay_str = std.mem.sliceTo(@as([*:0]u8, @ptrCast(delay_buf)), 0);
                if (delay_str.len > 0) {
                    const val = std.fmt.parseInt(u8, delay_str, 10) catch s.config.delay;
                    // Clamp to [0, 15] — anything higher is unplayable.
                    s.config.delay = @min(val, 15);
                    delay_override_active.* = true;
                    log.info("Delay overridden to {d}", .{s.config.delay});
                }
            }
            if (delay_override_active.*) {
                c.igSameLine(0, 8);
                c.igText("(overridden: %d)", s.config.delay);
                c.igSameLine(0, 8);
                if (c.igButton("Reset##delay", .{ .x = 50, .y = 0 })) {
                    // Recompute auto delay from ping.
                    const avg_rtt = if (s.stats.avg_ms > 0) s.stats.avg_ms else 50;
                    const computed: u8 = @intFromFloat(@ceil(avg_rtt / (1000.0 / 60.0)));
                    s.config.delay = @min(computed, 8);
                    delay_override_active.* = false;
                    log.info("Delay reset to auto: {d}", .{s.config.delay});
                }
            }

            c.igSpacing();
            c.igSeparator();
            c.igSpacing();
            if (c.igButton("Start Match", .{ .x = 160, .y = 36 })) {
                host_start_clicked.* = true;
                s.hostConfirm();
            }
            c.igSameLine(0, 16);
            if (c.igButton("Cancel", .{ .x = 120, .y = 36 })) {
                cleanupSession(np_session);
                ui_state.* = .idle;
            }
        },

        .launching => {
            // Both sides agreed — open the game now.
            // For the host this is reached after hostConfirm(); for the
            // client it's reached right after waitForConfig().
            game_launcher.launchGameAfterHandshake(
                allocator, io, cfg, log, pipe_name,
                np_session,
                win_launcher, game_pid, ipc_server,
                error_msg, error_msg_len,
            );
            if (game_pid.* > 0) {
                ui_state.* = .in_game;
            } else {
                ui_state.* = .error_state;
            }
        },

        .completed => {
            c.igText("Session completed.");
            c.igSpacing();
            if (c.igButton("OK", .{ .x = 120, .y = 30 })) {
                cleanupSession(np_session);
                ui_state.* = .idle;
            }
        },

        .failed => {
            const msg = s.errorMessage();
            game_launcher.setErr(error_msg, error_msg_len, if (msg.len > 0) msg else "Connection failed");
            cleanupSession(np_session);
            ui_state.* = .error_state;
        },

        .cancelled => {
            cleanupSession(np_session);
            ui_state.* = .idle;
        },
    }
}

// Module-local references removed: the host-screen IP buffers are now passed
// through startHostSession → drawWaitingForPeer as explicit parameters.

fn setClipboardZ(text: []const u8) void {
    // Build a null-terminated copy on the stack and hand it to ImGui.
    var buf: [128]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    c.igSetClipboardText(@ptrCast(&buf));
}
