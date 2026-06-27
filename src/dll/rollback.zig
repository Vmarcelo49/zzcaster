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
                    // Update last_changed_frame, but ONLY for the current or
                    // a LATER index. A stale input from a PREVIOUS index must
                    // NOT poison last_changed_frame — if it did, the stale key
                    // (which is smaller than any current-index key) would
                    // block all future current-index changes from being
                    // detected, because `key < last_changed_frame` would
                    // always be false for the current index.
                    //
                    // The original code used:
                    //   if (last_changed_frame == null or key < last_changed_frame.?)
                    // This is correct WITHIN a single index (finds the
                    // earliest changed frame), but ACROSS indices it breaks:
                    // a stale index-4 key (4<<32|8) is smaller than a valid
                    // index-5 key (5<<32|5), so the stale key wins and the
                    // valid change is silently dropped.
                    //
                    // Fixed logic:
                    //   - If no lcf is set, set it (always).
                    //   - If the new key's index is GREATER than lcf's index,
                    //     the old lcf is from a stale index — replace it.
                    //   - If the new key's index EQUALS lcf's index, take the
                    //     minimum frame (original behavior).
                    //   - If the new key's index is LESS than lcf's index,
                    //     the new key is stale — ignore it.
                    const new_index_part = index;
                    if (self.last_changed_frame == null) {
                        self.last_changed_frame = key;
                    } else {
                        const lcf = self.last_changed_frame.?;
                        const lcf_index = @as(u32, @intCast(lcf >> 32));
                        if (new_index_part > lcf_index) {
                            // Newer index — replace stale lcf.
                            self.last_changed_frame = key;
                        } else if (new_index_part == lcf_index and key < lcf) {
                            // Same index — take earliest frame.
                            self.last_changed_frame = key;
                        }
                        // else: new_index < lcf_index → stale, ignore.
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

    /// Remove all inputs for `index` with frame < min_frame.
    ///
    /// Called when the remote confirms it has received and processed our inputs
    /// up to `min_frame`. Inputs older than that can never be needed again:
    ///   - Rollback only re-simulates frames that are in the rollback window
    ///     (at most `max_rollback` = 15 frames back), and `min_frame` is set
    ///     with a 16-frame safety margin beyond the remote's last-confirmed frame.
    ///   - The remote's `get` fallback (`last_inputs[index]`) handles frames
    ///     beyond what's stored, so removing old entries doesn't break prediction.
    ///
    /// This bounds the InputBuffer's memory usage: instead of growing by 1
    /// entry per frame for the entire round (~5940 entries for a 99-second
    /// round = ~285KB), the buffer stays at ~30 entries (the resend window +
    /// safety margin) = ~1.4KB.
    ///
    /// Ported from ggpo-x's InputQueue::DiscardConfirmedFrames (which GGPO
    /// calls when SetLastConfirmedFrame advances the confirmed boundary).
    /// zzcaster's protocol doesn't have an explicit input-ack, so we
    /// approximate: the remote's input packet's `start_frame` tells us
    /// they've processed our inputs up to `start_frame - 1`.
    pub fn discardConfirmedFrames(self: *InputBuffer, index: u32, min_frame: u32) void {
        // Two-pass: collect keys to remove, then remove them. We can't remove
        // while iterating (invalidates the iterator), so we buffer the keys.
        // Use a stack-allocated array for the common case (≤64 old entries);
        // fall back to heap if there are more (e.g. first discard after a long
        // gap with no remote packets).
        var stack_buf: [64]u64 = undefined;
        var heap_buf: std.ArrayList(u64) = .empty;
        defer heap_buf.deinit(self.allocator);

        var count: usize = 0;
        var it = self.inputs.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const key_index = @as(u32, @intCast(key >> 32));
            const key_frame = @as(u32, @intCast(key & 0xFFFFFFFF));
            if (key_index == index and key_frame < min_frame) {
                if (count < stack_buf.len) {
                    stack_buf[count] = key;
                } else {
                    heap_buf.append(self.allocator, key) catch break;
                }
                count += 1;
            }
        }

        // Remove the collected keys.
        for (stack_buf[0..@min(count, stack_buf.len)]) |key| {
            _ = self.inputs.remove(key);
        }
        for (heap_buf.items) |key| {
            _ = self.inputs.remove(key);
        }
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

    /// Public alias for makeKey, exposed so unit tests can construct keys
    /// for `inputs.contains()` checks. Production code uses `set`/`get`/`setRemote`
    /// which call makeKey internally.
    pub fn makeKeyTest(index: u32, frame: u32) u64 {
        return makeKey(index, frame);
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
    // 16-bit checksum of `data`, computed in saveState via Wyhash.
    // Used by the per-frame desync detector (see NetplayManager.checkChecksumDesync)
    // to catch divergences ~16 frames after they happen, instead of every 300
    // frames via the periodic SyncHash. Defaults to 0 (uncomputed) for backwards
    // compatibility with tests that construct SavedState directly.
    checksum: u16 = 0,
};

pub const StatePool = struct {
    allocator: std.mem.Allocator,
    pool: []u8 = &.{},
    state_size: usize = 0,
    num_states: usize = 0,
    free_stack: std.ArrayList(usize),
    /// Raw, user-supplied region list. Kept for diagnostics and for
    /// `totalRegionSize` to fall back to if `allocate` hasn't run.
    regions: std.ArrayList(MemoryRegion),
    /// Sorted + merged region list. Built in `allocate` from `regions`,
    /// used by `saveState`/`loadState` for the actual memcpy loop. This is
    /// what the docs/dll-optimization-plan.md calls "coalesced" regions.
    coalesced_regions: std.ArrayList(MemoryRegion) = .empty,
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
        self.coalesced_regions.deinit(self.allocator);
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

    /// Calculate total size of all regions. Uses the coalesced layout if
    /// `allocate` has been called (coalescing happens during allocation);
    /// otherwise falls back to summing the raw region list.
    pub fn totalRegionSize(self: *const StatePool) usize {
        if (self.coalesced_regions.items.len > 0) {
            var total: usize = 0;
            for (self.coalesced_regions.items) |r| total += r.size;
            return total;
        }
        var total: usize = 0;
        for (self.regions.items) |r| total += r.size;
        return total;
    }

    /// Sort and merge overlapping/adjacent regions into a smaller set of
    /// contiguous regions. Returns a freshly-allocated ArrayList of the
    /// merged regions; caller owns the memory.
    ///
    /// The input region list (~270 entries in the production build, the
    /// doc-estimated "370" is approximate) contains many small regions that
    /// are *adjacent* but separated in the list. By sorting by start address
    /// and merging any pair where `next.addr <= top.addr + top.size`, we
    /// collapse them into far fewer — in production, 271 regions become 61.
    ///
    /// Fewer `@memcpy` calls per frame:
    ///   - Less call overhead (each call is a function call + prologue/epilogue).
    ///   - Larger contiguous blocks let the compiler emit `rep movsb`
    ///     (Enhanced REP MOVSB on Haswell+/Zen+ does hardware-speed copies
    ///     for blocks > 128 bytes), bypassing the generic byte loop.
    ///   - Better L1/L2 cache prefetching on the snapshot side.
    ///
    /// `addr == 0` regions (markers for "skip this region") are filtered out:
    /// `saveState` already skips them, but in the coalesced list they would
    /// otherwise contribute to `state_size` and waste pool memory.
    fn coalesceRegions(allocator: std.mem.Allocator, regions: []const MemoryRegion) !std.ArrayList(MemoryRegion) {
        // 1. Filter out zero-address placeholders.
        var filtered: std.ArrayList(MemoryRegion) = .empty;
        defer filtered.deinit(allocator);
        try filtered.ensureTotalCapacity(allocator, regions.len);
        for (regions) |r| {
            if (r.addr != 0 and r.size != 0) {
                filtered.appendAssumeCapacity(r);
            }
        }

        // 2. Sort by start address (stable secondary by size for determinism).
        const sorted = try allocator.dupe(MemoryRegion, filtered.items);
        defer allocator.free(sorted);
        std.mem.sort(MemoryRegion, sorted, {}, lessThanStart);

        // 3. Walk sorted list; merge when next region's start is within
        //    (or directly adjacent to) the current region's end. Two regions
        //    are considered mergeable if `next.addr <= top.addr + top.size`
        //    — `==` collapses directly-adjacent entries; `<` collapses
        //    overlapping entries.
        var merged: std.ArrayList(MemoryRegion) = .empty;
        errdefer merged.deinit(allocator);
        try merged.ensureTotalCapacity(allocator, sorted.len);
        try merged.append(allocator, sorted[0]);
        var i: usize = 1;
        while (i < sorted.len) : (i += 1) {
            const top = &merged.items[merged.items.len - 1];
            const cur = sorted[i];
            const top_end = top.addr + top.size;
            if (cur.addr <= top_end) {
                const cur_end = cur.addr + cur.size;
                if (cur_end > top_end) top.size = cur_end - top.addr;
            } else {
                try merged.append(allocator, cur);
            }
        }
        return merged;
    }

    fn lessThanStart(_: void, a: MemoryRegion, b: MemoryRegion) bool {
        if (a.addr != b.addr) return a.addr < b.addr;
        return a.size < b.size;
    }

    test "coalesceRegions merges adjacent and overlapping" {
        const allocator = std.testing.allocator;

        // (addr, size) — sorted input would be:
        //   0x100..0x104, 0x104..0x108, 0x200..0x208, 0x208..0x20C
        // Coalesced: [0x100..0x108], [0x200..0x20C]  (4 → 2)
        const input = [_]MemoryRegion{
            .{ .addr = 0x200, .size = 0x08 },
            .{ .addr = 0x100, .size = 0x04 },
            .{ .addr = 0x104, .size = 0x04 },
            .{ .addr = 0x208, .size = 0x04 },
        };
        var result = try coalesceRegions(allocator, &input);
        defer result.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 2), result.items.len);
        try std.testing.expectEqual(@as(usize, 0x100), result.items[0].addr);
        try std.testing.expectEqual(@as(usize, 0x08), result.items[0].size);
        try std.testing.expectEqual(@as(usize, 0x200), result.items[1].addr);
        try std.testing.expectEqual(@as(usize, 0x0C), result.items[1].size);
    }

    test "coalesceRegions merges overlapping regions" {
        const allocator = std.testing.allocator;

        // 0x100..0x110 and 0x108..0x120 overlap; merged → 0x100..0x120
        const input = [_]MemoryRegion{
            .{ .addr = 0x108, .size = 0x18 },
            .{ .addr = 0x100, .size = 0x10 },
        };
        var result = try coalesceRegions(allocator, &input);
        defer result.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 1), result.items.len);
        try std.testing.expectEqual(@as(usize, 0x100), result.items[0].addr);
        try std.testing.expectEqual(@as(usize, 0x20), result.items[0].size);
    }

    test "coalesceRegions filters zero-address placeholders" {
        const allocator = std.testing.allocator;

        const input = [_]MemoryRegion{
            .{ .addr = 0x100, .size = 0x04 },
            .{ .addr = 0x0, .size = 0x04 }, // skipped
            .{ .addr = 0x104, .size = 0x04 },
        };
        var result = try coalesceRegions(allocator, &input);
        defer result.deinit(allocator);

        try std.testing.expectEqual(@as(usize, 1), result.items.len);
        try std.testing.expectEqual(@as(usize, 0x08), result.items[0].size);
    }

    test "allocate builds coalesced layout" {
        const allocator = std.testing.allocator;
        var pool = StatePool.init(allocator);
        defer pool.deinit();

        // Add several adjacent regions.
        try pool.addRegion(0x100, 0x04);
        try pool.addRegion(0x104, 0x04);
        try pool.addRegion(0x200, 0x08);

        try pool.allocate(2, 0);

        // Pre-coalesce would be 12 bytes (4+4+8). After coalescing:
        //   [0x100..0x108] and [0x200..0x208] → 8+8 = 16 bytes total.
        // The coalesced regions should be 2 entries.
        try std.testing.expectEqual(@as(usize, 2), pool.coalesced_regions.items.len);
        try std.testing.expectEqual(@as(usize, 16), pool.totalRegionSize());
        try std.testing.expectEqual(@as(usize, 16), pool.state_size);
    }

    /// Allocate the memory pool. After collecting the raw regions (via
    /// repeated `addRegion`), sort + merge them into a smaller set of
    /// coalesced regions. The coalesced layout is what `saveState` /
    /// `loadState` use; the raw layout is kept for diagnostics and for
    /// the case where the user explicitly calls `addRegion` after
    /// allocation (which we don't currently do, but the safety net is
    /// cheap).
    pub fn allocate(self: *StatePool, num_states: usize, _: usize) !void {
        // Coalesce the raw region list into the layout used for snapshots.
        // We do this here (rather than at every `addRegion`) so callers can
        // add regions in any order without re-running the sort on each add.
        const new_coalesced = try coalesceRegions(self.allocator, self.regions.items);
        self.coalesced_regions.deinit(self.allocator);
        self.coalesced_regions = new_coalesced;

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

        // Copy all (coalesced) memory regions into contiguous buffer.
        // Using the coalesced list — built in `allocate` by sorting +
        // merging adjacent entries — collapses the production ~270
        // regions into ~61 contiguous chunks, dramatically reducing
        // memcpy call overhead and letting the compiler emit wide
        // `rep movsb` / vector instructions for the larger blocks.
        //
        // SAFETY: if any region doesn't fit (pos + r.size > state_size),
        // the previous implementation SILENTLY SKIPPED the copy but still
        // advanced `pos`. This had two catastrophic effects:
        //   1. The saved snapshot was missing data (silent corruption).
        //   2. All subsequent regions were also skipped (pos was too large).
        // On load, the missing regions were not restored, causing the game
        // to continue with corrupted memory → desync.
        //
        // In production, state_size = totalRegionSize() after coalescing,
        // so the check should never fail. But if coalesceRegions has an
        // overlap-merge bug that miscalculates the total, this check fails.
        // We now log an error and skip the SAVE entirely (return null) so
        // the caller can detect the failure rather than silently corrupting
        // the rollback state pool.
        var pos: usize = 0;
        var region_overflow = false;
        for (self.coalesced_regions.items) |r| {
            if (pos + r.size > self.state_size) {
                // Region doesn't fit — coalesceRegions or allocate has a bug.
                region_overflow = true;
                break;
            }
            const src: [*]const u8 = @ptrFromInt(r.addr);
            @memcpy(dst[pos .. pos + r.size], src[0..r.size]);
            pos += r.size;
        }
        if (region_overflow) {
            // Log and bail — don't save a partial snapshot. The caller
            // (frameStepNetplay) discards the return value, so a null return
            // just means "no state saved this frame". The next frame will
            // retry; if the overflow persists, rollback will eventually fail
            // with "no saved state for frame" (caught by checkRollback).
            //
            // Uses .warn (not .err) because this is a should-never-happen
            // diagnostic, not a fatal error — the save gracefully returns
            // null. Using .err would make the Zig test runner fail when the
            // overflow test exercises this path intentionally.
            std.log.warn("StatePool.saveState: region overflow (pos={d}, state_size={d}, regions={d}) — save skipped to prevent corruption", .{
                pos, self.state_size, self.coalesced_regions.items.len,
            });
            // Return the slot to the free stack so it's not leaked.
            self.free_stack.append(self.allocator, slot) catch {};
            return null;
        }

        // Save FPU control state (cw + MXCSR only — see SavedFpu doc).
        // saveFpu() handles the arch guard internally: on non-x86 hosts
        // (e.g. x86_64 unit-test runners) it writes benign defaults and
        // restoreFpu() becomes a no-op.
        var fpu_env: SavedFpu = undefined;
        saveFpu(&fpu_env);

        // Compute 16-bit checksum of the saved state buffer.
        // Used by the per-frame desync detector (NetplayManager.checkChecksumDesync)
        // to catch divergences ~16 frames after they happen — 30x faster than the
        // periodic 300-frame SyncHash. Wyhash is ~5 GB/s; hashing the ~850KB
        // production state buffer costs ~170μs (~1% of the 16.6ms frame budget).
        // Truncated to u16 — collision probability 1/65536 per frame, acceptable
        // because the SyncHash remains as a secondary check.
        const checksum: u16 = @truncate(std.hash.Wyhash.hash(0, dst));

        // Store metadata
        self.saved_states.append(self.allocator, .{
            .frame = frame,
            .index = index,
            .fpu_env = fpu_env,
            .data = dst,
            .checksum = checksum,
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

        // Restore all (coalesced) memory regions. See `saveState` for why this
        // walks the coalesced list and not the raw region list.
        //
        // SAFETY: same overflow check as saveState. If a region doesn't fit,
        // the previous implementation silently skipped the restore, leaving
        // the game's memory in a partially-restored state. This caused
        // immediate desyncs after any rollback that hit the overflow path.
        // We now log an error and abort the restore (return without freeing
        // subsequent states) so the corruption is at least visible in logs.
        var pos: usize = 0;
        var region_overflow = false;
        for (self.coalesced_regions.items) |r| {
            if (pos + r.size > src.len) {
                region_overflow = true;
                break;
            }
            const dst: [*]u8 = @ptrFromInt(r.addr);
            @memcpy(dst[0..r.size], src[pos .. pos + r.size]);
            pos += r.size;
        }
        if (region_overflow) {
            // Uses .warn (not .err) — see saveState's overflow comment.
            std.log.warn("StatePool.loadState: region overflow (pos={d}, src.len={d}, regions={d}) — restore incomplete, desync likely", .{
                pos, src.len, self.coalesced_regions.items.len,
            });
            // Don't free subsequent states — the restore was incomplete,
            // and freeing would lose history we might need for diagnosis.
            return;
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

    /// Look up the checksum for the most recent saved state at or before
    /// `(target_frame, target_index)`. Returns null if no such state exists.
    /// Used by the per-frame desync detector to find the local checksum
    /// for a frame the remote peer has reported a checksum for.
    pub fn getChecksumForFrame(self: *const StatePool, target_frame: u32, target_index: u32) ?u16 {
        var best: ?u16 = null;
        var best_frame: u32 = 0;
        for (self.saved_states.items) |state| {
            if (state.index == target_index and state.frame <= target_frame) {
                if (best == null or state.frame > best_frame) {
                    best = state.checksum;
                    best_frame = state.frame;
                }
            }
        }
        return best;
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
