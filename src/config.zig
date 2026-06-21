const std = @import("std");

pub const version_string = "4.0-zig";
pub const default_port: u16 = 46318;

pub const Config = struct {
    allocator: std.mem.Allocator,
    app_dir: []u8,
    game_dir: []u8,
    versus_win_count: u8 = 2,
    default_rollback: u8 = 4,
    max_real_delay: u8 = 254,
    high_cpu_priority: bool = true,
    stage_animations_off: bool = false,
    auto_replay_save: bool = true,
    auto_check_updates: bool = true,
    log_to_stdout: bool = false,

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.app_dir);
        self.allocator.free(self.game_dir);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, io: std.Io) !Config {
    var cfg = Config{
        .allocator = allocator,
        .app_dir = try allocator.dupe(u8, "."),
        .game_dir = try allocator.dupe(u8, "."),
    };

    // Try to read config.ini
    const file = std.Io.Dir.cwd().openFile(io, "zzcaster/config.ini", .{}) catch return cfg;
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const len = reader.interface.readSliceShort(&buf) catch return cfg;
    var lines = std.mem.splitScalar(u8, buf[0..len], '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " ");
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " ");

        if (std.mem.eql(u8, key, "versusWinCount")) {
            cfg.versus_win_count = std.fmt.parseInt(u8, val, 10) catch 2;
        } else if (std.mem.eql(u8, key, "defaultRollback")) {
            cfg.default_rollback = std.fmt.parseInt(u8, val, 10) catch 4;
        } else if (std.mem.eql(u8, key, "maxRealDelay")) {
            cfg.max_real_delay = std.fmt.parseInt(u8, val, 10) catch 254;
        } else if (std.mem.eql(u8, key, "highCpuPriority")) {
            cfg.high_cpu_priority = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        } else if (std.mem.eql(u8, key, "autoReplaySave")) {
            cfg.auto_replay_save = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        } else if (std.mem.eql(u8, key, "autoCheckUpdates")) {
            cfg.auto_check_updates = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1");
        }
    }

    return cfg;
}

pub fn saveConfig(cfg: *const Config, io: std.Io) !void {
    const file = try std.Io.Dir.cwd().createFile(io, "zzcaster/config.ini", .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.print("versusWinCount={d}\n", .{cfg.versus_win_count});
    try writer.print("defaultRollback={d}\n", .{cfg.default_rollback});
    try writer.print("maxRealDelay={d}\n", .{cfg.max_real_delay});
    try writer.print("highCpuPriority={s}\n", .{if (cfg.high_cpu_priority) "true" else "false"});
    try writer.print("autoReplaySave={s}\n", .{if (cfg.auto_replay_save) "true" else "false"});
    try writer.print("autoCheckUpdates={s}\n", .{if (cfg.auto_check_updates) "true" else "false"});

    try file.writeStreamingAll(io, writer.buffered());
}
