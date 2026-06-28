const std = @import("std");
const config = @import("common").config;
const logging = @import("common").logging;
const launcher = @import("launcher.zig");
const ipc = @import("common").ipc;
const session = @import("session.zig");
const game_launcher = @import("game_launcher.zig");
const ui = @import("ui.zig");
const ui_theme = @import("ui_theme.zig");
const connection_detector = @import("net").connection_detector;
const zgui = @import("zgui");

const UiState = ui.UiState;

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

/// Start a relay-assisted host session. The relay handles NAT traversal
/// so the host doesn't need to port-forward. A 4-letter room code is
/// generated — display it via getRoomCode().
///
/// `relay_source` is the text contents of relay_list.txt or the
/// relayServers= config field. If empty, uses the hardcoded default.
pub fn startRelayHostSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    port: u16,
    relay_source: []const u8,
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

    np_session.*.?.startRelayHost(relay_source, port, false) catch |err| {
        log.err("startRelayHost failed: {s}", .{@errorName(err)});
        cleanupSession(np_session);
        return;
    };
    if (np_session.*.?.getRoomCode()) |code| {
        log.info("Relay host session started on port {d} (room code={s}, name='{s}')", .{
            port, code, np_session.*.?.localName(),
        });
    } else {
        log.info("Relay host session started on port {d} (name='{s}')", .{
            port, np_session.*.?.localName(),
        });
    }
}

/// Start a relay-assisted join session.
///
/// `peer_identifier` is a 4-letter room code.
///
/// `relay_source` is the text contents of relay_list.txt. If empty,
/// uses the hardcoded default.
pub fn startRelayJoinSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    peer_identifier: []const u8,
    relay_source: []const u8,
    np_session: *?session.NetplaySession,
) void {
    cleanupSession(np_session);

    var s = session.NetplaySession.init(allocator, io, log);
    s.config.rollback = cfg.default_rollback;
    s.config.win_count = cfg.versus_win_count;
    s.setLocalName(cfg.display_name);
    s.detectConnectionType();
    np_session.* = s;

    np_session.*.?.startRelayJoin(relay_source, peer_identifier, false) catch |err| {
        log.err("startRelayJoin failed: {s}", .{@errorName(err)});
        cleanupSession(np_session);
        return;
    };
    log.info("Relay join session started -> {s} (name='{s}')", .{
        peer_identifier, np_session.*.?.localName(),
    });
}

/// Start a smart host session — direct listener + relay in parallel.
///
/// This is the unified Host button handler. It opens a direct ENet listener
/// on `port` AND starts a relay client (for NAT traversal) in parallel.
/// Whichever peer arrives first wins:
///
///   - If a direct peer connects (localhost/LAN), the relay client is
///     canceled and the existing ENet handshake flow takes over.
///   - If the relay handshake completes first (peer behind NAT), the direct
///     listener is torn down and re-created bound to the relay's
///     local_udp_port — preserving the NAT mapping. The peer's ENet CONNECT
///     then arrives at the new listener.
///
/// This fixes the regression where the smart host flow forced ALL host
/// sessions through the relay path — breaking localhost/LAN connections
/// where the relay is unreachable or unnecessary.
pub fn startSmartHostSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    port: u16,
    relay_source: []const u8,
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

    np_session.*.?.startSmartHost(relay_source, port, false) catch |err| {
        log.err("startSmartHost failed: {s}", .{@errorName(err)});
        cleanupSession(np_session);
        return;
    };
    if (np_session.*.?.getRoomCode()) |code| {
        log.info("Smart host session started (room code={s}, name='{s}')", .{
            code, np_session.*.?.localName(),
        });
    } else {
        log.info("Smart host session started (direct only, name='{s}')", .{
            np_session.*.?.localName(),
        });
    }
}

/// Start a smart join session — auto-detects input format and picks
/// the right connection strategy.
///
/// Detection rules (via connection_detector.parseInput):
///   .room_code (4 letters)     → relay join (room-code based)
///   .ip_port (any IP:port)     → direct join (relay is room-code only)
///   .invalid                   → error, don't start a session
pub fn startSmartJoinSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    input: []const u8,
    relay_source: []const u8,
    np_session: *?session.NetplaySession,
) void {
    const parsed = connection_detector.parseInput(input);

    switch (parsed.type) {
        .room_code => {
            log.info("Smart join: detected room code '{s}' — using relay", .{parsed.value});
            startRelayJoinSession(allocator, io, cfg, log, parsed.value, relay_source, np_session);
        },
        .ip_port => {
            log.info("Smart join: detected address '{s}' — using direct connection", .{input});
            startJoinSession(allocator, io, cfg, log, input, np_session);
        },
        .port, .empty, .invalid => {
            log.err("Smart join: invalid input '{s}' — expected #roomcode or ip:port", .{input});
            // Don't start a session — the UI will show an error.
        },
    }
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
    delay_buf: [:0]u8,
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

    // Main centered card that hosts the waiting-for-peer content.
    // The whole screen is divided into a centered card ~640x420 px.
    const cw: f32 = 640;
    const ch: f32 = 460;
    const cx = (1024 - cw) / 2;
    const cy = (768 - ch) / 2;
    zgui.setCursorPos(.{ cx, cy });

    if (ui_theme.beginCard("##wait_peer_card", cw, ch, false)) {
        // Title row.
        if (is_host) {
            ui_theme.cardTitle("HOSTING — WAITING FOR OPPONENT");
        } else {
            ui_theme.cardTitle("CONNECTING TO HOST");
        }
        zgui.spacing();

        switch (s.state) {
            .idle, .listening, .connecting, .handshaking, .ping_exchanging, .relay_connecting => {
                // --- Status message (most prominent) ---
                // Show the current status from session.getStatusMsg() — this
                // tells the user exactly what's happening right now.
                const status = s.getStatusMsg();
                if (status.len > 0) {
                    ui_theme.textColored(ui_theme.COL_TEXT, "{s}", .{status});
                    zgui.spacing();
                }

                // --- Share info (room code or IP:port) ---
                // For host: show what to share with the opponent.
                // For client: show what we're connecting to.
                if (is_host) {
                    // Host: show room code (relay) or IP:port (direct)
                    if (s.getRoomCode()) |code| {
                        var code_buf: [16]u8 = undefined;
                        const code_z = std.fmt.bufPrintZ(&code_buf, "#{s}", .{code}) catch "#????";
                        ui_theme.textColored(ui_theme.COL_MUTED, "Share this room code with your opponent:", .{});
                        zgui.spacing();
                        ui_theme.textColored(ui_theme.COL_RED, "{s}", .{code_z});
                        zgui.sameLine(.{ .spacing = 12 });
                        if (ui_theme.secondaryButton("Copy", 80, 28)) {
                            setClipboardZ(code_z);
                        }
                    } else if (s.publicIp()) |pub_ip| {
                        var addr_buf: [80]u8 = undefined;
                        const addr_z = std.fmt.bufPrintZ(&addr_buf, "{s}:{d}", .{ pub_ip, s.config.peer_port }) catch "?:?";
                        ui_theme.textColored(ui_theme.COL_MUTED, "Share this address with your opponent:", .{});
                        zgui.spacing();
                        ui_theme.textColored(ui_theme.COL_RED, "{s}", .{addr_z});
                        zgui.sameLine(.{ .spacing = 12 });
                        if (ui_theme.secondaryButton("Copy", 80, 28)) {
                            setClipboardZ(addr_z);
                        }
                    } else {
                        ui_theme.textColored(ui_theme.COL_MUTED, "Looking up public IP...", .{});
                    }
                    if (s.localIp()) |loc_ip| {
                        var addr_buf: [80]u8 = undefined;
                        const addr_z = std.fmt.bufPrintZ(&addr_buf, "Local IP: {s}:{d}", .{ loc_ip, s.config.peer_port }) catch "";
                        zgui.spacing();
                        ui_theme.textColored(ui_theme.COL_TEXT_DIM, "{s}", .{addr_z});
                    }
                } else {
                    // Client: show what we're connecting to
                    var addr_buf: [80]u8 = undefined;
                    const peer_z = std.mem.sliceTo(&s.config.peer_addr, 0);
                    if (peer_z.len > 0) {
                        const addr_z = std.fmt.bufPrintZ(&addr_buf, "Connecting to {s}:{d}", .{ peer_z, s.config.peer_port }) catch "Connecting...";
                        ui_theme.textColored(ui_theme.COL_MUTED, "{s}", .{addr_z});
                    }
                }

                const local_ct = s.localConnectionType();
                if (std.mem.eql(u8, local_ct, "Wired")) {
                    zgui.spacing();
                    ui_theme.textColored(ui_theme.COL_MUTED, "Wired connection detected. You're good to go!", .{});
                } else if (std.mem.eql(u8, local_ct, "Wireless")) {
                    zgui.spacing();
                    ui_theme.textColored(ui_theme.COL_RED, "Wi-Fi detected. A wired connection is recommended.", .{});
                }

                // Show remaining time for the current phase's timeout.
                if (s.remainingSeconds()) |remaining| {
                    var timer_buf: [64]u8 = undefined;
                    if (remaining >= 60) {
                        const mins = remaining / 60;
                        const secs = remaining % 60;
                        const timer_z = std.fmt.bufPrintZ(&timer_buf, "Timeout in: {d}m {d:0>2}s", .{ mins, secs }) catch "Timeout in: ...";
                        zgui.spacing();
                        ui_theme.textColored(ui_theme.COL_MUTED, "{s}", .{timer_z});
                    } else {
                        const timer_z = std.fmt.bufPrintZ(&timer_buf, "Timeout in: {d}s", .{remaining}) catch "Timeout in: ...";
                        zgui.spacing();
                        ui_theme.textColored(ui_theme.COL_MUTED, "{s}", .{timer_z});
                    }
                }

                // Cancel button at the bottom of the card.
                const btn_y = ch - 36 - ui_theme.CARD_PAD - ui_theme.CARD_PAD;
                zgui.setCursorPosY(btn_y);
                if (ui_theme.secondaryButton("Cancel", 140, 36)) {
                    cleanupSession(np_session);
                    ui_state.* = .idle;
                }
            },

            .waiting_confirmation => {
                // Host: handshake done, show ping + delay override + Start button.
                const remote = s.remoteName();
                if (remote.len > 0) {
                    ui_theme.textColored(ui_theme.COL_TEXT, "{s} connected!", .{remote});
                } else {
                    ui_theme.textColored(ui_theme.COL_TEXT, "Opponent connected!", .{});
                }
                zgui.spacing();
                // Show connection type for both players.
                const local_ct = s.localConnectionType();
                const remote_ct = s.remoteConnectionType();
                if (remote_ct.len > 0) {
                    ui_theme.textColored(ui_theme.COL_MUTED, "Opponent connection: {s}", .{remote_ct});
                }
                if (local_ct.len > 0) {
                    if (std.mem.eql(u8, local_ct, "Wired")) {
                        ui_theme.textColored(ui_theme.COL_MUTED, "Wired connection detected. You're good to go!", .{});
                    } else if (std.mem.eql(u8, local_ct, "Wireless")) {
                        ui_theme.textColored(ui_theme.COL_RED, "Wi-Fi detected. A wired connection is recommended.", .{});
                    } else {
                        ui_theme.textColored(ui_theme.COL_MUTED, "Your connection: {s}", .{local_ct});
                    }
                }
                zgui.spacing();
                zgui.text("Ping: avg={d:.0}ms  min={d:.0}ms  max={d:.0}ms", .{ s.stats.avg_ms, s.stats.min_ms, s.stats.max_ms });
                zgui.text("Auto input delay: {d}", .{ s.config.delay });
                zgui.spacing();

                // Delay override: the host can manually set the input delay
                // instead of using the auto-computed value. The override is
                // applied to s.config.delay before hostConfirm() sends the
                // config to the client.
                zgui.text("Override delay", .{});
                zgui.sameLine(.{ .spacing = 8 });
                zgui.pushItemWidth(80);
                _ = zgui.inputText("##delay_override", .{ .buf = delay_buf });
                zgui.popItemWidth();
                zgui.sameLine(.{ .spacing = 8 });
                if (ui_theme.secondaryButton("Apply##delay", 80, 0)) {
                    const delay_str = std.mem.sliceTo(delay_buf, 0);
                    if (delay_str.len > 0) {
                        const val = std.fmt.parseInt(u8, delay_str, 10) catch s.config.delay;
                        // Clamp to [0, 15] — anything higher is unplayable.
                        s.config.delay = @min(val, 15);
                        delay_override_active.* = true;
                        log.info("Delay overridden to {d}", .{s.config.delay});
                    }
                }
                if (delay_override_active.*) {
                    zgui.sameLine(.{ .spacing = 8 });
                    ui_theme.textColored(ui_theme.COL_MUTED, "(overridden: {d})", .{s.config.delay});
                    zgui.sameLine(.{ .spacing = 8 });
                    if (ui_theme.secondaryButton("Reset##delay", 70, 0)) {
                        // Recompute auto delay from ping.
                        const avg_rtt = if (s.stats.avg_ms > 0) s.stats.avg_ms else 50;
                        const computed: u8 = @intFromFloat(@ceil(avg_rtt / (1000.0 / 60.0)));
                        s.config.delay = @min(computed, 8);
                        delay_override_active.* = false;
                        log.info("Delay reset to auto: {d}", .{s.config.delay});
                    }
                }

                // Bottom action row.
                const btn_y = ch - 38 - ui_theme.CARD_PAD - ui_theme.CARD_PAD;
                zgui.setCursorPosY(btn_y);
                if (ui_theme.primaryButton("Start Match", 200, 38)) {
                    host_start_clicked.* = true;
                    s.hostConfirm();
                }
                zgui.sameLine(.{ .spacing = 12 });
                if (ui_theme.secondaryButton("Cancel", 140, 38)) {
                    cleanupSession(np_session);
                    ui_state.* = .idle;
                }
            },

            .launching => {
                // Both sides agreed — open the game now.
                // For the host this is reached after hostConfirm(); for the
                // client it's reached right after waitForConfig().
                game_launcher.launchGameAfterHandshake(
                    allocator,
                    io,
                    cfg,
                    log,
                    pipe_name,
                    np_session,
                    win_launcher,
                    game_pid,
                    ipc_server,
                    error_msg,
                    error_msg_len,
                );
                if (game_pid.* > 0) {
                    ui_state.* = .in_game;
                } else {
                    ui_state.* = .error_state;
                }
            },

            .completed => {
                ui_theme.textColored(ui_theme.COL_TEXT, "Session completed.", .{});
                const btn_y = ch - 36 - ui_theme.CARD_PAD - ui_theme.CARD_PAD;
                zgui.setCursorPosY(btn_y);
                if (ui_theme.primaryButton("OK", 140, 36)) {
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
    ui_theme.endCard();
}

fn setClipboardZ(text: []const u8) void {
    // Build a null-terminated copy on the stack and hand it to ImGui.
    var buf: [128:0]u8 = undefined;
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    zgui.setClipboardText(buf[0..n :0]);
}
