// src/net/relay_config.zig
// ============================================================================
// Relay server configuration and failover ordering.
//
// The client maintains a list of relay servers. On connect, the client tries
// them in order:
//
//   1. Any user-configured relay from config.ini (highest priority)
//   2. The hardcoded default (zzcaster.duckdns.org:3939)
//
// On TCP disconnect or timeout, the client advances to the next relay.
//
// Format of relay_list entries:
//   <host>[:<port>]
//
//   host    — IP or hostname
//   port    — default 3939
//
// Examples:
//   zzcaster.duckdns.org:3939
//   127.0.0.1:3939
// ============================================================================

const std = @import("std");
const protocol = @import("relay_protocol.zig");

pub const DEFAULT_RELAY_PORT: u16 = 3939;

/// A single relay entry — host + port.
pub const RelayEntry = struct {
    /// Hostname or IP — slice owned by the RelayList's allocator.
    /// Caller must keep the RelayList alive while using entries.
    host: []const u8,
    port: u16,

    /// Format as "host:port".
    /// Returns a slice into the caller-provided buffer.
    pub fn formatAddr(self: RelayEntry, buf: []u8) []u8 {
        const len = std.fmt.bufPrint(buf, "{s}:{d}", .{ self.host, self.port }) catch return buf[0..0];
        return len;
    }

    /// Format as "host:port" for log messages.
    pub fn formatLog(self: RelayEntry, buf: []u8) []u8 {
        return self.formatAddr(buf);
    }
};

/// RelayList holds the ordered list of relay servers to try.
/// Entries are owned by the list (host strings are duped into the list's
/// allocator). Free with `deinit`.
///
/// Uses the Zig 0.16 ArrayList pattern: `.empty` + per-call allocator.
pub const RelayList = struct {
    entries: std.ArrayList(RelayEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator) RelayList {
        // .empty is the zero state; allocator is passed per-call.
        // This matches the Zig 0.16 container init pattern.
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *RelayList, allocator: std.mem.Allocator) void {
        for (self.entries.items) |e| {
            allocator.free(e.host);
        }
        self.entries.deinit(allocator);
    }

    /// Append an entry. `host` is duped into the list's allocator.
    pub fn append(self: *RelayList, allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
        const host_dup = try allocator.dupe(u8, host);
        errdefer allocator.free(host_dup);
        try self.entries.append(allocator, .{ .host = host_dup, .port = port });
    }

    pub fn count(self: *const RelayList) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const RelayList, index: usize) ?RelayEntry {
        if (index >= self.entries.items.len) return null;
        return self.entries.items[index];
    }
};

/// Parse a single line from relay_list.txt into a RelayEntry.
///
/// Format: `<host>[:<port>]`
///   - Lines starting with '#' or ';' are comments → returns null
///   - Empty lines → returns null
///   - Port defaults to DEFAULT_RELAY_PORT (3939) if omitted
///
/// `host_buf` receives the host string (null-terminated not required).
/// Returns the parsed entry, or null if the line should be skipped.
pub fn parseLine(
    line: []const u8,
    host_buf: []u8,
) ?RelayEntry {
    // Trim whitespace
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '#' or trimmed[0] == ';') return null;

    var host: []const u8 = trimmed;
    var port: u16 = DEFAULT_RELAY_PORT;

    if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |colon| {
        // Try to parse what's after the colon as a port number
        const maybe_port = trimmed[colon + 1 ..];
        if (std.fmt.parseInt(u16, maybe_port, 10)) |p| {
            host = trimmed[0..colon];
            port = p;
        } else |_| {
            // Not a number — treat the whole thing as a host
            host = trimmed;
        }
    }

    if (host.len == 0) return null;
    if (host.len > host_buf.len) return null;

    @memcpy(host_buf[0..host.len], host);
    return .{
        .host = host_buf[0..host.len],
        .port = port,
    };
}

/// Build a RelayList from a multi-line string (the contents of
/// relay_list.txt or the [Network] RelayServers config field).
///
/// Lines are processed in order; entries are appended in the order they
/// appear. Comment lines and blank lines are skipped.
pub fn parseList(
    allocator: std.mem.Allocator,
    content: []const u8,
) !RelayList {
    var list = RelayList.init(allocator);
    errdefer list.deinit(allocator);

    var host_buf: [256]u8 = undefined;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (parseLine(line, &host_buf)) |entry| {
            try list.append(allocator, entry.host, entry.port);
        }
    }

    return list;
}

/// The hardcoded default relay list. Used when config.ini doesn't override.
///
/// This MUST stay in sync with the relay_list.txt file shipped in the
/// repo root.
pub const DEFAULT_RELAY_LIST: []const u8 =
    \\# zzcaster relay list — format: host[:port]
    \\# Default port: 3939
    \\
    \\# Primary zzcaster relay (room-code based, full NAT traversal support).
    \\zzcaster.duckdns.org:3939
    \\
    \\# Local dev (uncomment for testing against a local server)
    \\# 127.0.0.1:3939
;

// ============================================================================
// Tests
// ============================================================================

test "parseLine handles host:port" {
    var host_buf: [256]u8 = undefined;

    const e1 = parseLine("zzcaster.duckdns.org:3939", &host_buf).?;
    try std.testing.expectEqualStrings("zzcaster.duckdns.org", e1.host);
    try std.testing.expectEqual(@as(u16, 3939), e1.port);

    const e2 = parseLine("nat.example.com:3939", &host_buf).?;
    try std.testing.expectEqualStrings("nat.example.com", e2.host);

    const e3 = parseLine("nat.example.com", &host_buf).?;
    try std.testing.expectEqual(@as(u16, 3939), e3.port); // default port
}

test "parseLine handles IP addresses" {
    var host_buf: [256]u8 = undefined;
    const e = parseLine("127.0.0.1:3939", &host_buf).?;
    try std.testing.expectEqualStrings("127.0.0.1", e.host);
    try std.testing.expectEqual(@as(u16, 3939), e.port);
}

test "parseLine skips comments and blank lines" {
    var host_buf: [256]u8 = undefined;
    try std.testing.expect(parseLine("# comment", &host_buf) == null);
    try std.testing.expect(parseLine("; also a comment", &host_buf) == null);
    try std.testing.expect(parseLine("", &host_buf) == null);
    try std.testing.expect(parseLine("   \t  ", &host_buf) == null);
}

test "parseLine handles whitespace" {
    var host_buf: [256]u8 = undefined;
    const e = parseLine("  example.com:3939  \r\n", &host_buf).?;
    try std.testing.expectEqualStrings("example.com", e.host);
}

test "parseList builds a list in order" {
    const content =
        \\# comment
        \\
        \\zzcaster.duckdns.org:3939
        \\127.0.0.1:3939
        \\
    ;
    var list = try parseList(std.testing.allocator, content);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), list.count());

    const e0 = list.get(0).?;
    try std.testing.expectEqualStrings("zzcaster.duckdns.org", e0.host);

    const e1 = list.get(1).?;
    try std.testing.expectEqualStrings("127.0.0.1", e1.host);
}

test "parseList handles empty content" {
    var list = try parseList(std.testing.allocator, "");
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), list.count());
}

test "parseList handles all-comments" {
    var list = try parseList(std.testing.allocator, "# a\n# b\n# c\n");
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), list.count());
}

test "RelayEntry.formatAddr produces host:port" {
    var buf: [128]u8 = undefined;
    const e = RelayEntry{
        .host = "example.com",
        .port = 3939,
    };
    const formatted = e.formatAddr(&buf);
    try std.testing.expectEqualStrings("example.com:3939", formatted);
}

test "RelayEntry.formatLog produces host:port" {
    var buf: [128]u8 = undefined;
    const e = RelayEntry{
        .host = "zzcaster.duckdns.org",
        .port = 3939,
    };
    const formatted = e.formatLog(&buf);
    try std.testing.expectEqualStrings("zzcaster.duckdns.org:3939", formatted);
}

test "DEFAULT_RELAY_LIST contains the primary relay" {
    var list = try parseList(std.testing.allocator, DEFAULT_RELAY_LIST);
    defer list.deinit(std.testing.allocator);

    // Should have exactly 1 entry (the primary relay; the local dev line
    // is commented out).
    try std.testing.expectEqual(@as(usize, 1), list.count());

    const e = list.get(0).?;
    try std.testing.expectEqualStrings("zzcaster.duckdns.org", e.host);
    try std.testing.expectEqual(@as(u16, 3939), e.port);
}
