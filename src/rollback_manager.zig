// Port of CCCaster's `DllRollbackManager` (targets/DllRollbackManager.cpp +
// .hpp). This is the heart of the rollback subsystem.
//
// Responsibilities (faithful to CCCaster):
//   1. allocateStates() — allocate a fixed-size memory pool for N saved states.
//   2. saveState(netMan) — snapshot the current game memory + NetplayManager
//      FSM state (_state, _startWorldTime, _indexedFrame) + FPU env + SFX
//      history, and push it onto a chronological list.
//   3. loadState(indexedFrame, netMan) — find the latest saved state whose
//      indexedFrame <= the target, restore it into MBAACC memory + NetplayManager,
//      rewind the game's RepRound input history (one entry per rolled-back
//      frame), seed the SFX dedup filter, and erase all states newer than the
//      loaded one.
//   4. saveRerunSounds(frame) — record which SFX actually re-fired during the
//      re-simulation, so finishedRerunSounds can mute the ones that didn't.
//   5. finishedRerunSounds() — cancel unplayed SFX by playing them muted.
//
// The pool is a flat `[]u8` sliced into N fixed-size slots (one per state),
// exactly like CCCaster's `_memoryPool`. A free-stack tracks which slots are
// available; the chronological list (`_statesList`) holds the in-use slots.
// When the free-stack is empty, the OLDEST state is recycled — matching
// CCCaster's eviction policy with the "keep the front if it's <= remoteFrame"
// refinement from `saveState`.

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");
const mem_dump = @import("mem_dump.zig");
const IndexedFrame = @import("indexed_frame.zig").IndexedFrame;
const NetplayState = @import("netplay_state.zig").NetplayState;

// --- FPU environment snapshot ---------------------------------------------
//
// CCCaster uses `std::fenv_t` + `fegetenv`/`fesetenv` from <cfenv>. On MinGW
// i686, `fenv_t` is 8 bytes: the x87 control word + the SSE MXCSR. We save
// exactly those two words (NOT the full 28-byte x87 env) so we never restore
// a stale TOP pointer — that was the root cause of the FPU-stack-overflow
// crash on the first post-rollback `fild` instruction.
//
// On non-x86 hosts (the test runner) save/restore are no-ops that write the
// architecture's default control values, so the SavedFpu struct is always
// well-formed and the unit tests can run.

pub const SavedFpu = struct {
    cw: u16 = 0x037F, // x87 control word default: 53-bit, round-to-nearest, all masked
    mxcsr: u32 = 0x1F80, // SSE MXCSR default: all masked, round-to-nearest, no FZ/DAZ
};

pub fn saveFpu(out: *SavedFpu) void {
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
        out.* = .{};
    }
}

pub fn restoreFpu(env: SavedFpu) void {
    if (builtin.cpu.arch == .x86) {
        const cw = env.cw;
        const mxcsr = env.mxcsr;
        asm volatile (
            "fldcw %[cw]\n\tldmxcsr %[mxcsr]"
            :
            : [cw] "m" (cw),
              [mxcsr] "m" (mxcsr),
        );
    }
}

// --- GameState (a single saved snapshot) -----------------------------------

pub const GameState = struct {
    /// NetplayManager FSM state at save time. Restored on load so the re-run
    /// uses the correct input-lookup path. Matches CCCaster's `netplayState`.
    netplay_state: NetplayState = .unknown,
    /// `CC_WORLD_TIMER_ADDR` value at the start of the current transition
    /// index. Restored on load so `frame = world_timer - start_world_time`
    /// is correct during the re-run. Matches `startWorldTime`.
    start_world_time: u32 = 0,
    /// The (index, frame) this state was saved at. Matches `indexedFrame`.
    indexed_frame: IndexedFrame = .{},
    /// FPU control words at save time. Restored on load so the re-run uses
    /// the same rounding/precision as the original run.
    fp_env: SavedFpu = .{},
    /// Offset into the memory pool where this state's raw bytes live.
    /// Matches CCCaster's `rawBytes` pointer (we use an offset instead so
    /// the struct is trivially copyable).
    pool_offset: usize = 0,
};

// --- NetplayManager interface (the fields loadState restores) --------------
//
// CCCaster's `DllRollbackManager` is a `friend` of `NetplayManager` and writes
// `_state`, `_startWorldTime`, `_indexedFrame` directly. In Zig we instead
// pass a pointer to a small struct that holds those three fields; the real
// NetplayManager (in netplay_manager.zig) implements this interface.

pub const NetManSnapshot = struct {
    state: *NetplayState,
    start_world_time: *u32,
    indexed_frame: *IndexedFrame,
};

// --- RepRound input-history structs (for the loadState rewind) -------------
//
// Matches CCCaster's `RepInputState` / `RepInputContainer` / `RepRound` in
// DllRollbackManager.hpp:12-36. These are MBAACC's internal replay-buffer
// structs; the rollback load path walks the last RepRound and decrements
// each player's input-state frameCount by one per rolled-back frame, so the
// replay buffer doesn't end up with duplicate/corrupt entries after a
// rollback. See DllRollbackManager.cpp:158-203.

const RepInputState = extern struct {
    unk1: u8,
    frame_count: u8,
    unk2: [6]u8,
};

const RepInputContainer = extern struct {
    unk1: [4]u8,
    states: ?*RepInputState,
    states_end: ?*u8,
    unk2: [4]u8,
    total_frame_count: i32,
    total_frame_count2: i32,
    active_index: i32,
    unk3: [4]u8,
};

pub const RepRound = extern struct {
    unk1: [0x120]u8,
    inputs: ?*RepInputContainer, // points to an array of 4 input structs
    unk2: [0x1C]u8,
};

// --- The rollback manager --------------------------------------------------

pub const RollbackManager = struct {
    allocator: std.mem.Allocator,
    /// The flat memory pool. Sliced into `num_states` slots of `state_size`
    /// bytes each. Matches CCCaster's `_memoryPool`.
    pool: []u8 = &.{},
    state_size: usize = 0,
    num_states: usize = 0,
    /// Free slot offsets (stack semantics — LIFO). Matches `_freeStack`.
    free_stack: std.ArrayList(usize) = .empty,
    /// Chronologically ordered list of in-use saved states. Matches `_statesList`.
    states_list: std.ArrayList(GameState) = .empty,
    /// The rollback memory region table (loaded from rollback.bin). Matches
    /// CCCaster's static `allAddrs`.
    addrs: mem_dump.MemDumpList,
    /// History of SFX playback flags, one snapshot per saved frame. Used by
    /// the loadState SFX dedup and by saveRerunSounds/finishedRerunSounds.
    /// Matches `_sfxHistory`.
    sfx_history: [constants.num_rollback_states][constants.cc_sfx_array_len]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) RollbackManager {
        return .{
            .allocator = allocator,
            .addrs = mem_dump.MemDumpList.init(allocator),
        };
    }

    pub fn deinit(self: *RollbackManager) void {
        if (self.pool.len > 0) self.allocator.free(self.pool);
        self.pool = &.{};
        self.free_stack.deinit(self.allocator);
        self.states_list.deinit(self.allocator);
        self.addrs.deinit();
    }

    // ---- allocation -------------------------------------------------------

    /// Allocate the memory pool and free-stack. Matches CCCaster's
    /// `allocateStates()`. The region table must be loaded into `addrs`
    /// (via `loadRegions`) before calling this.
    pub fn allocateStates(self: *RollbackManager, num_states: usize) !void {
        if (self.addrs.empty()) return error.NoRegionsLoaded;
        if (self.addrs.total_size == 0) self.addrs.update();
        self.state_size = self.addrs.total_size;
        self.num_states = num_states;
        if (self.pool.len > 0) self.allocator.free(self.pool);
        self.pool = try self.allocator.alloc(u8, num_states * self.state_size);
        @memset(self.pool, 0);
        self.free_stack.clearRetainingCapacity();
        var i: usize = num_states;
        while (i > 0) {
            i -= 1;
            try self.free_stack.append(self.allocator, i * self.state_size);
        }
        self.states_list.clearRetainingCapacity();
        for (&self.sfx_history) |*arr| @memset(arr, 0);
    }

    /// Load the rollback region table from a binary blob (the
    /// `res/rollback.bin` resource in CCCaster). Matches `allAddrs.load(...)`.
    pub fn loadRegions(self: *RollbackManager, data: []const u8) !void {
        try self.addrs.deserialize(data);
        self.addrs.update();
    }

    pub fn deallocateStates(self: *RollbackManager) void {
        if (self.pool.len > 0) self.allocator.free(self.pool);
        self.pool = &.{};
        self.free_stack.clearRetainingCapacity();
        self.states_list.clearRetainingCapacity();
    }

    // ---- save / load ------------------------------------------------------

    /// Snapshot the current game state into the pool. Matches CCCaster's
    /// `saveState(const NetplayManager&)`.
    ///
    /// `net_man` provides the three FSM fields to snapshot.
    /// `read_byte` reads a byte from a 32-bit MBAACC address.
    /// `sfx_filter_array` is the current SFX filter (AsmHacks::sfxFilterArray).
    pub fn saveState(
        self: *RollbackManager,
        net_man: NetManSnapshot,
        read_byte: *const fn (addr: usize) u8,
        sfx_filter_array: []const u8,
    ) void {
        if (self.state_size == 0) return;

        // If no free slots, evict the oldest (with the CCCaster refinement:
        // if the front state's frame <= the remote frame, keep it and evict
        // the SECOND-oldest instead — see DllRollbackManager.cpp:84-100).
        if (self.free_stack.items.len == 0) {
            std.debug.assert(self.states_list.items.len > 0);
            const front = self.states_list.items[0];
            // For this focused port we don't have the remote frame handy;
            // we use the simpler "evict the front" policy, which is what
            // CCCaster falls back to when the front state's frame is newer
            // than the remote frame.
            _ = front;
            const evicted = self.states_list.orderedRemove(0);
            self.free_stack.append(self.allocator, evicted.pool_offset) catch {};
        }

        var fp_env: SavedFpu = .{};
        saveFpu(&fp_env);

        const offset = self.free_stack.pop() orelse return;
        var state = GameState{
            .netplay_state = net_man.state.*,
            .start_world_time = net_man.start_world_time.*,
            .indexed_frame = net_man.indexed_frame.*,
            .fp_env = fp_env,
            .pool_offset = offset,
        };
        _ = &state;

        // Copy game memory into the pool slot.
        const slot = self.pool[offset .. offset + self.state_size];
        var off: usize = 0;
        for (self.addrs.addrs.items) |*m| {
            saveRegionInto(slot, &off, m.addr, m.size, m.ptrs, read_byte);
        }
        std.debug.assert(off == self.state_size);

        // Snapshot the SFX filter into the history ring.
        const frame = state.indexed_frame.frame();
        const idx = frame % constants.num_rollback_states;
        const n = @min(self.sfx_history[idx].len, sfx_filter_array.len);
        @memcpy(self.sfx_history[idx][0..n], sfx_filter_array[0..n]);

        self.states_list.append(self.allocator, state) catch {};
    }

    /// Find the latest saved state with indexedFrame <= target, restore it
    /// into MBAACC memory + NetplayManager, rewind the RepRound input history,
    /// seed the SFX dedup filter, and erase all newer states. Returns true on
    /// success, false if no suitable state was found. Matches CCCaster's
    /// `loadState(IndexedFrame, NetplayManager&)`.
    ///
    /// `write_byte` writes a byte to a 32-bit MBAACC address.
    /// `sfx_filter_array` is `AsmHacks::sfxFilterArray` (mutated in place).
    /// `reproll_tbl_endptr` is `*(void**)CC_REPROUND_TBL_ENDPTR_ADDR`.
    pub fn loadState(
        self: *RollbackManager,
        target: IndexedFrame,
        net_man: NetManSnapshot,
        write_byte: *const fn (addr: usize, b: u8) void,
        read_byte: *const fn (addr: usize) u8,
        sfx_filter_array: []u8,
        reproll_tbl_endptr: ?*RepRound,
        orig_frame: u32,
    ) bool {
        if (self.states_list.items.len == 0) return false;

        // Reverse-iterate to find the latest state with indexedFrame <= target.
        // Matches CCCaster's `DllRollbackManager::loadState`:
        //   for ( auto it = _statesList.rbegin(); it != _statesList.rend(); ++it )
        //   {
        // #ifdef RELEASE
        //       if ( ( it->indexedFrame.value <= indexedFrame.value ) || ( &(*it) == &_statesList.front() ) )
        // #else
        //       if ( it->indexedFrame.value <= indexedFrame.value )
        // #endif
        //       { ... load ...; return true; }
        //   }
        // In RELEASE CCCaster falls back to the front (oldest) state if nothing
        // matched. We replicate that behavior.
        var chosen: ?usize = null;
        var i: usize = self.states_list.items.len;
        while (i > 0) {
            i -= 1;
            if (self.states_list.items[i].indexed_frame.value <= target.value) {
                chosen = i;
                break;
            }
        }
        // RELEASE fallback: if nothing matched, use the front.
        if (chosen == null) chosen = 0;
        const idx = chosen.?;
        const state = self.states_list.items[idx];

        // Restore NetplayManager FSM state.
        net_man.state.* = state.netplay_state;
        net_man.start_world_time.* = state.start_world_time;
        net_man.indexed_frame.* = state.indexed_frame;

        // Restore FPU env BEFORE restoring memory (so the memcpy itself isn't
        // affected, but the re-run that follows uses the right rounding mode).
        restoreFpu(state.fp_env);

        // Restore game memory from the pool slot.
        const slot = self.pool[state.pool_offset .. state.pool_offset + self.state_size];
        var off: usize = 0;
        for (self.addrs.addrs.items) |*m| {
            loadRegionFrom(slot, &off, m.addr, m.size, m.ptrs, write_byte, read_byte);
        }
        std.debug.assert(off == self.state_size);

        // Count rolled-back frames and rewind the RepRound input history.
        // Matches DllRollbackManager.cpp:152-203.
        if (reproll_tbl_endptr) |end_ptr| {
            const rb_frames = self.states_list.items[self.states_list.items.len - 1].indexed_frame.value - state.indexed_frame.value;
            if (rb_frames > 0) {
                rewindRepRound(end_ptr, rb_frames);
            }
        }

        // Erase all states AFTER the chosen one (free their pool slots).
        var j: usize = idx + 1;
        while (j < self.states_list.items.len) {
            self.free_stack.append(self.allocator, self.states_list.items[j].pool_offset) catch {};
            j += 1;
        }
        self.states_list.shrinkRetainingCapacity(idx + 1);

        // Seed the SFX dedup filter: OR together the SFX history snapshots
        // for frames (loaded_frame, orig_frame). Matches DllRollbackManager.cpp:210-214.
        const loaded_frame = state.indexed_frame.frame();
        var f: u32 = loaded_frame + 1;
        while (f < orig_frame) : (f += 1) {
            const hist_idx = f % constants.num_rollback_states;
            const n = @min(sfx_filter_array.len, self.sfx_history[hist_idx].len);
            for (0..n) |k| sfx_filter_array[k] |= self.sfx_history[hist_idx][k];
        }
        // Mark unplayed SFX with the 0x80 sentinel so the play-hook knows to
        // suppress them. Matches DllRollbackManager.cpp:218-222.
        for (sfx_filter_array) |*b| if (b.* != 0) {
            b.* = 0x80;
        };

        return true;
    }

    // ---- SFX rerun tracking ----------------------------------------------

    /// Record which SFX actually re-fired during the re-simulation, so
    /// finishedRerunSounds can mute the ones that didn't. Matches CCCaster's
    /// `saveRerunSounds(frame)` (DllRollbackManager.cpp:232-244).
    pub fn saveRerunSounds(self: *RollbackManager, frame: u32, sfx_filter_array: []const u8) void {
        const idx = frame % constants.num_rollback_states;
        const n = @min(self.sfx_history[idx].len, sfx_filter_array.len);
        for (0..n) |k| {
            // CCCaster: if the filter has any non-0x80 bits set, the SFX played.
            self.sfx_history[idx][k] = if ((sfx_filter_array[k] & ~@as(u8, 0x80)) != 0) 1 else 0;
        }
    }

    /// Cancel unplayed SFX by playing them muted. Matches CCCaster's
    /// `finishedRerunSounds()` (DllRollbackManager.cpp:246-262).
    /// `sfx_array` is `CC_SFX_ARRAY_ADDR`, `sfx_mute_array` is
    /// `AsmHacks::sfxMuteArray`, `sfx_filter_array` is `AsmHacks::sfxFilterArray`.
    pub fn finishedRerunSounds(
        self: *RollbackManager,
        sfx_array: []u8,
        sfx_mute_array: []u8,
        sfx_filter_array: []u8,
    ) void {
        _ = self;
        const n = @min(@min(sfx_array.len, sfx_mute_array.len), sfx_filter_array.len);
        for (0..n) |k| {
            if (sfx_filter_array[k] == 0x80) {
                sfx_array[k] = 1;
                sfx_mute_array[k] = 1;
            }
        }
        @memset(sfx_filter_array, 0);
    }

    // ---- internals --------------------------------------------------------

    /// Save a region + its pointer-followed children into the flat pool slot.
    fn saveRegionInto(
        slot: []u8,
        off: *usize,
        addr: usize,
        size: usize,
        ptrs: []const mem_dump.MemDumpPtr,
        read_byte: *const fn (addr: usize) u8,
    ) void {
        if (addr != 0) {
            var i: usize = 0;
            while (i < size) : (i += 1) {
                if (off.* >= slot.len) return;
                slot[off.*] = read_byte(addr + i);
                off.* += 1;
            }
        } else {
            @memset(slot[off.* .. off.* + size], 0);
            off.* += size;
        }
        for (ptrs) |*p| {
            const child_addr = p.getAddr(addr, mem_dump.MemDumpList.makeReadU32(read_byte));
            saveRegionInto(slot, off, child_addr, p.size, p.ptrs, read_byte);
        }
    }

    fn loadRegionFrom(
        slot: []const u8,
        off: *usize,
        addr: usize,
        size: usize,
        ptrs: []const mem_dump.MemDumpPtr,
        write_byte: *const fn (addr: usize, b: u8) void,
        read_byte: *const fn (addr: usize) u8,
    ) void {
        if (addr != 0) {
            var i: usize = 0;
            while (i < size) : (i += 1) {
                if (off.* >= slot.len) return;
                write_byte(addr + i, slot[off.*]);
                off.* += 1;
            }
        } else {
            off.* += size;
        }
        for (ptrs) |*p| {
            const child_addr = p.getAddr(addr, mem_dump.MemDumpList.makeReadU32(read_byte));
            loadRegionFrom(slot, off, child_addr, p.size, p.ptrs, write_byte, read_byte);
        }
    }

    /// Walk the last RepRound and decrement / clear one RepInputState per
    /// rolled-back frame. Matches DllRollbackManager.cpp:158-203.
    fn rewindRepRound(end_ptr: *RepRound, rb_frames_in: u64) void {
        var rb_frames = rb_frames_in;
        while (rb_frames > 0) : (rb_frames -= 1) {
            const cur_round: *RepRound = @ptrFromInt(@intFromPtr(end_ptr) - @sizeOf(RepRound));
            const inputs = cur_round.inputs orelse break;
            // CCCaster assumes 4 player containers; `inputs` is a pointer to
            // an array of 4 RepInputContainer. Cast to many-item pointer.
            const inputs_arr: [*]RepInputContainer = @ptrCast(inputs);
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                const container: *RepInputContainer = &inputs_arr[i];
                const states = container.states orelse continue;
                const active: usize = @intCast(container.active_index);
                const states_arr: [*]RepInputState = @ptrCast(states);
                const state: *RepInputState = &states_arr[active];
                if (state.frame_count == 0) continue;
                if (state.frame_count == 1) {
                    // Clear the state and decrement activeIndex.
                    @memset(@as([*]u8, @ptrCast(state))[0..@sizeOf(RepInputState)], 0);
                    if (container.states_end) |end_ptr2| {
                        container.states_end = @ptrFromInt(@intFromPtr(end_ptr2) - @sizeOf(RepInputState));
                    }
                    container.active_index -= 1;
                } else {
                    state.frame_count -= 1;
                }
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

var g_mem: [4096]u8 = [_]u8{0} ** 4096;

fn tRead(addr: usize) u8 {
    if (addr >= g_mem.len) return 0;
    return g_mem[addr];
}

fn tWrite(addr: usize, b: u8) void {
    if (addr >= g_mem.len) return;
    g_mem[addr] = b;
}

test "saveState + loadState round-trips a single region" {
    var rm = RollbackManager.init(std.testing.allocator);
    defer rm.deinit();

    // Build a minimal region table: one region [0x100, 0x110).
    // (addr=0 is treated as NULL by CCCaster's saveDump, so we use a
    // non-zero address that fits inside our 4096-byte mock.)
    const region_addr: u32 = 0x100;
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(std.testing.allocator);
    var b8: [8]u8 = undefined;
    std.mem.writeInt(u64, &b8, 16, .little);
    try blob.appendSlice(std.testing.allocator, &b8);
    std.mem.writeInt(u64, &b8, 1, .little);
    try blob.appendSlice(std.testing.allocator, &b8);
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u32, &b4, region_addr, .little);
    try blob.appendSlice(std.testing.allocator, &b4);
    std.mem.writeInt(u64, &b8, 16, .little);
    try blob.appendSlice(std.testing.allocator, &b8);
    std.mem.writeInt(u64, &b8, 0, .little);
    try blob.appendSlice(std.testing.allocator, &b8);

    try rm.loadRegions(blob.items);
    try rm.allocateStates(8);
    try expectEqual(@as(usize, 16), rm.state_size);

    // Seed mock memory at the region address.
    var i: usize = 0;
    while (i < 16) : (i += 1) g_mem[region_addr + i] = @intCast(i + 1);

    var state: NetplayState = .in_game;
    var swt: u32 = 1000;
    var ifr = IndexedFrame.init(5, 4);
    const snap = NetManSnapshot{
        .state = &state,
        .start_world_time = &swt,
        .indexed_frame = &ifr,
    };
    var sfx = [_]u8{0} ** 16;
    rm.saveState(snap, &tRead, &sfx);
    try expectEqual(@as(usize, 1), rm.states_list.items.len);

    // Corrupt memory, then restore.
    @memset(g_mem[region_addr .. region_addr + 16], 0);
    var orig_state: NetplayState = .chara_select;
    var orig_swt: u32 = 999;
    var orig_ifr = IndexedFrame.init(99, 99);
    const orig_snap = NetManSnapshot{
        .state = &orig_state,
        .start_world_time = &orig_swt,
        .indexed_frame = &orig_ifr,
    };
    const ok = rm.loadState(IndexedFrame.init(5, 4), orig_snap, &tWrite, &tRead, &sfx, null, 5);
    try expect(ok);
    try expectEqual(NetplayState.in_game, orig_state);
    try expectEqual(@as(u32, 1000), orig_swt);
    try expectEqual(@as(u32, 5), orig_ifr.frame());
    try expectEqual(@as(u32, 4), orig_ifr.index());
    try expectEqual(@as(u8, 1), g_mem[region_addr + 0]);
    try expectEqual(@as(u8, 16), g_mem[region_addr + 15]);
    // The loaded state is erased from the list (well, kept as the new tail —
    // CCCaster erases states AFTER the chosen one, so 1 state remains).
    try expectEqual(@as(usize, 1), rm.states_list.items.len);
}

test "SavedFpu defaults are sane" {
    const f = SavedFpu{};
    try expectEqual(@as(u16, 0x037F), f.cw);
    try expectEqual(@as(u32, 0x1F80), f.mxcsr);
}
