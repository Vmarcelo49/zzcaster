const std = @import("std");
const builtin = @import("builtin");
const config = @import("common").config;
const logging = @import("common").logging;
const ipc = @import("common").ipc;
const ui = @import("ui.zig");
const launcher = @import("launcher.zig");
const relay_client_mod = @import("net").relay_client;

pub const CliMode = enum {
    menu,
    training,
    versus,
    host,
    join,
    spectate,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const args_vector = init.minimal.args;

    // Parse CLI args (very minimal — just enough for non-interactive launch).
    //   zzcaster.exe                  → interactive ImGui menu (default)
    //   zzcaster.exe --mode=training  → bypass UI, launch offline training
    //   zzcaster.exe --mode=versus    → bypass UI, launch offline versus
    //   zzcaster.exe --mode=host --port=46318 [--name=Bob]
    //   zzcaster.exe --mode=join --peer=1.2.3.4:46318 [--name=Bob]
    //   zzcaster.exe --mode=spectate --peer=1.2.3.4:46318

    var it = try args_vector.iterateAllocator(allocator);
    defer it.deinit();
    var cli_mode: CliMode = .menu;
    var cli_port: u16 = config.default_port;
    var cli_peer: ?[]const u8 = null;
    var cli_name: ?[]const u8 = null;
    while (it.next()) |a| {
        if (std.mem.startsWith(u8, a, "--mode=")) {
            const v = a["--mode=".len..];
            cli_mode = std.meta.stringToEnum(CliMode, v) orelse {
                std.Io.File.stdout().writeStreamingAll(io, "unknown --mode value: ") catch {};
                std.Io.File.stdout().writeStreamingAll(io, v) catch {};
                std.Io.File.stdout().writeStreamingAll(io, "\n") catch {};
                std.process.exit(2);
            };
        } else if (std.mem.startsWith(u8, a, "--port=")) {
            cli_port = std.fmt.parseInt(u16, a["--port=".len..], 10) catch config.default_port;
        } else if (std.mem.startsWith(u8, a, "--peer=")) {
            cli_peer = a["--peer=".len..];
        } else if (std.mem.startsWith(u8, a, "--name=")) {
            cli_name = a["--name=".len..];
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            const usage =
                \\zzcaster v{s} — MBAACC netplay launcher
                \\
                \\Usage: zzcaster.exe [options]
                \\
                \\Options:
                \\  --mode=training       Launch offline training mode
                \\  --mode=versus         Launch offline versus mode
                \\  --mode=host           Host a netplay session (use --port)
                \\  --mode=join           Join a netplay session (use --peer)
                \\  --mode=spectate       Spectate a session (use --peer)
                \\  --port=N              Port number (default: 46318)
                \\  --peer=ip:port        Remote address to join/spectate
                \\  --peer=#ROOM          Room code to join via relay
                \\  --name=NAME           Display name for this session
                \\  -h, --help            Show this help message
                \\
                \\No arguments starts the GUI launcher.
                \\
            ;
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, usage, .{config.version_string}) catch usage[0..100];
            std.Io.File.stdout().writeStreamingAll(io, msg) catch {};
            return;
        }
    }

    // --name overrides the config's display name for this session.

    var pipe_name_buf: [64]u8 = undefined;
    const pipe_name = std.fmt.bufPrint(
        &pipe_name_buf,
        "zzcaster_{d}_pipe",
        .{launcher.getCurrentProcessId_win32()},
    ) catch "zzcaster_pipe";
    launcher.setenv_win32("CCCASTER_PIPE", pipe_name);

    // Resolve the log path to an ABSOLUTE, user-writable location.
    //
    // The previous code used the CWD-relative path "zzcaster/debug.log",
    // which broke in three common scenarios on Windows 10:
    //
    //   1. Launched from a shortcut with a different "Start in" folder —
    //      CWD is not the exe's directory, so the relative path points
    //      nowhere useful.
    //   2. Exe in Program Files — without a manifest, UAC virtualization
    //      silently redirected writes to %LOCALAPPDATA%\VirtualStore\...,
    //      which the user never checks. "No logs created" was the symptom.
    //   3. Exe in a read-only location (e.g. C:\Program Files (x86)) —
    //      createDirPath failed silently, so the log was never written.
    //
    // Using %LOCALAPPDATA%\zzcaster\debug.log fixes all three: it's
    // always writable by the current user, it's an absolute path (immune
    // to CWD issues), and it's the standard location for per-user app
    // data on Windows Vista+.
    var log_path_buf: [512]u8 = undefined;
    const log_path = launcher.resolveLogPath(&log_path_buf);

    // Init logging
    var log = try logging.Logger.init(allocator, io, log_path);
    defer log.deinit();
    log.info("CCCaster v{s} (zig port) [mode={s}]", .{ config.version_string, @tagName(cli_mode) });
    log.info("Log file: {s}", .{log_path});

    // Initialize Winsock BEFORE any networking. ENet calls WSAStartup
    // internally via enet_initialize(), but the relay client uses raw
    // ws2_32 sockets (socket, connect, send, recv, select) BEFORE ENet
    // is initialized — during the relay handshake phase. Without this
    // call, all relay client socket operations silently fail.
    if (!relay_client_mod.initWinsock()) {
        log.err("Failed to initialize Winsock — relay mode will not work", .{});
    }
    defer relay_client_mod.deinitWinsock();

    // Parse config
    var cfg = try config.loadConfig(allocator, io);
    defer cfg.deinit();
    log.info("App dir: {s}", .{cfg.app_dir});

    // --name overrides the config's display name for this session.
    if (cli_name) |name| {
        if (cfg.display_name.len > 0) allocator.free(cfg.display_name);
        cfg.display_name = allocator.dupe(u8, name) catch &.{};
    }

    // Non-interactive mode: bypass the UI entirely.
    if (cli_mode != .menu) {
        try ui.runCli(allocator, io, &cfg, &log, cli_mode, cli_port, cli_peer, pipe_name);
        return;
    }

    // Run the interactive ImGui UI (SDL2 init happens inside ui.run)
    try ui.run(allocator, io, &cfg, &log, pipe_name);
}
