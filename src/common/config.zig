const std = @import("std");

pub const version_string = "4.0-zig";
pub const default_port: u16 = 46318;

/// Max length of a display name (chars, excluding null terminator).
pub const max_name_len: usize = 31;

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
    /// Player display name shown to opponents during the netplay handshake.
    /// Empty string means "unset" — loadConfig() falls back to the name stored
    /// in the game's own System/NetConnect.dat (see fetchGameUserName).
    display_name: []u8 = &.{},

    /// Custom relay server list (one entry per line, format documented in
    /// src/net/relay_config.zig). If empty, the hardcoded DEFAULT_RELAY_LIST
    /// is used (live CCCaster relays as fallback).
    ///
    /// Example config.ini content:
    ///   relayServers=zzcaster:nat.example.com:3939
    ///   relayServers=cccaster:melty.argoneus.com:3939
    ///
    /// Multiple lines append multiple entries (in order).
    relay_servers: []u8 = &.{},

    pub fn deinit(self: *Config) void {
        self.allocator.free(self.app_dir);
        self.allocator.free(self.game_dir);
        if (self.display_name.len > 0) self.allocator.free(self.display_name);
        if (self.relay_servers.len > 0) self.allocator.free(self.relay_servers);
    }
};

pub fn loadConfig(allocator: std.mem.Allocator, io: std.Io) !Config {
    const app_dir = try allocator.dupe(u8, ".");
    errdefer allocator.free(app_dir);
    const game_dir = try allocator.dupe(u8, ".");

    var cfg = Config{
        .allocator = allocator,
        .app_dir = app_dir,
        .game_dir = game_dir,
    };

    // Try to read config.ini
    const file = std.Io.Dir.cwd().openFile(io, "zzcaster/config.ini", .{}) catch return cfg;
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    const len = reader.interface.readSliceShort(&buf) catch return cfg;
    parseConfig(&cfg, buf[0..len]);

    // Fallback: if no display name was configured, read it from the game's own
    // network config file (System/NetConnect.dat) — matches the legacy
    // CCCaster behavior (MainUi.cpp:1523: _config.setString("displayName",
    // ProcessManager::fetchGameUserName())).
    if (cfg.display_name.len == 0) {
        var name_buf: [64]u8 = undefined;
        if (fetchGameUserName(io, cfg.game_dir, &name_buf)) |name| {
            cfg.display_name = allocator.dupe(u8, name) catch &.{};
        }
    }

    return cfg;
}

/// Parse an INI-format config string into the given Config. Pure (no I/O) so
/// it can be unit-tested without touching the filesystem. The caller owns
/// `cfg.display_name` — this function allocates it via `cfg.allocator` and
/// frees any previous value first (so duplicate keys in the file replace).
///
/// Keys (matches saveConfig's output format):
///   versusWinCount=<u8>        default 2
///   defaultRollback=<u8>       default 4
///   maxRealDelay=<u8>          default 254
///   highCpuPriority=true|1     default true
///   autoReplaySave=true|1      default true
///   autoCheckUpdates=true|1    default true
///   displayName=<string>       default "" (empty)
/// Lines starting with '#' and blank lines are ignored. Invalid integer
/// values fall back to the field default.
pub fn parseConfig(cfg: *Config, content: []const u8) void {
    const allocator = cfg.allocator;
    var lines = std.mem.splitScalar(u8, content, '\n');

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
        } else if (std.mem.eql(u8, key, "displayName")) {
            // Replace any previously-loaded value (e.g. from an earlier line).
            if (cfg.display_name.len > 0) allocator.free(cfg.display_name);
            cfg.display_name = allocator.dupe(u8, val) catch &.{};
        } else if (std.mem.eql(u8, key, "relayServers")) {
            // Append to the existing list (one entry per line). Multiple
            // relayServers= lines accumulate — this lets users list multiple
            // relays in the flat-key INI format.
            const old = cfg.relay_servers;
            defer if (old.len > 0) allocator.free(old);
            const sep_len: usize = if (old.len > 0) 1 else 0; // newline separator
            const new_len = old.len + sep_len + val.len;
            const new_buf = allocator.alloc(u8, new_len) catch return;
            if (old.len > 0) {
                @memcpy(new_buf[0..old.len], old);
                new_buf[old.len] = '\n';
                @memcpy(new_buf[old.len + 1 ..], val);
            } else {
                @memcpy(new_buf[0..val.len], val);
            }
            cfg.relay_servers = new_buf;
        }
    }
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
    try writer.print("displayName={s}\n", .{cfg.display_name});

    // Save relay servers — one relayServers= line per entry.
    // We split on newlines and emit each non-empty line as a separate
    // relayServers= key (matches the parse-side accumulation logic).
    if (cfg.relay_servers.len > 0) {
        var relay_lines = std.mem.splitScalar(u8, cfg.relay_servers, '\n');
        while (relay_lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len > 0) {
                try writer.print("relayServers={s}\n", .{trimmed});
            }
        }
    }

    try file.writeStreamingAll(io, writer.buffered());
}

/// Read the player's network username from the game's own config file.
/// The MBAACC network config (System/NetConnect.dat) is a text file with a
/// line of the form:    UserName "PlayerName"
/// We extract the text between the first and last double-quote on that line.
/// Returns a slice into the caller-provided buffer, or null if the file is
/// missing / the key is absent / the value is empty.
///
/// Ported from the legacy ProcessManager::fetchGameUserName() (CCCaster
/// netplay/ProcessManager.cpp:335-369).
pub fn fetchGameUserName(io: std.Io, game_dir: []const u8, buf: []u8) ?[]const u8 {
    // Build "<game_dir>/System/NetConnect.dat" in a local buffer.
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/System/NetConnect.dat", .{game_dir}) catch return null;

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const len = reader.interface.readSliceShort(&read_buf) catch return null;
    const content = read_buf[0..len];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (!std.mem.startsWith(u8, line, "UserName")) continue;

        // Find the opening quote.
        const first_quote = std.mem.indexOfScalar(u8, line, '"') orelse return null;
        // Find the closing quote (last quote in the line).
        const last_quote = std.mem.lastIndexOfScalar(u8, line, '"') orelse return null;
        if (last_quote <= first_quote) return null;

        const name = line[first_quote + 1 .. last_quote];
        if (name.len == 0) return null;

        const copy_len = @min(name.len, buf.len);
        @memcpy(buf[0..copy_len], name[0..copy_len]);
        return buf[0..copy_len];
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================
//
// Run with: zig build test
//
// These cover parseConfig (the pure INI-parsing logic extracted from
// loadConfig). loadConfig itself isn't tested directly because it touches the
// filesystem — parseConfig is the testable seam.

fn defaultConfig(allocator: std.mem.Allocator) Config {
    return .{
        .allocator = allocator,
        .app_dir = allocator.dupe(u8, ".") catch unreachable,
        .game_dir = allocator.dupe(u8, ".") catch unreachable,
    };
}

test "parseConfig reads versusWinCount" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg, "versusWinCount=5\n");
    try std.testing.expectEqual(@as(u8, 5), cfg.versus_win_count);
}

test "parseConfig reads displayName" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg, "displayName=Bob\n");
    try std.testing.expectEqualStrings("Bob", cfg.display_name);
}

test "parseConfig reads all boolean keys with true/1" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg,
        \\highCpuPriority=true
        \\autoReplaySave=1
        \\autoCheckUpdates=true
        \\
    );
    try std.testing.expect(cfg.high_cpu_priority);
    try std.testing.expect(cfg.auto_replay_save);
    try std.testing.expect(cfg.auto_check_updates);
}

test "parseConfig ignores comments and blank lines" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg,
        \\# this is a comment
        \\
        \\versusWinCount=3
        \\   # indented comment
        \\displayName=Alice
        \\
    );
    try std.testing.expectEqual(@as(u8, 3), cfg.versus_win_count);
    try std.testing.expectEqualStrings("Alice", cfg.display_name);
}

test "parseConfig defaults when key absent" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg, "# empty config\n");
    try std.testing.expectEqual(@as(u8, 2), cfg.versus_win_count);
    try std.testing.expectEqual(@as(u8, 4), cfg.default_rollback);
    try std.testing.expectEqual(@as(u8, 254), cfg.max_real_delay);
    try std.testing.expect(cfg.high_cpu_priority);
    try std.testing.expect(cfg.auto_replay_save);
    try std.testing.expect(cfg.auto_check_updates);
    try std.testing.expectEqual(@as(usize, 0), cfg.display_name.len);
}

test "parseConfig invalid integer falls back to default" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg, "versusWinCount=notanumber\n");
    try std.testing.expectEqual(@as(u8, 2), cfg.versus_win_count);
}

test "parseConfig duplicate key keeps last value" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg, "displayName=First\ndisplayName=Second\n");
    try std.testing.expectEqualStrings("Second", cfg.display_name);
}

test "parseConfig reads single relayServers" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg, "relayServers=zzcaster:nat.example.com:3939\n");
    try std.testing.expectEqualStrings("zzcaster:nat.example.com:3939", cfg.relay_servers);
}

test "parseConfig accumulates multiple relayServers lines" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg,
        \\relayServers=zzcaster:nat.example.com:3939
        \\relayServers=cccaster:melty.argoneus.com:3939
        \\
    );
    // Should contain both entries, separated by a newline.
    try std.testing.expectEqualStrings(
        "zzcaster:nat.example.com:3939\ncccaster:melty.argoneus.com:3939",
        cfg.relay_servers,
    );
}

test "parseConfig relayServers defaults to empty" {
    const allocator = std.testing.allocator;
    var cfg = defaultConfig(allocator);
    defer cfg.deinit();

    parseConfig(&cfg, "# no relay config\n");
    try std.testing.expectEqual(@as(usize, 0), cfg.relay_servers.len);
}
