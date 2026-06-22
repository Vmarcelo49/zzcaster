const std = @import("std");
const logging = @import("common").logging;
const builtin = @import("builtin");

// Rollback state pool — saves/restores game memory snapshots.
// In a full implementation, the memory regions to save are loaded from
// res/rollback.bin (a binary file listing all addresses+sizes to snapshot).
// Here we implement the pool itself + FPU state save/restore.

pub const InputBuffer = struct {
    allocator: std.mem.Allocator,
    inputs: std.AutoHashMap(u64, u16),
    last_changed_frame: ?u64 = null,
    end_frames: std.AutoHashMap(u32, u32),
    last_inputs: std.AutoHashMap(u32, u16),
    end_index: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) InputBuffer {
        return .{
            .allocator = allocator,
            .inputs = std.AutoHashMap(u64, u16).init(allocator),
            .end_frames = std.AutoHashMap(u32, u32).init(allocator),
            .last_inputs = std.AutoHashMap(u32, u16).init(allocator),
        };
    }

    pub fn deinit(self: *InputBuffer) void {
        self.inputs.deinit();
        self.end_frames.deinit();
        self.last_inputs.deinit();
    }

    pub fn get(self: *const InputBuffer, index: u32, frame: u32) u16 {
        const key = makeKey(index, frame);
        if (self.inputs.get(key)) |v| return v;
        if (self.last_inputs.get(index)) |v| return v;
        if (index > 0) {
            var idx = index;
            while (idx > 0) {
                idx -= 1;
                if (self.last_inputs.get(idx)) |v| return v;
            }
        }
        return 0;
    }

    pub fn set(self: *InputBuffer, index: u32, frame: u32, input: u16) void {
        const key = makeKey(index, frame);
        self.inputs.put(key, input) catch {};
        self.updateMeta(index, frame, input);
    }

    pub fn setRemote(self: *InputBuffer, index: u32, start_frame: u32, inputs: []const u16, check_changes: bool) void {
        for (inputs, 0..) |input, i| {
            const frame = start_frame + @as(u32, @intCast(i));
            const key = makeKey(index, frame);
            if (check_changes) {
                const prev = self.inputs.get(key) orelse 0;
                if (prev != input) {
                    if (self.last_changed_frame == null or key < self.last_changed_frame.?) {
                        self.last_changed_frame = key;
                    }
                }
            }
            self.inputs.put(key, input) catch {};
            self.updateMeta(index, frame, input);
        }
    }

    fn updateMeta(self: *InputBuffer, index: u32, frame: u32, input: u16) void {
        if (self.end_frames.getPtr(index)) |ef| {
            if (frame + 1 > ef.*) {
                ef.* = frame + 1;
                self.last_inputs.put(index, input) catch {};
            }
        } else {
            self.end_frames.put(index, frame + 1) catch {};
            self.last_inputs.put(index, input) catch {};
        }
        if (index >= self.end_index) self.end_index = index + 1;
    }

    pub fn clearLastChanged(self: *InputBuffer) void {
        self.last_changed_frame = null;
    }

    pub fn getEndFrame(self: *const InputBuffer, index: u32) u32 {
        return self.end_frames.get(index) orelse 0;
    }

    pub fn getEndIndex(self: *const InputBuffer) u32 {
        return self.end_index;
    }

    fn makeKey(index: u32, frame: u32) u64 {
        return (@as(u64, index) << 32) | @as(u64, frame);
    }
};

// Memory region to save/restore during rollback
pub const MemoryRegion = struct {
    addr: usize,
    size: usize,
};

// Saved game state
pub const SavedState = struct {
    frame: u32,
    index: u32,
    fpu_env: [28]u8, // x87 FPU control word save area (fenv_t on x86)
    data: []u8,      // contiguous buffer for all memory regions
};

pub const StatePool = struct {
    allocator: std.mem.Allocator,
    pool: []u8 = &.{},
    state_size: usize = 0,
    num_states: usize = 0,
    free_stack: std.ArrayList(usize),
    regions: std.ArrayList(MemoryRegion),
    saved_states: std.ArrayList(SavedState),

    pub fn init(allocator: std.mem.Allocator) StatePool {
        return .{
            .allocator = allocator,
            .free_stack = .empty,
            .regions = .empty,
            .saved_states = .empty,
        };
    }

    pub fn deinit(self: *StatePool) void {
        if (self.pool.len > 0) self.allocator.free(self.pool);
        self.free_stack.deinit(self.allocator);
        // Free saved state data buffers
        for (self.saved_states.items) |s| {
            self.allocator.free(s.data);
        }
        self.saved_states.deinit(self.allocator);
        self.regions.deinit(self.allocator);
    }

    /// Add a memory region to save/restore (from res/rollback.bin)
    pub fn addRegion(self: *StatePool, addr: usize, size: usize) !void {
        try self.regions.append(self.allocator, .{ .addr = addr, .size = size });
    }

    /// Calculate total size of all regions
    pub fn totalRegionSize(self: *const StatePool) usize {
        var total: usize = 0;
        for (self.regions.items) |r| total += r.size;
        return total;
    }

    /// Allocate the memory pool
    pub fn allocate(self: *StatePool, num_states: usize, _: usize) !void {
        const region_size = self.totalRegionSize();
        if (region_size == 0) {
            // No regions loaded — use a default size
            self.state_size = 4096;
        } else {
            self.state_size = region_size;
        }
        self.num_states = num_states;
        self.pool = try self.allocator.alloc(u8, num_states * self.state_size);
        try self.free_stack.ensureTotalCapacity(self.allocator, num_states);
        var i: usize = num_states;
        while (i > 0) {
            i -= 1;
            try self.free_stack.append(self.allocator, i);
        }
    }

    /// Save current game state (memory regions + FPU env)
    pub fn saveState(self: *StatePool, frame: u32, index: u32) ?usize {
        if (self.state_size == 0 or self.free_stack.items.len == 0) return null;
        const slot = self.free_stack.pop() orelse return null;
        const offset = slot * self.state_size;
        const dst = self.pool[offset .. offset + self.state_size];

        // Copy all memory regions into contiguous buffer
        var pos: usize = 0;
        for (self.regions.items) |r| {
            if (r.addr != 0 and pos + r.size <= self.state_size) {
                const src: [*]const u8 = @ptrFromInt(r.addr);
                @memcpy(dst[pos .. pos + r.size], src[0..r.size]);
            }
            pos += r.size;
        }

        // Save FPU environment (critical for deterministic re-simulation).
        // fnstenv/fldenv are x86-only; on non-x86 targets (e.g. Linux x86_64
        // host compilation) we skip — the DLL target is always x86 anyway.
        var fpu_env: [28]u8 = undefined;
        if (builtin.cpu.arch == .x86) {
            saveFpu(&fpu_env);
        } else {
            @memset(&fpu_env, 0);
        }

        // Store metadata
        self.saved_states.append(self.allocator, .{
            .frame = frame,
            .index = index,
            .fpu_env = fpu_env,
            .data = dst,
        }) catch return null;

        return slot;
    }

    /// Load a saved state (restore memory + FPU env)
    pub fn loadState(self: *StatePool, slot: usize) void {
        if (slot >= self.saved_states.items.len) return;
        const state = self.saved_states.items[slot];
        const src = state.data;

        // Restore FPU environment FIRST (before any float ops)
        if (builtin.cpu.arch == .x86) {
            restoreFpu(&state.fpu_env);
        }

        // Restore all memory regions
        var pos: usize = 0;
        for (self.regions.items) |r| {
            if (r.addr != 0 and pos + r.size <= src.len) {
                const dst: [*]u8 = @ptrFromInt(r.addr);
                @memcpy(dst[0..r.size], src[pos .. pos + r.size]);
            }
            pos += r.size;
        }

        // Free all states after this one (they're invalidated)
        while (self.saved_states.items.len > slot + 1) {
            const removed = self.saved_states.pop() orelse break;
            // Return slot to free stack
            const slot_idx = (@intFromPtr(removed.data.ptr) - @intFromPtr(self.pool.ptr)) / self.state_size;
            self.free_stack.append(self.allocator, slot_idx) catch {};
        }
    }

    /// Find and load the latest state with frame <= target_frame
    /// Returns the frame that was loaded, or null if no match
    pub fn loadStateForFrame(self: *StatePool, target_frame: u32, target_index: u32) ?u32 {
        var best_slot: ?usize = null;
        var best_frame: u32 = 0;

        for (self.saved_states.items, 0..) |state, i| {
            if (state.index == target_index and state.frame <= target_frame) {
                if (best_slot == null or state.frame > best_frame) {
                    best_slot = i;
                    best_frame = state.frame;
                }
            }
        }

        if (best_slot) |slot| {
            self.loadState(slot);
            return best_frame;
        }
        return null;
    }

    /// Load memory regions from res/rollback.bin
    pub fn loadFromRbBin(self: *StatePool, path: []const u8, io: std.Io, log: *logging.Logger) !void {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch {
            log.warn("rollback.bin not found at {s} — rollback disabled", .{path});
            return error.FileNotFound;
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const data = try self.allocator.alloc(u8, stat.size);
        defer self.allocator.free(data);
        _ = try file.readPositionalAll(io, data, 0);

        // rollback.bin format: sequence of (u32 address, u32 size) pairs
        var i: usize = 0;
        var count: usize = 0;
        while (i + 8 <= data.len) : (i += 8) {
            const addr = std.mem.readInt(u32, data[i..][0..4], .little);
            const size = std.mem.readInt(u32, data[i + 4 ..][0..4], .little);
            if (addr == 0 and size == 0) break;
            try self.addRegion(addr, size);
            count += 1;
        }
        log.info("Loaded {d} memory regions from rollback.bin ({d} bytes total)", .{
            count, self.totalRegionSize(),
        });
    }
};

// Free functions for x86-only FPU state save/restore. These are kept out of
// the StatePool struct so that the asm constraints don't trip Zig 0.15's
// "cannot output to const local" check on the struct method receiver.
//
// We use the AT&T syntax `fnstenv -28(%esp)` style: write the FPU env to a
// 28-byte region on the stack via a manual sub/store. Simpler approach: use
// `fnstenv [esp]` and then read it back — but Zig 0.15's asm parser wants
// `%[name]` syntax for named operands.
fn saveFpu(out: *[28]u8) void {
    // Allocate a local stack slot and have fnstenv write to it via the
    // pointer operand (input "=m" makes it an output).
    var buf: [28]u8 = undefined;
    asm volatile ("fnstenv %[fpu_env]"
        : [fpu_env] "=m" (buf),
    );
    out.* = buf;
}

fn restoreFpu(env: *const [28]u8) void {
    const buf: [28]u8 = env.*;
    asm volatile ("fldenv %[fpu_env]"
        :
        : [fpu_env] "m" (buf),
    );
}
