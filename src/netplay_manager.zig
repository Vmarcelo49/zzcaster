// Port of the rollback-relevant parts of CCCaster's `NetplayManager`
// (targets/DllNetplayManager.hpp + .cpp).
//
// CCCaster's NetplayManager is a large class that handles the full netplay
// FSM: state transitions, input delay, RNG sync, retry-menu sync, spectate
// start indices, replay export, etc. This port keeps ONLY the pieces that
// the rollback subsystem directly exercises:
//
//   - The NetplayState field + accessors (_state, getState, setState).
//   - The indexed-frame bookkeeping (_indexedFrame, _startWorldTime,
//     updateFrame, getFrame, getIndex).
//   - The NetplayConfig + the delay/rollback accessors (getDelay,
//     getRollbackDelay, isInRollback, isInGame).
//   - The two input containers (_inputs[0..2]) and the input setters/getters
//     (getRawInput, setInput, setInputs, getBothInputs) — including the
//     `checkStartingFromIndex` flag that drives `_lastChangedFrame`.
//   - isRemoteInputReady (the lockstep gate).
//   - clearLastChangedFrame / getLastChangedFrame.
//
// Everything else (chara-select menu navigation, retry-menu sync, RNG sync,
// spectate, replay export) is intentionally omitted — this is a focused
// port of the rollback subsystem, not a full netplay reimplementation.

const std = @import("std");
const constants = @import("constants.zig");
const IndexedFrame = @import("indexed_frame.zig").IndexedFrame;
const NetplayState = @import("netplay_state.zig").NetplayState;
const inputs_container = @import("inputs_container.zig");
const InputsContainer = inputs_container.InputsContainer;

pub const num_inputs: u32 = constants.num_inputs;

pub const NetplayManager = struct {
    allocator: std.mem.Allocator,

    // --- Config ----------------------------------------------------------
    config: constants.NetplayConfig = .{},

    // --- FSM state -------------------------------------------------------
    /// Current netplay state. CCCaster: `_state`.
    state: NetplayState = .unknown,
    /// `CC_WORLD_TIMER_ADDR` value at the start of the current transition
    /// index. `frame = world_timer - start_world_time`. CCCaster: `_startWorldTime`.
    start_world_time: u32 = 0,
    /// Current (index, frame). CCCaster: `_indexedFrame`.
    indexed_frame: IndexedFrame = .{},
    /// The starting transition index for inputs. Older indices are erased
    /// when we enter Loading. CCCaster: `_startIndex`.
    start_index: u32 = 0,

    // --- Inputs ----------------------------------------------------------
    /// Two input containers, one per player. CCCaster: `_inputs[2]`.
    /// Index 0 = player 1, index 1 = player 2.
    inputs: [2]InputsContainer(u16),

    /// Which player is local (1 or 2). CCCaster: `_localPlayer`.
    local_player: u8 = 1,
    /// Which player is remote (1 or 2). CCCaster: `_remotePlayer`.
    remote_player: u8 = 2,

    // --- World-timer hook ------------------------------------------------
    /// Callback the host sets to read `*CC_WORLD_TIMER_ADDR`. On Windows this
    /// dereferences the live address; in tests it reads from a mock.
    read_world_timer: *const fn () u32 = defaultReadWorldTimer,

    // --- State transition bookkeeping (matches CCCaster setState) ---------
    /// IndexedFrame of the most recent transition. Used by setState to know
    /// whether to increment the index (any transition past CharaSelect) or
    /// reset to the initial index (AutoCharaSelect → CharaSelect).
    spectate_start_index: u32 = 0,
    /// Internal fields that setState touches (kept private to match CCCaster).
    _local_retry_menu_index: i8 = -1,
    _remote_retry_menu_index: i8 = -1,

    pub fn init(allocator: std.mem.Allocator) NetplayManager {
        return .{
            .allocator = allocator,
            .inputs = .{
                InputsContainer(u16).init(allocator),
                InputsContainer(u16).init(allocator),
            },
        };
    }

    pub fn deinit(self: *NetplayManager) void {
        for (&self.inputs) |*c| c.deinit();
    }

    // ---- frame / index accessors ----------------------------------------

    pub fn getFrame(self: *const NetplayManager) u32 {
        return self.indexed_frame.frame();
    }

    pub fn getIndex(self: *const NetplayManager) u32 {
        return self.indexed_frame.index();
    }

    pub fn getIndexedFrame(self: *const NetplayManager) IndexedFrame {
        return self.indexed_frame;
    }

    /// `frame = *CC_WORLD_TIMER_ADDR - start_world_time`. Matches CCCaster's
    /// `updateFrame()`.
    pub fn updateFrame(self: *NetplayManager) void {
        self.indexed_frame.setFrame(self.read_world_timer() -% self.start_world_time);
    }

    pub fn getRemoteFrame(self: *const NetplayManager) u32 {
        return self.inputs[self.remote_player - 1].getEndFrameAt(self.getIndex() - self.start_index);
    }

    pub fn getRemoteIndex(self: *const NetplayManager) u32 {
        const end = self.inputs[self.remote_player - 1].getEndIndex();
        if (end == 0) return 0;
        return self.start_index + end - 1;
    }

    pub fn getRemoteFrameDelta(self: *const NetplayManager) i32 {
        if (self.getIndex() == self.getRemoteIndex())
            return @as(i32, @intCast(self.getFrame())) - @as(i32, @intCast(self.getRemoteFrame() + self.config.delay - self.config.rollback_delay));
        return 0;
    }

    // ---- state queries --------------------------------------------------

    pub fn getState(self: *const NetplayManager) NetplayState {
        return self.state;
    }

    pub fn isInGame(self: *const NetplayManager) bool {
        return self.state == .in_game;
    }

    /// Matches CCCaster's `isInRollback()`:
    ///   return isInGame() && config.rollback && config.mode.isNetplay();
    pub fn isInRollback(self: *const NetplayManager) bool {
        return self.isInGame() and self.config.rollback > 0 and self.config.is_netplay;
    }

    /// Matches CCCaster's `getDelay()`:
    ///   return ( isInRollback() ? config.rollbackDelay : config.delay );
    pub fn getDelay(self: *const NetplayManager) u8 {
        return if (self.isInRollback()) self.config.rollback_delay else self.config.delay;
    }

    pub fn getRollbackDelay(self: *const NetplayManager) u8 {
        return self.config.rollback_delay;
    }

    pub fn getRollback(self: *const NetplayManager) u8 {
        return self.config.rollback;
    }

    // ---- input accessors ------------------------------------------------

    /// Get the input at the current (index, frame). Matches `getRawInput(player)`.
    pub fn getRawInput(self: *const NetplayManager, player: u8) u16 {
        std.debug.assert(player == 1 or player == 2);
        std.debug.assert(self.getIndex() >= self.start_index);
        return self.inputs[player - 1].get(self.getIndex() - self.start_index, self.getFrame());
    }

    /// Get the input at a specific (index, frame). Matches `getRawInput(player, frame)`.
    pub fn getRawInputAt(self: *const NetplayManager, player: u8, frame: u32) u16 {
        std.debug.assert(player == 1 or player == 2);
        std.debug.assert(self.getIndex() >= self.start_index);
        return self.inputs[player - 1].get(self.getIndex() - self.start_index, frame);
    }

    /// Set the local input for the current frame. Matches CCCaster's
    /// `setInput(player, input)` (DllNetplayManager.cpp:825-841):
    ///   - isInRollback() → frame = getFrame() + rollbackDelay
    ///   - RetryMenu      → frame = getFrame()
    ///   - offline+split  → player 1: frame = getFrame() + delay
    ///                      player 2: frame = getFrame() + rollbackDelay
    ///   - else           → frame = getFrame() + delay
    pub fn setInput(self: *NetplayManager, player: u8, input: u16) void {
        std.debug.assert(player == 1 or player == 2);
        std.debug.assert(self.getIndex() >= self.start_index);
        const idx = self.getIndex() - self.start_index;
        if (self.isInRollback()) {
            self.inputs[player - 1].set(idx, self.getFrame() + self.config.rollback_delay, input);
        } else if (self.state == .retry_menu) {
            self.inputs[player - 1].set(idx, self.getFrame(), input);
        } else if (self.config.is_offline) {
            // split-delay offline mode: P1 uses delay, P2 uses rollbackDelay.
            const d: u8 = if (player == 1) self.config.delay else self.config.rollback_delay;
            self.inputs[player - 1].set(idx, self.getFrame() + d, input);
        } else {
            self.inputs[player - 1].set(idx, self.getFrame() + self.config.delay, input);
        }
    }

    /// Apply a batch of remote inputs. Matches CCCaster's
    /// `setInputs(player, PlayerInputs)` (DllNetplayManager.cpp:873-887):
    ///   - Drop if `index + 1 < getIndex()` (stale) or `index < startIndex`.
    ///   - `checkStartingFromIndex = isInRollback() ? getIndex() - startIndex : UINT_MAX`.
    ///   - `inputs[player-1].set(index - startIndex, startFrame, items, n, checkStartingFromIndex)`.
    pub fn setInputs(
        self: *NetplayManager,
        player: u8,
        index: u32,
        start_frame: u32,
        items: []const u16,
    ) void {
        std.debug.assert(player == 1 or player == 2);
        if (index + 1 < self.getIndex()) return;
        if (index < self.start_index) return;
        std.debug.assert(index >= self.start_index);
        const check_starting_from: u32 = if (self.isInRollback())
            self.getIndex() - self.start_index
        else
            std.math.maxInt(u32);
        self.inputs[player - 1].setBatch(
            index - self.start_index,
            start_frame,
            items,
            check_starting_from,
        );
    }

    // ---- last-changed-frame (rollback trigger) --------------------------

    pub fn getLastChangedFrame(self: *const NetplayManager) IndexedFrame {
        // CCCaster returns the remote player's container's _lastChangedFrame.
        // The two containers are independent; the remote one is what rollback
        // cares about (local inputs are always known).
        return self.inputs[self.remote_player - 1].getLastChangedFrame();
    }

    pub fn clearLastChangedFrame(self: *NetplayManager) void {
        self.inputs[self.remote_player - 1].clearLastChangedFrame();
    }

    // ---- lockstep gate --------------------------------------------------

    /// Matches CCCaster's `isRemoteInputReady()` (DllNetplayManager.cpp:974-1022).
    /// Returns true if we have enough remote input to simulate the current
    /// frame; false means the caller should wait for more packets.
    pub fn isRemoteInputReady(self: *const NetplayManager) bool {
        // CharaIntro / Loading / Skippable / RetryMenu / pre-CharaSelect →
        // run at our own pace; catch-up mash handles lag.
        if (@intFromEnum(self.state) < @intFromEnum(NetplayState.chara_select) or
            self.state == .skippable or
            self.state == .loading or
            self.state == .retry_menu or
            self.state == .chara_intro)
        {
            return true;
        }

        const remote = &self.inputs[self.remote_player - 1];
        if (remote.empty()) return false;
        std.debug.assert(remote.getEndIndex() >= 1);

        // If the remote index is behind our index, wait.
        if (self.start_index + remote.getEndIndex() - 1 < self.getIndex()) return false;

        // If the remote index is ahead, we're in an older state — no wait.
        if (self.start_index + remote.getEndIndex() - 1 > self.getIndex()) return true;

        // Same index — check if we have the frame we need.
        if (remote.getEndFrame() == 0) return false;
        std.debug.assert(remote.getEndFrame() >= 1);

        const max_frames_ahead: u32 = if (self.isInRollback()) self.config.rollback else 0;
        if (remote.getEndFrame() - 1 + max_frames_ahead < self.getFrame()) return false;

        return true;
    }

    // ---- state transitions ----------------------------------------------

    /// Transition to `new_state`. Matches the rollback-relevant parts of
    /// CCCaster's `setState(state)` (DllNetplayManager.cpp:660-769):
    ///   - Validate the transition (isValidNext); ignore if invalid.
    ///   - For transitions to CharaSelect or later: increment the index and
    ///     reset frame=0, capture startWorldTime = *CC_WORLD_TIMER_ADDR.
    ///   - For AutoCharaSelect → CharaSelect: reset to the initial index.
    ///   - For Loading: erase old indices if the buffered preserve start
    ///     index advanced.
    ///   - For InGame: mark inGameIndexes (omitted here — not rollback-critical).
    ///
    /// The full CCCaster setState also does menu/replay bookkeeping that this
    /// focused port doesn't need; we keep only the parts that affect rollback.
    pub fn setState(self: *NetplayManager, new_state: NetplayState) void {
        if (!NetplayState.isValidNext(self.state, new_state)) return;

        if (@intFromEnum(new_state) >= @intFromEnum(NetplayState.chara_select)) {
            if (self.state == .auto_chara_select) {
                // Spectate: start from the initial index and frame.
                self.start_world_time = 0;
                self.indexed_frame = .{};
            } else {
                // Increment the index, start counting frames from 0.
                self.indexed_frame.setIndex(self.indexed_frame.index() + 1);
                self.start_world_time = self.read_world_timer();
                self.indexed_frame.setFrame(0);
            }
            if (new_state == .chara_select) self.spectate_start_index = self.getIndex();
            if (new_state == .loading) {
                self.spectate_start_index = self.getIndex();
                // Erase old indices (preserveStartIndex logic omitted — we
                // keep all indices, which is safe for the rollback port).
                self._local_retry_menu_index = -1;
                self._remote_retry_menu_index = -1;
            }
        }

        self.state = new_state;
    }
};

// Default world-timer reader — returns 0. The host (the real DLL) overrides
// this with a function that dereferences CC_WORLD_TIMER_ADDR.
fn defaultReadWorldTimer() u32 {
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

var g_world_timer: u32 = 0;
fn mockWorldTimer() u32 {
    return g_world_timer;
}

test "setInput uses rollbackDelay during in_game with rollback" {
    var nm = NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.config = .{ .delay = 2, .rollback_delay = 0, .rollback = 4, .is_netplay = true };
    nm.state = .in_game;
    nm.indexed_frame = IndexedFrame.init(5, 4); // frame 5, index 4
    nm.start_index = 4;

    nm.setInput(1, 0x1234);

    // rollbackDelay = 0 → input lands at frame 5+0 = 5.
    try expectEqual(@as(u16, 0x1234), nm.inputs[0].get(0, 5));
}

test "setInput uses delay during chara_select" {
    var nm = NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.config = .{ .delay = 2, .rollback_delay = 0, .rollback = 4, .is_netplay = true };
    nm.state = .chara_select;
    nm.indexed_frame = IndexedFrame.init(5, 4);
    nm.start_index = 4;

    nm.setInput(1, 0x1234);

    // delay = 2 → input lands at frame 5+2 = 7.
    try expectEqual(@as(u16, 0x1234), nm.inputs[0].get(0, 7));
}

test "setInputs records last_changed_frame only when in rollback" {
    var nm = NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.config = .{ .delay = 0, .rollback_delay = 0, .rollback = 4, .is_netplay = true };
    nm.state = .in_game;
    nm.indexed_frame = IndexedFrame.init(5, 4);
    nm.start_index = 4;

    // Seed a predicted input at offset index 0 (absolute index 4), frame 3.
    nm.inputs[1].set(0, 3, 0x01);

    // Receive the actual remote input — frame 3 differs.
    const actual = [_]u16{0x09};
    nm.setInputs(2, 4, 3, &actual);

    // CCCaster stores the OFFSET index in lastChangedFrame (because setBatch
    // is called with `index - startIndex`). The rollback trigger compares
    // lcf.value < getIndexedFrame().value — both sides must be compared
    // consistently. CCCaster's loadState then takes the RELEASE front-fallback
    // because the offset lcf (0:3) is <= every saved absolute indexedFrame.
    const lcf = nm.getLastChangedFrame();
    try expectEqual(@as(u32, 0), lcf.index()); // offset index
    try expectEqual(@as(u32, 3), lcf.frame());
}

test "setInputs does NOT record changes when not in rollback" {
    var nm = NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.config = .{ .delay = 0, .rollback_delay = 0, .rollback = 0, .is_netplay = true };
    nm.state = .chara_select;
    nm.indexed_frame = IndexedFrame.init(5, 4);
    nm.start_index = 4;

    nm.inputs[1].set(0, 3, 0x01);
    const actual = [_]u16{0x09};
    nm.setInputs(2, 4, 3, &actual);

    // checkStartingFromIndex = UINT_MAX → no change recorded.
    try expectEqual(IndexedFrame.max_value.value, nm.getLastChangedFrame().value);
}

test "isRemoteInputReady blocks when remote is behind" {
    var nm = NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.config = .{ .delay = 0, .rollback_delay = 0, .rollback = 4, .is_netplay = true };
    nm.state = .in_game;
    nm.indexed_frame = IndexedFrame.init(10, 4);
    nm.start_index = 4;

    // Remote has only reached index 3 — we're at index 4. Must wait.
    const actual = [_]u16{ 0, 0, 0 };
    nm.setInputs(2, 3, 0, &actual);
    try expect(!nm.isRemoteInputReady());
}

test "isRemoteInputReady allows rollback frames ahead" {
    var nm = NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.config = .{ .delay = 0, .rollback_delay = 0, .rollback = 4, .is_netplay = true };
    nm.state = .in_game;
    nm.indexed_frame = IndexedFrame.init(10, 4);
    nm.start_index = 4;

    // Remote has reached index 4, frame 8. With rollback=4, max_frames_ahead=4.
    // needed = 10. (8 + 4) = 12 >= 10 → ready.
    const actual = [_]u16{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }; // 9 frames, endFrame = 9
    nm.setInputs(2, 4, 0, &actual);
    try expect(nm.isRemoteInputReady());
}

test "setState increments the index on each transition past CharaSelect" {
    var nm = NetplayManager.init(std.testing.allocator);
    defer nm.deinit();
    nm.read_world_timer = &mockWorldTimer;
    g_world_timer = 100;
    nm.state = .initial;
    nm.indexed_frame = IndexedFrame.init(5, 0);

    nm.setState(.chara_select);
    try expectEqual(@as(u32, 1), nm.getIndex());
    try expectEqual(@as(u32, 0), nm.getFrame());
    try expectEqual(@as(u32, 100), nm.start_world_time);

    g_world_timer = 200;
    nm.setState(.loading);
    try expectEqual(@as(u32, 2), nm.getIndex());
    try expectEqual(@as(u32, 200), nm.start_world_time);
}
