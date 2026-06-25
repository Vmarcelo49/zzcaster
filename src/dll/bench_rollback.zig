const std = @import("std");
const rollback_regions = @import("rollback_regions.zig");

const Region = rollback_regions.Region;

const Io = std.Io.Threaded;

const BenchmarkResult = struct {
    region_count: usize,
    bytes_per_state: usize,
    save_us_total: i128,
    save_us_per_call: f64,
    save_bytes_per_sec: f64,
    load_us_total: i128,
    load_us_per_call: f64,
    load_bytes_per_sec: f64,
    iterations: u32,
};

const Coalesced = struct {
    /// Sorted, non-overlapping regions (contiguous neighbors merged).
    regions: []Region,
    /// Mapping from the original regions[i] to the coalesced slot that
    /// contains it. Indexes into `regions`. May be 0..regions.len-1.
    /// Length equals the input region's length.
    src_to_coalesced: []usize,
    /// Total bytes per snapshot (sum of coalesced region sizes).
    bytes_per_state: usize,
};

/// Build the pre-coalesced region list (no merging) and the post-coalesced
/// list (sorted + merge adjacent or overlapping). Returns null if the input
/// is already optimal (no merges possible).
///
/// Algorithm:
///   1. Sort by start address (stable secondary by end address).
///   2. Walk sorted list; when region[i].end >= region[i+1].start, merge
///      region[i+1] into region[i] (extend end to region[i+1].end).
///   3. Continue until no more merges in a full pass.
fn coalesce(allocator: std.mem.Allocator, input: []const Region) !Coalesced {
    // 1. Sort by start address.
    const sorted = try allocator.dupe(Region, input);
    defer allocator.free(sorted);
    std.mem.sort(Region, sorted, {}, lessThanStart);

    // 2. Merge overlapping or adjacent regions.
    var merged: std.ArrayList(Region) = .empty;
    defer merged.deinit(allocator);
    try merged.append(allocator, sorted[0]);
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        const top = &merged.items[merged.items.len - 1];
        const cur = sorted[i];
        if (cur.addr <= top.addr + top.size) {
            // Overlapping or adjacent: extend the top region's end.
            const new_end = @max(top.addr + top.size, cur.addr + cur.size);
            top.size = new_end - top.addr;
        } else {
            try merged.append(allocator, cur);
        }
    }

    // 3. Build a map from original region index → coalesced slot.
    const src_to_coalesced = try allocator.alloc(usize, input.len);
    for (src_to_coalesced) |*slot| slot.* = 0;
    var co_idx: usize = 0;
    var co_end: usize = merged.items[co_idx].addr + merged.items[co_idx].size;
    for (input, 0..) |r, j| {
        // Advance co_idx until the coalesced region contains r.
        while (r.addr + r.size > co_end and co_idx + 1 < merged.items.len) {
            co_idx += 1;
            co_end = merged.items[co_idx].addr + merged.items[co_idx].size;
        }
        src_to_coalesced[j] = co_idx;
    }

    // 4. Compute total bytes per state.
    var bytes_per_state: usize = 0;
    for (merged.items) |r| bytes_per_state += r.size;

    return .{
        .regions = try merged.toOwnedSlice(allocator),
        .src_to_coalesced = src_to_coalesced,
        .bytes_per_state = bytes_per_state,
    };
}

fn lessThanStart(_: void, a: Region, b: Region) bool {
    if (a.addr != b.addr) return a.addr < b.addr;
    return a.size < b.size;
}

const MockProcessMemory = struct {
    /// Simulates the MBAACC process address space starting at address 0.
    /// Each region in the rollback list maps to an offset within this buffer.
    /// The buffer is sized to cover the highest address (0x7B1D2C + 4).
    data: []u8,
    base_addr: usize,

    fn init(allocator: std.mem.Allocator, base_addr: usize, size: usize) !MockProcessMemory {
        const data = try allocator.alloc(u8, size);
        // Seed with deterministic pseudo-random data so that we exercise
        // the full memcpy path (no zero-skip optimizations).
        var prng = std.Random.DefaultPrng.init(0xDEAD_BEEF);
        for (data) |*b| b.* = prng.random().int(u8);
        return .{ .data = data, .base_addr = base_addr };
    }

    fn deinit(self: *MockProcessMemory, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    /// Map an address (as in rollback_regions) to a pointer into our buffer.
    fn ptr(self: *const MockProcessMemory, addr: usize) [*]u8 {
        const off = addr - self.base_addr;
        return self.data.ptr + off;
    }

    fn slice(self: *const MockProcessMemory, addr: usize, size: usize) []u8 {
        return self.ptr(addr)[0..size];
    }
};

fn nowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).toNanoseconds();
}

fn runNaive(memory: *MockProcessMemory, snapshot: []u8, regions: []const Region, iterations: u32, io: std.Io) BenchmarkResult {
    // Pre-compute pointers once so the benchmark isn't measuring the
    // "@ptrFromInt" lookup — only the memcpy.
    var total: usize = 0;
    for (regions) |r| total += r.size;
    var pos: usize = 0;
    var srcs: [370]usize = undefined; // max 370 regions
    var sizes: [370]usize = undefined;
    var i: usize = 0;
    while (i < regions.len and i < 370) : (i += 1) {
        srcs[i] = regions[i].addr;
        sizes[i] = regions[i].size;
        pos += regions[i].size;
    }

    const save_start = nowNs(io);
    var k: u32 = 0;
    while (k < iterations) : (k += 1) {
        var p: usize = 0;
        for (srcs[0..regions.len], sizes[0..regions.len]) |addr, sz| {
            @memcpy(snapshot[p .. p + sz], memory.slice(addr, sz));
            p += sz;
        }
    }
    const save_end = nowNs(io);

    const load_start = nowNs(io);
    var j: u32 = 0;
    while (j < iterations) : (j += 1) {
        var p: usize = 0;
        for (srcs[0..regions.len], sizes[0..regions.len]) |addr, sz| {
            @memcpy(memory.slice(addr, sz), snapshot[p .. p + sz]);
            p += sz;
        }
    }
    const load_end = nowNs(io);

    const save_ns = save_end - save_start;
    const load_ns = load_end - load_start;
    return .{
        .region_count = regions.len,
        .bytes_per_state = total,
        .save_us_total = @divTrunc(save_ns, 1000),
        .save_us_per_call = @as(f64, @floatFromInt(save_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0,
        .save_bytes_per_sec = @as(f64, @floatFromInt(total * iterations)) * 1e9 / @as(f64, @floatFromInt(save_ns)),
        .load_us_total = @divTrunc(load_ns, 1000),
        .load_us_per_call = @as(f64, @floatFromInt(load_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0,
        .load_bytes_per_sec = @as(f64, @floatFromInt(total * iterations)) * 1e9 / @as(f64, @floatFromInt(load_ns)),
        .iterations = iterations,
    };
}

fn runCoalesced(memory: *MockProcessMemory, snapshot: []u8, regions: []const Region, iterations: u32, io: std.Io) BenchmarkResult {
    var total: usize = 0;
    for (regions) |r| total += r.size;

    var srcs: [64]usize = undefined; // coalesced count is much smaller (under 20 in practice)
    var sizes: [64]usize = undefined;
    var i: usize = 0;
    while (i < regions.len and i < 64) : (i += 1) {
        srcs[i] = regions[i].addr;
        sizes[i] = regions[i].size;
    }

    const save_start = nowNs(io);
    var k: u32 = 0;
    while (k < iterations) : (k += 1) {
        var p: usize = 0;
        for (srcs[0..regions.len], sizes[0..regions.len]) |addr, sz| {
            @memcpy(snapshot[p .. p + sz], memory.slice(addr, sz));
            p += sz;
        }
    }
    const save_end = nowNs(io);

    const load_start = nowNs(io);
    var j: u32 = 0;
    while (j < iterations) : (j += 1) {
        var p: usize = 0;
        for (srcs[0..regions.len], sizes[0..regions.len]) |addr, sz| {
            @memcpy(memory.slice(addr, sz), snapshot[p .. p + sz]);
            p += sz;
        }
    }
    const load_end = nowNs(io);

    const save_ns = save_end - save_start;
    const load_ns = load_end - load_start;
    return .{
        .region_count = regions.len,
        .bytes_per_state = total,
        .save_us_total = @divTrunc(save_ns, 1000),
        .save_us_per_call = @as(f64, @floatFromInt(save_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0,
        .save_bytes_per_sec = @as(f64, @floatFromInt(total * iterations)) * 1e9 / @as(f64, @floatFromInt(save_ns)),
        .load_us_total = @divTrunc(load_ns, 1000),
        .load_us_per_call = @as(f64, @floatFromInt(load_ns)) / @as(f64, @floatFromInt(iterations)) / 1000.0,
        .load_bytes_per_sec = @as(f64, @floatFromInt(total * iterations)) * 1e9 / @as(f64, @floatFromInt(load_ns)),
        .iterations = iterations,
    };
}

fn printResult(label: []const u8, r: BenchmarkResult, w: *std.Io.Writer) !void {
    try w.print(
        \\[{s}]
        \\  regions             : {d}
        \\  bytes/state         : {d} ({d} KB)
        \\  iterations          : {d}
        \\  save total          : {d} us ({d:.2} us/call, {d:.2} MB/s)
        \\  load total          : {d} us ({d:.2} us/call, {d:.2} MB/s)
        \\
    , .{
        label,
        r.region_count,
        r.bytes_per_state,
        r.bytes_per_state / 1024,
        r.iterations,
        r.save_us_total, r.save_us_per_call, r.save_bytes_per_sec / (1024 * 1024),
        r.load_us_total, r.load_us_per_call, r.load_bytes_per_sec / (1024 * 1024),
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout.interface;

    // Mock process memory: covers 0x400000..0xC00000 (8 MB window starting
    // well before the lowest region and well past the highest 0x7B1D2C).
    const base_addr: usize = 0x400000;
    const mem_size: usize = 0x800000;
    var memory = try MockProcessMemory.init(allocator, base_addr, mem_size);
    defer memory.deinit(allocator);

    // Coalesce the production region list.
    const coalesced = try coalesce(allocator, &rollback_regions.all_regions);
    defer allocator.free(coalesced.regions);
    defer allocator.free(coalesced.src_to_coalesced);

    const iterations: u32 = 1000;

    try w.print("ZZCaster rollback micro-benchmark\n", .{});
    try w.print("==================================\n\n", .{});
    try w.print("Real rollback regions (from src/dll/rollback_regions.zig):\n", .{});
    try w.print("  pre-coalesced:  {d} regions\n", .{rollback_regions.all_regions.len});
    try w.print("  post-coalesced: {d} regions\n", .{coalesced.regions.len});
    try w.print("  reduction:      {d:.1}x fewer regions\n\n", .{
        @as(f64, @floatFromInt(rollback_regions.all_regions.len)) /
            @as(f64, @floatFromInt(coalesced.regions.len)),
    });

    // Translate region addresses into the mock process memory (offset by
    // base_addr) so the pointers we hand to @memcpy are valid.
    const translated = try allocator.alloc(Region, rollback_regions.all_regions.len);
    defer allocator.free(translated);
    for (rollback_regions.all_regions, 0..) |r, i| {
        translated[i] = .{ .addr = r.addr, .size = r.size };
    }

    const coalesced_translated = try allocator.alloc(Region, coalesced.regions.len);
    defer allocator.free(coalesced_translated);
    for (coalesced.regions, 0..) |r, i| {
        coalesced_translated[i] = .{ .addr = r.addr, .size = r.size };
    }

    const snapshot_naive = try allocator.alloc(u8, coalesced.bytes_per_state);
    defer allocator.free(snapshot_naive);
    const snapshot_co = try allocator.alloc(u8, coalesced.bytes_per_state);
    defer allocator.free(snapshot_co);

    // Warmup.
    _ = try MockProcessMemory.init(allocator, base_addr, 1024);

    const naive = runNaive(&memory, snapshot_naive, translated, iterations, io);
    try printResult("PRE-COALESCED (current behavior: ~370 individual memcpys)", naive, w);

    const coalesced_r = runCoalesced(&memory, snapshot_co, coalesced_translated, iterations, io);
    try printResult("POST-COALESCED (sort+merge adjacent)", coalesced_r, w);

    try w.print("Speedup:\n", .{});
    try w.print(
        \\  save: {d:.2}x faster ({d:.2} us/call → {d:.2} us/call)
        \\  load: {d:.2}x faster ({d:.2} us/call → {d:.2} us/call)
        \\
    , .{
        naive.save_us_per_call / coalesced_r.save_us_per_call,
        naive.save_us_per_call, coalesced_r.save_us_per_call,
        naive.load_us_per_call / coalesced_r.load_us_per_call,
        naive.load_us_per_call, coalesced_r.load_us_per_call,
    });

    try stdout.end();
}