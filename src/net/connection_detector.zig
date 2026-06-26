// src/net/connection_detector.zig
// ============================================================================
// Auto-detection of user input format for the netplay Join field.
//
// Given a user-typed string, determines whether it's:
//   .room_code     — 4 chars from the unambiguous alphabet (A-Z, 2-9, no I/O/0/1)
//                    → relay join (zzcaster flavor)
//   .local_ip      — 127.x.x.x, 10.x.x.x, 192.168.x.x, 172.16-31.x.x,
//                    localhost, or [::1]
//                    → direct join (no relay needed)
//   .public_ip     — any other IP:port or hostname:port
//                    → try relay-assisted first (cccaster flavor),
//                      then direct as fallback
//   .invalid       — can't be parsed
// ============================================================================

const std = @import("std");
const protocol = @import("relay_protocol.zig");

pub const InputType = enum {
    room_code, // 4-letter code → zzcaster relay
    local_ip, // private/loopback IP → direct only
    public_ip_or_host, // public IP/hostname → relay first, then direct
    invalid,
};

/// Detect what kind of input the user typed in the Join field.
///
/// Rules:
///   - Exactly 4 chars, all from ROOM_CODE_ALPHABET → .room_code
///   - Contains ':' → try to parse as ip:port or hostname:port
///     - If IP is private/loopback → .local_ip
///     - Otherwise → .public_ip_or_host
///   - Anything else → .invalid
///
/// For host mode (no join input), the host always uses relay first,
/// then falls back to direct. This function isn't needed for hosting.
pub fn detectInputType(input: []const u8) InputType {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return .invalid;

    // Check for room code: exactly 4 chars from the safe alphabet
    if (trimmed.len == 4 and protocol.isValidRoomCode(trimmed)) {
        return .room_code;
    }

    // Must contain ':' to be an ip:port or hostname:port
    const colon = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return .invalid;
    const host_part = trimmed[0..colon];
    const port_str = trimmed[colon + 1 ..];

    // Port must be a valid number
    _ = std.fmt.parseInt(u16, port_str, 10) catch return .invalid;

    if (host_part.len == 0) return .invalid;

    // Check for localhost
    if (std.mem.eql(u8, host_part, "localhost")) {
        return .local_ip;
    }

    // Check for IPv6 loopback [::1]
    if (std.mem.startsWith(u8, host_part, "[")) {
        return .local_ip; // IPv6 — treat as local for now
    }

    // Try to parse as IPv4 dotted-decimal
    if (isPrivateIPv4(host_part)) {
        return .local_ip;
    }

    // If it looks like a valid IPv4 but not private, it's public
    if (isValidIPv4(host_part)) {
        return .public_ip_or_host;
    }

    // If it's not a valid IPv4 but contains valid hostname chars, treat
    // as public hostname (e.g., "zzcaster.duckdns.org")
    if (isValidHostname(host_part)) {
        return .public_ip_or_host;
    }

    return .invalid;
}

/// Check if a string is a valid IPv4 dotted-decimal address.
fn isValidIPv4(s: []const u8) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > 4) return false;
        const octet = std.fmt.parseInt(u8, part, 10) catch return false;
        _ = octet;
    }
    return count == 4;
}

/// Check if a string is a private/loopback IPv4 address.
/// Private ranges (RFC 1918):
///   10.0.0.0/8       — 10.x.x.x
///   172.16.0.0/12    — 172.16.x.x through 172.31.x.x
///   192.168.0.0/16   — 192.168.x.x
/// Loopback:
///   127.0.0.0/8      — 127.x.x.x
/// Link-local:
///   169.254.0.0/16   — 169.254.x.x
fn isPrivateIPv4(s: []const u8) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    const p1 = parts.next() orelse return false;
    const p2 = parts.next() orelse return false;
    const o1 = std.fmt.parseInt(u8, p1, 10) catch return false;
    const o2 = std.fmt.parseInt(u8, p2, 10) catch return false;

    // 127.x.x.x — loopback
    if (o1 == 127) return true;
    // 10.x.x.x — private class A
    if (o1 == 10) return true;
    // 192.168.x.x — private class C
    if (o1 == 192 and o2 == 168) return true;
    // 172.16-31.x.x — private class B
    if (o1 == 172 and o2 >= 16 and o2 <= 31) return true;
    // 169.254.x.x — link-local
    if (o1 == 169 and o2 == 254) return true;

    return false;
}

/// Check if a string is a valid hostname (RFC 1123, simplified).
/// Allows: letters, digits, hyphens, dots. Must not start/end with hyphen.
fn isValidHostname(s: []const u8) bool {
    if (s.len == 0 or s.len > 253) return false;
    var last_was_dot = false;
    var last_was_hyphen = false;

    for (s, 0..) |c, i| {
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        const is_hyphen = c == '-';
        const is_dot = c == '.';

        if (!is_alnum and !is_hyphen and !is_dot) return false;

        if (is_hyphen_or_dot(c)) {
            if (i == 0) return false; // can't start with - or .
            if (last_was_hyphen or last_was_dot) return false; // no consecutive - or .
        }

        last_was_hyphen = is_hyphen;
        last_was_dot = is_dot;
    }

    // Must end with alphanumeric (not - or .)
    if (last_was_hyphen or last_was_dot) return false;

    return true;
}

fn is_hyphen_or_dot(c: u8) bool {
    return c == '-' or c == '.';
}

// ============================================================================
// Tests
// ============================================================================

test "detectInputType: room code" {
    try std.testing.expectEqual(InputType.room_code, detectInputType("ABCD"));
    try std.testing.expectEqual(InputType.room_code, detectInputType("WXYZ"));
    try std.testing.expectEqual(InputType.room_code, detectInputType("2345"));
}

test "detectInputType: localhost" {
    try std.testing.expectEqual(InputType.local_ip, detectInputType("localhost:46318"));
    try std.testing.expectEqual(InputType.local_ip, detectInputType("127.0.0.1:46318"));
    try std.testing.expectEqual(InputType.local_ip, detectInputType("127.0.0.1:5"));
}

test "detectInputType: private IPs" {
    try std.testing.expectEqual(InputType.local_ip, detectInputType("192.168.0.2:46318"));
    try std.testing.expectEqual(InputType.local_ip, detectInputType("192.168.1.100:46318"));
    try std.testing.expectEqual(InputType.local_ip, detectInputType("10.0.0.1:46318"));
    try std.testing.expectEqual(InputType.local_ip, detectInputType("172.16.0.1:46318"));
    try std.testing.expectEqual(InputType.local_ip, detectInputType("172.31.255.255:46318"));
}

test "detectInputType: public IPs" {
    try std.testing.expectEqual(InputType.public_ip_or_host, detectInputType("203.0.113.10:46318"));
    try std.testing.expectEqual(InputType.public_ip_or_host, detectInputType("8.8.8.8:46318"));
    try std.testing.expectEqual(InputType.public_ip_or_host, detectInputType("64.181.172.230:3939"));
}

test "detectInputType: hostnames" {
    try std.testing.expectEqual(InputType.public_ip_or_host, detectInputType("zzcaster.duckdns.org:3939"));
    try std.testing.expectEqual(InputType.public_ip_or_host, detectInputType("example.com:46318"));
    try std.testing.expectEqual(InputType.public_ip_or_host, detectInputType("melty.argoneus.com:3939"));
}

test "detectInputType: invalid inputs" {
    try std.testing.expectEqual(InputType.invalid, detectInputType(""));
    try std.testing.expectEqual(InputType.invalid, detectInputType("abc")); // too short for room code
    try std.testing.expectEqual(InputType.invalid, detectInputType("ABCDE")); // too long for room code
    try std.testing.expectEqual(InputType.invalid, detectInputType("ABC1")); // has 1
    try std.testing.expectEqual(InputType.invalid, detectInputType("no-port")); // no colon
    try std.testing.expectEqual(InputType.invalid, detectInputType(":46318")); // no host
    try std.testing.expectEqual(InputType.invalid, detectInputType("1.2.3.4:")); // no port
    try std.testing.expectEqual(InputType.invalid, detectInputType("1.2.3.4:abc")); // bad port
}

test "detectInputType: trims whitespace" {
    try std.testing.expectEqual(InputType.room_code, detectInputType("  ABCD  "));
    try std.testing.expectEqual(InputType.local_ip, detectInputType("  127.0.0.1:46318\n"));
}
