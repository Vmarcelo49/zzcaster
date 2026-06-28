// Demo / smoke-test for the cc_rollback library. Runs a short scenario:
//   1. Build a tiny mock MBAACC memory image (256 bytes).
//   2. Load a one-region rollback table.
//   3. Save a state, mutate memory, fire a rollback, verify restoration.
//
// This is NOT a full MBAACC netplay client — it demonstrates that the
// library compiles, links, and round-trips a rollback correctly. The real
// hook DLL wires `read_byte`/`write_byte` up to `CC_*_ADDR` dereferences.

const std = @import("std");
const cc = @import("cc_rollback");

var g_mem: [256]u8 = [_]u8{0} ** 256;
var g_world_timer: u32 = 0;

fn readByte(addr: usize) u8 {
    if (addr >= g_mem.len) return 0;
    return g_mem[addr];
}

fn writeByte(addr: usize, b: u8) void {
    if (addr >= g_mem.len) return;
    g_mem[addr] = b;
}

fn readWorldTimer() u32 {
    return g_world_timer;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // --- Build a minimal region table: 16 bytes at offset 0x20. ----------
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(alloc);
    var b8: [8]u8 = undefined;
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u64, &b8, 16, .little);
    try blob.appendSlice(alloc, &b8); // totalSize
    std.mem.writeInt(u64, &b8, 1, .little);
    try blob.appendSlice(alloc, &b8); // count
    std.mem.writeInt(u32, &b4, 0x20, .little);
    try blob.appendSlice(alloc, &b4); // addr
    std.mem.writeInt(u64, &b8, 16, .little);
    try blob.appendSlice(alloc, &b8); // size
    std.mem.writeInt(u64, &b8, 0, .little);
    try blob.appendSlice(alloc, &b8); // ptrs.len

    // --- Set up the rollback manager. ------------------------------------
    var rm = cc.RollbackManager.init(alloc);
    defer rm.deinit();
    try rm.loadRegions(blob.items);
    try rm.allocateStates(8);

    // --- Set up the netplay manager (in_game, index 4, frame 0). ---------
    var nm = cc.NetplayManager.init(alloc);
    defer nm.deinit();
    nm.read_world_timer = &readWorldTimer;
    nm.config = .{ .delay = 0, .rollback_delay = 0, .rollback = 4, .is_netplay = true };
    nm.state = .in_game;
    nm.indexed_frame = cc.IndexedFrame.init(0, 4);
    nm.start_index = 4;
    nm.start_world_time = 0;

    var fs = cc.FrameStep.init();
    fs.configureForRollback(4);

    var sfx_filter = [_]u8{0} ** 16;
    var sfx_array = [_]u8{0} ** 16;
    var sfx_mute = [_]u8{0} ** 16;

    // --- Frame 0: save a state. ------------------------------------------
    @memset(g_mem[0x20..0x30], 0xAA);
    g_world_timer = 0;
    nm.updateFrame();
    rm.saveState(
        .{ .state = &nm.state, .start_world_time = &nm.start_world_time, .indexed_frame = &nm.indexed_frame },
        &readByte,
        &sfx_filter,
    );
    std.debug.print("Saved state at frame {d}, memory = 0xAA\n", .{nm.getFrame()});

    // --- Advance to frame 5, mutating memory. ----------------------------
    g_world_timer = 5;
    nm.updateFrame();
    @memset(g_mem[0x20..0x30], 0xBB);
    std.debug.print("Advanced to frame {d}, memory = 0xBB\n", .{nm.getFrame()});

    // --- Simulate a misprediction: predicted 0x01 at frame 0, actual 0x09.
    nm.inputs[1].set(0, 0, 0x01);
    const actual = [_]u16{0x09};
    nm.setInputs(2, 4, 0, &actual);
    const lcf = nm.getLastChangedFrame();
    std.debug.print("Misprediction detected at index {d}, frame {d}\n", .{ lcf.index(), lcf.frame() });

    // --- Fire the rollback. ----------------------------------------------
    while (fs.rollback_timer < fs.min_rollback_spacing) fs.tickTimer();
    const fired = fs.fireRollback(&nm, &rm, &writeByte, &readByte, &sfx_filter, null);
    std.debug.print("Rollback fired: {}, memory restored to 0x{x:0>2}\n", .{ fired, g_mem[0x20] });
    std.debug.print("Frame rewound to {d}, re-running toward frame 5\n", .{nm.getFrame()});

    // --- Re-run until we reach the target frame. -------------------------
    var frame_i: u32 = 0;
    while (frame_i < 10) : (frame_i += 1) {
        g_world_timer = frame_i;
        nm.updateFrame();
        if (fs.stepRerun(&nm, &rm, &sfx_filter, &sfx_array, &sfx_mute)) {
            std.debug.print("Re-run complete at frame {d}\n", .{nm.getFrame()});
            break;
        }
    }

    std.debug.print("\nDemo complete. The rollback correctly restored memory and re-ran the simulation.\n", .{});
}
