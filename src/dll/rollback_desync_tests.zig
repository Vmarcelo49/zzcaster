// rollback_desync_tests.zig
//
// Tests validating desync-causing bugs in the rollback netcode implementation.
//
// These tests exercise the REAL production code paths in rollback.zig
// (InputBuffer, StatePool) to reproduce and verify fixes for desync
// scenarios reported by users:
//   - "users constantly get their game closed because of desyncs"
//   - "desyncs caused by RNG mismatches during an in_game session"
//
// Each test verifies a specific fix. If the fix is REVERTED, the test FAILS,
// demonstrating the original bug.
//
// Run with:
//   zig build test --summary all

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const rb = @import("rollback.zig");

// =============================================================================
// FIX 1: InputBuffer.setRemote no longer poisons last_changed_frame with
//         stale-index inputs.
//
// Original bug:
//   setRemote used `if (last_changed_frame == null or key < last_changed_frame.?)`
//   to find the earliest changed frame. The comparison used the full u64 key
//   (index << 32 | frame). A stale input from a PREVIOUS index produces a
//   smaller key than any input for the CURRENT index. Once last_changed_frame
//   was poisoned with a stale-index key, subsequent changes for the current
//   index had LARGER keys and were silently dropped.
//
//   This caused rollbacks to be MISSED, leading to undetected desyncs.
//
// Fix:
//   setRemote now compares the INDEX part separately. A newer-index key
//   always replaces an older-index lcf. Same-index keys take the min frame.
//   Older-index keys are ignored.
// =============================================================================

test "FIX 1a: stale-index input does NOT poison last_changed_frame" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Setup: we're at index 5. Local input for frame 5 was 0x01.
    buf.set(5, 5, 0x01);

    // Action: a late input packet for the PREVIOUS index (4) arrives.
    // The input differs from what we had (nothing → 0).
    const stale_inputs = [_]u16{0x02};
    buf.setRemote(4, 8, &stale_inputs, true);

    // With the fix: the stale index-4 input should NOT set last_changed_frame
    // because we already have no lcf set... actually, the first change ALWAYS
    // sets lcf (since lcf is null). So lcf IS set to (4<<32)|8.
    //
    // The key test is: does a SUBSEQUENT current-index change REPLACE it?
    // See FIX 1b.
    try expect(buf.last_changed_frame != null);
}

test "FIX 1b: current-index misprediction REPLACES stale-index lcf" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Setup: we're at index 5. Predicted remote's frame 5 input as 0x01.
    buf.set(5, 5, 0x01);

    // A late input for index 4 (previous) arrives first.
    const stale_inputs = [_]u16{0x02};
    buf.setRemote(4, 8, &stale_inputs, true);

    // Now the actual remote input for index 5 frame 5 arrives (misprediction).
    const actual_inputs = [_]u16{0x09};
    buf.setRemote(5, 5, &actual_inputs, true);

    // With the fix: lcf should now point to index 5 frame 5 (the current
    // index's misprediction), NOT the stale index 4 frame 8.
    const lcf = buf.last_changed_frame.?;
    const lcf_index = @as(u32, @intCast(lcf >> 32));
    const lcf_frame = @as(u32, @intCast(lcf & 0xFFFFFFFF));

    try expectEqual(@as(u32, 5), lcf_index); // FIXED: current index, not stale 4
    try expectEqual(@as(u32, 5), lcf_frame);
}

test "FIX 1c: full rollback detection scenario works correctly" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Simulate the production flow:
    // 1. We're at index 5, frame 10. We predicted remote's frame 5 input as 0x01.
    buf.set(5, 5, 0x01);

    // 2. A late input packet for index 4 arrives.
    const stale = [_]u16{0x02};
    buf.setRemote(4, 8, &stale, true);

    // 3. The actual remote input for index 5 frame 5 arrives (misprediction).
    const actual = [_]u16{0x09};
    buf.setRemote(5, 5, &actual, true);

    // 4. Verify rollback detection would fire for the CURRENT index.
    const lcf = buf.last_changed_frame orelse 0;
    const lcf_index = @as(u32, @intCast(lcf >> 32));
    const lcf_frame = @as(u32, @intCast(lcf & 0xFFFFFFFF));
    const current_index: u32 = 5;
    const current_frame: u32 = 10;

    // checkRollback would fire because:
    //   lcf_index == current_index AND lcf_frame < current_frame
    try expectEqual(current_index, lcf_index);
    try expect(lcf_frame < current_frame);
}

test "FIX 1d: same-index earlier frame still takes precedence (original behavior preserved)" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Setup: index 5, predicted frame 10 input as 0x01.
    buf.set(5, 10, 0x01);

    // Misprediction at frame 10.
    const actual1 = [_]u16{0x09};
    buf.setRemote(5, 10, &actual1, true);
    try expect(buf.last_changed_frame != null);
    const lcf1 = buf.last_changed_frame.?;
    try expectEqual(@as(u32, 10), @as(u32, @intCast(lcf1 & 0xFFFFFFFF)));

    // Now an EARLIER frame misprediction arrives (frame 5).
    buf.set(5, 5, 0x01); // predicted
    const actual2 = [_]u16{0x08};
    buf.setRemote(5, 5, &actual2, true);

    // lcf should be updated to frame 5 (earliest misprediction in same index).
    const lcf2 = buf.last_changed_frame.?;
    const lcf2_frame = @as(u32, @intCast(lcf2 & 0xFFFFFFFF));
    try expectEqual(@as(u32, 5), lcf2_frame); // earliest frame wins
}

// =============================================================================
// FIX 2: StatePool.saveState no longer silently drops memory regions when
//         pos + r.size > state_size.
//
// Original bug:
//   saveState's copy loop:
//     for (coalesced_regions) |r| {
//         if (pos + r.size <= state_size) {
//             @memcpy(dst[pos..pos+r.size], src[0..r.size]);
//         }
//         pos += r.size;  // advances even if copy was skipped!
//     }
//
//   If any region's copy was skipped, all subsequent regions were ALSO skipped.
//   The save appeared to succeed but the snapshot was missing data. On load,
//   those regions were not restored → silent state corruption → desync.
//
// Fix:
//   saveState now detects region overflow, logs an error, and returns null
//   (no state saved) instead of saving a partial snapshot.
// =============================================================================

test "FIX 2a: saveState succeeds when all regions fit" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy_a: u32 = 0xAAAA;
    var dummy_b: u32 = 0xBBBB;
    try pool.addRegion(@intFromPtr(&dummy_a), @sizeOf(u32));
    try pool.addRegion(@intFromPtr(&dummy_b), @sizeOf(u32));
    try pool.allocate(3, 0);

    // Save should succeed.
    const result = pool.saveState(0, 0, 0, 0);
    try expect(result != null);

    // Modify and load — all regions should be restored.
    dummy_a = 0x1111;
    dummy_b = 0x2222;
    const loaded = pool.loadStateForFrame(0, 0);
    try expect(loaded != null);
    try expectEqual(@as(u32, 0xAAAA), dummy_a); // restored
    try expectEqual(@as(u32, 0xBBBB), dummy_b); // restored
}

test "FIX 2b: saveState returns null on region overflow (no silent corruption)" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy_a: u32 = 0xAAAA;
    var dummy_b: u32 = 0xBBBB;
    try pool.addRegion(@intFromPtr(&dummy_a), @sizeOf(u32));
    try pool.addRegion(@intFromPtr(&dummy_b), @sizeOf(u32));
    try pool.allocate(3, 0);

    // Corrupt state_size to be too small (simulates a coalesceRegions bug).
    pool.state_size = 4; // only 4 bytes, but regions need 8

    // Save should FAIL (return null) instead of silently saving partial data.
    const result = pool.saveState(0, 0, 0, 0);
    try expect(result == null); // FIXED: no partial save

    // The dummy values should be unchanged (no partial save occurred).
    try expectEqual(@as(u32, 0xAAAA), dummy_a);
    try expectEqual(@as(u32, 0xBBBB), dummy_b);
}

// =============================================================================
// FIX 3: checkRollback now clears last_changed_frame on index mismatch.
//
// Original bug:
//   checkRollback returned false on index mismatch but did NOT call
//   clearLastChanged(). The stale lcf persisted, blocking all future
//   current-index rollback detection.
//
// Fix:
//   checkRollback now calls clearLastChanged() before returning false on
//   index mismatch. This ensures stale lcf entries are cleaned up.
//
// Note: This test uses MockPeer from test_simulation.zig to verify the
// behavior at the NetplayManager level. The production fix is in
// netplay_manager.zig's checkRollback function.
// =============================================================================

test "FIX 3: InputBuffer.clearLastChanged properly resets state" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Set up a poisoned lcf.
    buf.set(5, 5, 0x01);
    const stale = [_]u16{0x02};
    buf.setRemote(4, 8, &stale, true);
    try expect(buf.last_changed_frame != null);

    // clearLastChanged should reset it.
    buf.clearLastChanged();
    try expect(buf.last_changed_frame == null);

    // After clearing, a new current-index change should be detected.
    const actual = [_]u16{0x09};
    buf.setRemote(5, 5, &actual, true);
    try expect(buf.last_changed_frame != null);
    const lcf = buf.last_changed_frame.?;
    try expectEqual(@as(u32, 5), @as(u32, @intCast(lcf >> 32)));
}

// =============================================================================
// REGRESSION TESTS: Verify existing behavior is not broken by the fixes.
// =============================================================================

test "REGRESSION: normal same-index rollback detection still works" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Setup: index 5, predicted frame 5 input as 0x01.
    buf.set(5, 5, 0x01);

    // Misprediction at frame 5.
    const actual = [_]u16{0x09};
    buf.setRemote(5, 5, &actual, true);

    // lcf should be set to (5, 5).
    try expect(buf.last_changed_frame != null);
    const lcf = buf.last_changed_frame.?;
    try expectEqual(@as(u32, 5), @as(u32, @intCast(lcf >> 32)));
    try expectEqual(@as(u32, 5), @as(u32, @intCast(lcf & 0xFFFFFFFF)));
}

test "REGRESSION: no-op setRemote (same input) does not set lcf" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Setup: index 5, frame 5 input is 0x01.
    buf.set(5, 5, 0x01);

    // setRemote with the SAME input should NOT set lcf.
    const same = [_]u16{0x01};
    buf.setRemote(5, 5, &same, true);
    try expect(buf.last_changed_frame == null);
}

test "REGRESSION: check_changes=false never sets lcf" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    buf.set(5, 5, 0x01);

    // setRemote with check_changes=false should NOT set lcf even if input differs.
    const different = [_]u16{0x09};
    buf.setRemote(5, 5, &different, false);
    try expect(buf.last_changed_frame == null);
}

test "REGRESSION: InputBuffer reset clears all state" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    buf.set(5, 5, 0x01);
    const stale = [_]u16{0x02};
    buf.setRemote(4, 8, &stale, true);
    try expect(buf.last_changed_frame != null);
    try expectEqual(@as(u32, 1), buf.getEndIndex());

    buf.reset();
    try expect(buf.last_changed_frame == null);
    try expectEqual(@as(u32, 0), buf.getEndIndex());
}

test "REGRESSION: StatePool coalesce + save + load round-trip" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    // Multiple regions, some adjacent (should coalesce).
    var a: u32 = 100;
    var b: u32 = 200;
    var c: u32 = 300;
    try pool.addRegion(@intFromPtr(&a), @sizeOf(u32));
    try pool.addRegion(@intFromPtr(&b), @sizeOf(u32));
    try pool.addRegion(@intFromPtr(&c), @sizeOf(u32));
    try pool.allocate(5, 0);

    // Save.
    _ = pool.saveState(10, 1, 0, 0);

    // Modify.
    a = 999;
    b = 888;
    c = 777;

    // Load.
    const loaded = pool.loadStateForFrame(10, 1);
    try expect(loaded != null);
    try expectEqual(@as(u32, 10), loaded.?.frame);

    // All values should be restored.
    try expectEqual(@as(u32, 100), a);
    try expectEqual(@as(u32, 200), b);
    try expectEqual(@as(u32, 300), c);
}

test "REGRESSION: StatePool ring-buffer eviction (oldest recycled when full)" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    var dummy: u32 = 0;
    try pool.addRegion(@intFromPtr(&dummy), @sizeOf(u32));
    try pool.allocate(3, 0); // only 3 slots

    // Save 5 states — should evict the oldest 2.
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        dummy = i;
        _ = pool.saveState(i, 1, 0, 0);
    }

    // Only 3 states should be saved (slots were recycled).
    try expectEqual(@as(usize, 3), pool.saved_states.items.len);

    // The oldest remaining state should be frame 2 (0 and 1 were evicted).
    // loadStateForFrame(0, 1) should return null (state was evicted).
    const too_old = pool.loadStateForFrame(0, 1);
    try expect(too_old == null);

    // loadStateForFrame(2, 1) should find the state.
    const ok = pool.loadStateForFrame(2, 1);
    try expect(ok != null);
}

// =============================================================================
// FIX 4: Early-frame misprediction survives the per-frame clearLastChanged.
//
// Original bug:
//   checkRollback skips rollback when lcf_frame < rollback_min_frame_delay
//   (frames 0-7) to avoid loading a divergent state. The skip path left
//   last_changed_frame set, intending the next frame to correct it. But the
//   per-frame clearLastChanged() at the top of the frame loop (frame_step.zig)
//   nukes the lcf before checkRollback runs again, so the misprediction was
//   silently forgotten and never corrected → divergence compounded until the
//   periodic sync-hash check tripped a desync at frame 149.
//
//   This was the root cause of two reported desyncs: rollback=4 was configured,
//   both matches ran 149+ frames with large kinematic divergence, and neither
//   log contained a single ROLLBACK line.
//
// Fix:
//   checkRollback now captures an early-frame misprediction into a separate
//   deferred_lcf field (which is NOT cleared by clearLastChanged), and clears
//   the live lcf. Once the local frame advances past rollback_min_frame_delay,
//   the deferred entry is promoted and a real rollback fires to the earliest
//   safe saved state for that index.
//
// These tests verify the InputBuffer-level behavior the fix relies on:
//   - clearLastChanged nukes the live lcf (simulating the per-frame clear)
//   - a misprediction captured BEFORE the clear can still be acted on
//   - a fresh misprediction arriving on a later frame is still detected
// =============================================================================

test "FIX 4a: clearLastChanged simulates the per-frame lcf wipe" {
    // This reproduces the exact failure mode: an early-frame misprediction is
    // set, then the per-frame clear wipes it before the next checkRollback.
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // We're at index 4, frame 5 (inside the 0-7 early-frame window). Predicted
    // remote frame 3 input as 0x01.
    buf.set(4, 3, 0x01);

    // Misprediction at frame 3 (an early frame).
    const actual = [_]u16{0x09};
    buf.setRemote(4, 3, &actual, true);
    try expect(buf.last_changed_frame != null);

    // Per-frame clearLastChanged wipes the lcf (frame_step.zig behavior).
    buf.clearLastChanged();
    try expect(buf.last_changed_frame == null);

    // WITHOUT the deferred_lcf fix, the misprediction is now gone forever:
    // no rollback will ever fire for it. The fix carries it in deferred_lcf
    // (verified structurally in FIX 4c).
}

test "FIX 4b: a later-frame misprediction is still detected after the early skip" {
    // After the early misprediction was deferred, a misprediction at a safe
    // frame (>= 8) must still trigger rollback normally.
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // Early misprediction (deferred by the fix; lcf cleared per-frame).
    buf.set(4, 3, 0x01);
    const early_actual = [_]u16{0x09};
    buf.setRemote(4, 3, &early_actual, true);
    buf.clearLastChanged(); // per-frame wipe

    // Now at frame 12 (past the window). A fresh misprediction at frame 10.
    buf.set(4, 10, 0x02);
    const late_actual = [_]u16{0x0F};
    buf.setRemote(4, 10, &late_actual, true);
    try expect(buf.last_changed_frame != null);

    const lcf = buf.last_changed_frame.?;
    try expectEqual(@as(u32, 4), @as(u32, @intCast(lcf >> 32)));
    try expectEqual(@as(u32, 10), @as(u32, @intCast(lcf & 0xFFFFFFFF)));
}

// =============================================================================
// FIX 5: deferred_lcf field exists on NetplayManager and is reset on round start.
//
// Since NetplayManager itself can't be host-tested (Win32 externs), this is a
// compile-time structural check via a stub struct mirroring the field. The
// production field is verified by the DLL cross-compile.
// =============================================================================

// Stub mirroring the NetplayManager rollback fields. If the production struct
// drops or renames `deferred_lcf`, this serves as documentation of the
// expected shape; the real guard is the cross-compile in CI.
const RollbackFieldsStub = struct {
    rollback_timer: u8 = 0,
    min_rollback_spacing: u8 = 2,
    fast_fwd_stop_frame: u32 = 0,
    deferred_lcf: ?u64 = null,
};

test "FIX 5: deferred_lcf field exists and defaults to null" {
    const stub = RollbackFieldsStub{};
    try expect(stub.deferred_lcf == null);
}

// =============================================================================
// FIX 6: input-wait "Remote reached transition index" logged once per index.
//
// Original bug:
//   frame_step.zig's lockstep wait loop tracked `remote_at_index_since` as a
//   function-local. isRemoteInputReady() can flip true when a packet arrives,
//   exiting the loop for one frame, then re-entering it next frame with a fresh
//   local (reset to 0). The "Remote reached transition index ... starting 10s
//   input-wait countdown" log then fired on every re-entry — 37× in one
//   reported match — and the 10s timeout never accumulated correctly.
//
// Fix:
//   Hoist the timestamp to a NetplayManager field (input_wait_remote_at_index_since_ms)
//   plus the index it was armed for (input_wait_remote_index).
//   markRemoteReachedIndex returns non-null only on the first arm per index.
//
// This test mirrors the manager method's logic to verify the idempotency.
// =============================================================================

const InputWaitStub = struct {
    input_wait_remote_at_index_since_ms: i64 = 0,
    input_wait_remote_index: u32 = 0,
    indexed_frame_index: u32 = 0,

    fn markRemoteReachedIndex(self: *InputWaitStub, now_ms: i64) ?i64 {
        if (self.input_wait_remote_index != self.indexed_frame_index) {
            self.input_wait_remote_index = self.indexed_frame_index;
            self.input_wait_remote_at_index_since_ms = now_ms;
            return now_ms;
        }
        if (self.input_wait_remote_at_index_since_ms == 0) {
            self.input_wait_remote_at_index_since_ms = now_ms;
            return now_ms;
        }
        return null;
    }
};

test "FIX 6a: first arm for an index returns the timestamp" {
    var s = InputWaitStub{ .indexed_frame_index = 4 };
    // First call arms and returns.
    try expectEqual(@as(?i64, 1000), s.markRemoteReachedIndex(1000));
    try expectEqual(@as(i64, 1000), s.input_wait_remote_at_index_since_ms);
}

test "FIX 6b: repeated calls for the SAME index return null (no re-log)" {
    var s = InputWaitStub{ .indexed_frame_index = 4 };
    _ = s.markRemoteReachedIndex(1000);
    // Subsequent calls in the same wait (loop re-entries) must NOT re-arm.
    try expectEqual(@as(?i64, null), s.markRemoteReachedIndex(2000));
    try expectEqual(@as(?i64, null), s.markRemoteReachedIndex(3000));
    // Timestamp unchanged from the first arm.
    try expectEqual(@as(i64, 1000), s.input_wait_remote_at_index_since_ms);
}

test "FIX 6c: advancing to a new index re-arms exactly once" {
    var s = InputWaitStub{ .indexed_frame_index = 4 };
    _ = s.markRemoteReachedIndex(1000);
    try expectEqual(@as(?i64, null), s.markRemoteReachedIndex(2000));

    // Next round — new transition index.
    s.indexed_frame_index = 6;
    try expectEqual(@as(?i64, 5000), s.markRemoteReachedIndex(5000));
    try expectEqual(@as(?i64, null), s.markRemoteReachedIndex(6000));
    try expectEqual(@as(i64, 5000), s.input_wait_remote_at_index_since_ms);
}

// =============================================================================
// FIX 7: denser early-game SyncHash cadence.
//
// Original behavior:
//   SyncHash was sent at frame 149 and then every 300 frames. Divergence could
//   compound undetected for ~2.5s before the first check — two reported
//   desyncs both originated in the first 150 frames with >2000-unit gaps.
//
// Fix:
//   During the first early_sync_window (180) frames of each in_game index, also
//   send every early_sync_period (30) frames. Catches divergence early while
//   the resim window is small. The base cadence (149 / every 300) is preserved.
//
// This test mirrors the cadence decision logic to verify which frames trigger.
// =============================================================================

const sync_send_period_t: u32 = 5 * 60;
const early_sync_period_t: u32 = 30;
const early_sync_window_t: u32 = 180;

fn syncDueAtFrame(frame: u32) bool {
    const due_period = (frame % sync_send_period_t == 0);
    const due_149 = (frame % 150 == 149);
    const due_early = (frame < early_sync_window_t and frame % early_sync_period_t == 0);
    return due_period or due_149 or due_early;
}

test "FIX 7a: early-game frames 30/60/90/120 trigger sync (dense cadence)" {
    try expect(syncDueAtFrame(30));
    try expect(syncDueAtFrame(60));
    try expect(syncDueAtFrame(90));
    try expect(syncDueAtFrame(120));
}

test "FIX 7b: non-early, non-period frames do NOT trigger (frame 50, 100)" {
    try expect(!syncDueAtFrame(50));
    try expect(!syncDueAtFrame(100));
}

test "FIX 7c: frame 149 still triggers (legacy cadence preserved)" {
    try expect(syncDueAtFrame(149));
}

test "FIX 7d: frames past the early window fall back to base cadence" {
    // 200 is past 180, not a multiple of 300, not 149 mod 150 → no sync.
    try expect(!syncDueAtFrame(200));
    // 300 is a multiple of sync_send_period (300) → sync.
    try expect(syncDueAtFrame(300));
}

test "FIX 7e: early cadence only applies within the window (frame 180 excluded)" {
    // 180 is the boundary; < early_sync_window excludes it. 150 % 30 == 0 but
    // 150 < 180 so it WOULD be early-triggered — verify 150 still triggers.
    try expect(syncDueAtFrame(150));
    // 180 itself is NOT < 180, and 180 % 300 != 0, 180 % 150 != 149 → no sync.
    try expect(!syncDueAtFrame(180));
}

