// src/net/connection_detector.zig
// ============================================================================
// Auto-detection of user input format for the unified netplay input field.
//
// Parsing rules (applied in order):
//   1. Empty string                → .empty (host: random port)
//   2. Starts with '#'             → .room_code (strip #, join via relay)
//   3. Contains ':'                → .ip_port (parse as host:port)
//   4. All digits, valid port range → .port (host: use this port)
//   5. Anything else               → .invalid
// ============================================================================

const std = @import("std");

pub const InputType = enum {
    empty,
    room_code,
    ip_port,
    port,
    invalid,
};

/// Result of parsing user input — includes extracted data.
pub const ParsedInput = struct {
    type: InputType,

    /// For .room_code: the code without the '#' prefix (e.g., "ABCD")
    /// For .ip_port: the full "host:port" string
    /// For .port: empty (use .port_value)
    /// For .empty/.invalid: empty
    value: []const u8,

    /// For .port: the parsed port number
    /// For .ip_port: the port extracted from "host:port"
    /// For .room_code/.empty/.invalid: 0
    port: u16,

    /// For .ip_port: true if the host part is a private/loopback IP
    /// (127.x, 10.x, 192.168.x, 172.16-31.x, localhost, 169.254.x)
    /// For other types: false
    is_local: bool,
};

/// Parse user input from the unified text field.
///
/// Rules:
///   ""              → .empty
///   "#ABCD"         → .room_code, value="ABCD"
///   "192.168.0.2:46318" → .ip_port, value="192.168.0.2:46318", port=46318, is_local=true
///   "203.0.113.10:46318" → .ip_port, value="203.0.113.10:46318", port=46318, is_local=false
///   "46318"         → .port, port=46318
///   "abc"           → .invalid
pub fn parseInput(input: []const u8) ParsedInput {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");

    if (trimmed.len == 0) {
        return .{ .type = .empty, .value = "", .port = 0, .is_local = false };
    }

    // Check for room code: starts with '#'
    if (trimmed[0] == '#') {
        const code = trimmed[1..];
        return .{ .type = .room_code, .value = code, .port = 0, .is_local = false };
    }

    // Check for ip:port: contains ':'
    if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |colon| {
        const host_part = trimmed[0..colon];
        const port_str = trimmed[colon + 1 ..];

        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            return .{ .type = .invalid, .value = "", .port = 0, .is_local = false };
        };

        return .{
            .type = .ip_port,
            .value = trimmed,
            .port = port,
            .is_local = isPrivateOrLoopback(host_part),
        };
    }

    // Check for bare port number
    if (std.fmt.parseInt(u16, trimmed, 10) catch null) |port| {
        if (port > 0) {
            return .{ .type = .port, .value = "", .port = port, .is_local = false };
        }
    }

    return .{ .type = .invalid, .value = "", .port = 0, .is_local = false };
}

/// Check if a host string is a private/loopback address.
/// Private ranges (RFC 1918):
///   10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
/// Loopback: 127.0.0.0/8, localhost
/// Link-local: 169.254.0.0/16
fn isPrivateOrLoopback(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost")) return true;

    var parts = std.mem.splitScalar(u8, host, '.');
    const p1 = parts.next() orelse return false;
    const p2 = parts.next() orelse return false;
    const o1 = std.fmt.parseInt(u8, p1, 10) catch return false;
    const o2 = std.fmt.parseInt(u8, p2, 10) catch return false;

    if (o1 == 127) return true; // loopback
    if (o1 == 10) return true; // private class A
    if (o1 == 192 and o2 == 168) return true; // private class C
    if (o1 == 172 and o2 >= 16 and o2 <= 31) return true; // private class B
    if (o1 == 169 and o2 == 254) return true; // link-local

    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "parseInput: empty string" {
    const r = parseInput("");
    try std.testing.expectEqual(InputType.empty, r.type);
    try std.testing.expectEqual(@as(u16, 0), r.port);
}

test "parseInput: empty after trim" {
    const r = parseInput("   \n  ");
    try std.testing.expectEqual(InputType.empty, r.type);
}

test "parseInput: room code with #" {
    const r = parseInput("#ABCD");
    try std.testing.expectEqual(InputType.room_code, r.type);
    try std.testing.expectEqualStrings("ABCD", r.value);
}

test "parseInput: room code with # and whitespace" {
    const r = parseInput("  #WXYZ  ");
    try std.testing.expectEqual(InputType.room_code, r.type);
    try std.testing.expectEqualStrings("WXYZ", r.value);
}

test "parseInput: ip:port local" {
    const r = parseInput("127.0.0.1:46318");
    try std.testing.expectEqual(InputType.ip_port, r.type);
    try std.testing.expectEqual(@as(u16, 46318), r.port);
    try std.testing.expect(r.is_local);
}

test "parseInput: ip:port private LAN" {
    const r = parseInput("192.168.0.2:46318");
    try std.testing.expectEqual(InputType.ip_port, r.type);
    try std.testing.expect(r.is_local);
}

test "parseInput: ip:port public" {
    const r = parseInput("203.0.113.10:46318");
    try std.testing.expectEqual(InputType.ip_port, r.type);
    try std.testing.expect(!r.is_local);
}

test "parseInput: hostname:port" {
    const r = parseInput("zzcaster.duckdns.org:3939");
    try std.testing.expectEqual(InputType.ip_port, r.type);
    try std.testing.expectEqual(@as(u16, 3939), r.port);
    try std.testing.expect(!r.is_local);
}

test "parseInput: localhost:port" {
    const r = parseInput("localhost:46318");
    try std.testing.expectEqual(InputType.ip_port, r.type);
    try std.testing.expect(r.is_local);
}

test "parseInput: bare port number" {
    const r = parseInput("46318");
    try std.testing.expectEqual(InputType.port, r.type);
    try std.testing.expectEqual(@as(u16, 46318), r.port);
}

test "parseInput: port 0 is invalid" {
    const r = parseInput("0");
    try std.testing.expectEqual(InputType.invalid, r.type);
}

test "parseInput: random text is invalid" {
    try std.testing.expectEqual(InputType.invalid, parseInput("hello").type);
    try std.testing.expectEqual(InputType.invalid, parseInput("abc123").type);
    try std.testing.expectEqual(InputType.invalid, parseInput("12.34.56.78").type); // no port
}

test "parseInput: ip:port with bad port is invalid" {
    try std.testing.expectEqual(InputType.invalid, parseInput("1.2.3.4:abc").type);
    try std.testing.expectEqual(InputType.invalid, parseInput("1.2.3.4:").type);
}

test "parseInput: port too large is invalid" {
    try std.testing.expectEqual(InputType.invalid, parseInput("99999").type);
}

test "parseInput: 10.x.x.x is local" {
    const r = parseInput("10.0.0.5:8080");
    try std.testing.expect(r.is_local);
}

test "parseInput: 172.16-31.x.x is local" {
    try std.testing.expect(parseInput("172.16.0.1:8080").is_local);
    try std.testing.expect(parseInput("172.31.255.255:8080").is_local);
    try std.testing.expect(!parseInput("172.15.0.1:8080").is_local);
    try std.testing.expect(!parseInput("172.32.0.1:8080").is_local);
}

test "parseInput: 169.254.x.x is local (link-local)" {
    try std.testing.expect(parseInput("169.254.1.1:8080").is_local);
}

test "parseInput: 8.8.8.8 is NOT local" {
    try std.testing.expect(!parseInput("8.8.8.8:53").is_local);
}
