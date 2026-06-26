// src/net/relay_protocol.zig
// ============================================================================
// Wire format for the zzcaster NAT-traversal relay protocol, with
// dual-mode support for the original CCCaster relay protocol.
//
// Both protocols share the same MatchInfo / TunInfo / UdpData formats.
// Only the initial TCP handshake differs:
//
//   zzcaster relay:
//     Host   → [u8 type][u16 le port][u8 code_len][code bytes]
//     Client → [u8 type][u8 code_len][code bytes]
//     Server → Hosted / MatchInfo / TunInfo / Error
//     Match key: 4-letter room code
//
//   cccaster relay:
//     Host   → [u8 type][u16 le port]                        (3 bytes — TypedHostingPort)
//     Client → [u8 type]["ip:port" ASCII, no null]           (10-22 bytes — TypedConnectionAddress)
//     Server → MatchInfo / TunInfo  (NO Hosted, NO Error — just closes TCP on failure)
//     Match key: string-equal on "{type}{host_public_ip}:{host_local_port}"
//
// All integers are LITTLE-ENDIAN (matches CCCaster).
//
// Authoritative spec: docs/nat-traversal-protocol.md
// ============================================================================

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

pub const TYPE_TCP: u8 = 'T'; // 0x54
pub const TYPE_UDP: u8 = 'U'; // 0x55

/// 4-letter room code, unambiguous alphabet (no I/O/0/1).
pub const ROOM_CODE_LEN: usize = 4;
pub const ROOM_CODE_ALPHABET: []const u8 = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

/// Magic header strings — shared between both protocols.
pub const MATCH_INFO_HEADER: []const u8 = "MatchInfo"; // 9 bytes
pub const TUN_INFO_HEADER: []const u8 = "TunInfo"; // 7 bytes
pub const HOSTED_HEADER: []const u8 = "Hosted"; // 6 bytes — zzcaster only
pub const ERROR_HEADER: []const u8 = "Error"; // 5 bytes — zzcaster only

/// Error codes (zzcaster protocol only — CCCaster has no Error reply).
pub const ERR_ROOM_NOT_FOUND: u8 = 1;
pub const ERR_ROOM_EXPIRED: u8 = 2;
pub const ERR_PROTOCOL_ERROR: u8 = 3;
pub const ERR_ROOM_TAKEN: u8 = 4;

/// Maximum sizes for sanity-checking incoming packets.
pub const MAX_TUN_INFO_ADDR_LEN: usize = 22; // "255.255.255.255:65535"
pub const MAX_TUN_INFO_LEN: usize = 7 + 4 + MAX_TUN_INFO_ADDR_LEN + 1; // header + matchId + addr + null
pub const MAX_ERROR_MSG_LEN: usize = 64;
pub const MAX_ERROR_LEN: usize = 5 + 1 + MAX_ERROR_MSG_LEN;

/// Maximum initial TCP message size we'll read.
pub const MAX_INITIAL_MSG_LEN: usize = 64;

/// MatchId sent in UdpData must be non-zero — 0 means "invalid / STUN probe".
pub const INVALID_MATCH_ID: u32 = 0;

// ============================================================================
// Relay flavor — which protocol variant to speak
// ============================================================================

/// RelayFlavor identifies which protocol variant a relay speaks.
///
/// The two flavors share MatchInfo / TunInfo / UdpData wire formats but
/// differ in the initial TCP handshake:
///   - .zzcaster: room codes, Hosted reply, Error replies
///   - .cccaster: IP-based matching, no Hosted, no Error (just TCP close)
///
/// The client picks the flavor based on the entry in relay_list.txt.
pub const RelayFlavor = enum {
    zzcaster,
    cccaster,

    /// String label for the relay_list.txt format ("zzcaster:" / "cccaster:").
    pub fn label(self: RelayFlavor) []const u8 {
        return switch (self) {
            .zzcaster => "zzcaster",
            .cccaster => "cccaster",
        };
    }

    /// Parse a label string into a flavor. Returns null for unknown labels.
    pub fn fromLabel(s: []const u8) ?RelayFlavor {
        if (std.mem.eql(u8, s, "zzcaster")) return .zzcaster;
        if (std.mem.eql(u8, s, "cccaster")) return .cccaster;
        return null;
    }
};

// ============================================================================
// Outgoing message encoders — initial TCP handshake (client → server)
// ============================================================================

/// Encode a HostRegister message (zzcaster flavor).
///
/// Wire format: [u8 type 'T'|'U'][u16 le port][u8 code_len][code bytes]
///
/// `code` may be empty (len 0) — server will generate one and reply with Hosted.
/// `code` may be up to 4 bytes — must use the unambiguous alphabet.
pub fn encodeHostRegister(buf: []u8, t: u8, port: u16, code: []const u8) []u8 {
    std.debug.assert(buf.len >= 4 + code.len);
    std.debug.assert(code.len <= ROOM_CODE_LEN);
    std.debug.assert(t == TYPE_TCP or t == TYPE_UDP);

    buf[0] = t;
    std.mem.writeInt(u16, buf[1..3], port, .little);
    buf[3] = @intCast(code.len);
    if (code.len > 0) {
        @memcpy(buf[4 .. 4 + code.len], code);
    }
    return buf[0 .. 4 + code.len];
}

/// Encode a ClientJoin message (zzcaster flavor).
///
/// Wire format: [u8 type 'T'|'U'][u8 code_len][code bytes]
///
/// `code` must be exactly 4 bytes.
pub fn encodeClientJoin(buf: []u8, t: u8, code: []const u8) []u8 {
    std.debug.assert(buf.len >= 2 + code.len);
    std.debug.assert(code.len == ROOM_CODE_LEN);
    std.debug.assert(t == TYPE_TCP or t == TYPE_UDP);

    buf[0] = t;
    buf[1] = @intCast(code.len);
    @memcpy(buf[2 .. 2 + code.len], code);
    return buf[0 .. 2 + code.len];
}

/// Encode a TypedHostingPort message (cccaster flavor) — host side.
///
/// Wire format: [u8 type 'T'|'U'][u16 le port]
///
/// CCCaster's server.py reads exactly 3 bytes for this; the host's TCP
/// address is the match key (the server stores "T<host_ip>:<port>" keyed
/// by the TCP socket).
pub fn encodeTypedHostingPort(buf: []u8, t: u8, port: u16) []u8 {
    std.debug.assert(buf.len >= 3);
    std.debug.assert(t == TYPE_TCP or t == TYPE_UDP);

    buf[0] = t;
    std.mem.writeInt(u16, buf[1..3], port, .little);
    return buf[0..3];
}

/// Encode a TypedConnectionAddress message (cccaster flavor) — client side.
///
/// Wire format: [u8 type 'T'|'U']["ip:port" ASCII, NO null terminator]
///
/// `addr` is the host's public IP:port string (e.g., "203.0.113.10:46318").
/// The client learns this out-of-band (the host shared it via Discord etc.)
/// or via the lobby server.
///
/// CCCaster's server.py reads 10-22 bytes for this — it matches on
/// string equality against the host's "T<host_ip>:<port>" entry.
pub fn encodeTypedConnectionAddress(buf: []u8, t: u8, addr: []const u8) []u8 {
    std.debug.assert(buf.len >= 1 + addr.len);
    std.debug.assert(t == TYPE_TCP or t == TYPE_UDP);
    std.debug.assert(addr.len >= 9 and addr.len <= 21); // "1.1.1.1:0" to "255.255.255.255:65535"

    buf[0] = t;
    @memcpy(buf[1 .. 1 + addr.len], addr);
    return buf[0 .. 1 + addr.len];
}

// ============================================================================
// Outgoing message encoders — UDP (client → server, post-MatchInfo)
// ============================================================================

/// Encode a UdpData packet (5 bytes, identical for both flavors).
///
/// Wire format: [u8 isClient][u32 le matchId]
///
/// Both peers send this every 50ms after receiving MatchInfo. The relay
/// uses the source address to learn each peer's public UDP endpoint,
/// then sends TunInfo to the opposite peer over TCP.
pub fn encodeUdpData(buf: []u8, is_client: bool, match_id: u32) []u8 {
    std.debug.assert(buf.len >= 5);
    std.debug.assert(match_id != INVALID_MATCH_ID);

    buf[0] = if (is_client) 1 else 0;
    std.mem.writeInt(u32, buf[1..5], match_id, .little);
    return buf[0..5];
}

// ============================================================================
// Outgoing message encoders — STUN probe (client → server, UDP)
// ============================================================================

/// Encode a STUN probe packet. Any non-UdpData UDP packet triggers a STUN
/// reply from the server (8 bytes: [4 IP BE][2 port BE][2 padding=0]).
///
/// We send a single byte 0x58 ('X') — small and obviously not a valid
/// UdpData (which is 5 bytes with matchId != 0).
pub fn encodeStunProbe(buf: []u8) []u8 {
    std.debug.assert(buf.len >= 1);
    buf[0] = 'X';
    return buf[0..1];
}

/// Decode a STUN reply (8 bytes: [4 IP BE][2 port BE][2 padding=0]).
pub const StunReply = struct {
    ip: [4]u8,
    port: u16,
};

pub fn decodeStunReply(data: []const u8) ?StunReply {
    if (data.len < 8) return null;
    return .{
        .ip = .{ data[0], data[1], data[2], data[3] },
        // Big-endian port (matches standard STUN RFC 5389, NOT the rest
        // of our protocol which is little-endian — this is intentional,
        // documented in the spec).
        .port = (@as(u16, data[4]) << 8) | data[5],
    };
}

// ============================================================================
// Incoming message decoders — TCP (server → client)
// ============================================================================

/// Kind of message the server can send over TCP.
pub const ServerMsgKind = enum {
    unknown,
    match_info, // both flavors
    tun_info, // both flavors
    hosted, // zzcaster only
    err, // zzcaster only
};

/// Decoded server message. Only the field matching `kind` is valid.
pub const ServerMsg = union(ServerMsgKind) {
    unknown: void,
    match_info: struct { match_id: u32 },
    tun_info: struct { match_id: u32, addr: []const u8 }, // addr points into the input buffer
    hosted: struct { code: []const u8 }, // code points into the input buffer (always 4 bytes)
    err: struct { code: u8, msg: []const u8 }, // msg points into the input buffer
};

/// Decode an incoming TCP message from the relay server.
///
/// `data` is the bytes received. The returned `ServerMsg` may contain
/// slices that point INTO `data` — the caller must keep `data` alive
/// while using the result.
///
/// Returns `.unknown` if the message can't be identified. The caller
/// should treat this as a protocol error and disconnect.
pub fn decodeServerMsg(data: []const u8) ServerMsg {
    // MatchInfo: "MatchInfo" + u32 le matchId (13 bytes total)
    if (data.len >= 9 + 4 and std.mem.eql(u8, data[0..9], MATCH_INFO_HEADER)) {
        return .{
            .match_info = .{
                .match_id = std.mem.readInt(u32, data[9..13], .little),
            },
        };
    }

    // TunInfo: "TunInfo" + u32 le matchId + "ip:port\0"
    //
    // TCP is a stream protocol — a single server Write can arrive as
    // multiple recv calls. If the null terminator hasn't arrived yet,
    // we MUST return .unknown so the caller waits for more data instead
    // of treating a partial address as a complete message (which would
    // cause parseIpPort to fail and the client to abort the connection).
    if (data.len >= 7 + 4 and std.mem.eql(u8, data[0..7], TUN_INFO_HEADER)) {
        const match_id = std.mem.readInt(u32, data[7..11], .little);
        // Find null terminator
        var end: usize = 11;
        while (end < data.len and data[end] != 0 and end - 11 < MAX_TUN_INFO_ADDR_LEN) {
            end += 1;
        }
        // If we didn't find the null terminator, the message is incomplete
        // (TCP fragmentation) or malformed (addr exceeds MAX_TUN_INFO_ADDR_LEN).
        // Return .unknown so the caller waits for more data.
        if (end >= data.len or data[end] != 0) return .{ .unknown = {} };
        return .{
            .tun_info = .{
                .match_id = match_id,
                .addr = data[11..end],
            },
        };
    }

    // Hosted: "Hosted" + 4-byte code (zzcaster only)
    if (data.len >= 6 + ROOM_CODE_LEN and std.mem.eql(u8, data[0..6], HOSTED_HEADER)) {
        return .{
            .hosted = .{
                .code = data[6 .. 6 + ROOM_CODE_LEN],
            },
        };
    }

    // Error: "Error" + u8 code + msg bytes (zzcaster only)
    if (data.len >= 5 + 1 and std.mem.eql(u8, data[0..5], ERROR_HEADER)) {
        return .{
            .err = .{
                .code = data[5],
                .msg = data[6..],
            },
        };
    }

    return .{ .unknown = {} };
}

// ============================================================================
// Incoming message decoders — UDP (server → client, STUN reply)
// ============================================================================

/// Try to parse a UDP datagram as a STUN reply (8 bytes).
/// Returns null if the datagram isn't a valid STUN reply.
///
/// Note: UdpData packets flow CLIENT → SERVER, never the other way.
/// So any UDP packet FROM the relay is either a STUN reply or junk.
pub fn tryDecodeStunReply(data: []const u8) ?StunReply {
    return decodeStunReply(data);
}

// ============================================================================
// Room code generation
// ============================================================================

/// Generate a random 4-letter room code from the unambiguous alphabet.
/// Caller provides the random number source so tests can be deterministic.
///
/// Use std.crypto.random for production, a seeded Prng for tests.
pub fn generateRoomCode(rand: std.Random) [ROOM_CODE_LEN]u8 {
    var code: [ROOM_CODE_LEN]u8 = undefined;
    for (&code) |*c| {
        c.* = ROOM_CODE_ALPHABET[rand.intRangeAtMost(usize, 0, ROOM_CODE_ALPHABET.len - 1)];
    }
    return code;
}

/// Validate that a room code uses only the unambiguous alphabet.
pub fn isValidRoomCode(code: []const u8) bool {
    if (code.len != ROOM_CODE_LEN) return false;
    for (code) |c| {
        if (std.mem.indexOfScalar(u8, ROOM_CODE_ALPHABET, c) == null) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

test "encodeHostRegister produces correct bytes" {
    var buf: [64]u8 = undefined;
    const encoded = encodeHostRegister(&buf, TYPE_UDP, 46318, "ABCD");
    try std.testing.expectEqual(@as(usize, 8), encoded.len);
    try std.testing.expectEqual(@as(u8, 'U'), encoded[0]);
    // 46318 = 0xB4EE → little-endian: 0xEE 0xB4
    try std.testing.expectEqual(@as(u8, 0xEE), encoded[1]);
    try std.testing.expectEqual(@as(u8, 0xB4), encoded[2]);
    try std.testing.expectEqual(@as(u8, 4), encoded[3]);
    try std.testing.expectEqualStrings("ABCD", encoded[4..8]);
}

test "encodeHostRegister with empty code (server assigns)" {
    var buf: [64]u8 = undefined;
    const encoded = encodeHostRegister(&buf, TYPE_UDP, 46318, "");
    try std.testing.expectEqual(@as(usize, 4), encoded.len);
    try std.testing.expectEqual(@as(u8, 0), encoded[3]);
}

test "encodeClientJoin produces correct bytes" {
    var buf: [64]u8 = undefined;
    const encoded = encodeClientJoin(&buf, TYPE_UDP, "ABCD");
    try std.testing.expectEqual(@as(usize, 6), encoded.len);
    try std.testing.expectEqual(@as(u8, 'U'), encoded[0]);
    try std.testing.expectEqual(@as(u8, 4), encoded[1]);
    try std.testing.expectEqualStrings("ABCD", encoded[2..6]);
}

test "encodeTypedHostingPort produces correct 3 bytes (cccaster flavor)" {
    var buf: [64]u8 = undefined;
    const encoded = encodeTypedHostingPort(&buf, TYPE_UDP, 46318);
    try std.testing.expectEqual(@as(usize, 3), encoded.len);
    try std.testing.expectEqual(@as(u8, 'U'), encoded[0]);
    // 46318 = 0xB4EE → little-endian: 0xEE 0xB4
    try std.testing.expectEqual(@as(u8, 0xEE), encoded[1]);
    try std.testing.expectEqual(@as(u8, 0xB4), encoded[2]);
}

test "encodeTypedConnectionAddress produces correct bytes (cccaster flavor)" {
    var buf: [64]u8 = undefined;
    const encoded = encodeTypedConnectionAddress(&buf, TYPE_UDP, "203.0.113.10:46318");
    try std.testing.expectEqual(@as(usize, 1 + 18), encoded.len);
    try std.testing.expectEqual(@as(u8, 'U'), encoded[0]);
    try std.testing.expectEqualStrings("203.0.113.10:46318", encoded[1..]);
}

test "encodeUdpData produces correct 5 bytes" {
    var buf: [8]u8 = undefined;
    const encoded = encodeUdpData(&buf, true, 0xDEADBEEF);
    try std.testing.expectEqual(@as(usize, 5), encoded.len);
    try std.testing.expectEqual(@as(u8, 1), encoded[0]); // isClient=true
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, encoded[1..5], .little));
}

test "encodeUdpData host side (isClient=false)" {
    var buf: [8]u8 = undefined;
    const encoded = encodeUdpData(&buf, false, 42);
    try std.testing.expectEqual(@as(u8, 0), encoded[0]);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, encoded[1..5], .little));
}

test "encodeStunProbe produces 1 byte" {
    var buf: [8]u8 = undefined;
    const encoded = encodeStunProbe(&buf);
    try std.testing.expectEqual(@as(usize, 1), encoded.len);
    try std.testing.expectEqual(@as(u8, 'X'), encoded[0]);
}

test "decodeStunReply parses 8 bytes correctly" {
    // 203.0.113.10 : 54321 = 0xD431 → BE: 0xD4 0x31
    const reply = [_]u8{ 203, 0, 113, 10, 0xD4, 0x31, 0, 0 };
    const parsed = decodeStunReply(&reply) orelse return error.TestExpectedSome;
    try std.testing.expectEqual(@as(u8, 203), parsed.ip[0]);
    try std.testing.expectEqual(@as(u8, 0), parsed.ip[1]);
    try std.testing.expectEqual(@as(u8, 113), parsed.ip[2]);
    try std.testing.expectEqual(@as(u8, 10), parsed.ip[3]);
    try std.testing.expectEqual(@as(u16, 54321), parsed.port);
}

test "decodeStunReply rejects short packets" {
    const short = [_]u8{ 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expect(decodeStunReply(&short) == null);
}

test "decodeServerMsg parses MatchInfo" {
    // "MatchInfo" + matchId=0xCAFEBABE LE
    var msg: [13]u8 = undefined;
    @memcpy(msg[0..9], MATCH_INFO_HEADER);
    std.mem.writeInt(u32, msg[9..13], 0xCAFEBABE, .little);
    const decoded = decodeServerMsg(&msg);
    try std.testing.expect(decoded == .match_info);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), decoded.match_info.match_id);
}

test "decodeServerMsg parses TunInfo" {
    // "TunInfo" + matchId=42 LE + "203.0.113.10:54321\0"
    var msg: [40]u8 = undefined;
    @memcpy(msg[0..7], TUN_INFO_HEADER);
    std.mem.writeInt(u32, msg[7..11], 42, .little);
    const addr = "203.0.113.10:54321";
    @memcpy(msg[11 .. 11 + addr.len], addr);
    msg[11 + addr.len] = 0;
    const total_len = 11 + addr.len + 1;
    const decoded = decodeServerMsg(msg[0..total_len]);
    try std.testing.expect(decoded == .tun_info);
    try std.testing.expectEqual(@as(u32, 42), decoded.tun_info.match_id);
    try std.testing.expectEqualStrings("203.0.113.10:54321", decoded.tun_info.addr);
}

test "decodeServerMsg parses Hosted" {
    // "Hosted" + "ABCD"
    var msg: [10]u8 = undefined;
    @memcpy(msg[0..6], HOSTED_HEADER);
    @memcpy(msg[6..10], "ABCD");
    const decoded = decodeServerMsg(&msg);
    try std.testing.expect(decoded == .hosted);
    try std.testing.expectEqualStrings("ABCD", decoded.hosted.code);
}

test "decodeServerMsg parses Error" {
    // "Error" + code=1 + "room not found"
    var msg: [32]u8 = undefined;
    @memcpy(msg[0..5], ERROR_HEADER);
    msg[5] = 1;
    const err_msg = "room not found";
    @memcpy(msg[6 .. 6 + err_msg.len], err_msg);
    const decoded = decodeServerMsg(msg[0 .. 6 + err_msg.len]);
    try std.testing.expect(decoded == .err);
    try std.testing.expectEqual(@as(u8, 1), decoded.err.code);
    try std.testing.expectEqualStrings("room not found", decoded.err.msg);
}

test "decodeServerMsg returns unknown for garbage" {
    const garbage = [_]u8{ 0xFF, 0xEE, 0xDD, 0xCC };
    const decoded = decodeServerMsg(&garbage);
    try std.testing.expect(decoded == .unknown);
}

test "decodeServerMsg returns unknown for TunInfo without null terminator (TCP fragmentation)" {
    // "TunInfo" + matchId=42 LE + "203.0.113.10:5432" (NO null terminator)
    // This simulates a partial TCP read where the null hasn't arrived yet.
    var msg: [40]u8 = undefined;
    @memcpy(msg[0..7], TUN_INFO_HEADER);
    std.mem.writeInt(u32, msg[7..11], 42, .little);
    const addr = "203.0.113.10:5432"; // 16 chars, no \0
    @memcpy(msg[11 .. 11 + addr.len], addr);
    const decoded = decodeServerMsg(msg[0 .. 11 + addr.len]);
    try std.testing.expect(decoded == .unknown);
}

test "decodeServerMsg returns unknown for TunInfo with only matchId (addr not yet received)" {
    // "TunInfo" + matchId=42 LE, no addr at all
    var msg: [11]u8 = undefined;
    @memcpy(msg[0..7], TUN_INFO_HEADER);
    std.mem.writeInt(u32, msg[7..11], 42, .little);
    const decoded = decodeServerMsg(&msg);
    try std.testing.expect(decoded == .unknown);
}

test "decodeServerMsg parses TunInfo with empty addr (just null terminator)" {
    // "TunInfo" + matchId=42 LE + "\0" (empty addr — edge case)
    var msg: [12]u8 = undefined;
    @memcpy(msg[0..7], TUN_INFO_HEADER);
    std.mem.writeInt(u32, msg[7..11], 42, .little);
    msg[11] = 0;
    const decoded = decodeServerMsg(&msg);
    try std.testing.expect(decoded == .tun_info);
    try std.testing.expectEqual(@as(u32, 42), decoded.tun_info.match_id);
    try std.testing.expectEqualStrings("", decoded.tun_info.addr);
}

test "isValidRoomCode accepts valid codes" {
    try std.testing.expect(isValidRoomCode("ABCD"));
    try std.testing.expect(isValidRoomCode("WXYZ"));
    try std.testing.expect(isValidRoomCode("2345"));
    try std.testing.expect(isValidRoomCode("6789"));
}

test "isValidRoomCode rejects bad codes" {
    try std.testing.expect(!isValidRoomCode("ABC")); // too short
    try std.testing.expect(!isValidRoomCode("ABCDE")); // too long
    try std.testing.expect(!isValidRoomCode("ABCI")); // has I
    try std.testing.expect(!isValidRoomCode("ABC0")); // has 0
    try std.testing.expect(!isValidRoomCode("ABC1")); // has 1
    try std.testing.expect(!isValidRoomCode("ABCO")); // has O
    try std.testing.expect(!isValidRoomCode("abc")); // lowercase
}

test "generateRoomCode produces valid codes" {
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const code = generateRoomCode(rand);
        try std.testing.expect(isValidRoomCode(&code));
    }
}

test "RelayFlavor label round-trips" {
    try std.testing.expectEqualStrings("zzcaster", RelayFlavor.zzcaster.label());
    try std.testing.expectEqualStrings("cccaster", RelayFlavor.cccaster.label());
    try std.testing.expectEqual(RelayFlavor.zzcaster, RelayFlavor.fromLabel("zzcaster").?);
    try std.testing.expectEqual(RelayFlavor.cccaster, RelayFlavor.fromLabel("cccaster").?);
    try std.testing.expect(RelayFlavor.fromLabel("unknown") == null);
}
