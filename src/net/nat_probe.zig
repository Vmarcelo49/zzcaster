// src/net/nat_probe.zig
// ============================================================================
// NAT type detection via STUN probe.
//
// Sends a UDP packet to the relay server's UDP port. The relay replies
// with 8 bytes containing the sender's public IP and port (as observed
// by the relay). By comparing the public port against the local port,
// and by probing from two different local ports, we can determine the
// NAT type:
//
//   - .direct       — public port matches local port (no NAT)
//   - .full_cone    — same public port for two different destinations
//   - .restricted   — (cannot distinguish from full_cone with one STUN
//                      server — both behave the same for our purposes)
//   - .port_restricted — same as above
//   - .symmetric    — different public port per outbound destination
//                     (hole-punch will fail — recommend direct IP or VPN)
//   - .unknown      — probe failed (network error, relay down, etc.)
//
// This module talks to the relay server's UDP port (3939 by default).
// The relay handles STUN probes — any UDP packet that isn't a valid
// 5-byte UdpData is treated as a STUN probe and gets an 8-byte reply.
//
// IMPORTANT: this module uses raw ws2_32 sockets (not ENet). ENet is
// for game traffic; STUN probes are a one-shot query best done with a
// bare socket that we control completely.
// ============================================================================

const std = @import("std");
const protocol = @import("relay_protocol.zig");
const relay_config = @import("relay_config.zig");

// ============================================================================
// ws2_32 bindings — minimal subset for UDP probing.
// ============================================================================

const ws2_32 = @import("ws2_32.zig");

// ============================================================================
// NAT types
// ============================================================================

pub const NatType = enum {
    direct, // public port == local port (no NAT)
    full_cone, // same public port for different destinations (hole-punch will work)
    restricted, // (treated same as full_cone for hole-punch purposes)
    port_restricted, // (treated same as full_cone for hole-punch purposes)
    symmetric, // different public port per destination (hole-punch will FAIL)
    unknown, // probe failed

    /// Human-readable label for UI display.
    pub fn label(self: NatType) []const u8 {
        return switch (self) {
            .direct => "Direct",
            .full_cone => "Cone NAT",
            .restricted => "Restricted NAT",
            .port_restricted => "Port-restricted NAT",
            .symmetric => "Symmetric NAT",
            .unknown => "Unknown",
        };
    }

    /// True if this NAT type can host a relay-assisted match.
    /// Symmetric NAT cannot — hole-punch will fail.
    /// Unknown is treated as "try anyway" (true) — better to let the user
    /// try and fail than to preemptively block them.
    pub fn canHost(self: NatType) bool {
        return self != .symmetric;
    }

    /// Icon/emoji-like indicator (single char) for compact UI display.
    pub fn indicator(self: NatType) []const u8 {
        return switch (self) {
            .direct => "[OK]",
            .full_cone, .restricted, .port_restricted => "[NAT]",
            .symmetric => "[!!]",
            .unknown => "[?]",
        };
    }
};

// ============================================================================
// Result of a single STUN probe
// ============================================================================

pub const ProbeResult = struct {
    /// Local UDP port the socket was bound to.
    local_port: u16,
    /// Public UDP port as observed by the relay.
    public_port: u16,
    /// Public IPv4 address as observed by the relay.
    public_ip: [4]u8,
};

// ============================================================================
// Internal helpers
// ============================================================================

/// Resolve a hostname to an IPv4 address. Returns the address as a u32
/// whose in-memory byte layout matches the network-order IP (i.e., for
/// "203.0.113.10" the bytes in memory are [203, 0, 113, 10]).
/// This is what sockaddr_in.addr expects.
///
/// Handles dotted-decimal ("203.0.113.10") and hostnames
/// ("melty.argoneus.com"). Returns 0 on failure.
fn resolveHost(host: []const u8) u32 {
    // Try dotted-decimal first (fast path, no DNS).
    var host_buf: [256:0]u8 = undefined;
    if (host.len >= host_buf.len) return 0;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    // inet_addr returns the IP as a u32 in network byte order. On x86
    // (little-endian), the in-memory bytes are already [b0, b1, b2, b3]
    // for IP "b0.b1.b2.b3" — exactly what sockaddr_in.addr wants.
    const addr = ws2_32.inet_addr(&host_buf);
    if (addr != 0 and addr != std.math.maxInt(u32)) {
        return addr;
    }

    // Fall back to DNS lookup.
    const he = ws2_32.gethostbyname(&host_buf) orelse return 0;
    const addr_list = he.h_addr_list orelse return 0;
    const first_addr_ptr = addr_list[0] orelse return 0;
    // gethostbyname returns addresses in network byte order (big-endian),
    // same as inet_addr. Copy the raw bytes into a u32 so the result
    // matches inet_addr's return value on any platform endianness.
    // (The previous std.mem.readInt(..., .little) was correct only on
    // little-endian targets like x86-windows-gnu — same fix as
    // relay_client.zig resolveHost, commit f96c6e9.)
    var result: u32 = undefined;
    @memcpy(std.mem.asBytes(&result), @as([*]u8, first_addr_ptr)[0..4]);
    return result;
}

/// Build a sockaddr_in for the given IPv4 (network byte order) + port.
fn makeSockaddr(ip_nbo: u32, port_host: u16) ws2_32.sockaddr_in {
    return .{
        .family = ws2_32.AF_INET,
        .port = std.mem.nativeToBig(u16, port_host), // network byte order
        .addr = ip_nbo,
    };
}

/// Create a UDP socket bound to a specific local port (or 0 for any).
/// Returns the socket fd, or null on error.
fn createBoundSocket(local_port: u16) ?c_int {
    const fd = ws2_32.socket(ws2_32.AF_INET, ws2_32.SOCK_DGRAM, 0);
    if (fd < 0) return null;
    errdefer _ = ws2_32.closesocket(fd);

    // Set SO_REUSEADDR so we can rebind quickly during testing.
    var reuse: c_int = 1;
    _ = ws2_32.setsockopt(fd, ws2_32.SOL_SOCKET, ws2_32.SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

    // Set receive timeout to 2 seconds.
    const timeout_ms: c_int = 2000;
    _ = ws2_32.setsockopt(fd, ws2_32.SOL_SOCKET, ws2_32.SO_RCVTIMEO, @ptrCast(&timeout_ms), @sizeOf(c_int));

    var local_addr = makeSockaddr(0, local_port); // 0.0.0.0:local_port
    if (ws2_32.bind(fd, &local_addr, @sizeOf(ws2_32.sockaddr_in)) != 0) {
        return null;
    }

    return fd;
}

/// Get the local port a socket was bound to (useful when we bound to 0).
fn getLocalPort(fd: c_int) ?u16 {
    var addr: ws2_32.sockaddr_in = undefined;
    var addr_len: c_int = @sizeOf(ws2_32.sockaddr_in);
    if (ws2_32.getsockname(fd, &addr, &addr_len) != 0) return null;
    return std.mem.bigToNative(u16, addr.port);
}

/// Send a STUN probe to the given relay address and receive the reply.
/// Returns null on timeout or error.
fn sendProbe(fd: c_int, dest_ip_nbo: u32, dest_port: u16) ?protocol.StunReply {
    var dest = makeSockaddr(dest_ip_nbo, dest_port);

    // Send 1-byte STUN probe ('X' — not a valid UdpData which is 5 bytes).
    var probe_buf: [1]u8 = undefined;
    const probe = protocol.encodeStunProbe(&probe_buf);
    const sent = ws2_32.sendto(fd, probe.ptr, @intCast(probe.len), 0, &dest, @sizeOf(ws2_32.sockaddr_in));
    if (sent != probe.len) return null;

    // Receive 8-byte reply.
    var reply_buf: [64]u8 = undefined;
    var from: ws2_32.sockaddr_in = undefined;
    var from_len: c_int = @sizeOf(ws2_32.sockaddr_in);
    const recv_len = ws2_32.recvfrom(fd, &reply_buf, reply_buf.len, 0, &from, &from_len);
    if (recv_len < 8) return null;

    return protocol.decodeStunReply(reply_buf[0..@intCast(recv_len)]);
}

// ============================================================================
// WSAStartup / cleanup
// ============================================================================
//
// initWinsock() / deinitWinsock() live in the shared ws2_32 module. They are
// re-exported here as `pub const` so existing callers that imported
// `nat_probe.initWinsock` continue to work, and so that `detectNatType`
// remains callable standalone (with the documented precondition that the
// caller has called initWinsock first).
//
// Only the launcher's main() actually calls initWinsock — the DLL goes
// through ENet, which calls WSAStartup internally.

pub const initWinsock = ws2_32.initWinsock;
pub const deinitWinsock = ws2_32.deinitWinsock;


// ============================================================================
// Public API — detect NAT type
// ============================================================================

/// Detect the NAT type by probing the given relay server.
///
/// This sends two STUN probes from two different local UDP ports to the
/// same relay. If both probes report the same public port, the NAT is
/// "cone" (full/restricted/port-restricted — all work for hole-punch).
/// If they differ, it's symmetric (hole-punch will fail).
///
/// Caller must have called initWinsock() first.
///
/// `relay_host` — hostname or IP of the relay server (e.g., "melty.argoneus.com")
/// `relay_port` — UDP port of the relay (typically 3939)
pub fn detectNatType(relay_host: []const u8, relay_port: u16) NatType {
    const ip_nbo = resolveHost(relay_host);
    if (ip_nbo == 0) return .unknown;

    // First probe — bind to a random local port (0 = "let OS pick")
    const fd1 = createBoundSocket(0) orelse return .unknown;
    defer _ = ws2_32.closesocket(fd1);

    const local_port_1 = getLocalPort(fd1) orelse return .unknown;
    const reply1 = sendProbe(fd1, ip_nbo, relay_port) orelse return .unknown;

    // If public port matches local port — direct connection, no NAT.
    if (reply1.port == local_port_1) {
        return .direct;
    }

    // Second probe — bind to a different local port.
    // We can't pick a specific port, but the OS will assign a different
    // one when we bind a new socket to 0.
    const fd2 = createBoundSocket(0) orelse return .unknown;
    defer _ = ws2_32.closesocket(fd2);

    // Verify the second socket bound successfully (we don't need the
    // actual port number — we just need the socket to be valid so we
    // can probe from a different local port than the first socket).
    _ = getLocalPort(fd2) orelse return .unknown;
    const reply2 = sendProbe(fd2, ip_nbo, relay_port) orelse return .unknown;

    // If both probes from DIFFERENT local ports got the SAME public port,
    // it's a cone NAT (full/restricted/port-restricted — all work for
    // hole-punch). If they differ, it's symmetric (hole-punch fails).
    if (reply1.port == reply2.port) {
        // Can't distinguish full_cone / restricted / port_restricted with
        // a single STUN server. Treat as full_cone — that's the most
        // permissive and hole-punch works for all three.
        return .full_cone;
    } else {
        return .symmetric;
    }
}

/// Convenience: detect NAT type using the first available relay from a
/// RelayList. Tries each relay in order until one responds.
pub fn detectNatTypeFromList(list: *const relay_config.RelayList) NatType {
    for (0..list.count()) |i| {
        const entry = list.get(i) orelse continue;
        const result = detectNatType(entry.host, entry.port);
        if (result != .unknown) return result;
    }
    return .unknown;
}

// ============================================================================
// Tests (logic-only — full network tests need a live relay)
// ============================================================================

test "NatType.label returns human-readable strings" {
    try std.testing.expectEqualStrings("Direct", NatType.direct.label());
    try std.testing.expectEqualStrings("Symmetric NAT", NatType.symmetric.label());
    try std.testing.expectEqualStrings("Unknown", NatType.unknown.label());
}

test "NatType.canHost returns false for symmetric, true otherwise" {
    try std.testing.expect(NatType.direct.canHost());
    try std.testing.expect(NatType.full_cone.canHost());
    try std.testing.expect(NatType.restricted.canHost());
    try std.testing.expect(NatType.port_restricted.canHost());
    try std.testing.expect(!NatType.symmetric.canHost());
    // Unknown returns true — better to try than to preemptively block.
    try std.testing.expect(NatType.unknown.canHost());
}

test "NatType.indicator returns short tag" {
    try std.testing.expectEqualStrings("[OK]", NatType.direct.indicator());
    try std.testing.expectEqualStrings("[!!]", NatType.symmetric.indicator());
    try std.testing.expectEqualStrings("[?]", NatType.unknown.indicator());
}
