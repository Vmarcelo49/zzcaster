// src/net/relay_config.zig
// ============================================================================
// Relay server configuration and failover ordering.
//
// The client maintains a list of relay servers, each tagged with a flavor
// (zzcaster or cccaster). On connect, the client tries them in order:
//
//   1. Any user-configured relay from config.ini (highest priority)
//   2. The hardcoded defaults (CCCaster relays first as fallback,
//      zzcaster relay slot reserved for when one is deployed)
//
// On TCP disconnect or timeout, the client advances to the next relay.
// This gives us:
//   - Day 1: works against CCCaster's live relays (no deploy needed)
//   - Day N: user can opt into the zzcaster relay via config.ini
//   - Day N+1: zzcaster relay goes live, becomes default in next release
//
// Format of relay_list entries:
//   [<flavor>:]<host>[:<port>]
//
//   flavor  — "zzcaster" or "cccaster" (default: zzcaster)
//   host    — IP or hostname
//   port    — default 3939
//
// Examples:
//   cccaster:melty.argoneus.com:3939
//   cccaster:104.238.130.23:3939
//   zzcaster:nat.example.com:3939
//   127.0.0.1:3939                  (defaults to zzcaster flavor)
// ============================================================================

const std = @import("std");
const protocol = @import("relay_protocol.zig");

pub const DEFAULT_RELAY_PORT: u16 = 3939;

/// A single relay entry — flavor + address.
pub const RelayEntry = struct {
    flavor: protocol.RelayFlavor,
    /// Hostname or IP — slice owned by the RelayList's allocator.
    /// Caller must keep the RelayList alive while using entries.
    host: []const u8,
    port: u16,

    /// Format as "host:port" (no flavor prefix).
    /// Returns a slice into the caller-provided buffer.
    pub fn formatAddr(self: RelayEntry, buf: []u8) []u8 {
        const len = std.fmt.bufPrint(buf, "{s}:{d}", .{ self.host, self.port }) catch return buf[0..0];
        return len;
    }

    /// Format as "[flavor] host:port" for log messages.
    pub fn formatLog(self: RelayEntry, buf: []u8) []u8 {
        const len = std.fmt.bufPrint(buf, "[{s}] {s}:{d}", .{ self.flavor.label(), self.host, self.port }) catch return buf[0..0];
        return len;
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
    pub fn append(self: *RelayList, allocator: std.mem.Allocator, flavor: protocol.RelayFlavor, host: []const u8, port: u16) !void {
        const host_dup = try allocator.dupe(u8, host);
        errdefer allocator.free(host_dup);
        try self.entries.append(allocator, .{ .flavor = flavor, .host = host_dup, .port = port });
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
/// Format: `[<flavor>:]<host>[:<port>]`
///   - Lines starting with '#' or ';' are comments → returns null
///   - Empty lines → returns null
///   - Flavor prefix is "zzcaster:" or "cccaster:" (case-insensitive)
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

    var rest = trimmed;
    var flavor: protocol.RelayFlavor = .zzcaster; // default

    // Check for flavor prefix — "zzcaster:" or "cccaster:"
    if (std.mem.indexOfScalar(u8, rest, ':')) |first_colon| {
        const possible_flavor = rest[0..first_colon];
        if (protocol.RelayFlavor.fromLabel(possible_flavor)) |f| {
            flavor = f;
            rest = rest[first_colon + 1 ..];
        }
        // else: not a flavor prefix — the colon was probably part of an
        // IPv6 address (we don't support IPv6 yet) or just a host:port
        // separator. Fall through with rest unchanged.
    }

    // Now `rest` is "host[:port]"
    var host: []const u8 = rest;
    var port: u16 = DEFAULT_RELAY_PORT;

    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        // Try to parse what's after the colon as a port number
        const maybe_port = rest[colon + 1 ..];
        if (std.fmt.parseInt(u16, maybe_port, 10)) |p| {
            host = rest[0..colon];
            port = p;
        } else |_| {
            // Not a number — treat the whole thing as a host
            host = rest;
        }
    }

    if (host.len == 0) return null;
    if (host.len > host_buf.len) return null;

    @memcpy(host_buf[0..host.len], host);
    return .{
        .flavor = flavor,
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
            try list.append(allocator, entry.flavor, entry.host, entry.port);
        }
    }

    return list;
}

/// The hardcoded default relay list. Used when config.ini doesn't
/// override.
///
/// Order: cccaster relays first (they're live and tested) as fallback,
/// then a zzcaster relay placeholder commented out (uncomment when one
/// is deployed).
///
/// This MUST stay in sync with the relay_list.txt file shipped in the
/// repo root.
pub const DEFAULT_RELAY_LIST: []const u8 =
    \\# zzcaster relay list — format: [flavor:]host[:port]
    \\# Flavors: zzcaster (room codes) or cccaster (IP-based matching)
    \\# Default port: 3939
    \\
    \\# Live CCCaster relays (fallback — work today, tested in production)
    \\cccaster:melty.argoneus.com:3939
    \\cccaster:104.238.130.23:3939
    \\
    \\# zzcaster relay (uncomment when one is deployed)
    \\# zzcaster:nat.zzcaster.com:3939
    \\
    \\# Local dev (uncomment for testing against a local server)
    \\# zzcaster:127.0.0.1:3939
;

// ============================================================================
// Tests
// ============================================================================

test "parseLine handles flavor prefix" {
    var host_buf: [256]u8 = undefined;

    const e1 = parseLine("cccaster:melty.argoneus.com:3939", &host_buf).?;
    try std.testing.expectEqual(protocol.RelayFlavor.cccaster, e1.flavor);
    try std.testing.expectEqualStrings("melty.argoneus.com", e1.host);
    try std.testing.expectEqual(@as(u16, 3939), e1.port);

    const e2 = parseLine("zzcaster:nat.example.com:3939", &host_buf).?;
    try std.testing.expectEqual(protocol.RelayFlavor.zzcaster, e2.flavor);
    try std.testing.expectEqualStrings("nat.example.com", e2.host);

    const e3 = parseLine("zzcaster:nat.example.com", &host_buf).?;
    try std.testing.expectEqual(@as(u16, 3939), e3.port); // default port
}

test "parseLine defaults to zzcaster flavor when no prefix" {
    var host_buf: [256]u8 = undefined;
    const e = parseLine("127.0.0.1:3939", &host_buf).?;
    try std.testing.expectEqual(protocol.RelayFlavor.zzcaster, e.flavor);
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
    const e = parseLine("  cccaster:example.com:3939  \r\n", &host_buf).?;
    try std.testing.expectEqualStrings("example.com", e.host);
}

test "parseList builds a list in order" {
    const content =
        \\# comment
        \\
        \\cccaster:melty.argoneus.com:3939
        \\zzcaster:127.0.0.1:3939
        \\
    ;
    var list = try parseList(std.testing.allocator, content);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), list.count());

    const e0 = list.get(0).?;
    try std.testing.expectEqual(protocol.RelayFlavor.cccaster, e0.flavor);
    try std.testing.expectEqualStrings("melty.argoneus.com", e0.host);

    const e1 = list.get(1).?;
    try std.testing.expectEqual(protocol.RelayFlavor.zzcaster, e1.flavor);
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
        .flavor = .zzcaster,
        .host = "example.com",
        .port = 3939,
    };
    const formatted = e.formatAddr(&buf);
    try std.testing.expectEqualStrings("example.com:3939", formatted);
}

test "RelayEntry.formatLog includes flavor" {
    var buf: [128]u8 = undefined;
    const e = RelayEntry{
        .flavor = .cccaster,
        .host = "melty.argoneus.com",
        .port = 3939,
    };
    const formatted = e.formatLog(&buf);
    try std.testing.expectEqualStrings("[cccaster] melty.argoneus.com:3939", formatted);
}

test "DEFAULT_RELAY_LIST contains cccaster fallbacks" {
    var list = try parseList(std.testing.allocator, DEFAULT_RELAY_LIST);
    defer list.deinit(std.testing.allocator);

    // Should have at least the 2 cccaster entries (others are commented)
    try std.testing.expect(list.count() >= 2);

    var cccaster_count: usize = 0;
    var zzcaster_count: usize = 0;
    for (0..list.count()) |i| {
        const e = list.get(i).?;
        switch (e.flavor) {
            .cccaster => cccaster_count += 1,
            .zzcaster => zzcaster_count += 1,
        }
    }
    try std.testing.expect(cccaster_count >= 2);
    try std.testing.expectEqual(@as(usize, 0), zzcaster_count); // all commented out
}
