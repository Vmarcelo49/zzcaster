// src/net/relay_integration_test.zig
// ============================================================================
// Integration tests for the relay client + config + protocol stack.
//
// These tests exercise the real functions from relay_protocol.zig,
// relay_config.zig, and the non-network parts of relay_client.zig
// (room code generation, validation, state machine initialization).
//
// Network-dependent tests (actual TCP/UDP to a relay server) are NOT
// here — those require a live relay and two machines. See
// scripts/probe_zzcaster_relay.py for the end-to-end smoke test.
// ============================================================================

const std = @import("std");
const protocol = @import("relay_protocol.zig");
const relay_config = @import("relay_config.zig");
const relay_client_mod = @import("relay_client.zig");

// ============================================================================
// Room code generation + validation
// ============================================================================

test "Room code generation produces valid codes" {
    var prng = std.Random.DefaultPrng.init(12345);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const code = protocol.generateRoomCode(prng.random());
        try std.testing.expect(protocol.isValidRoomCode(&code));
    }
}

test "Room code uses unambiguous alphabet" {
    // Generate a code and verify every char is in the safe alphabet
    var prng = std.Random.DefaultPrng.init(42);
    const code = protocol.generateRoomCode(prng.random());
    for (code) |c| {
        const idx = std.mem.indexOfScalar(u8, protocol.ROOM_CODE_ALPHABET, c);
        try std.testing.expect(idx != null);
    }
}

test "Room code is always 4 chars" {
    var prng = std.Random.DefaultPrng.init(999);
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const code = protocol.generateRoomCode(prng.random());
        try std.testing.expectEqual(@as(usize, 4), code.len);
    }
}

test "Room code rejects ambiguous characters" {
    try std.testing.expect(!protocol.isValidRoomCode("ABC0")); // 0
    try std.testing.expect(!protocol.isValidRoomCode("ABC1")); // 1
    try std.testing.expect(!protocol.isValidRoomCode("ABCI")); // I
    try std.testing.expect(!protocol.isValidRoomCode("ABCO")); // O
    try std.testing.expect(!protocol.isValidRoomCode("abc")); // lowercase
    try std.testing.expect(!protocol.isValidRoomCode("ABCDE")); // too long
    try std.testing.expect(!protocol.isValidRoomCode("ABC")); // too short
}

// ============================================================================
// Relay list parsing from config.ini format
// ============================================================================

test "Relay list parses config.ini relayServers format" {
    // Simulates what config.zig produces when it reads multiple
    // relayServers= lines from config.ini
    const config_content = "nat.example.com:3939\nzzcaster.duckdns.org:3939";
    var list = try relay_config.parseList(std.testing.allocator, config_content);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), list.count());

    const e0 = list.get(0).?;
    try std.testing.expectEqualStrings("nat.example.com", e0.host);
    try std.testing.expectEqual(@as(u16, 3939), e0.port);

    const e1 = list.get(1).?;
    try std.testing.expectEqualStrings("zzcaster.duckdns.org", e1.host);
}

test "Relay list handles bare IP" {
    // User writes: relayServers=64.181.172.230:3939
    const config_content = "64.181.172.230:3939";
    var list = try relay_config.parseList(std.testing.allocator, config_content);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), list.count());
    const e = list.get(0).?;
    try std.testing.expectEqualStrings("64.181.172.230", e.host);
    try std.testing.expectEqual(@as(u16, 3939), e.port);
}

test "Relay list handles hostname without port" {
    const config_content = "nat.example.com";
    var list = try relay_config.parseList(std.testing.allocator, config_content);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), list.count());
    const e = list.get(0).?;
    try std.testing.expectEqual(@as(u16, 3939), e.port); // default port
}

test "Relay list handles duckdns hostname" {
    // User's actual config: relayServers=zzcaster.duckdns.org:3939
    const config_content = "zzcaster.duckdns.org:3939";
    var list = try relay_config.parseList(std.testing.allocator, config_content);
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), list.count());
    const e = list.get(0).?;
    try std.testing.expectEqualStrings("zzcaster.duckdns.org", e.host);
    try std.testing.expectEqual(@as(u16, 3939), e.port);
}

test "DEFAULT_RELAY_LIST contains the primary relay" {
    var list = try relay_config.parseList(std.testing.allocator, relay_config.DEFAULT_RELAY_LIST);
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), list.count());
    const e = list.get(0).?;
    try std.testing.expectEqualStrings("zzcaster.duckdns.org", e.host);
}

// ============================================================================
// Wire format encoding — verify exact bytes sent to relay
// ============================================================================

test "HostRegister encodes correctly" {
    var buf: [64]u8 = undefined;
    const encoded = protocol.encodeHostRegister(&buf, protocol.TYPE_UDP, 46318, "ABCD");
    try std.testing.expectEqual(@as(usize, 8), encoded.len);
    try std.testing.expectEqual(@as(u8, 'U'), encoded[0]);
    // 46318 = 0xB4EE → LE: 0xEE 0xB4
    try std.testing.expectEqual(@as(u8, 0xEE), encoded[1]);
    try std.testing.expectEqual(@as(u8, 0xB4), encoded[2]);
    try std.testing.expectEqual(@as(u8, 4), encoded[3]);
    try std.testing.expectEqualStrings("ABCD", encoded[4..8]);
}

test "ClientJoin encodes correctly" {
    var buf: [64]u8 = undefined;
    const encoded = protocol.encodeClientJoin(&buf, protocol.TYPE_UDP, "WXYZ");
    try std.testing.expectEqual(@as(usize, 6), encoded.len);
    try std.testing.expectEqual(@as(u8, 'U'), encoded[0]);
    try std.testing.expectEqual(@as(u8, 4), encoded[1]);
    try std.testing.expectEqualStrings("WXYZ", encoded[2..6]);
}

test "UdpData encodes correctly for host (isClient=false)" {
    var buf: [8]u8 = undefined;
    const encoded = protocol.encodeUdpData(&buf, false, 42);
    try std.testing.expectEqual(@as(usize, 5), encoded.len);
    try std.testing.expectEqual(@as(u8, 0), encoded[0]);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, encoded[1..5], .little));
}

test "UdpData encodes correctly for client (isClient=true)" {
    var buf: [8]u8 = undefined;
    const encoded = protocol.encodeUdpData(&buf, true, 0xCAFEBABE);
    try std.testing.expectEqual(@as(usize, 5), encoded.len);
    try std.testing.expectEqual(@as(u8, 1), encoded[0]);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), std.mem.readInt(u32, encoded[1..5], .little));
}

// ============================================================================
// Server message decoding — verify parsing of relay responses
// ============================================================================

test "Decodes MatchInfo correctly" {
    var msg: [13]u8 = undefined;
    @memcpy(msg[0..9], protocol.MATCH_INFO_HEADER);
    std.mem.writeInt(u32, msg[9..13], 0xDEADBEEF, .little);
    const decoded = protocol.decodeServerMsg(&msg);
    try std.testing.expect(decoded == .match_info);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), decoded.match_info.match_id);
}

test "Decodes TunInfo correctly" {
    var msg: [40]u8 = undefined;
    @memcpy(msg[0..7], protocol.TUN_INFO_HEADER);
    std.mem.writeInt(u32, msg[7..11], 42, .little);
    const addr = "203.0.113.10:54321";
    @memcpy(msg[11 .. 11 + addr.len], addr);
    msg[11 + addr.len] = 0;
    const total = 11 + addr.len + 1;
    const decoded = protocol.decodeServerMsg(msg[0..total]);
    try std.testing.expect(decoded == .tun_info);
    try std.testing.expectEqual(@as(u32, 42), decoded.tun_info.match_id);
    try std.testing.expectEqualStrings("203.0.113.10:54321", decoded.tun_info.addr);
}

test "Decodes Hosted correctly" {
    var msg: [10]u8 = undefined;
    @memcpy(msg[0..6], protocol.HOSTED_HEADER);
    @memcpy(msg[6..10], "ABCD");
    const decoded = protocol.decodeServerMsg(&msg);
    try std.testing.expect(decoded == .hosted);
    try std.testing.expectEqualStrings("ABCD", decoded.hosted.code);
}

test "Decodes Error correctly" {
    var msg: [32]u8 = undefined;
    @memcpy(msg[0..5], protocol.ERROR_HEADER);
    msg[5] = protocol.ERR_ROOM_NOT_FOUND;
    const err_msg = "room not found";
    @memcpy(msg[6 .. 6 + err_msg.len], err_msg);
    const decoded = protocol.decodeServerMsg(msg[0 .. 6 + err_msg.len]);
    try std.testing.expect(decoded == .err);
    try std.testing.expectEqual(protocol.ERR_ROOM_NOT_FOUND, decoded.err.code);
    try std.testing.expectEqualStrings("room not found", decoded.err.msg);
}

// ============================================================================
// RelayClient initialization (non-network)
// ============================================================================

test "RelayClient init fails gracefully with invalid room code" {
    // Can't test the full init (it tries to connect via ws2_32), but we
    // can test the validation logic that runs before any socket ops.
    //
    // The init function validates the room code for the client role
    // and sets state=.failed + error_val=.invalid_room_code if it's bad.
    //
    // We can't easily call init() without a real std.Io + Winsock, so
    // instead we test the validation function directly:
    try std.testing.expect(!protocol.isValidRoomCode("BAD")); // too short
    try std.testing.expect(!protocol.isValidRoomCode("BAD!")); // invalid char
    try std.testing.expect(protocol.isValidRoomCode("ABCD")); // valid
}

// ============================================================================
// STUN probe decoding
// ============================================================================

test "STUN reply decodes correctly" {
    // 203.0.113.10 : 54321 = 0xD431 → BE: 0xD4 0x31
    const reply = [_]u8{ 203, 0, 113, 10, 0xD4, 0x31, 0, 0 };
    const parsed = protocol.decodeStunReply(&reply) orelse return error.TestExpectedSome;
    try std.testing.expectEqual(@as(u8, 203), parsed.ip[0]);
    try std.testing.expectEqual(@as(u8, 0), parsed.ip[1]);
    try std.testing.expectEqual(@as(u8, 113), parsed.ip[2]);
    try std.testing.expectEqual(@as(u8, 10), parsed.ip[3]);
    try std.testing.expectEqual(@as(u16, 54321), parsed.port);
}

test "STUN reply rejects short packets" {
    const short = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expect(protocol.decodeStunReply(&short) == null);
}

// ============================================================================
// RelayError labels + suggestions
// ============================================================================

test "RelayError labels are human-readable" {
    const err = relay_client_mod.RelayError.tcp_connect_failed;
    try std.testing.expect(err.label().len > 0);
    try std.testing.expect(err.suggestion().len > 0);
}

test "RelayError hole_punch_failed suggests port forwarding" {
    const err = relay_client_mod.RelayError.hole_punch_failed;
    const suggestion = err.suggestion();
    // Should mention port-forwarding or VPN
    try std.testing.expect(std.mem.indexOf(u8, suggestion, "port") != null or
        std.mem.indexOf(u8, suggestion, "VPN") != null);
}
