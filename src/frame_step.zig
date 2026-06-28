// Port of the rollback-trigger logic in CCCaster's `DllMain.cpp`
// (the `frameStepNormal` / `frameStepRerun` / `frameStep` functions,
// lines ~192-988).
//
// This is the per-frame driver that decides WHEN to save a state, WHEN to
// fire a rollback, and WHEN to re-run. The decision tree (faithful to
// CCCaster):
//
//   frameStep():
//     1. netMan.updateFrame() — recompute `frame = world_timer - start_world_time`.
//     2. If `fastFwdStopFrame.value != 0` → frameStepRerun() (we're inside a
//        rollback re-simulation; don't save states, just advance the frame
//        until we reach `fastFwdStopFrame`).
//     3. Else → frameStepNormal():
//        a. If isInGame() && getRollback() → saveState().  [only save in-game]
//        b. Clear lastChangedFrame (when rollbackTimer == minRollbackSpacing).
//        c. Wait loop: poll network until isRemoteInputReady() (or timeout).
//        d. Decrement rollbackTimer if it's below minRollbackSpacing.
//        e. If isInRollback() && rollbackTimer == minRollbackSpacing &&
//           getLastChangedFrame().value < getIndexedFrame().value → fire
//           rollback: set fastFwdStopFrame, loadState(getLastChangedFrame()),
//           clearLastChangedFrame(), --rollbackTimer, return.
//
// The actual network polling / input-reading / rendering is the host's job —
// this port exposes the decision logic as pure functions the host calls.

const std = @import("std");
const constants = @import("constants.zig");
const IndexedFrame = @import("indexed_frame.zig").IndexedFrame;
const NetplayState = @import("netplay_state.zig").NetplayState;
const nm_mod = @import("netplay_manager.zig");
const rm_mod = @import("rollback_manager.zig");

pub const FrameStep = struct {
    /// The frame we're re-running toward. 0 = not currently re-running.
    /// Matches CCCaster's `fastFwdStopFrame`.
    fast_fwd_stop_frame: IndexedFrame = .{ .value = 0 },

    /// Cooldown between rollbacks. CCCaster: `int rollbackTimer = 0`.
    /// Starts at 0; set to `min_rollback_spacing` after a rollback fires;
    /// decrements each frame until it reaches `min_rollback_spacing` again.
    rollback_timer: i32 = 0,

    /// Minimum frames that must run normally before another rollback.
    /// CCCaster: `uint8_t minRollbackSpacing = 2`, clamped to [2, 4] based on
    /// `config.rollback` (DllMain.cpp:674).
    min_rollback_spacing: u8 = 2,

    pub fn init() FrameStep {
        return .{};
    }

    /// True when we're inside a rollback re-simulation.
    /// Matches `fastFwdStopFrame.value != 0`.
    pub fn isRerunning(self: *const FrameStep) bool {
        return self.fast_fwd_stop_frame.value != 0;
    }

    /// Set the min-rollback-spacing based on the configured rollback depth.
    /// Matches DllMain.cpp:674: `minRollbackSpacing = clamped<uint8_t>(rollback, 2, 4)`.
    pub fn configureForRollback(self: *FrameStep, rollback: u8) void {
        self.min_rollback_spacing = clamp(u8, rollback, 2, 4);
        self.rollback_timer = self.min_rollback_spacing;
    }

    /// Per-frame update of the rollback timer. Matches DllMain.cpp:583-588:
    ///   if ( rollbackTimer < minRollbackSpacing ) {
    ///       --rollbackTimer;
    ///       if ( rollbackTimer < 0 ) rollbackTimer = minRollbackSpacing;
    ///   }
    pub fn tickTimer(self: *FrameStep) void {
        if (self.rollback_timer < self.min_rollback_spacing) {
            self.rollback_timer -= 1;
            if (self.rollback_timer < 0) self.rollback_timer = self.min_rollback_spacing;
        }
    }

    /// Should we save a state this frame? Matches DllMain.cpp:204-207:
    ///   case InGame:
    ///       if ( netMan.getRollback() )
    ///           rollMan.saveState ( netMan );
    /// (Only save states in-game, and only if rollback is configured.)
    pub fn shouldSaveState(self: *const FrameStep, nm: *const nm_mod.NetplayManager) bool {
        _ = self;
        return nm.isInGame() and nm.getRollback() > 0;
    }

    /// Should we clear lastChangedFrame this frame? Matches DllMain.cpp:536-538:
    ///   if ( rollbackTimer == minRollbackSpacing )
    ///       netMan.clearLastChangedFrame();
    /// (Only clear when the timer is full — i.e. we're ready to fire a new
    /// rollback. This prevents stale lcfs from a previous frame's setRemote
    /// from triggering a late spurious rollback.)
    pub fn shouldClearLastChanged(self: *const FrameStep) bool {
        return self.rollback_timer == self.min_rollback_spacing;
    }

    /// Should we fire a rollback this frame? Matches DllMain.cpp:591-621:
    ///   if ( netMan.isInRollback()
    ///           && rollbackTimer == minRollbackSpacing
    ///           && netMan.getLastChangedFrame().value < netMan.getIndexedFrame().value )
    pub fn shouldFireRollback(self: *const FrameStep, nm: *const nm_mod.NetplayManager) bool {
        if (!nm.isInRollback()) return false;
        if (self.rollback_timer != self.min_rollback_spacing) return false;
        return nm.getLastChangedFrame().value < nm.getIndexedFrame().value;
    }

    /// Fire a rollback. Returns true if the rollback was triggered (state
    /// loaded, re-run armed); false if loadState failed. The host is
    /// responsible for setting CC_SKIP_FRAMES_ADDR = 1 after a successful
    /// rollback (DllMain.cpp:608).
    ///
    /// `write_byte` writes a byte to a 32-bit MBAACC address (for loadState's
    /// memory restore). `sfx_filter_array` is AsmHacks::sfxFilterArray.
    /// `reproll_tbl_endptr` is `*(void**)CC_REPROUND_TBL_ENDPTR_ADDR`.
    pub fn fireRollback(
        self: *FrameStep,
        nm: *nm_mod.NetplayManager,
        rm: *rm_mod.RollbackManager,
        write_byte: *const fn (addr: usize, b: u8) void,
        read_byte: *const fn (addr: usize) u8,
        sfx_filter_array: []u8,
        reproll_tbl_endptr: ?*rm_mod.RepRound,
    ) bool {
        const target = nm.getLastChangedFrame();
        const orig_frame = nm.getFrame();

        // Arm the re-run: fastFwdStopFrame = current indexed frame.
        self.fast_fwd_stop_frame = nm.getIndexedFrame();

        // Build the NetManSnapshot for loadState to restore into.
        const snap = rm_mod.NetManSnapshot{
            .state = &nm.state,
            .start_world_time = &nm.start_world_time,
            .indexed_frame = &nm.indexed_frame,
        };
        const ok = rm.loadState(target, snap, write_byte, read_byte, sfx_filter_array, reproll_tbl_endptr, orig_frame);
        if (!ok) {
            // loadState failed — DON'T clear lcf; retry next frame.
            // (DllMain.cpp:620 logs "Rollback to target failed!")
            self.fast_fwd_stop_frame = .{ .value = 0 };
            return false;
        }

        // Success — clear the lcf and decrement the timer.
        nm.clearLastChangedFrame();
        self.rollback_timer -= 1;
        return true;
    }

    /// Re-run step. Matches DllMain.cpp:921-955 (frameStepRerun):
    ///   - Don't save any states while re-running ("the inputs are faked").
    ///   - saveRerunSounds(getFrame()).
    ///   - If getIndexedFrame() >= fastFwdStopFrame → stop re-running
    ///     (fastFwdStopFrame = 0, re-enable rendering, finishedRerunSounds()).
    ///   - Else → keep skipping rendering.
    ///
    /// Returns true when the re-run is COMPLETE this frame (caller should
    /// fall through to normal frame logic next frame); false when the re-run
    /// is still in progress (caller should return immediately).
    pub fn stepRerun(
        self: *FrameStep,
        nm: *nm_mod.NetplayManager,
        rm: *rm_mod.RollbackManager,
        sfx_filter_array: []const u8,
        sfx_array: []u8,
        sfx_mute_array: []u8,
    ) bool {
        // Save sound state during the re-run.
        rm.saveRerunSounds(nm.getFrame(), sfx_filter_array);

        if (nm.getIndexedFrame().value >= self.fast_fwd_stop_frame.value) {
            // Reached the target frame — stop re-running.
            self.fast_fwd_stop_frame = .{ .value = 0 };
            rm.finishedRerunSounds(sfx_array, sfx_mute_array, @constCast(sfx_filter_array));
            return true; // re-run complete
        }
        return false; // still re-running
    }

    /// Manually set the intro-state to 0 during a rollback re-run that has
    /// advanced past CC_PRE_GAME_INTRO_FRAMES. Matches DllMain.cpp:974-976:
    ///   if ( isInRollback() && getFrame() > CC_PRE_GAME_INTRO_FRAMES && *CC_INTRO_STATE_ADDR )
    ///       *CC_INTRO_STATE_ADDR = 0;
    pub fn maybeClearIntroState(
        self: *const FrameStep,
        nm: *const nm_mod.NetplayManager,
        read_intro_state: *const fn () u8,
        write_intro_state: *const fn (v: u8) void,
    ) void {
        _ = self;
        if (!nm.isInRollback()) return;
        if (nm.getFrame() <= constants.cc_pre_game_intro_frames) return;
        if (read_intro_state() == 0) return;
        write_intro_state(0);
    }
};

// ---- helpers --------------------------------------------------------------

fn clamp(comptime T: type, v: T, lo: T, hi: T) T {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

// ---------------------------------------------------------------------------
// Tests — a full rollback cycle (save → predict → misprediction → load → re-run).
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

var g_mem: [4096]u8 = [_]u8{0} ** 4096;
var g_world_timer: u32 = 0;
var g_intro_state: u8 = 0;

fn tRead(addr: usize) u8 {
    if (addr >= g_mem.len) return 0;
    return g_mem[addr];
}

fn tWrite(addr: usize, b: u8) void {
    if (addr >= g_mem.len) return;
    g_mem[addr] = b;
}

fn tWorldTimer() u32 {
    return g_world_timer;
}

fn tReadIntro() u8 {
    return g_intro_state;
}

fn tWriteIntro(v: u8) void {
    g_intro_state = v;
}

test "full rollback cycle: save → mispredict → load → re-run" {
    const alloc = std.testing.allocator;

    var nm = nm_mod.NetplayManager.init(alloc);
    defer nm.deinit();
    nm.read_world_timer = &tWorldTimer;
    nm.config = .{ .delay = 0, .rollback_delay = 0, .rollback = 4, .is_netplay = true };
    // Skip the FSM transition validation — go straight to in_game at index 4, frame 0.
    nm.state = .in_game;
    nm.indexed_frame = IndexedFrame.init(0, 4);
    nm.start_index = 4;
    nm.start_world_time = 0;

    var rm = rm_mod.RollbackManager.init(alloc);
    defer rm.deinit();
    // Build a tiny region table: 16 bytes at offset 0x100.
    // (addr=0 is treated as NULL by CCCaster's saveDump.)
    const region_addr: u32 = 0x100;
    var blob = std.ArrayList(u8).empty;
    defer blob.deinit(alloc);
    var b8: [8]u8 = undefined;
    var b4: [4]u8 = undefined;
    std.mem.writeInt(u64, &b8, 16, .little);
    try blob.appendSlice(alloc, &b8); // totalSize
    std.mem.writeInt(u64, &b8, 1, .little);
    try blob.appendSlice(alloc, &b8); // count
    std.mem.writeInt(u32, &b4, region_addr, .little);
    try blob.appendSlice(alloc, &b4); // addr
    std.mem.writeInt(u64, &b8, 16, .little);
    try blob.appendSlice(alloc, &b8); // size
    std.mem.writeInt(u64, &b8, 0, .little);
    try blob.appendSlice(alloc, &b8); // ptrs.len
    try rm.loadRegions(blob.items);
    try rm.allocateStates(8);

    var fs = FrameStep.init();
    fs.configureForRollback(4);

    var sfx_filter = [_]u8{0} ** 16;
    var sfx_array = [_]u8{0} ** 16;
    var sfx_mute = [_]u8{0} ** 16;

    // Frame 0: save a state. Seed memory with a known pattern.
    @memset(g_mem[region_addr .. region_addr + 16], 0xAA);
    g_world_timer = 0;
    nm.updateFrame();
    try expect(fs.shouldSaveState(&nm));
    rm.saveState(
        .{ .state = &nm.state, .start_world_time = &nm.start_world_time, .indexed_frame = &nm.indexed_frame },
        &tRead,
        &sfx_filter,
    );

    // Advance to frame 5, mutating memory along the way.
    g_world_timer = 5;
    nm.updateFrame();
    try expectEqual(@as(u32, 5), nm.getFrame());
    @memset(g_mem[region_addr .. region_addr + 16], 0xBB); // simulated gameplay mutation

    // Simulate a remote-input misprediction at frame 0.
    // We seed a predicted input at frame 0, then receive the actual (different).
    // CCCaster stores the OFFSET index in lastChangedFrame.
    nm.inputs[1].set(0, 0, 0x01); // remote player, offset 0, frame 0, predicted 0x01
    const actual = [_]u16{0x09}; // actual remote input differs
    nm.setInputs(2, 4, 0, &actual);

    // The misprediction should be recorded (offset index 0, frame 0).
    const lcf = nm.getLastChangedFrame();
    try expectEqual(@as(u32, 0), lcf.index());
    try expectEqual(@as(u32, 0), lcf.frame());

    // Tick the timer to full so the rollback can fire.
    while (fs.rollback_timer < fs.min_rollback_spacing) fs.tickTimer();

    try expect(fs.shouldFireRollback(&nm));

    // Fire the rollback — this loads the saved state (memory restored to 0xAA)
    // and arms the re-run.
    const fired = fs.fireRollback(&nm, &rm, &tWrite, &tRead, &sfx_filter, null);
    try expect(fired);
    try expect(fs.isRerunning());

    // Memory should be restored to the saved state (0xAA).
    try expectEqual(@as(u8, 0xAA), g_mem[region_addr + 0]);
    try expectEqual(@as(u8, 0xAA), g_mem[region_addr + 15]);

    // The indexed_frame should be rewound to the loaded state's frame (0).
    try expectEqual(@as(u32, 0), nm.getFrame());

    // Re-run: advance frames until we reach fast_fwd_stop_frame.
    // fast_fwd_stop_frame was set to the pre-rollback indexed_frame (5:4).
    var rerun_done = false;
    var frame_i: u32 = 0;
    while (frame_i < 10) : (frame_i += 1) {
        g_world_timer = frame_i;
        nm.updateFrame();
        if (fs.stepRerun(&nm, &rm, &sfx_filter, &sfx_array, &sfx_mute)) {
            rerun_done = true;
            break;
        }
    }
    try expect(rerun_done);
    try expect(!fs.isRerunning());
}

test "configureForRollback clamps min_rollback_spacing to [2, 4]" {
    var fs = FrameStep.init();
    fs.configureForRollback(1); // clamps to 2
    try expectEqual(@as(u8, 2), fs.min_rollback_spacing);
    fs.configureForRollback(8); // clamps to 4
    try expectEqual(@as(u8, 4), fs.min_rollback_spacing);
    fs.configureForRollback(3); // 3 is in range
    try expectEqual(@as(u8, 3), fs.min_rollback_spacing);
}

test "shouldFireRollback respects the timer" {
    var fs = FrameStep.init();
    fs.configureForRollback(4);
    var nm = nm_mod.NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.config = .{ .rollback = 4, .is_netplay = true };
    nm.state = .in_game;
    nm.indexed_frame = IndexedFrame.init(10, 4);
    nm.start_index = 4;
    nm.inputs[1].last_changed_frame = IndexedFrame.init(5, 4);

    // Timer is full (just configured) → should fire.
    try expect(fs.shouldFireRollback(&nm));

    // Decrement the timer → should NOT fire.
    fs.rollback_timer = 0;
    try expect(!fs.shouldFireRollback(&nm));
}

test "shouldFireRollback requires lcf < current indexed_frame" {
    var fs = FrameStep.init();
    fs.configureForRollback(4);
    var nm = nm_mod.NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.config = .{ .rollback = 4, .is_netplay = true };
    nm.state = .in_game;
    nm.indexed_frame = IndexedFrame.init(10, 4);
    nm.start_index = 4;

    // lcf at the same frame as current → no rollback.
    nm.inputs[1].last_changed_frame = IndexedFrame.init(10, 4);
    try expect(!fs.shouldFireRollback(&nm));

    // lcf in the future → no rollback.
    nm.inputs[1].last_changed_frame = IndexedFrame.init(15, 4);
    try expect(!fs.shouldFireRollback(&nm));

    // lcf in the past → rollback.
    nm.inputs[1].last_changed_frame = IndexedFrame.init(5, 4);
    try expect(fs.shouldFireRollback(&nm));
}
