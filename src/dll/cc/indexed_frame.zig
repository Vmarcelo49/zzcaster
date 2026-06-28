// Port of CCCaster's `union IndexedFrame` (Constants.hpp:245-256).
//
// CCCaster uses a C++ union:
//   union IndexedFrame {
//       struct { uint32_t frame, index; } parts;
//       uint64_t value;
//   };
//
// In Zig we expose both views on the same u64 via helper functions. The
// memory layout is identical: `value = (index << 32) | frame`, little-endian,
// so the wire format and comparison semantics match CCCaster byte-for-byte.
//
// CCCaster initializes `MaxIndexedFrame = {{ UINT_MAX, UINT_MAX }}`; we expose
// the same sentinel as `max_value`.

const std = @import("std");

pub const IndexedFrame = struct {
    /// Combined 64-bit value: high 32 bits = index, low 32 bits = frame.
    /// Matches CCCaster's `uint64_t value` view of the union.
    value: u64 = 0,

    pub const max_value: IndexedFrame = .{ .value = std.math.maxInt(u64) };

    pub inline fn init(f: u32, i: u32) IndexedFrame {
        return .{ .value = (@as(u64, i) << 32) | @as(u64, f) };
    }

    pub inline fn frame(self: IndexedFrame) u32 {
        return @intCast(self.value & 0xFFFFFFFF);
    }

    pub inline fn index(self: IndexedFrame) u32 {
        return @intCast(self.value >> 32);
    }

    pub inline fn setFrame(self: *IndexedFrame, f: u32) void {
        self.value = (self.value & 0xFFFFFFFF00000000) | @as(u64, f);
    }

    pub inline fn setIndex(self: *IndexedFrame, i: u32) void {
        self.value = (self.value & 0x00000000FFFFFFFF) | (@as(u64, i) << 32);
    }

    /// Format as `index:frame` — matches CCCaster's `operator<<`.
    pub fn format(
        self: IndexedFrame,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{d}:{d}", .{ self.index(), self.frame() });
    }

    pub inline fn eql(a: IndexedFrame, b: IndexedFrame) bool {
        return a.value == b.value;
    }

    pub inline fn lessThan(a: IndexedFrame, b: IndexedFrame) bool {
        return a.value < b.value;
    }
};

test "IndexedFrame round-trip" {
    const f = IndexedFrame.init(42, 7);
    try std.testing.expectEqual(@as(u32, 42), f.frame());
    try std.testing.expectEqual(@as(u32, 7), f.index());

    var g = IndexedFrame.init(0, 0);
    g.setFrame(100);
    g.setIndex(3);
    try std.testing.expectEqual(@as(u32, 100), g.frame());
    try std.testing.expectEqual(@as(u32, 3), g.index());
    try std.testing.expectEqual(@as(u64, (@as(u64, 3) << 32) | 100), g.value);
}

test "IndexedFrame max sentinel" {
    const m = IndexedFrame.max_value;
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), m.value);
}
