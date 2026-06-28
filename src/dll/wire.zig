// CCCaster-compatible wire format helpers.
//
// All CCCaster protocol messages are framed as:
//   [1 byte msgType][1 byte compressionLevel=0][body...][16 byte MD5 of body]
//
// The MD5 is computed over the body bytes (compressionLevel byte NOT included
// — confirmed by reading CCCaster's `Serializable::save` in lib/Protocol.hpp:113
// and the `compressionLevel` field's `mutable` qualifier, which lets the
// hash-side `save` mutate it without affecting const-ness of the message).
//
// See docs/spectator-study.md §2.3 for the per-message body layouts and
// §3.4 P3 for the implementation plan.
//
// ## MsgType tag values
//
// CCCaster's `MsgType` enum (lib/ProtocolEnums.hpp) is alphabetically sorted.
// Here are the tags we actually use in zzcaster:
//
//   0x02  BothInputs          (was 0x20 in zzcaster)
//   0x07  ErrorMessage        (was 0x06)
//   0x0A  InitialGameState    (was 0x10)
//   0x0B  IpAddrPort          (replaces zzcaster's 0xFE REDIRECT)
//   0x15  PlayerInputs        (was 0x01)
//   0x16  RngState            (was 0x02)
//   0x1B  SyncHash            (was 0x04)
//   0x1F  VersionConfig       (was 0x07)
//   0x21  TransitionIndex     (was 0x03)
//
// zzcaster-only extension (not in CCCaster):
//   0x01  HELLO               (spectator → host: "I'm ready, please activate me")
//         Body: [4 bytes desired_start_index LE] (0 = host decides)
//         No MD5 — kept as a simple zzcaster extension for now. CCCaster uses
//         the IpAddrPort (0x0B) message as the spectator's "I'm ready"
//         signal, but that requires the spectator to advertise its own
//         ctrl-socket address (which we don't have in the ENet-single-host
//         model). HELLO is a simpler stand-in; once P4 (SpectateConfig
//         exchange) lands, HELLO may be replaced by ConfirmConfig (0x05).

const std = @import("std");

pub const MD5_HASH_SIZE: usize = 16;
pub const COMPRESSION_LEVEL: u8 = 0; // CCCaster always uses 0

// === Message type tags (CCCaster-compatible) ===

pub const MSG_HELLO: u8 = 0x01; // zzcaster extension (spectator → host)
pub const MSG_BOTH_INPUTS: u8 = 0x02;
pub const MSG_CONFIRM_CONFIG: u8 = 0x05;
pub const MSG_ERROR_MESSAGE: u8 = 0x07;
pub const MSG_INITIAL_GAME_STATE: u8 = 0x0A;
pub const MSG_IP_ADDR_PORT: u8 = 0x0B;
pub const MSG_MENU_INDEX: u8 = 0x10;
pub const MSG_PLAYER_INPUTS: u8 = 0x15;
pub const MSG_RNG_STATE: u8 = 0x16;
pub const MSG_SPECTATE_CONFIG: u8 = 0x18;
pub const MSG_SYNC_HASH: u8 = 0x1B;
pub const MSG_VERSION_CONFIG: u8 = 0x1F;
pub const MSG_TRANSITION_INDEX: u8 = 0x21;

// zzcaster-only extension (no CCCaster equivalent — CCCaster uses re-send
// timers instead of ACKs). Kept for backwards compat within zzcaster↔zzcaster
// sessions; not sent when in CCCaster-compat mode (P3+).
pub const MSG_RNG_ACK: u8 = 0x05; // NOTE: collides with MSG_CONFIRM_CONFIG!
// This is intentional — once P3 ships, RNG_ACK is removed and ConfirmConfig
// takes 0x05. Until then, zzcaster sessions use 0x05 = RNG_ACK and never
// send ConfirmConfig.

// === MD5 ===

const Md5 = std.crypto.hash.Md5;

fn md5(data: []const u8, out: *[16]u8) void {
    Md5.hash(data, out, .{});
}

// === Framing ===

/// Write a CCCaster-compatible message frame:
///   [1 byte msg_type][1 byte compressionLevel=0][body...][16 byte MD5 of body]
///
/// Returns the total number of bytes written, or 0 if `out` is too small.
/// `body` is the message body WITHOUT the type tag or compression byte.
pub fn writeMessage(out: []u8, msg_type: u8, body: []const u8) usize {
    const total = 2 + body.len + MD5_HASH_SIZE;
    if (out.len < total) return 0;
    out[0] = msg_type;
    out[1] = COMPRESSION_LEVEL;
    @memcpy(out[2 .. 2 + body.len], body);
    var hash: [16]u8 = undefined;
    md5(body, &hash);
    @memcpy(out[2 + body.len .. 2 + body.len + 16], &hash);
    return total;
}

/// Parse a CCCaster message frame.
/// Returns the message type and a slice into `buf` for the body, or null if:
///   - The frame is too short.
///   - The MD5 doesn't match (corrupt or tampered).
///
/// `buf` should be the full message including type byte, compression byte,
/// body, and trailing MD5.
pub fn readMessage(buf: []const u8) ?struct { msg_type: u8, body: []const u8 } {
    if (buf.len < 2 + MD5_HASH_SIZE) return null;
    const msg_type = buf[0];
    // buf[1] is compressionLevel — currently always 0, ignore.
    const body = buf[2 .. buf.len - MD5_HASH_SIZE];
    var hash: [16]u8 = undefined;
    md5(body, &hash);
    if (!std.mem.eql(u8, &hash, buf[buf.len - MD5_HASH_SIZE ..])) return null;
    return .{ .msg_type = msg_type, .body = body };
}

// === Cereal-compatible primitive writers ===
//
// CCCaster uses cereal's BinaryArchive. The relevant primitive encodings:
//
//   uint8_t  → 1 byte
//   uint16_t → 2 bytes little-endian
//   uint32_t → 4 bytes little-endian
//   uint64_t → 8 bytes little-endian
//   std::string → [4 bytes size LE][N bytes content] (no null terminator)
//   std::array<T, N> → N × sizeof(T) bytes (no size prefix)
//
// Cereal's BinaryArchive uses native endianness on save and swap-on-load if
// the load machine's endianness differs. Since both MBAACC and zzcaster run
// on x86 (little-endian), we can hardcode little-endian and skip the swap
// logic. (If we ever port to a big-endian platform, we'd need to revisit.)

/// Write a cereal-compatible string: [4 byte size LE][N bytes content].
/// Returns the number of bytes written, or 0 if `out` is too small.
pub fn writeCerealString(out: []u8, s: []const u8) usize {
    const total = 4 + s.len;
    if (out.len < total) return 0;
    std.mem.writeInt(u32, out[0..4], @intCast(s.len), .little);
    @memcpy(out[4 .. 4 + s.len], s);
    return total;
}

/// Read a cereal-compatible string. Returns the string slice into `buf`
/// and the number of bytes consumed (including the 4-byte size prefix),
/// or null if the buffer is too short or the size field is implausible.
pub fn readCerealString(buf: []const u8) ?struct { s: []const u8, consumed: usize } {
    if (buf.len < 4) return null;
    const size = std.mem.readInt(u32, buf[0..4], .little);
    if (size > buf.len - 4) return null; // overflow / truncated
    return .{ .s = buf[4 .. 4 + size], .consumed = 4 + size };
}

// === Tests ===

test "writeMessage / readMessage roundtrip" {
    var out: [64]u8 = undefined;
    const body = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const n = writeMessage(&out, MSG_TRANSITION_INDEX, &body);
    try std.testing.expectEqual(@as(usize, 2 + 4 + 16), n);

    const parsed = readMessage(out[0..n]) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, MSG_TRANSITION_INDEX), parsed.msg_type);
    try std.testing.expectEqualSlices(u8, &body, parsed.body);
}

test "readMessage rejects bad MD5" {
    var out: [64]u8 = undefined;
    const body = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const n = writeMessage(&out, MSG_TRANSITION_INDEX, &body);

    // Flip a byte in the body
    out[2] ^= 0x01;

    const parsed = readMessage(out[0..n]);
    try std.testing.expect(parsed == null);
}

test "writeCerealString / readCerealString roundtrip" {
    var buf: [64]u8 = undefined;
    const s = "1.2.3.4";
    const n = writeCerealString(&buf, s);
    try std.testing.expectEqual(@as(usize, 4 + 7), n);

    const parsed = readCerealString(buf[0..n]) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings(s, parsed.s);
    try std.testing.expectEqual(@as(usize, 4 + 7), parsed.consumed);
}

test "readCerealString rejects truncated" {
    const buf = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x00 }; // size=4B, only 1 byte follows
    const parsed = readCerealString(&buf);
    try std.testing.expect(parsed == null);
}

test "MD5 matches known value" {
    // Known: MD5("") = d41d8cd98f00b204e9800998ecf8427e
    var hash: [16]u8 = undefined;
    md5("", &hash);
    try std.testing.expectEqual(@as(u8, 0xd4), hash[0]);
    try std.testing.expectEqual(@as(u8, 0x1d), hash[1]);
    try std.testing.expectEqual(@as(u8, 0x7e), hash[15]);
}
