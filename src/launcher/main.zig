const std = @import("std");
const builtin = @import("builtin");
const config = @import("common").config;
const logging = @import("common").logging;
const ipc = @import("common").ipc;
const ui = @import("ui.zig");
const launcher = @import("launcher.zig");

pub const CliMode = enum {
    menu,
    training,
    versus,
    host,
    join,
    spectate,
};

// Zig 0.16: main() receives the full std.process.Init — the runtime provides a
// ready-to-use general purpose allocator (init.gpa, leak-checked in Debug) and
// I/O backend (init.io), so we no longer construct those manually. Args live
// under init.minimal.args (Init wraps Minimal).
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
    //
    // Zig 0.16: argsWithAllocator is gone; iterate via Args.Iterator.
    // On Windows the iterator buffers into a WTF-8 string; initAllocator is
    // the cross-platform path that handles both POSIX and Windows.
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
            std.Io.File.stdout().writeStreamingAll(io, "Usage: zzcaster.exe [--mode=training|versus|host|join|spectate] [--port=N] [--peer=ip:port] [--name=NAME]\n") catch {};
            return;
        }
    }

    // --name overrides the config's display name for this session.
    // (Applied here — needs both cli_name and cfg to be in scope.)

    // Each launcher instance needs a unique pipe name so two zzcaster.exe
    // processes can run side-by-side (e.g. for local netplay testing).
    var pipe_name_buf: [64]u8 = undefined;
    const pipe_name = std.fmt.bufPrint(
        &pipe_name_buf,
        "zzcaster_{d}_pipe",
        .{launcher.getCurrentProcessId_win32()},
    ) catch "zzcaster_pipe";
    launcher.setenv_win32("CCCASTER_PIPE", pipe_name);

    // Init logging
    var log = try logging.Logger.init(allocator, io, "zzcaster/debug.log");
    defer log.deinit();
    log.info("CCCaster v{s} (zig port) [mode={s}]", .{ config.version_string, @tagName(cli_mode) });

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
