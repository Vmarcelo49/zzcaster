// Host-side tests for the CCCaster-compatible wire format.
//
// These tests run on the host (Linux) — they don't touch ENet or D3D9.
// They verify the wire framing (MD5 + cereal strings) and the message
// tag constants against the documented CCCaster values.
//
// See docs/spectator-study.md §2.2 for the tag mapping table and §4.2
// for the test plan.

const std = @import("std");
const wire = @import("wire.zig");

test "wire constants match CCCaster alphabetical enum order" {
    // From lib/ProtocolEnums.hpp (alphabetical) + Protocol.hpp:34 (enum class).
    // See docs/spectator-study.md §2.2 for the full table.
    try std.testing.expectEqual(@as(u8, 0x02), wire.MSG_BOTH_INPUTS); // BothInputs
    try std.testing.expectEqual(@as(u8, 0x07), wire.MSG_ERROR_MESSAGE); // ErrorMessage
    try std.testing.expectEqual(@as(u8, 0x0A), wire.MSG_INITIAL_GAME_STATE); // InitialGameState
    try std.testing.expectEqual(@as(u8, 0x0B), wire.MSG_IP_ADDR_PORT); // IpAddrPort
    try std.testing.expectEqual(@as(u8, 0x15), wire.MSG_PLAYER_INPUTS); // PlayerInputs
    try std.testing.expectEqual(@as(u8, 0x16), wire.MSG_RNG_STATE); // RngState
    try std.testing.expectEqual(@as(u8, 0x1B), wire.MSG_SYNC_HASH); // SyncHash
    try std.testing.expectEqual(@as(u8, 0x1F), wire.MSG_VERSION_CONFIG); // VersionConfig
    try std.testing.expectEqual(@as(u8, 0x21), wire.MSG_TRANSITION_INDEX); // TransitionIndex
}

test "wire HELLO is 0x01 (zzcaster extension, no CCCaster equivalent)" {
    // HELLO is a zzcaster extension documented in wire.zig. CCCaster uses
    // IpAddrPort (0x0B) as the spectator's "I'm ready" signal, but that
    // requires the spectator to advertise its ctrl-socket address — which
    // we don't have in the single-ENet-host model. HELLO is simpler.
    try std.testing.expectEqual(@as(u8, 0x01), wire.MSG_HELLO);
}

test "wire MSG_RNG_ACK collides with MSG_CONFIRM_CONFIG intentionally" {
    // Both are 0x05. This is intentional: zzcaster uses 0x05 = RNG_ACK
    // (a zzcaster-only extension; CCCaster uses re-send timers instead).
    // Once P4 (SpectateConfig exchange) lands, RNG_ACK will be removed
    // and ConfirmConfig will take 0x05. See wire.zig for the full story.
    try std.testing.expectEqual(wire.MSG_RNG_ACK, wire.MSG_CONFIRM_CONFIG);
}

test "wire framing round-trip works for all message types we use" {
    var out: [256]u8 = undefined;
    const tags = [_]u8{
        wire.MSG_HELLO,
        wire.MSG_BOTH_INPUTS,
        wire.MSG_ERROR_MESSAGE,
        wire.MSG_INITIAL_GAME_STATE,
        wire.MSG_IP_ADDR_PORT,
        wire.MSG_PLAYER_INPUTS,
        wire.MSG_RNG_STATE,
        wire.MSG_SYNC_HASH,
        wire.MSG_VERSION_CONFIG,
        wire.MSG_TRANSITION_INDEX,
    };
    for (tags) |tag| {
        const body = [_]u8{ tag, tag, tag, tag }; // arbitrary body
        const n = wire.writeMessage(&out, tag, &body);
        try std.testing.expect(n > 0);

        const parsed = wire.readMessage(out[0..n]) orelse return error.ParseFailed;
        try std.testing.expectEqual(tag, parsed.msg_type);
        try std.testing.expectEqualSlices(u8, &body, parsed.body);
    }
}

test "wire framing rejects corrupt body" {
    var out: [256]u8 = undefined;
    const body = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const n = wire.writeMessage(&out, wire.MSG_BOTH_INPUTS, &body);

    // Flip a body byte
    out[2] ^= 0x01;

    const parsed = wire.readMessage(out[0..n]);
    try std.testing.expect(parsed == null);
}

test "wire framing rejects truncated frame" {
    // Too short to contain even the type + compression + MD5
    const short_buf = [_]u8{ 0x00, 0x00, 0x00 };
    const parsed = wire.readMessage(&short_buf);
    try std.testing.expect(parsed == null);
}

test "wire framing handles empty body" {
    var out: [64]u8 = undefined;
    const empty_body = [_]u8{};
    const n = wire.writeMessage(&out, wire.MSG_TRANSITION_INDEX, &empty_body);
    try std.testing.expectEqual(@as(usize, 2 + 0 + 16), n);

    const parsed = wire.readMessage(out[0..n]) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u8, wire.MSG_TRANSITION_INDEX), parsed.msg_type);
    try std.testing.expectEqual(@as(usize, 0), parsed.body.len);
}

test "wire cereal string round-trip with various lengths" {
    const cases = [_][]const u8{
        "",                  // empty
        "a",                 // 1 byte
        "1.2.3.4",           // short IPv4
        "255.255.255.255",   // longer IPv4
        "example.com:46318", // hostname:port
    };
    for (cases) |s| {
        var buf: [128]u8 = undefined;
        const n = wire.writeCerealString(&buf, s);
        try std.testing.expectEqual(@as(usize, 4 + s.len), n);

        const parsed = wire.readCerealString(buf[0..n]) orelse return error.ParseFailed;
        try std.testing.expectEqualStrings(s, parsed.s);
        try std.testing.expectEqual(@as(usize, 4 + s.len), parsed.consumed);
    }
}

test "wire cereal string rejects truncated" {
    // size=4B (0xFF 0xFF 0xFF 0xFF) but only 1 byte follows
    const buf = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    const parsed = wire.readCerealString(&buf);
    try std.testing.expect(parsed == null);
}

test "wire cereal string rejects size overflow" {
    // size = 0xFFFFFFFF — way bigger than the buffer
    const buf = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xAA, 0xBB, 0xCC, 0xDD };
    const parsed = wire.readCerealString(&buf);
    try std.testing.expect(parsed == null);
}

test "wire framing total length formula" {
    // Total = 1 (type) + 1 (compressionLevel) + body.len + 16 (MD5)
    var out: [256]u8 = undefined;
    const body_lens = [_]usize{ 0, 1, 4, 8, 64, 128 };
    for (body_lens) |blen| {
        const body = std.mem.zeroes([128]u8);
        const n = wire.writeMessage(&out, wire.MSG_TRANSITION_INDEX, body[0..blen]);
        try std.testing.expectEqual(@as(usize, 2 + blen + 16), n);
    }
}

test "MD5 matches known empty-string hash" {
    // Known: MD5("") = d41d8cd98f00b204e9800998ecf8427e
    // We can't call wire.md5 directly (it's private), but we can verify
    // via writeMessage: an empty body should produce the known MD5 in the
    // trailing 16 bytes.
    var out: [64]u8 = undefined;
    const empty_body = [_]u8{};
    const n = wire.writeMessage(&out, wire.MSG_TRANSITION_INDEX, &empty_body);
    try std.testing.expectEqual(@as(usize, 2 + 0 + 16), n);

    // The MD5 should be at out[2..18]
    const expected_md5 = [_]u8{
        0xd4, 0x1d, 0x8c, 0xd9, 0x8f, 0x00, 0xb2, 0x04,
        0xe9, 0x80, 0x09, 0x98, 0xec, 0xf8, 0x42, 0x7e,
    };
    try std.testing.expectEqualSlices(u8, &expected_md5, out[2..18]);
}

test "MD5 matches known 'abc' hash" {
    // Known: MD5("abc") = 900150983cd24fb0d6963f7d28e17f72
    var out: [64]u8 = undefined;
    const body = [_]u8{ 'a', 'b', 'c' };
    const n = wire.writeMessage(&out, wire.MSG_TRANSITION_INDEX, &body);
    try std.testing.expectEqual(@as(usize, 2 + 3 + 16), n);

    const expected_md5 = [_]u8{
        0x90, 0x01, 0x50, 0x98, 0x3c, 0xd2, 0x4f, 0xb0,
        0xd6, 0x96, 0x3f, 0x7d, 0x28, 0xe1, 0x7f, 0x72,
    };
    try std.testing.expectEqualSlices(u8, &expected_md5, out[5..21]);
}
