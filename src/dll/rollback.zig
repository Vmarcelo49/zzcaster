// Adapter layer: wraps the CCCaster-faithful rollback port (in the `cc/`
// subdirectory) and exposes the API that zzcaster's netplay_manager.zig and
// frame_step.zig already expect.
//
// This file replaces the old hashmap-based InputBuffer and array-based
// StatePool with the new port's vector-of-vectors InputsContainer and
// MemDumpList-backed RollbackManager — without requiring any changes to
// netplay_manager.zig or frame_step.zig.
//
// The key behavioral differences from the old code:
//   1. InputsContainer uses std.ArrayList(std.ArrayList(u16)) (matching
//      CCCaster's std::vector<std::vector<T>>) instead of a flat hashmap.
//      This eliminates the hashmap's last_changed_frame ordering bugs.
//   2. RollbackManager uses MemDumpList with support for pointer-following
//      child regions (the effects array chain) — matching CCCaster's
//      MemDumpPtr mechanism. (The adapter currently feeds flat regions from
//      rollback_regions.zig; pointer-following can be added later.)
//   3. The loadState logic matches CCCaster's DllRollbackManager::loadState
//      exactly — reverse-iterate the states list, load the latest state
//      with indexedFrame <= target, erase newer states.

const std = @import("std");
const builtin = @import("builtin");
const rb_regions = @import("rollback_regions.zig");

// The CCCaster-faithful port modules.
const cc = struct {
    const inputs_container = @import("cc/inputs_container.zig");
    const mem_dump = @import("cc/mem_dump.zig");
    const rollback_manager = @import("cc/rollback_manager.zig");
    const indexed_frame = @import("cc/indexed_frame.zig");
    const IndexedFrame = indexed_frame.IndexedFrame;
    const InputsContainer = inputs_container.InputsContainer;
    const MemDumpList = mem_dump.MemDumpList;
    const MemDump = mem_dump.MemDump;
    const RollbackManager = rollback_manager.RollbackManager;
    const NetManSnapshot = rollback_manager.NetManSnapshot;
    const SavedFpu = rollback_manager.SavedFpu;
    const GameState = rollback_manager.GameState;
};

// ===========================================================================
// InputBuffer — adapter around cc.InputsContainer(u16)
// ===========================================================================
//
// Exposes the same API as the old hashmap-based InputBuffer so
// netplay_manager.zig doesn't need changes. The key difference:
//   - `last_changed_frame` is `?u64` (null = no change) in the old API.
//   - cc.InputsContainer uses `IndexedFrame` (u64 value, max = no change).
//   The adapter converts between the two representations.

pub const InputBuffer = struct {
    inner: cc.InputsContainer(u16),
    /// Cached last_changed_frame as ?u64 (null = no change). Kept in sync
    /// with the inner InputsContainer's IndexedFrame by setRemote and
    /// clearLastChanged. Exposed as a field so callers can read it directly
    /// (matching the old hashmap-based InputBuffer API).
    last_changed_frame: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) InputBuffer {
        return .{ .inner = cc.InputsContainer(u16).init(allocator) };
    }

    pub fn deinit(self: *InputBuffer) void {
        self.inner.deinit();
    }

    pub fn get(self: *const InputBuffer, index: u32, frame: u32) u16 {
        return self.inner.get(index, frame);
    }

    pub fn set(self: *InputBuffer, index: u32, frame: u32, input: u16) void {
        self.inner.set(index, frame, input);
    }

    /// Remote-input batch set. When `check_changes` is true, scans for the
    /// first changed frame and records it in last_changed_frame (matching
    /// CCCaster's `checkStartingFromIndex = isInRollback ? 0 : UINT_MAX`).
    pub fn setRemote(self: *InputBuffer, index: u32, start_frame: u32, inputs: []const u16, check_changes: bool) void {
        const check_from: u32 = if (check_changes) 0 else std.math.maxInt(u32);
        self.inner.setBatch(index, start_frame, inputs, check_from);
        // Sync the cached field from the inner container.
        const lcf = self.inner.getLastChangedFrame();
        self.last_changed_frame = if (lcf.value == cc.IndexedFrame.max_value.value) null else lcf.value;
    }

    pub fn clearLastChanged(self: *InputBuffer) void {
        self.inner.clearLastChangedFrame();
        self.last_changed_frame = null;
    }

    pub fn reset(self: *InputBuffer) void {
        self.inner.clear();
        self.last_changed_frame = null;
    }

    /// Grow the outer dimension so `index` is considered "reached" by the
    /// remote peer, without populating any actual inputs. Matches CCCaster's
    /// `InputsContainer::resize(index, 0, 0)` called from `setRemoteIndex`.
    pub fn resizeOuter(self: *InputBuffer, index: u32) void {
        const empty: []const u16 = &.{};
        self.inner.setBatch(index, 0, empty, std.math.maxInt(u32));
    }

    pub fn getEndFrame(self: *const InputBuffer, index: u32) u32 {
        return self.inner.getEndFrameAt(index);
    }

    pub fn getEndIndex(self: *const InputBuffer) u32 {
        return self.inner.getEndIndex();
    }
};

// ===========================================================================
// SavedFpu / SavedState — re-exported from the port
// ===========================================================================

pub const SavedFpu = cc.SavedFpu;

pub const SavedState = struct {
    frame: u32,
    index: u32,
    fpu_env: SavedFpu,
    data: []u8,
    netplay_state: u8 = 0,
    start_world_time: u32 = 0,
};

pub const MemoryRegion = struct {
    addr: usize,
    size: usize,
};

// ===========================================================================
// StatePool — adapter around cc.RollbackManager
// ===========================================================================
//
// Exposes the same API as the old StatePool so netplay_manager.zig and
// frame_step.zig don't need changes. The key difference: the new port uses
// callback-based memory access (read_byte/write_byte) so the core logic is
// testable on a mock. On Windows (the DLL build), the callbacks dereference
// MBAACC addresses directly via @ptrFromInt.

pub const StatePool = struct {
    allocator: std.mem.Allocator,
    inner: cc.RollbackManager,
    /// Flat region list (from rollback_regions.zig). Kept for diagnostics
    /// and for `totalRegionSize` to report the right number before allocate.
    regions: std.ArrayList(MemoryRegion),

    // Compat fields for zzcaster's netplay_manager.zig access patterns:
    //   `self.state_pool.pool.len == 0` → check if allocated
    //   `self.state_pool.num_states`     → pool slot count
    // These are kept in sync by allocate()/reset().
    pool: []u8 = &.{},
    num_states: usize = 0,

    // Compat for the test suite: state_size and has_effects. The new port
    // uses MemDumpList for regions; state_size is the port's inner.state_size.
    // has_effects is always false in the adapter (pointer-following is
    // configured via the region table, not auto-detected).
    has_effects: bool = false,
    pub fn stateSize(self: *const StatePool) usize {
        return self.inner.state_size;
    }

    // Compat for test_simulation.zig which checks saved_states.items.len and
    // free_stack.items.len. We expose them as read-only computed fields via
    // accessor functions. The tests use `pool.saved_states_count()`.
    pub fn saved_states_count(self: *const StatePool) usize {
        return self.inner.states_list.items.len;
    }
    pub fn free_stack_count(self: *const StatePool) usize {
        return self.inner.free_stack.items.len;
    }

    /// Read-only view of a saved state, matching the old SavedState struct's
    /// public fields. Used by the test suite to verify saveState stored the
    /// correct frame/netplay_state/start_world_time.
    pub const SavedStateView = struct {
        frame: u32,
        index: u32,
        netplay_state: u8,
        start_world_time: u32,
    };

    pub fn getSavedState(self: *const StatePool, i: usize) SavedStateView {
        const s = self.inner.states_list.items[i];
        return .{
            .frame = s.indexed_frame.frame(),
            .index = s.indexed_frame.index(),
            .netplay_state = s.netplay_state,
            .start_world_time = s.start_world_time,
        };
    }

    pub fn init(allocator: std.mem.Allocator) StatePool {
        return .{
            .allocator = allocator,
            .inner = cc.RollbackManager.init(allocator),
            .regions = .empty,
        };
    }

    pub fn deinit(self: *StatePool) void {
        self.inner.deinit();
        self.regions.deinit(self.allocator);
    }

    pub fn addRegion(self: *StatePool, addr: usize, size: usize) !void {
        try self.regions.append(self.allocator, .{ .addr = addr, .size = size });
    }

    pub fn totalRegionSize(self: *const StatePool) usize {
        var total: usize = 0;
        for (self.regions.items) |r| total += r.size;
        return total;
    }

    /// Allocate the memory pool. Feeds the flat regions into the port's
    /// MemDumpList, then calls allocateStates.
    pub fn allocate(self: *StatePool, num_states_in: usize, _: usize) !void {
        // Feed regions into the port's MemDumpList.
        for (self.regions.items) |r| {
            self.inner.addrs.append(.{ .addr = r.addr, .size = r.size });
        }
        self.inner.addrs.update();
        try self.inner.allocateStates(num_states_in);
        // Sync compat fields.
        self.pool = self.inner.pool;
        self.num_states = self.inner.num_states;
    }

    pub fn reset(self: *StatePool) void {
        // The old StatePool.reset() clears saved states and re-populates the
        // free_stack WITHOUT freeing the pool — it's used for rematches where
        // the same pool is re-used. The port's RollbackManager doesn't have a
        // direct equivalent, so we deallocate + re-allocate to achieve the
        // same effect.
        if (self.inner.num_states > 0) {
            const n = self.inner.num_states;
            self.inner.deallocateStates();
            // Re-allocate with the same regions (already in self.inner.addrs).
            self.inner.allocateStates(n) catch {};
            self.pool = self.inner.pool;
            self.num_states = self.inner.num_states;
        } else {
            self.pool = &.{};
            self.num_states = 0;
        }
    }

    /// Save the current game state. Matches the old StatePool.saveState API:
    /// takes (frame, index, netplay_state, start_world_time) as values.
    /// Internally builds a NetManSnapshot (pointers to stack temps) and calls
    /// the port's saveState with Windows dereference callbacks.
    pub fn saveState(self: *StatePool, frame: u32, index: u32, netplay_state: u8, start_world_time: u32) ?usize {
        if (self.inner.state_size == 0) return null;

        // Build stack-local storage for the NetManSnapshot to point at.
        var ns_state: u8 = netplay_state;
        var ns_swt: u32 = start_world_time;
        var ns_ifr = cc.IndexedFrame.init(frame, index);
        const snap = cc.NetManSnapshot{
            .state = &ns_state,
            .start_world_time = &ns_swt,
            .indexed_frame = &ns_ifr,
        };

        // Empty SFX filter — zzcaster's sfx_dedup.zig manages SFX history
        // separately (via snapshotToHistory). The port's sfx_history stays
        // all zeros, which is fine (it's not used by the adapter).
        const empty_sfx: []const u8 = &.{};
        self.inner.saveState(snap, &readByte, empty_sfx);

        // Return the index of the just-saved state (last in the list).
        if (self.inner.states_list.items.len > 0) {
            return self.inner.states_list.items.len - 1;
        }
        return null;
    }

    pub const LoadResult = struct {
        frame: u32,
        netplay_state: u8,
        start_world_time: u32,
    };

    /// Find and load the latest state with frame <= target_frame for the
    /// given index. Matches the old StatePool.loadStateForFrame API.
    /// Returns the restored frame + FSM state, or null if no match.
    pub fn loadStateForFrame(self: *StatePool, target_frame: u32, target_index: u32) ?LoadResult {
        if (self.inner.states_list.items.len == 0) return null;

        // Build stack-local storage for the NetManSnapshot to write INTO.
        // The port's loadState will restore the FSM fields into these.
        var ns_state: u8 = 0;
        var ns_swt: u32 = 0;
        var ns_ifr = cc.IndexedFrame.init(0, 0);
        const snap = cc.NetManSnapshot{
            .state = &ns_state,
            .start_world_time = &ns_swt,
            .indexed_frame = &ns_ifr,
        };

        // Call the port's loadState — it does the reverse-iterate internally
        // (matching CCCaster's DllRollbackManager::loadState). Pass null
        // reproll (zzcaster's checkRollback handles RepRound separately) and
        // empty sfx_filter (zzcaster's sfx_dedup handles SFX separately).
        const empty_sfx: []u8 = &.{};
        const ok = self.inner.loadState(
            cc.IndexedFrame.init(target_frame, target_index),
            snap,
            &writeByte,
            &readByte,
            empty_sfx,
            null,
            target_frame,
        );
        if (!ok) return null;

        return .{
            .frame = ns_ifr.frame(),
            .netplay_state = ns_state,
            .start_world_time = ns_swt,
        };
    }
};

// ===========================================================================
// Windows memory-access callbacks
// ===========================================================================
//
// These dereference 32-bit MBAACC virtual addresses directly. They are only
// safe to call when running inside MBAA.exe on Windows (the DLL build). On
// the host (for tests), the StatePool tests use real stack addresses which
// are valid host pointers, so these callbacks work there too.

fn readByte(addr: usize) u8 {
    const ptr: *u8 = @ptrFromInt(addr);
    return ptr.*;
}

fn writeByte(addr: usize, b: u8) void {
    const ptr: *u8 = @ptrFromInt(addr);
    ptr.* = b;
}
