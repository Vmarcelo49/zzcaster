const std = @import("std");
const logging = @import("common").logging;
const builtin = @import("builtin");

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
                const used_input = self.get(index, frame);
                if (used_input != input) {
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

    pub fn reset(self: *InputBuffer) void {
        self.inputs.clearRetainingCapacity();
        self.end_frames.clearRetainingCapacity();
        self.last_inputs.clearRetainingCapacity();
        self.last_changed_frame = null;
        self.end_index = 0;
    }

    /// Grow the outer dimension so that `index` is considered "reached" by
    /// the remote peer, without populating any actual inputs for that index.
    /// Mirrors CCCaster's `InputsContainer::resize(index, 0, 0)` called from
    /// `NetplayManager::setRemoteIndex` (DllNetplayManager.cpp:1130-1138):
    ///   _inputs[_remotePlayer - 1].resize ( remoteIndex - _startIndex, 0, 0 );
    ///
    /// This is what makes the local peer's `isRemoteInputReady()` see that the
    /// remote peer has advanced to `index` even before any `PlayerInputs` for
    /// that index has arrived. Without this, a lost `PlayerInputs` at the new
    /// index (UDP-unreliable) combined with a lost/delayed `TransitionIndex`
    /// (also unreliable in CCCaster) would leave the local container's
    /// `end_index` stuck at the old value, and the local peer would wait
    /// indefinitely for the remote to "catch up" even though the remote has
    /// already moved on.
    ///
    /// In zzcaster's hashmap-based container there is no explicit "outer
    /// vector"; the equivalent is to bump `end_index` and ensure `end_frames`
    /// has an entry for `index` (defaulting to 0 = "no frames yet"). The
    /// `last_inputs` map is NOT updated — there are no inputs at this index
    /// yet, so `get(index, frame)` will fall through to the previous index's
    /// last input via `lastInputBefore` logic in `get()`.
    pub fn resizeOuter(self: *InputBuffer, index: u32) void {
        // Bump end_index so getEndIndex() reports the remote has reached `index`.
        if (index >= self.end_index) self.end_index = index + 1;
        // Ensure end_frames has an entry for `index` (0 = no frames populated).
        // Without this, getEndFrame(index) returns 0 via `.orelse 0`, which is
        // correct, but having the entry present makes the "remote has reached
        // this index but sent no frames yet" state explicit and inspectable.
        if (!self.end_frames.contains(index)) {
            self.end_frames.put(index, 0) catch {};
        }
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

// FPU state snapshot — only what affects determinism.
//
// We save and restore the x87 control word (rounding mode, exception masks,
// precision control) and the SSE MXCSR (control + status, since MBAACC is
// built with -msse2). We deliberately do NOT touch:
//   - the x87 data registers st(0)..st(7)
//   - the x87 tag word
//   - the x87 TOP pointer (stack top, bits 12-14 of the status word)
//
// Why: the previous implementation used `fnstenv`/`fldenv`, which save and
// restore the FULL 28-byte x87 environment including TOP and the tag word.
// On rollback restore, `fldenv` would write back a STALE TOP pointer captured
// at save time. When the game's MBAACC code then executed `fild` instructions
// (e.g. at 0x410721 in the per-frame character update), the FPU thought the
// stack was non-empty and raised a #SF (stack fault) exception — crashing
// both peers with "floating point stack check" as soon as the first rollback
// fired after entering `in_game`.
//
// CCCaster's legacy C++ avoids this by using `fegetenv`/`fesetenv` from
// <cfenv>. On MinGW-w64 i686, `fenv_t` is only 8 bytes (control word +
// status word) and MinGW's `fesetenv` internally masks the TOP bits during
// restore, leaving the FPU stack pointer untouched. Our `fnstcw`/`fldcw` +
// `stmxcsr`/`ldmxcsr` approach is functionally equivalent and strictly safer
// (no chance of restoring a stale TOP).
pub const SavedFpu = struct {
    cw: u16, // x87 control word
    mxcsr: u32, // SSE control/status word
};

// Saved game state
pub const SavedState = struct {
    frame: u32,
    index: u32,
    fpu_env: SavedFpu, // x87 cw + SSE MXCSR only (see SavedFpu doc)
    data: []u8, // contiguous buffer for all memory regions
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
        // `pool` is the single owner of all snapshot memory. `saved_states[i].data`
        // is a slice INTO `pool`, not a separate allocation, so we must NOT call
        // allocator.free on each `s.data` — that would be a double-free.
        // Just free the pool once, then the bookkeeping arrays.
        self.saved_states.deinit(self.allocator);
        self.free_stack.deinit(self.allocator);
        self.regions.deinit(self.allocator);
        if (self.pool.len > 0) self.allocator.free(self.pool);
        self.pool = &.{};
        self.state_size = 0;
        self.num_states = 0;
    }

    /// Add a memory region to save/restore (regions are sourced from
    /// `rollback_regions.zig` at comptime; see `NetplayManager.onEnterInGame`).
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
    ///
    /// If no free slots are available, the OLDEST saved state is overwritten
    /// (ring-buffer semantics). This prevents rollback from silently dying
    /// after `num_states` saves (e.g. 60 frames at 60 FPS = 1 second of play).
    pub fn saveState(self: *StatePool, frame: u32, index: u32) ?usize {
        if (self.state_size == 0) return null;

        var slot: usize = undefined;
        if (self.free_stack.items.len > 0) {
            slot = self.free_stack.pop() orelse return null;
        } else if (self.saved_states.items.len > 0) {
            // Recycle the oldest entry. We don't return its slot to the
            // free_stack on the way out — we hand it straight to the new
            // snapshot. `orderedRemove(0)` shrinks `saved_states` by one.
            const oldest = self.saved_states.orderedRemove(0);
            slot = (@intFromPtr(oldest.data.ptr) - @intFromPtr(self.pool.ptr)) / self.state_size;
        } else {
            return null;
        }

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

        // Save FPU control state (cw + MXCSR only — see SavedFpu doc).
        // saveFpu() handles the arch guard internally: on non-x86 hosts
        // (e.g. x86_64 unit-test runners) it writes benign defaults and
        // restoreFpu() becomes a no-op.
        var fpu_env: SavedFpu = undefined;
        saveFpu(&fpu_env);

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

        // Restore FPU control state FIRST (before any float ops).
        // restoreFpu() handles the arch guard internally.
        restoreFpu(&state.fpu_env);

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

    pub fn reset(self: *StatePool) void {
        self.saved_states.clearRetainingCapacity();
        self.free_stack.clearRetainingCapacity();
        var i: usize = self.num_states;
        while (i > 0) {
            i -= 1;
            self.free_stack.append(self.allocator, i) catch {};
        }
    }

    // The previous `pub fn loadFromRbBin(self, path, io, log) !void` was
    // REMOVED — it was a legacy code path. The active path lives in
    // `src/dll/rollback_regions.zig` (`all_regions`) and is consumed directly
    // by `NetplayManager.onEnterInGame()`. `loadFromRbBin` had no callers
    // (verified by grep) and no tests; keeping it created a second, untested
    // path for the same concern. If you need region-loading functionality
    // again, extend `rollback_regions.zig` (comptime-hardcoded regions)
    // rather than reviving this binary-file code path.
};

// Save the FPU control state (x87 control word + SSE MXCSR).
//
// We intentionally use `fnstcw` (NOT `fnstenv`) and `stmxcsr` so that we
// capture ONLY the control words that affect determinism. The x87 status
// word (incl. TOP pointer), tag word, and data registers are NOT saved —
// they describe transient execution state that should not be restored.
//
// On non-x86 hosts (e.g. x86_64 unit-test runners) we fall back to writing
// the architecture's default control values so the SavedFpu struct is still
// well-formed; restoreFpu() will be a no-op in that case.
fn saveFpu(out: *SavedFpu) void {
    if (builtin.cpu.arch == .x86) {
        var cw: u16 = 0;
        var mxcsr: u32 = 0;
        asm volatile (
            "fnstcw %[cw]\n\tstmxcsr %[mxcsr]"
            : [cw] "=m" (cw),
              [mxcsr] "=m" (mxcsr),
        );
        out.cw = cw;
        out.mxcsr = mxcsr;
    } else {
        // Defaults match what _fpreset / ldmxcsr would set on x86.
        out.cw = 0x037F; // x87: 53-bit precision, round-to-nearest, all exceptions masked
        out.mxcsr = 0x1F80; // SSE: all exceptions masked, round-to-nearest, no FZ/DAZ
    }
}

// Restore the FPU control state (x87 control word + SSE MXCSR).
//
// Uses `fldcw` (NOT `fldenv`) and `ldmxcsr` so that ONLY the control words
// are written. The x87 status word, tag word, TOP pointer, and data
// registers are left untouched — eliminating the stale-TOP / FPU-stack-
// overflow bug that the previous `fldenv`-based implementation triggered
// on the first rollback after entering `in_game`.
fn restoreFpu(env: *const SavedFpu) void {
    if (builtin.cpu.arch != .x86) return;
    const cw: u16 = env.cw;
    const mxcsr: u32 = env.mxcsr;
    asm volatile (
        "fldcw %[cw]\n\tldmxcsr %[mxcsr]"
        :
        : [cw] "m" (cw),
          [mxcsr] "m" (mxcsr),
    );
}
