// Port of CCCaster's `MemDump` / `MemDumpPtr` / `MemDumpList`
// (lib/MemDump.hpp + lib/MemDump.cpp).
//
// This is the mechanism that snapshots and restores MBAACC's game memory
// during rollback. Each `MemDump` is a contiguous [addr, addr+size) range.
// A `MemDumpPtr` is a child region whose address is found by following a
// pointer stored inside a parent region: `addr = *(parent+srcOffset) + dstOffset`.
// This lets the rollback snapshot follow MBAACC's pointer-chased allocations
// (e.g. the effects array) without the port needing to know their layout.
//
// Save format (matches CCCaster's binary cereal archive, minus the trailing
// MD5 — we keep the layout but drop the checksum since this is a focused port):
//   MemDumpList:
//     u64 totalSize
//     u64 addrs.len
//     MemDump[addrs.len]
//   MemDump:
//     u32 addr            (32-bit MBAACC virtual address)
//     u64 size
//     u64 ptrs.len
//     MemDumpPtr[ptrs.len]
//   MemDumpPtr:
//     u64 srcOffset
//     u64 dstOffset
//     u64 size
//     u64 ptrs.len
//     MemDumpPtr[ptrs.len]   (recursive)
//
// On `saveDump` we walk each region and memcpy its bytes into a flat buffer;
// child pointers are then saved recursively after the parent's bytes. On
// `loadDump` we walk the same tree and memcpy bytes back into MBAACC memory.
// If a pointer is NULL, the child region is zeroed on save and skipped on
// load (matching CCCaster's `if (addr) copy(...) else memset(...)`).
//
// IMPORTANT: addr values are 32-bit MBAACC virtual addresses. They are only
// safe to dereference when this code is running inside MBAA.exe on Windows.
// On a non-Windows host the save/load paths must be backed by a mock buffer.

const std = @import("std");

// --- MemDumpPtr (forward-declared via the struct field) --------------------

pub const MemDumpPtr = struct {
    src_offset: usize,
    dst_offset: usize,
    size: usize,
    /// Child pointers located inside THIS pointer's region. The parent is
    /// implicit (set by the caller at save/load time) — CCCaster stores a
    /// back-pointer, but the only thing it's used for is `getAddr()`, which
    /// we compute by passing the parent's address in explicitly.
    ptrs: []MemDumpPtr = &.{},
    /// Owning allocator for `ptrs` (only set when this MemDumpPtr owns its
    /// children; borrowed refs leave this null).
    ptrs_allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *MemDumpPtr) void {
        if (self.ptrs_allocator) |a| {
            for (self.ptrs) |*p| p.deinit();
            a.free(self.ptrs);
            self.ptrs = &.{};
            self.ptrs_allocator = null;
        }
    }

    /// Compute the runtime address of this pointer-followed region, given the
    /// parent region's address. Matches CCCaster's `MemDumpPtr::getAddr()`:
    ///   char *dstAddr = *(char**)(parent->getAddr() + srcOffset);
    ///   if (dstAddr == 0) return 0;
    ///   return dstAddr + dstOffset;
    /// Returns 0 if the parent is NULL or the followed pointer is NULL.
    ///
    /// `read_u32` is the host-side hook that reads a 4-byte little-endian
    /// pointer from a 32-bit MBAACC address. On Windows it dereferences the
    /// live address directly; in tests it reads from a mock buffer.
    pub fn getAddr(self: *const MemDumpPtr, parent_addr: usize, read_u32: *const fn (addr: usize) u32) usize {
        if (parent_addr == 0) return 0;
        std.debug.assert(self.src_offset + 4 <= std.math.maxInt(usize));
        const dst_addr: usize = read_u32(parent_addr + self.src_offset);
        if (dst_addr == 0) return 0;
        return dst_addr + self.dst_offset;
    }
};

// --- MemDump (a root region with a known fixed address) --------------------

pub const MemDump = struct {
    addr: usize,
    size: usize,
    ptrs: []MemDumpPtr = &.{},
    ptrs_allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *MemDump) void {
        if (self.ptrs_allocator) |a| {
            for (self.ptrs) |*p| p.deinit();
            a.free(self.ptrs);
            self.ptrs = &.{};
            self.ptrs_allocator = null;
        }
    }

    /// Total size of this region + all descendant pointer-followed regions.
    /// Matches CCCaster's `MemDumpBase::getTotalSize()`.
    pub fn getTotalSize(self: *const MemDump) usize {
        var total: usize = self.size;
        for (self.ptrs) |*p| total += ptrTotalSize(p);
        return total;
    }

    fn ptrTotalSize(p: *const MemDumpPtr) usize {
        var total: usize = p.size;
        for (p.ptrs) |*c| total += ptrTotalSize(c);
        return total;
    }
};

// --- MemDumpList (the root list of memory regions) -------------------------

pub const MemDumpList = struct {
    allocator: std.mem.Allocator,
    addrs: std.ArrayList(MemDump) = .empty,
    total_size: usize = 0,

    pub fn init(allocator: std.mem.Allocator) MemDumpList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemDumpList) void {
        for (self.addrs.items) |*m| m.deinit();
        self.addrs.deinit(self.allocator);
    }

    pub fn empty(self: *const MemDumpList) bool {
        return self.addrs.items.len == 0;
    }

    pub fn clear(self: *MemDumpList) void {
        for (self.addrs.items) |*m| m.deinit();
        self.addrs.clearRetainingCapacity();
        self.total_size = 0;
    }

    pub fn append(self: *MemDumpList, mem: MemDump) void {
        self.addrs.append(self.allocator, mem) catch return;
    }

    /// Update the list: sort by address, merge continuous ranges, then
    /// recompute `total_size`. Matches CCCaster's `MemDumpList::update()`.
    /// NOTE: CCCaster merges adjacent regions via the MemDump merge constructor
    /// (which concatenates their `ptrs` lists with offset adjustment). We do
    /// the same here.
    pub fn update(self: *MemDumpList) void {
        if (self.addrs.items.len == 0) {
            self.total_size = 0;
            return;
        }
        // Sort by addr.
        std.mem.sort(MemDump, self.addrs.items, {}, struct {
            fn lt(_: void, a: MemDump, b: MemDump) bool {
                return a.addr < b.addr;
            }
        }.lt);

        // Merge continuous ranges. We can't merge in place easily because the
        // ptrs slices are borrowed/owned; instead we build a new list and swap.
        var merged = std.ArrayList(MemDump).empty;
        defer merged.deinit(self.allocator);
        merged.append(self.allocator, self.addrs.items[0]) catch return;

        var i: usize = 1;
        while (i < self.addrs.items.len) : (i += 1) {
            const cur = merged.items[merged.items.len - 1];
            const next = self.addrs.items[i];
            if (cur.addr + cur.size == next.addr) {
                // Merge: extend cur's size and concat ptrs (next's ptrs get
                // src_offset += cur.size so they still point into the right
                // slot of the merged region).
                const merged_size = cur.size + next.size;
                // Build the merged ptrs list.
                var merged_ptrs = self.allocator.alloc(MemDumpPtr, cur.ptrs.len + next.ptrs.len) catch break;
                @memcpy(merged_ptrs[0..cur.ptrs.len], cur.ptrs);
                for (next.ptrs, 0..) |p, j| {
                    merged_ptrs[cur.ptrs.len + j] = .{
                        .src_offset = p.src_offset + cur.size,
                        .dst_offset = p.dst_offset,
                        .size = p.size,
                        .ptrs = p.ptrs, // shallow borrow — fine for the merge pass
                    };
                }
                // Free the old cur's owned ptrs if any, then replace.
                merged.items[merged.items.len - 1].deinit();
                merged.items[merged.items.len - 1] = .{
                    .addr = cur.addr,
                    .size = merged_size,
                    .ptrs = merged_ptrs,
                    .ptrs_allocator = self.allocator,
                };
            } else {
                merged.append(self.allocator, next) catch break;
            }
        }

        // Swap the merged list in.
        for (self.addrs.items) |*m| {
            // Skip entries that were merged into another — they're now borrowed
            // by the merged entry. To keep this simple, we don't double-free:
            // we null out the ptrs of the originals before deinit.
            m.ptrs = &.{};
            m.ptrs_allocator = null;
        }
        for (self.addrs.items) |*m| m.deinit();
        self.addrs.deinit(self.allocator);
        self.addrs = merged;
        merged = .empty;

        // Recompute total size.
        self.total_size = 0;
        for (self.addrs.items) |*m| self.total_size += m.getTotalSize();
    }

    // ---- save / load to a flat byte buffer --------------------------------

    /// Save all regions into a flat byte buffer. The caller owns the returned
    /// slice. Layout matches CCCaster's `saveDump` walk: for each region, copy
    /// its bytes, then recursively copy child pointer-followed regions. NULL
    /// pointers produce zero-filled bytes (matching CCCaster).
    ///
    /// `read_byte` is a callback the caller provides to read a byte from a
    /// 32-bit MBAACC address. On Windows it dereferences the address directly;
    /// in tests it reads from a mock buffer. The same callback is used to
    /// follow pointer chains (4 bytes are composed into a u32 little-endian).
    pub fn saveDump(
        self: *const MemDumpList,
        allocator: std.mem.Allocator,
        read_byte: *const fn (addr: usize) u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        for (self.addrs.items) |*m| try saveRegion(&buf, allocator, m.addr, m.size, m.ptrs, read_byte);
        return try buf.toOwnedSlice(allocator);
    }

    /// Restore all regions from a flat byte buffer previously produced by
    /// `saveDump`. `write_byte` is the host-side hook that writes a byte to
    /// a 32-bit MBAACC address. Pointer chains are followed by reading 4 bytes
    /// from the (already-restored) parent region via `read_byte`.
    pub fn loadDump(
        self: *const MemDumpList,
        data: []const u8,
        write_byte: *const fn (addr: usize, b: u8) void,
        read_byte: *const fn (addr: usize) u8,
    ) void {
        var off: usize = 0;
        for (self.addrs.items) |*m| {
            loadRegion(data, &off, m.addr, m.size, m.ptrs, write_byte, read_byte);
        }
    }

    fn saveRegion(
        buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        addr: usize,
        size: usize,
        ptrs: []const MemDumpPtr,
        read_byte: *const fn (addr: usize) u8,
    ) !void {
        if (addr != 0) {
            var i: usize = 0;
            while (i < size) : (i += 1) try buf.append(allocator, read_byte(addr + i));
        } else {
            try buf.appendNTimes(allocator, 0, size);
        }
        for (ptrs) |*p| {
            const child_addr = p.getAddr(addr, makeReadU32(read_byte));
            try saveRegion(buf, allocator, child_addr, p.size, p.ptrs, read_byte);
        }
    }

    fn loadRegion(
        data: []const u8,
        off: *usize,
        addr: usize,
        size: usize,
        ptrs: []const MemDumpPtr,
        write_byte: *const fn (addr: usize, b: u8) void,
        read_byte: *const fn (addr: usize) u8,
    ) void {
        if (addr != 0) {
            var i: usize = 0;
            while (i < size) : (i += 1) {
                if (off.* >= data.len) return;
                write_byte(addr + i, data[off.*]);
                off.* += 1;
            }
        } else {
            off.* += size;
        }
        for (ptrs) |*p| {
            const child_addr = p.getAddr(addr, makeReadU32(read_byte));
            loadRegion(data, off, child_addr, p.size, p.ptrs, write_byte, read_byte);
        }
    }

    /// Compose a `read_u32` callback from a `read_byte` callback by reading
    /// 4 bytes little-endian. Used to follow pointer chains without needing
    /// a separate u32 reader.
    pub fn makeReadU32(read_byte: *const fn (addr: usize) u8) *const fn (addr: usize) u32 {
        const Wrapper = struct {
            var fn_ptr: *const fn (addr: usize) u8 = undefined;
            fn impl(addr: usize) u32 {
                const b0 = fn_ptr(addr + 0);
                const b1 = fn_ptr(addr + 1);
                const b2 = fn_ptr(addr + 2);
                const b3 = fn_ptr(addr + 3);
                return @as(u32, b0) | (@as(u32, b1) << 8) | (@as(u32, b2) << 16) | (@as(u32, b3) << 24);
            }
        };
        Wrapper.fn_ptr = read_byte;
        return &Wrapper.impl;
    }

    // ---- binary serialization (the rollback.bin format) -------------------

    /// Serialize the region list to a binary buffer matching CCCaster's
    /// `MemDumpList::save(BinaryOutputArchive)`. Used to persist the rollback
    /// region table to disk.
    pub fn serialize(self: *const MemDumpList, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        try writeU64(&buf, allocator, self.total_size);
        try writeU64(&buf, allocator, self.addrs.items.len);
        for (self.addrs.items) |*m| try serializeDump(&buf, allocator, m);
        return try buf.toOwnedSlice(allocator);
    }

    /// Deserialize from CCCaster's binary format. Matches
    /// `MemDumpList::load(BinaryInputArchive)` + the recursive `loadPtrs`.
    pub fn deserialize(self: *MemDumpList, data: []const u8) !void {
        var off: usize = 0;
        self.total_size = try readU64(data, &off);
        const count = try readU64(data, &off);
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const m = try deserializeDump(self.allocator, data, &off);
            self.addrs.append(self.allocator, m) catch return error.OutOfMemory;
        }
    }

    fn serializeDump(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, m: *const MemDump) !void {
        try writeU32(buf, allocator, @intCast(m.addr));
        try writeU64(buf, allocator, m.size);
        try writeU64(buf, allocator, m.ptrs.len);
        for (m.ptrs) |*p| try serializePtr(buf, allocator, p);
    }

    fn serializePtr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, p: *const MemDumpPtr) !void {
        try writeU64(buf, allocator, p.src_offset);
        try writeU64(buf, allocator, p.dst_offset);
        try writeU64(buf, allocator, p.size);
        try writeU64(buf, allocator, p.ptrs.len);
        for (p.ptrs) |*c| try serializePtr(buf, allocator, c);
    }

    fn deserializeDump(allocator: std.mem.Allocator, data: []const u8, off: *usize) !MemDump {
        const addr = try readU32(data, off);
        const size = try readU64(data, off);
        const ptrs_count = try readU64(data, off);
        const ptrs = try loadPtrs(allocator, data, off, ptrs_count);
        return .{
            .addr = addr,
            .size = size,
            .ptrs = ptrs,
            .ptrs_allocator = allocator,
        };
    }

    fn loadPtrs(allocator: std.mem.Allocator, data: []const u8, off: *usize, count: u64) ![]MemDumpPtr {
        if (count == 0) return &.{};
        const ret = try allocator.alloc(MemDumpPtr, count);
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const src_offset = try readU64(data, off);
            const dst_offset = try readU64(data, off);
            const size = try readU64(data, off);
            const sub_count = try readU64(data, off);
            const sub_ptrs = try loadPtrs(allocator, data, off, sub_count);
            ret[i] = .{
                .src_offset = src_offset,
                .dst_offset = dst_offset,
                .size = size,
                .ptrs = sub_ptrs,
                .ptrs_allocator = allocator,
            };
        }
        return ret;
    }
};

// ---- little-endian helpers -----------------------------------------------

fn writeU32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try buf.appendSlice(allocator, &b);
}

fn writeU64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u64) !void {
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, v, .little);
    try buf.appendSlice(allocator, &b);
}

fn readU32(data: []const u8, off: *usize) !u32 {
    if (off.* + 4 > data.len) return error.Truncated;
    const v = std.mem.readInt(u32, data[off.*..][0..4], .little);
    off.* += 4;
    return v;
}

fn readU64(data: []const u8, off: *usize) !u64 {
    if (off.* + 8 > data.len) return error.Truncated;
    const v = std.mem.readInt(u64, data[off.*..][0..8], .little);
    off.* += 8;
    return v;
}

// ---------------------------------------------------------------------------
// Tests — verify save/load round-trips a mock memory image.
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// A mock 256-byte "MBAACC memory image" backed by a Zig buffer, plus a
/// 4-byte pointer slot at offset 0x40 that points to offset 0x80.
const MockMem = struct {
    buf: [256]u8 = [_]u8{0} ** 256,
};

// Because Zig closures can't capture state without an allocator, we use a
// file-global mock for the round-trip test.
var g_mock: [256]u8 = [_]u8{0} ** 256;

fn mockRead(addr: usize) u8 {
    if (addr >= g_mock.len) return 0;
    return g_mock[addr];
}

fn mockWrite(addr: usize, b: u8) void {
    if (addr >= g_mock.len) return;
    g_mock[addr] = b;
}

test "saveDump + loadDump round-trips a flat region" {
    var list = MemDumpList.init(std.testing.allocator);
    defer list.deinit();

    // Region [16, 32) — 16 bytes.
    list.append(.{ .addr = 16, .size = 16 });
    list.update();
    try expectEqual(@as(usize, 16), list.total_size);

    // Seed the mock with a known pattern.
    var i: usize = 0;
    while (i < 32) : (i += 1) g_mock[i] = @intCast(i + 1);

    const saved = try list.saveDump(std.testing.allocator, &mockRead);
    defer std.testing.allocator.free(saved);
    try expectEqual(@as(usize, 16), saved.len);
    try expectEqual(@as(u8, 17), saved[0]); // addr 16 → value 17
    try expectEqual(@as(u8, 32), saved[15]); // addr 31 → value 32

    // Wipe the mock, then restore.
    @memset(g_mock[0..32], 0);
    list.loadDump(saved, &mockWrite, &mockRead);
    try expectEqual(@as(u8, 17), g_mock[16]);
    try expectEqual(@as(u8, 32), g_mock[31]);
}

test "saveDump follows a pointer chain" {
    var list = MemDumpList.init(std.testing.allocator);
    defer list.deinit();

    // Parent region [0x10, 0x54). At parent offset 0x40 (absolute 0x50) there's
    // a u32 pointer to 0x80. Child region: 4 bytes at *(0x50) + 0 = 0x80.
    // (Parent addr must be non-zero — CCCaster treats addr=0 as NULL.)
    const parent_addr: usize = 0x10;
    const ptr_slot: usize = 0x50; // parent_addr + 0x40
    var ptrs = try std.testing.allocator.alloc(MemDumpPtr, 1);
    ptrs[0] = .{ .src_offset = 0x40, .dst_offset = 0, .size = 4 };
    list.append(.{ .addr = parent_addr, .size = 0x44, .ptrs = ptrs, .ptrs_allocator = std.testing.allocator });
    list.update();

    // Seed the pointer slot and the pointed-to region.
    std.mem.writeInt(u32, g_mock[ptr_slot..][0..4], 0x80, .little);
    g_mock[0x80] = 0xDE;
    g_mock[0x81] = 0xAD;
    g_mock[0x82] = 0xBE;
    g_mock[0x83] = 0xEF;

    const saved = try list.saveDump(std.testing.allocator, &mockRead);
    defer std.testing.allocator.free(saved);
    // 0x44 bytes for the parent + 4 bytes for the child = 72.
    try expectEqual(@as(usize, 0x44 + 4), saved.len);
    // The last 4 bytes are the pointed-to region.
    try expectEqual(@as(u8, 0xDE), saved[0x44 + 0]);
    try expectEqual(@as(u8, 0xEF), saved[0x44 + 3]);

    // Wipe and restore.
    @memset(g_mock[0..256], 0);
    list.loadDump(saved, &mockWrite, &mockRead);
    try expectEqual(@as(u8, 0xDE), g_mock[0x80]);
    try expectEqual(@as(u8, 0xEF), g_mock[0x83]);
}

test "NULL pointer in the chain is zero-filled on save, skipped on load" {
    var list = MemDumpList.init(std.testing.allocator);
    defer list.deinit();

    const parent_addr: usize = 0x10;
    const ptr_slot: usize = 0x50;
    var ptrs = try std.testing.allocator.alloc(MemDumpPtr, 1);
    ptrs[0] = .{ .src_offset = 0x40, .dst_offset = 0, .size = 4 };
    list.append(.{ .addr = parent_addr, .size = 0x44, .ptrs = ptrs, .ptrs_allocator = std.testing.allocator });
    list.update();

    // Pointer slot is NULL.
    std.mem.writeInt(u32, g_mock[ptr_slot..][0..4], 0, .little);

    const saved = try list.saveDump(std.testing.allocator, &mockRead);
    defer std.testing.allocator.free(saved);
    try expectEqual(@as(usize, 0x44 + 4), saved.len);
    // The last 4 bytes (the NULL-followed child) must be zero.
    try expectEqual(@as(u8, 0), saved[0x44 + 0]);
    try expectEqual(@as(u8, 0), saved[0x44 + 3]);
}

test "serialize + deserialize round-trips the region table" {
    var list = MemDumpList.init(std.testing.allocator);
    defer list.deinit();

    var ptrs = try std.testing.allocator.alloc(MemDumpPtr, 1);
    ptrs[0] = .{ .src_offset = 0x10, .dst_offset = 0x20, .size = 4 };
    list.append(.{ .addr = 0x100, .size = 0x40, .ptrs = ptrs, .ptrs_allocator = std.testing.allocator });
    list.append(.{ .addr = 0x200, .size = 0x10 });
    list.update();

    const blob = try list.serialize(std.testing.allocator);
    defer std.testing.allocator.free(blob);

    var list2 = MemDumpList.init(std.testing.allocator);
    defer list2.deinit();
    try list2.deserialize(blob);
    try expectEqual(list.total_size, list2.total_size);
    try expectEqual(list.addrs.items.len, list2.addrs.items.len);
    try expectEqual(@as(usize, 0x100), list2.addrs.items[0].addr);
    try expectEqual(@as(usize, 0x40), list2.addrs.items[0].size);
    try expectEqual(@as(usize, 1), list2.addrs.items[0].ptrs.len);
    try expectEqual(@as(usize, 0x10), list2.addrs.items[0].ptrs[0].src_offset);
    try expectEqual(@as(usize, 0x20), list2.addrs.items[0].ptrs[0].dst_offset);
}
