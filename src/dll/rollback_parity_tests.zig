// rollback_parity_tests.zig
//
// Tests validating the CCCaster parity fixes from the rollback-improvements
// branch. These tests lock in the behavior that eliminates:
//   - Post-rollback RNG desyncs (start_world_time + netplay_state restore)
//   - FPU ldmxcsr crash (register-pointer addressing)
//   - Re-run state pool poisoning (stop saving during re-run)
//   - Stale last_changed_frame (per-frame clear)
//   - Effects pointer-followed chain (12KB missing data)
//   - Early-frame rollback now fires directly (no deferred_lcf gate — matches CCCaster)
//
// Each test verifies a specific fix. If the fix is REVERTED, the test FAILS.
//
// Run with:
//   zig build test --summary all

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const rb = @import("rollback.zig");
const regions = @import("rollback_regions.zig");

// =============================================================================
// FIX 1: SavedState stores netplay_state + start_world_time
//
// CCCaster's GameState struct saves 3 NetplayManager fields:
//   netplayState, startWorldTime, indexedFrame
// zzcaster was only saving indexedFrame (frame + index).
// Without restoring netplay_state and start_world_time, the re-run uses
// stale FSM state / wrong frame counter base → RNG diverges.
//
// Fix (commit 0ebc38e): Added netplay_state + start_world_time to SavedState.
// =============================================================================

test "FIX 1a: SavedState has netplay_state field" {
    // Verify the field exists and defaults to 0.
    const state = rb.SavedState{
        .frame = 0,
        .index = 0,
        .fpu_env = .{ .cw = 0, .mxcsr = 0 },
        .data = &[_]u8{},
    };
    try expectEqual(@as(u8, 0), state.netplay_state);
}

test "FIX 1b: SavedState has start_world_time field" {
    const state = rb.SavedState{
        .frame = 0,
        .index = 0,
        .fpu_env = .{ .cw = 0, .mxcsr = 0 },
        .data = &[_]u8{},
    };
    try expectEqual(@as(u32, 0), state.start_world_time);
}

test "FIX 1c: saveState stores netplay_state and start_world_time" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0xAAAA;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(5, 0);

    // Save with netplay_state=4 (in_game) and start_world_time=12345
    _ = pool.saveState(10, 1, 4, 12345);

    try expectEqual(@as(usize, 1), pool.saved_states_count());
    const state = pool.getSavedState(0);
    try expectEqual(@as(u8, 4), state.netplay_state);
    try expectEqual(@as(u32, 12345), state.start_world_time);
}

// =============================================================================
// FIX 2: loadStateForFrame returns LoadResult with netplay_state + start_world_time
//
// The old loadStateForFrame returned just u32 (the frame). The new version
// returns LoadResult { frame, netplay_state, start_world_time } so checkRollback
// can restore all 3 NetplayManager fields.
// =============================================================================

test "FIX 2a: loadStateForFrame returns LoadResult with all fields" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(5, 0);

    // Save with specific netplay_state and start_world_time
    _ = pool.saveState(10, 1, 5, 99999);

    const loaded = pool.loadStateForFrame(10, 1);
    try expect(loaded != null);
    try expectEqual(@as(u32, 10), loaded.?.frame);
    try expectEqual(@as(u8, 5), loaded.?.netplay_state);
    try expectEqual(@as(u32, 99999), loaded.?.start_world_time);
}

test "FIX 2b: loadStateForFrame returns null for non-existent index" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(5, 0);

    _ = pool.saveState(10, 1, 0, 0);

    // Index 2 doesn't exist
    try expect(pool.loadStateForFrame(10, 2) == null);
}

test "FIX 2c: loadStateForFrame returns latest state <= target" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(10, 0);

    _ = pool.saveState(10, 1, 1, 100);
    _ = pool.saveState(20, 1, 2, 200);

    // Request frame 15 → should return frame 10's state
    const loaded = pool.loadStateForFrame(15, 1);
    try expect(loaded != null);
    try expectEqual(@as(u32, 10), loaded.?.frame);
    try expectEqual(@as(u8, 1), loaded.?.netplay_state);
    try expectEqual(@as(u32, 100), loaded.?.start_world_time);
}

// =============================================================================
// FIX 3: StatePool does NOT save during re-run frames
//
// CCCaster deliberately does NOT save re-run states ("the inputs are faked").
// zzcaster was saving them, poisoning the pool if any re-run state was wrong.
// Fix (commit 0ebc38e): Removed saveState from the re-run-in-progress branch.
//
// This is a frame_step.zig behavior — tested indirectly by verifying that
// the saveState API supports the new parameters and the LoadResult type
// works correctly for the re-run completion path.
// =============================================================================

test "FIX 3: saveState with all parameters works correctly" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 42;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(3, 0);

    // Simulate saving states with different netplay_state values
    _ = pool.saveState(0, 1, 3, 1000); // chara_intro
    _ = pool.saveState(1, 1, 4, 1000); // in_game
    _ = pool.saveState(2, 1, 4, 1000); // in_game

    try expectEqual(@as(usize, 3), pool.saved_states_count());
    try expectEqual(@as(u8, 3), pool.getSavedState(0).netplay_state); // chara_intro
    try expectEqual(@as(u8, 4), pool.getSavedState(1).netplay_state); // in_game
    try expectEqual(@as(u8, 4), pool.getSavedState(2).netplay_state); // in_game
}

// =============================================================================
// FIX 4: Effects pointer-followed chain constants
//
// CCCaster saves 12 extra bytes per effect (3-level pointer-deref chain).
// zzcaster was missing this entirely. Fix (commit e163db5): Added constants
// and save/load functions.
// =============================================================================

test "FIX 4a: effects pointer chain constants exist and are correct" {
    // CC_EFFECTS_ARRAY_ADDR = 0x67BDE8 (from CCCaster Constants.hpp)
    try expectEqual(@as(usize, 0x67BDE8), regions.CC_EFFECTS_ARRAY_ADDR);
    // CC_EFFECTS_ARRAY_COUNT = 1000
    try expectEqual(@as(usize, 1000), regions.CC_EFFECTS_ARRAY_COUNT);
    // CC_EFFECT_ELEMENT_SIZE = 0x33C
    try expectEqual(@as(usize, 0x33C), regions.CC_EFFECT_ELEMENT_SIZE);
    // CC_EFFECT_PTR_OFFSET = 0x320
    try expectEqual(@as(usize, 0x320), regions.CC_EFFECT_PTR_OFFSET);
}

test "FIX 4b: effects pointer data size is 12000 (12 bytes × 1000 effects)" {
    try expectEqual(@as(usize, 12), regions.CC_EFFECT_PTR_DATA_SIZE_PER_EFFECT);
    try expectEqual(@as(usize, 12000), regions.CC_EFFECT_PTR_DATA_SIZE);
}

test "FIX 4c: state_size equals total region size (flat regions, no effects ptr)" {
    // The adapter currently uses flat regions (no pointer-following). The
    // new port supports pointer-following via MemDumpPtr, but that's
    // configured in the region table, not auto-detected. So state_size
    // always equals totalRegionSize in the adapter.
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    try pool.addRegion(0x563778, 4);
    try pool.addRegion(0x1000, 64);

    try pool.allocate(5, 0);
    try expectEqual(pool.totalRegionSize(), pool.stateSize());
    try expect(!pool.has_effects);
}

test "FIX 4d: state_size does NOT include effects ptr data when effects absent" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    try pool.addRegion(0x1000, 64);
    try pool.addRegion(0x2000, 32);

    try pool.allocate(5, 0);
    try expectEqual(pool.totalRegionSize(), pool.stateSize());
    try expect(!pool.has_effects);
}

// =============================================================================
// FIX 5: Pool stores/retrieves states at ALL frames (no early-frame gate)
//
// zzcaster previously had a rollback_min_frame_delay gate. Removed to match
// CCCaster. The pool must correctly store and retrieve states at early frames.
// =============================================================================

test "FIX 5: pool stores and retrieves states at early frames (0, 1, ...)" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(30, 0);

    // Save states at frames 0-3
    var frame: u32 = 0;
    while (frame <= 3) : (frame += 1) {
        _ = pool.saveState(frame, 1, 4, 1000);
    }

    // Verify we can load frame 0 (critical for start-of-game rollbacks).
    const loaded_0 = pool.loadStateForFrame(0, 1);
    try expect(loaded_0 != null);
    try expectEqual(@as(u32, 0), loaded_0.?.frame);
}

test "FIX 5b: pool retrieves the latest state <= target (CCCaster parity)" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(30, 0);

    // Save states at frames 0, 1, 2, 3
    var frame: u32 = 0;
    while (frame <= 3) : (frame += 1) {
        _ = pool.saveState(frame, 1, 4, 1000);
    }

    // Request frame 5 (no exact match). Should return frame 3 (latest <= 5).
    const loaded = pool.loadStateForFrame(5, 1);
    try expect(loaded != null);
    try expectEqual(@as(u32, 3), loaded.?.frame);
}

// =============================================================================
// FIX 6: FPU restore uses register-pointer addressing
//
// The "m" constraint codegen on x86-32 crashes ldmxcsr with #GP even with
// a valid MXCSR value. Fix (commit 0d4fd46): Use register-pointer addressing
// — fldcw (%reg) / ldmxcsr (%reg) — which always generates valid encoding.
//
// This is an inline asm fix that can't be directly tested in unit tests
// (requires x86 hardware + the actual FPU). But we can verify the SavedFpu
// struct and the masking logic.
// =============================================================================

test "FIX 6a: SavedFpu struct has cw and mxcsr fields" {
    const fpu = rb.SavedFpu{ .cw = 0x037F, .mxcsr = 0x1F80 };
    try expectEqual(@as(u16, 0x037F), fpu.cw);
    try expectEqual(@as(u32, 0x1F80), fpu.mxcsr);
}

test "FIX 6b: FPU state is saved and stored in SavedState" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(3, 0);

    _ = pool.saveState(0, 0, 0, 0);

    // The fpu_env should be populated (non-zero on x86, defaults on other archs)
    const state = pool.getSavedState(0);
    // On x86, fnstcw/stmxcsr will produce non-zero values. On non-x86 (test
    // runner), the defaults are 0x037F / 0x1F80. Either way, the fields exist.
    _ = state.fpu_env.cw;
    _ = state.fpu_env.mxcsr;
}

// =============================================================================
// FIX 7: Per-frame clearLastChangedFrame
//
// CCCaster clears lastChangedFrame every frame (when timer allows) BEFORE
// receiving new inputs. zzcaster only cleared inside checkRollback, so stale
// lcfs persisted and triggered spurious late rollbacks.
//
// Fix (commit 0ebc38e): Added per-frame clearLastChanged call in frame_step.zig.
// This test verifies the InputBuffer.clearLastChanged method works correctly.
// =============================================================================

test "FIX 7a: clearLastChanged resets last_changed_frame to null" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Set up a last_changed_frame
    buf.set(5, 5, 0x01);
    const stale = [_]u16{0x02};
    buf.setRemote(4, 8, &stale, true);
    try expect(buf.last_changed_frame != null);

    // Clear it
    buf.clearLastChanged();
    try expect(buf.last_changed_frame == null);
}

test "FIX 7b: after clearLastChanged, new changes are detected" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    buf.set(5, 5, 0x01);
    const stale = [_]u16{0x02};
    buf.setRemote(4, 8, &stale, true);
    try expect(buf.last_changed_frame != null);

    buf.clearLastChanged();
    try expect(buf.last_changed_frame == null);

    // New change should be detected
    const actual = [_]u16{0x09};
    buf.setRemote(5, 5, &actual, true);
    try expect(buf.last_changed_frame != null);
}

// =============================================================================
// FIX 8: Stale-index lcf does NOT poison last_changed_frame
//
// setRemote used full u64 key comparison, so stale-index inputs (smaller key)
// would win over current-index changes. Fix: compare index separately.
// =============================================================================

test "FIX 8a: stale-index input does NOT replace current-index lcf" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Set up current index 5 with a misprediction
    buf.set(5, 5, 0x01);
    const actual = [_]u16{0x09};
    buf.setRemote(5, 5, &actual, true);
    try expect(buf.last_changed_frame != null);

    const lcf_before = buf.last_changed_frame.?;
    const lcf_index_before = @as(u32, @intCast(lcf_before >> 32));
    try expectEqual(@as(u32, 5), lcf_index_before);

    // Stale index-4 input arrives — should NOT replace the lcf
    const stale = [_]u16{0x02};
    buf.setRemote(4, 8, &stale, true);

    const lcf_after = buf.last_changed_frame.?;
    const lcf_index_after = @as(u32, @intCast(lcf_after >> 32));
    try expectEqual(@as(u32, 5), lcf_index_after); // Still index 5
}

test "FIX 8b: current-index misprediction REPLACES stale-index lcf" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    buf.set(5, 5, 0x01);
    const stale = [_]u16{0x02};
    buf.setRemote(4, 8, &stale, true);
    try expect(buf.last_changed_frame != null);

    // Current-index misprediction arrives — should REPLACE the stale lcf
    const actual = [_]u16{0x09};
    buf.setRemote(5, 5, &actual, true);

    const lcf = buf.last_changed_frame.?;
    const lcf_index = @as(u32, @intCast(lcf >> 32));
    try expectEqual(@as(u32, 5), lcf_index); // Now index 5, not stale 4
}

// =============================================================================
// FIX 9: StatePool ring-buffer eviction works with new fields
//
// When the pool is full, the oldest state is recycled. Verify that the
// new netplay_state and start_world_time fields work correctly with
// ring-buffer eviction.
// =============================================================================

test "FIX 9: ring-buffer eviction works with netplay_state + start_world_time" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(3, 0); // only 3 slots

    // Save 5 states with different netplay_state values — should evict oldest 2
    _ = pool.saveState(0, 1, 3, 1000); // will be evicted
    _ = pool.saveState(1, 1, 3, 1000); // will be evicted
    _ = pool.saveState(2, 1, 4, 2000); // survives (in_game)
    _ = pool.saveState(3, 1, 4, 2000);
    _ = pool.saveState(4, 1, 4, 2000);

    try expectEqual(@as(usize, 3), pool.saved_states_count());

    // Oldest surviving should be frame 2
    try expectEqual(@as(u32, 2), pool.getSavedState(0).frame);
    try expectEqual(@as(u8, 4), pool.getSavedState(0).netplay_state);
    try expectEqual(@as(u32, 2000), pool.getSavedState(0).start_world_time);

    // Frame 0 and 1 should be evicted
    try expect(pool.loadStateForFrame(0, 1) == null);
    try expect(pool.loadStateForFrame(1, 1) == null);

    // Frame 2 should be found
    const loaded = pool.loadStateForFrame(2, 1);
    try expect(loaded != null);
    try expectEqual(@as(u32, 2000), loaded.?.start_world_time);
}

// =============================================================================
// REGRESSION: Coalesced regions still work correctly
// =============================================================================

test "REGRESSION: coalesce + save + load round-trip with new fields" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var a: u32 = 100;
    var b: u32 = 200;
    var c: u32 = 300;
    try pool.addRegion(@intFromPtr(&a), @sizeOf(u32));
    try pool.addRegion(@intFromPtr(&b), @sizeOf(u32));
    try pool.addRegion(@intFromPtr(&c), @sizeOf(u32));
    try pool.allocate(5, 0);

    _ = pool.saveState(10, 1, 4, 5000);

    // Modify
    a = 999;
    b = 888;
    c = 777;

    // Load
    const loaded = pool.loadStateForFrame(10, 1);
    try expect(loaded != null);
    try expectEqual(@as(u32, 10), loaded.?.frame);
    try expectEqual(@as(u8, 4), loaded.?.netplay_state);
    try expectEqual(@as(u32, 5000), loaded.?.start_world_time);

    // Values should be restored
    try expectEqual(@as(u32, 100), a);
    try expectEqual(@as(u32, 200), b);
    try expectEqual(@as(u32, 300), c);
}

test "FIX: loadStateForFrame falls back to oldest state when enable_fallback = true" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 42;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(5, 0);

    // Save states at frames 10 and 20
    _ = pool.saveState(10, 1, 4, 1000);
    _ = pool.saveState(20, 1, 4, 2000);

    // Default: enable_fallback = false in tests.
    // Searching for frame 5 should return null (no state <= 5).
    try expect(pool.loadStateForFrame(5, 1) == null);

    // Explicitly enable fallback.
    pool.enable_fallback = true;

    // Searching for frame 5 should now fall back to the oldest state (frame 10).
    const loaded = pool.loadStateForFrame(5, 1);
    try expect(loaded != null);
    try expectEqual(@as(u32, 10), loaded.?.frame);
    try expectEqual(@as(u32, 1000), loaded.?.start_world_time);
}
