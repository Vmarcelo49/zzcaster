const std = @import("std");
const config = @import("common").config;
const logging = @import("common").logging;
const launcher = @import("launcher.zig");
const ipc = @import("common").ipc;
const session = @import("session.zig");

pub fn parsePort(buf: [*]u8) u16 {
    const s = std.mem.sliceTo(@as([*:0]u8, @ptrCast(buf)), 0);
    return std.fmt.parseInt(u16, s, 10) catch config.default_port;
}

/// Write an error message into a fixed-size [256]u8 buffer with a null
/// sentinel, and record the message length. Used to pass error text from
/// launcher functions back to the UI's error_state screen.
pub fn setErr(msg: *[256]u8, len: *usize, text: []const u8) void {
    const n = @min(text.len, msg.len - 1);
    @memcpy(msg[0..n], text[0..n]);
    msg[n] = 0;
    len.* = n;
}

/// Clean up all game-related state: close IPC pipe, close process handles,
/// reset PID. Must be called before launching a new game so the named pipe
/// is released and can be re-created.
pub fn cleanupGame(
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
) void {
    if (ipc_server.*) |*srv| srv.close();
    ipc_server.* = null;
    if (win_launcher.*) |*wl| wl.terminate();
    win_launcher.* = null;
    game_pid.* = 0;
}

/// Launch MBAA.exe in offline mode (training or versus). Builds the IPC
/// config buffer (no peer address) and sends it to the DLL after it
/// connects. On any failure, sets *error_msg and returns without launching.
pub fn launchGameImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    training: bool,
    is_netplay_host: bool,
    port: u16,
    pipe_name: []const u8,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    // Clean up any previous game state before launching a new one.
    cleanupGame(win_launcher, game_pid, ipc_server);

    const game_exe = std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate path");
        return;
    };
    defer allocator.free(game_exe);
    const dll_path = std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate dll path");
        return;
    };
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        setErr(error_msg, error_msg_len, "MBAA.exe not found");
        log.err("MBAA.exe not found: {s}", .{game_exe});
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        setErr(error_msg, error_msg_len, "hook.dll not found");
        log.err("hook.dll not found: {s}", .{dll_path});
        return;
    };

    ipc_server.* = ipc.IpcServer.listen(pipe_name) catch {
        setErr(error_msg, error_msg_len, "IPC listen failed");
        return;
    };

    win_launcher.* = launcher.WindowsLauncher{};
    const pid = win_launcher.*.?.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        setErr(error_msg, error_msg_len, "Failed to launch MBAA.exe");
        return;
    };
    game_pid.* = pid;
    log.info("Game launched (PID={d})", .{pid});

    if (ipc_server.*) |*srv| {
        if (win_launcher.*) |*wl| {
            if (!wl.isAlive()) {
                setErr(error_msg, error_msg_len, "Game exited immediately");
                return;
            }
        }
        srv.waitForConnection() catch {
            setErr(error_msg, error_msg_len, "IPC connection failed");
            return;
        };
    }
    log.info("DLL connected via IPC", .{});

    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0;
    if (training) config_buf[0] |= 0x01;
    if (is_netplay_host) config_buf[0] |= 0x02 | 0x04;
    config_buf[1] = cfg.default_rollback;
    config_buf[2] = cfg.default_rollback;
    config_buf[3] = cfg.versus_win_count;
    config_buf[4] = 1;
    std.mem.writeInt(u16, config_buf[5..7], port, .little);
    // local_udp_port = 0 (offline mode, no relay handoff).
    std.mem.writeInt(u16, config_buf[7..9], 0, .little);
    const msg_len = 9;

    if (ipc_server.*) |*srv| {
        if (srv.send(config_buf[0..msg_len])) {
            log.info("Config sent (host={} training={} port={d})", .{ is_netplay_host, training, port });
        } else {
            log.err("Config send FAILED (gle={d}) — DLL will not enter training/versus mode", .{srv.last_send_error});
            setErr(error_msg, error_msg_len, "IPC send failed (config not delivered to DLL)");
        }
    }
}

/// Launch MBAA.exe for direct spectate or legacy join (no handshake — peer
/// address is taken straight from the UI text field). Builds the IPC config
/// buffer with the peer address appended and sends it to the DLL.
pub fn launchNetplayImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    addr_str: []const u8,
    is_spectator: bool,
    pipe_name: []const u8,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    // Clean up any previous game state before launching a new one.
    cleanupGame(win_launcher, game_pid, ipc_server);

    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse {
        setErr(error_msg, error_msg_len, "Invalid format. Use IP:port");
        return;
    };
    const peer_addr = addr_str[0..colon];
    const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch config.default_port;

    const game_exe = std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate path");
        return;
    };
    defer allocator.free(game_exe);
    const dll_path = std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate dll path");
        return;
    };
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        setErr(error_msg, error_msg_len, "MBAA.exe not found");
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        setErr(error_msg, error_msg_len, "hook.dll not found");
        return;
    };

    ipc_server.* = ipc.IpcServer.listen(pipe_name) catch {
        setErr(error_msg, error_msg_len, "IPC listen failed");
        return;
    };

    win_launcher.* = launcher.WindowsLauncher{};
    const pid = win_launcher.*.?.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        setErr(error_msg, error_msg_len, "Failed to launch MBAA.exe");
        return;
    };
    game_pid.* = pid;
    log.info("Game launched (PID={d})", .{pid});

    if (ipc_server.*) |*srv| {
        if (win_launcher.*) |*wl| {
            if (!wl.isAlive()) {
                setErr(error_msg, error_msg_len, "Game exited immediately");
                return;
            }
        }
        srv.waitForConnection() catch {
            setErr(error_msg, error_msg_len, "IPC connection failed");
            return;
        };
    }

    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0x02 | (if (is_spectator) @as(u8, 0x08) else 0);
    config_buf[1] = if (is_spectator) 0 else cfg.default_rollback;
    config_buf[2] = if (is_spectator) 0 else cfg.default_rollback;
    config_buf[3] = cfg.versus_win_count;
    config_buf[4] = 1;
    std.mem.writeInt(u16, config_buf[5..7], port, .little);
    // local_udp_port = 0 (direct connection, no relay handoff for spectator
    // join via direct IP). The DLL reads this field and treats 0 as
    // "bind to any port".
    std.mem.writeInt(u16, config_buf[7..9], 0, .little);
    const addr_copy_len = @min(peer_addr.len, 247);
    @memcpy(config_buf[9 .. 9 + addr_copy_len], peer_addr[0..addr_copy_len]);
    const msg_len = 9 + addr_copy_len;

    if (ipc_server.*) |*srv| {
        if (srv.send(config_buf[0..msg_len])) {
            log.info("Config sent ({s} -> {s}:{d})", .{
                if (is_spectator) "spectator" else "client", peer_addr, port,
            });
        } else {
            log.err("Config send FAILED (gle={d}) — DLL will not connect to peer", .{srv.last_send_error});
            setErr(error_msg, error_msg_len, "IPC send failed (config not delivered to DLL)");
        }
    }
}

/// Launch the game after the launcher-side handshake completed. Mirrors
/// MainApp.cpp:1263-1289: close the handshake socket, wait ~1s (so the OS
/// releases the UDP port — the legacy startTimer delay), then CreateProcess +
/// inject + send the negotiated config via IPC.
pub fn launchGameAfterHandshake(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    pipe_name: []const u8,
    np_session: *?session.NetplaySession,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    // Snapshot the negotiated config BEFORE we tear down the session.
    const snap = blk: {
        if (np_session.*) |*s| break :blk s.config;
        setErr(error_msg, error_msg_len, "No session to launch from");
        return;
    };
    const is_host = snap.is_host;
    const peer_port = snap.peer_port;
    const delay = snap.delay;
    const rollback = snap.rollback;
    const win_count = snap.win_count;
    const host_player = snap.host_player;
    var peer_addr: [64]u8 = snap.peer_addr;

    // Tear down the transport so the OS frees the UDP port. No thread to
    // join — the session runs on the main thread.
    //
    // Client: wait a short delay before tearing down ENet so the host has
    // time to receive and process our `confirm` packet. Without this, the
    // enet_peer_disconnect (from s.deinit) can race with the confirm
    // delivery — ENet may process the disconnect before the confirm,
    // causing the host to fail with "Peer disconnected waiting for confirm".
    // The host polls ENet once per SDL frame (~16ms), so 500ms is more than
    // enough for the host to receive and process the confirm.
    if (!snap.is_host) {
        log.info("Client: waiting 500ms before ENet teardown (confirm delivery)...", .{});
        std.Io.sleep(io, .{ .nanoseconds = 500 * std.time.ns_per_ms }, .real) catch {};
    }
    if (np_session.*) |*s| {
        s.deinit();
    }
    np_session.* = null;

    log.info("Handshake done ({s}). Closing socket, waiting 1s before opening game...", .{
        if (is_host) "host" else "client",
    });
    // Mirror the legacy 1000ms startTimer delay (MainApp.cpp:933-934) so the
    // OS releases the port before the DLL rebinds it.
    std.Io.sleep(io, .{ .nanoseconds = 1 * std.time.ns_per_s }, .real) catch {};

    // Clean up any previous game state before launching a new one.
    cleanupGame(win_launcher, game_pid, ipc_server);

    const game_exe = std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate path");
        return;
    };
    defer allocator.free(game_exe);
    const dll_path = std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate dll path");
        return;
    };
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        setErr(error_msg, error_msg_len, "MBAA.exe not found");
        log.err("MBAA.exe not found: {s}", .{game_exe});
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        setErr(error_msg, error_msg_len, "hook.dll not found");
        log.err("hook.dll not found: {s}", .{dll_path});
        return;
    };

    ipc_server.* = ipc.IpcServer.listen(pipe_name) catch {
        setErr(error_msg, error_msg_len, "IPC listen failed");
        return;
    };

    win_launcher.* = launcher.WindowsLauncher{};
    const pid = win_launcher.*.?.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        setErr(error_msg, error_msg_len, "Failed to launch MBAA.exe");
        return;
    };
    game_pid.* = pid;
    log.info("Game launched (PID={d})", .{pid});

    if (ipc_server.*) |*srv| {
        if (win_launcher.*) |*wl| {
            if (!wl.isAlive()) {
                setErr(error_msg, error_msg_len, "Game exited immediately");
                return;
            }
        }
        srv.waitForConnection() catch {
            setErr(error_msg, error_msg_len, "IPC connection failed");
            return;
        };
    }
    log.info("DLL connected via IPC", .{});

    // Build the config buffer using the SAME layout the DLL parses in
    // dllmain.zig:waitForConfig():
    //   [1 byte flags] [1 byte delay] [1 byte rollback] [1 byte win_count]
    //   [1 byte host_player] [2 bytes peer_port] [2 bytes local_udp_port]
    //   [N bytes peer_addr]
    // flags bit0=training, bit1=netplay, bit2=host, bit3=spectator.
    //
    // local_udp_port (NEW): the local UDP port used for NAT-traversal
    // hole-punching. 0 = direct connection (DLL binds to any port).
    // Non-zero = relay connection (DLL must bind its ENet host to this
    // exact port to preserve the NAT mapping).
    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0x02 | (if (is_host) @as(u8, 0x04) else 0);
    config_buf[1] = delay;
    config_buf[2] = rollback;
    config_buf[3] = win_count;
    config_buf[4] = host_player;
    std.mem.writeInt(u16, config_buf[5..7], peer_port, .little);
    std.mem.writeInt(u16, config_buf[7..9], snap.local_udp_port, .little);

    // Host does NOT send a peer address (it listens); client sends the host's
    // address so the DLL can connect outbound.
    var msg_len: usize = 9;
    if (!is_host) {
        const addr_slice = std.mem.sliceTo(&peer_addr, 0);
        const addr_copy_len = @min(addr_slice.len, 247);
        @memcpy(config_buf[9 .. 9 + addr_copy_len], addr_slice[0..addr_copy_len]);
        msg_len = 9 + addr_copy_len;
    }

    if (ipc_server.*) |*srv| {
        if (srv.send(config_buf[0..msg_len])) {
            log.info("Config sent to DLL (host={} delay={d} rollback={d} port={d} local_udp_port={d})", .{
                is_host, delay, rollback, peer_port, snap.local_udp_port,
            });
        } else {
            log.err("Config send FAILED (gle={d}) — DLL will not start netplay correctly", .{srv.last_send_error});
            setErr(error_msg, error_msg_len, "IPC send failed (config not delivered to DLL)");
        }
    }
}

// CLI
pub fn launchGame(allocator: std.mem.Allocator, io: std.Io, cfg: *config.Config, log: *logging.Logger, training: bool, is_netplay_host: bool, port: u16, pipe_name: []const u8, non_interactive: bool) !void {
    _ = non_interactive;
    const game_exe = try std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" });
    defer allocator.free(game_exe);
    const dll_path = try std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" });
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        log.err("MBAA.exe not found: {s}", .{game_exe});
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        log.err("hook.dll not found: {s}", .{dll_path});
        return;
    };

    var ipc_server = try ipc.IpcServer.listen(pipe_name);
    defer ipc_server.close();
    log.info("IPC server listening", .{});

    var win_launcher = launcher.WindowsLauncher{};
    const pid = win_launcher.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        log.err("Failed to launch MBAA.exe", .{});
        return;
    };
    log.info("Game launched (PID={d})", .{pid});

    if (!win_launcher.isAlive()) {
        log.err("Game exited immediately", .{});
        return;
    }

    ipc_server.waitForConnection() catch {
        log.warn("IPC connection failed", .{});
        return;
    };
    log.info("DLL connected via IPC", .{});

    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0;
    if (training) config_buf[0] |= 0x01;
    if (is_netplay_host) config_buf[0] |= 0x02 | 0x04;
    config_buf[1] = cfg.default_rollback;
    config_buf[2] = cfg.default_rollback;
    config_buf[3] = cfg.versus_win_count;
    config_buf[4] = 1;
    std.mem.writeInt(u16, config_buf[5..7], port, .little);
    const msg_len = 7;

    _ = ipc_server.send(config_buf[0..msg_len]);
    log.info("Config sent to DLL (netplay={}, host={}, training={}, port={d})", .{
        is_netplay_host, is_netplay_host, training, port,
    });

    while (win_launcher.isAlive()) {
        // Zig 0.16: std.Thread.sleep is gone — use std.Io.sleep(io, dur, clock).
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {};
    }
    log.info("Game exited", .{});
}

pub fn launchNetplayPeerImpl(allocator: std.mem.Allocator, io: std.Io, cfg: *config.Config, log: *logging.Logger, addr_str: []const u8, is_spectator: bool, pipe_name: []const u8) !void {
    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return;
    const peer_addr = addr_str[0..colon];
    const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch config.default_port;

    const game_exe = try std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" });
    defer allocator.free(game_exe);
    const dll_path = try std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" });
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch return;
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch return;

    var ipc_server = try ipc.IpcServer.listen(pipe_name);
    defer ipc_server.close();

    var win_launcher = launcher.WindowsLauncher{};
    const pid = win_launcher.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch return;
    log.info("Game launched (PID={d})", .{pid});

    if (!win_launcher.isAlive()) {
        log.err("Game exited immediately", .{});
        return;
    }

    ipc_server.waitForConnection() catch {};
    log.info("DLL connected via IPC", .{});

    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0x02 | (if (is_spectator) @as(u8, 0x08) else 0);
    config_buf[1] = if (is_spectator) 0 else cfg.default_rollback;
    config_buf[2] = if (is_spectator) 0 else cfg.default_rollback;
    config_buf[3] = cfg.versus_win_count;
    config_buf[4] = 1;
    std.mem.writeInt(u16, config_buf[5..7], port, .little);
    const addr_copy_len = @min(peer_addr.len, 248);
    @memcpy(config_buf[7 .. 7 + addr_copy_len], peer_addr[0..addr_copy_len]);
    const msg_len = 7 + addr_copy_len;

    _ = ipc_server.send(config_buf[0..msg_len]);
    log.info("Config sent ({s} -> {s}:{d})", .{
        if (is_spectator) "spectator" else "client", peer_addr, port,
    });

    while (win_launcher.isAlive()) {
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {};
    }
    log.info("Session ended", .{});
}

/// CLI netplay
pub fn runCliNetplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    port: u16,
    peer_host: ?[]const u8,
    is_spectator: bool,
    pipe_name: []const u8,
) !void {
    _ = is_spectator;
    var s = session.NetplaySession.init(allocator, io, log);
    defer s.deinit();
    s.config.rollback = cfg.default_rollback;
    s.config.win_count = cfg.versus_win_count;
    s.setLocalName(cfg.display_name);
    s.detectConnectionType();

    if (peer_host == null) {
        // Host: look up public IP, listen, handshake, then auto-confirm.
        s.lookupHostAddresses();
        try s.startHost(port, false);
    } else {
        try s.startJoin(peer_host.?, port, false);
    }

    // Run the handshake on the main thread. step() is non-blocking, so we
    // sleep ~16ms between steps to approximate 60fps. The handshake will
    // complete in a few seconds (or time out / fail).
    while (s.state != .launching and s.state != .failed and s.state != .cancelled) {
        s.step();
        if (s.state == .waiting_confirmation) {
            // CLI host mode: auto-confirm like the legacy --dummy path.
            s.hostConfirm();
        }
        std.Io.sleep(io, .{ .nanoseconds = 16 * std.time.ns_per_ms }, .real) catch {};
    }

    if (s.state != .launching) {
        log.err("Handshake did not reach launching state (state={s})", .{@tagName(s.state)});
        return error.HandshakeFailed;
    }

    log.info("Handshake OK — launching game (delay={d} rollback={d})", .{
        s.config.delay, s.config.rollback,
    });

    // Snapshot config and tear down the handshake socket before opening the
    // game (matches launchGameAfterHandshake in the GUI path).
    const snap = s.config;
    // Client: wait a short delay before tearing down ENet so the host has
    // time to receive and process our `confirm` packet (same rationale as
    // launchGameAfterHandshake — see comment there).
    if (!snap.is_host) {
        log.info("Client: waiting 500ms before ENet teardown (confirm delivery)...", .{});
        std.Io.sleep(io, .{ .nanoseconds = 500 * std.time.ns_per_ms }, .real) catch {};
    }
    s.deinit();

    // 1s delay so the OS frees the UDP port before the DLL rebinds it.
    std.Io.sleep(io, .{ .nanoseconds = 1 * std.time.ns_per_s }, .real) catch {};

    // Launch the game + inject + send config via IPC.
    const game_exe = try std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" });
    defer allocator.free(game_exe);
    const dll_path = try std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" });
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        log.err("MBAA.exe not found: {s}", .{game_exe});
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        log.err("hook.dll not found: {s}", .{dll_path});
        return;
    };

    var ipc_server = try ipc.IpcServer.listen(pipe_name);
    defer ipc_server.close();
    log.info("IPC server listening", .{});

    var win_launcher = launcher.WindowsLauncher{};
    const pid = win_launcher.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        log.err("Failed to launch MBAA.exe", .{});
        return;
    };
    log.info("Game launched (PID={d})", .{pid});

    if (!win_launcher.isAlive()) {
        log.err("Game exited immediately", .{});
        return;
    }

    ipc_server.waitForConnection() catch {
        log.warn("IPC connection failed", .{});
        return;
    };
    log.info("DLL connected via IPC", .{});

    // Build config buffer (same layout as launchGameAfterHandshake).
    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0x02 | (if (snap.is_host) @as(u8, 0x04) else 0);
    config_buf[1] = snap.delay;
    config_buf[2] = snap.rollback;
    config_buf[3] = snap.win_count;
    config_buf[4] = snap.host_player;
    std.mem.writeInt(u16, config_buf[5..7], snap.peer_port, .little);

    var msg_len: usize = 7;
    if (!snap.is_host) {
        const addr_slice = std.mem.sliceTo(&snap.peer_addr, 0);
        const addr_copy_len = @min(addr_slice.len, 248);
        @memcpy(config_buf[7 .. 7 + addr_copy_len], addr_slice[0..addr_copy_len]);
        msg_len = 7 + addr_copy_len;
    }

    _ = ipc_server.send(config_buf[0..msg_len]);
    log.info("Config sent to DLL (host={} delay={d} port={d})", .{
        snap.is_host, snap.delay, snap.peer_port,
    });

    while (win_launcher.isAlive()) {
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {};
    }
    log.info("Game exited", .{});
}
