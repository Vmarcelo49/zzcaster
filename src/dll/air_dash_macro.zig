// air_dash_macro.zig — optional "Air Dash Macro" input transformation.
//
// Detects `9AB` (up-forward + A+B) or `7AB` (up-back + A+B) and expands it
// into a 2-frame sequence: jump on frame N, air-dash on frame N+1. This lets
// players who can't reliably hit the 1-frame jump→dash window perform the
// air-dash off a single button press.
//
// The macro is a pure, stateless-except-for-its-own-machine transform on a
// `u16` input. It knows nothing about frames, the InputBuffer, netplay, or
// rollback. Callers feed it the post-state-filter local input each frame and
// store whatever it returns. Because the expanded sequence is what enters the
// InputBuffer, it is automatically what gets sent over the network and what a
// rollback re-run replays — no rollback-awareness is required here.
//
// State machine:
//
//   IDLE ──9AB/7AB──► PENDING (emit jump direction only) ──next frame──► IDLE
//                                                             (emit dash)
//
// Per design doc §4.3 and §6: once the macro commits to a sequence on frame N,
// the frame-N+1 dash is emitted regardless of what the player presses that
// frame (the jump already happened; the dash must follow). Holding 9AB across
// multiple frames produces alternating jump/dash cycles. The macro only fires
// on A+B with no other buttons held and only for diagonals 9/7 (8AB / 6AB do
// not trigger it).
//
// Input encoding (combined u16 = dir | (btns << 4)):
//   dir nibble (bits 0-3): numpad notation (9=up-right, 7=up-left, ...)
//   btns (bits 4-15): A=0x0010, B=0x0020, AB=0x0040  → in the combined u16
//                     these land at 0x0100 / 0x0200 / 0x0400.
//   9AB = 0x0709, 7AB = 0x0707, 6AB = 0x0706, 4AB = 0x0704.
const std = @import("std");

const MacroState = enum {
    idle, // waiting for 9AB / 7AB
    pending, // jump emitted last frame; inject the dash this frame
};

/// Result of a single `step` call. `triggered` is true only on the frame where
/// the macro detects 9AB/7AB and starts a sequence — callers log it for
/// debugging desync reports (design doc §5.5). The frame-N+1 dash emission is
/// not a "trigger" (it's the committed tail of the previous trigger), so
/// `triggered` is false there.
pub const StepResult = struct {
    output: u16,
    triggered: bool,
};

/// Button-bit mask for A | B | AB in the 12-bit btns field. Used both to detect
/// the trigger and to build the dash output.
const ab_buttons: u16 = 0x0070; // button_a (0x0010) | button_b (0x0020) | button_ab (0x0040)

pub const AirDashMacro = struct {
    /// Master switch. When false, `step` is a pure passthrough. Loaded from the
    /// per-player `air_dash_macro` field in ControllerMapping (mapping.ini).
    enabled: bool = false,
    state: MacroState = .idle,
    /// Dash direction to inject on the frame after a trigger (6 after 9AB,
    /// 4 after 7AB). Only meaningful while `state == .pending`.
    dash_dir: u8 = 0,

    /// Clear the state machine. Called on round transitions and whenever the
    /// game leaves the in-game state, so a pending dash from the end of one
    /// round can't leak into the first frame of the next (design doc §6.6).
    pub fn reset(self: *AirDashMacro) void {
        self.state = .idle;
        self.dash_dir = 0;
    }

    /// Advance the state machine by one frame.
    ///
    /// `raw_input` is the post-state-filter local input (i.e. after
    /// `getNetplayInput`). The returned `output` is what should be stored in
    /// the InputBuffer / written to game memory for THIS frame.
    pub fn step(self: *AirDashMacro, raw_input: u16) StepResult {
        if (!self.enabled) return .{ .output = raw_input, .triggered = false };

        // If we committed to a sequence last frame, the dash must fire now no
        // matter what the player is currently pressing — the jump already
        // happened, so the input the game saw last frame is inconsistent with
        // anything other than completing the dash (design doc §6.2).
        if (self.state == .pending) {
            const dash_input: u16 = @as(u16, self.dash_dir) | (ab_buttons << 4);
            self.state = .idle;
            self.dash_dir = 0;
            return .{ .output = dash_input, .triggered = false };
        }

        // IDLE: look for the trigger. Extract dir (low nibble) and the 12-bit
        // button field. `has_ab` accepts either the dedicated AB macro button
        // (0x0040) or A+B pressed simultaneously (0x0010 | 0x0020). We also
        // require that no button OTHER than A/B/AB is held — otherwise a
        // 9AB+C or 9AB+D press (which the game may interpret differently)
        // would be silently rewritten. SOCD has already been resolved upstream
        // so dir is a clean numpad value.
        const dir: u8 = @intCast(raw_input & 0x0F);
        const btns: u16 = (raw_input >> 4) & 0x0FFF;
        const has_ab = (btns & 0x0040 != 0) or (btns & 0x0030 == 0x0030);
        const other_buttons = btns & ~ab_buttons;

        if (has_ab and (dir == 9 or dir == 7) and other_buttons == 0) {
            self.state = .pending;
            self.dash_dir = if (dir == 9) 6 else 4;
            // Frame N: just the jump direction, no buttons. Emitting the bare
            // diagonal here (rather than e.g. 9AB) is what makes the next
            // frame's dash a true air-dash: the game sees the character leave
            // the ground on frame N, then reads a forward/back dash on frame
            // N+1 while airborne.
            return .{ .output = @as(u16, dir), .triggered = true };
        }

        return .{ .output = raw_input, .triggered = false };
    }
};

// ============================================================================
// Tests — host-runnable (this module imports only std). Wired into
// `zig build test` via build.zig's air_dash_macro_test module.
// ============================================================================

const testing = std.testing;

/// 9AB in the combined u16 encoding: dir=9, btns=A|B|AB=0x0070 → 0x0709.
const input_9ab: u16 = 0x0709;
const input_7ab: u16 = 0x0707;
const input_6ab: u16 = 0x0706;
const input_8ab: u16 = 0x0708;
const neutral: u16 = 0x0000;

/// dir | (A|B|AB << 4) — what the macro emits for the dash frame.
fn dashWithDir(dir: u8) u16 {
    return @as(u16, dir) | (ab_buttons << 4);
}

test "disabled macro is a pure passthrough" {
    var m: AirDashMacro = .{ .enabled = false };
    // Same input, same output, no trigger — even for a would-be trigger.
    try testing.expectEqual(@as(u16, 0x0709), m.step(input_9ab).output);
    try testing.expectEqual(false, m.step(input_9ab).triggered);
    // And it stays idle, so enabling later starts from a clean slate.
    try testing.expectEqual(MacroState.idle, m.state);
}

test "9AB expands to jump (frame N) then forward dash (frame N+1)" {
    var m: AirDashMacro = .{ .enabled = true };

    // Frame N: trigger fires, emit just the jump diagonal.
    const r0 = m.step(input_9ab);
    try testing.expectEqual(@as(u16, 9), r0.output);
    try testing.expectEqual(true, r0.triggered);
    try testing.expectEqual(MacroState.pending, m.state);

    // Frame N+1: committed dash, regardless of current input.
    const r1 = m.step(neutral);
    try testing.expectEqual(dashWithDir(6), r1.output);
    try testing.expectEqual(false, r1.triggered);
    try testing.expectEqual(MacroState.idle, m.state);
}

test "7AB expands to jump (frame N) then back dash (frame N+1)" {
    var m: AirDashMacro = .{ .enabled = true };

    const r0 = m.step(input_7ab);
    try testing.expectEqual(@as(u16, 7), r0.output);
    try testing.expectEqual(true, r0.triggered);

    const r1 = m.step(neutral);
    try testing.expectEqual(dashWithDir(4), r1.output);
    try testing.expectEqual(false, r1.triggered);
}

test "dash fires on frame N+1 even if buttons released" {
    // Design doc §6.2: the macro commits to the dash on frame N+1 regardless
    // of whether the player is still holding the buttons.
    var m: AirDashMacro = .{ .enabled = true };
    _ = m.step(input_9ab);
    // Player releases everything on frame N+1.
    const r = m.step(neutral);
    try testing.expectEqual(dashWithDir(6), r.output);
}

test "direction change mid-sequence is ignored" {
    // Design doc §6.3: pressing 7AB on frame N+1 (while committed to a forward
    // dash from a frame-N 9AB) does NOT switch the dash to back-dash. The
    // 7AB is consumed as the committed forward dash; the player would have to
    // press 7AB again on frame N+2 (once idle) to start a back-dash sequence.
    var m: AirDashMacro = .{ .enabled = true };
    _ = m.step(input_9ab);
    const r = m.step(input_7ab);
    try testing.expectEqual(dashWithDir(6), r.output);
    try testing.expectEqual(MacroState.idle, m.state);
}

test "holding 9AB produces alternating jump/dash cycles" {
    // Design doc §6.1: holding 9AB triggers a new sequence every other frame.
    var m: AirDashMacro = .{ .enabled = true };

    // Frame 0: trigger, jump.
    try testing.expectEqual(@as(u16, 9), m.step(input_9ab).output);
    // Frame 1: committed dash.
    try testing.expectEqual(dashWithDir(6), m.step(input_9ab).output);
    // Frame 2: still holding → NEW trigger, jump again.
    const r2 = m.step(input_9ab);
    try testing.expectEqual(@as(u16, 9), r2.output);
    try testing.expectEqual(true, r2.triggered);
    // Frame 3: committed dash again.
    try testing.expectEqual(dashWithDir(6), m.step(input_9ab).output);
}

test "non-AB buttons do not trigger the macro" {
    // 9ABC (C also held): btns = A|B|AB|C = 0x0078 → other_buttons != 0,
    // so the macro must NOT fire. The input passes through unchanged.
    var m: AirDashMacro = .{ .enabled = true };
    const input_9abc: u16 = 9 | ((0x0070 | 0x0008) << 4); // dir=9, btns=A|B|AB|C
    const r = m.step(input_9abc);
    try testing.expectEqual(input_9abc, r.output);
    try testing.expectEqual(false, r.triggered);
    try testing.expectEqual(MacroState.idle, m.state);
}

test "8AB and 6AB do not trigger the macro" {
    // Only diagonals 9 and 7 trigger. Straight-up or forward + AB pass through.
    var m: AirDashMacro = .{ .enabled = true };

    const r8 = m.step(input_8ab);
    try testing.expectEqual(input_8ab, r8.output);
    try testing.expectEqual(false, r8.triggered);

    const r6 = m.step(input_6ab);
    try testing.expectEqual(input_6ab, r6.output);
    try testing.expectEqual(false, r6.triggered);
}

test "A+B pressed simultaneously triggers the macro (not just the AB button)" {
    // Some controllers have no dedicated AB button; players press A and B
    // together. btns = A|B = 0x0030 → combined 0x0309. has_ab accepts this.
    var m: AirDashMacro = .{ .enabled = true };
    const input_9_a_plus_b: u16 = 9 | (0x0030 << 4); // dir=9, btns=A|B (no AB bit)

    const r0 = m.step(input_9_a_plus_b);
    try testing.expectEqual(@as(u16, 9), r0.output);
    try testing.expectEqual(true, r0.triggered);

    const r1 = m.step(neutral);
    try testing.expectEqual(dashWithDir(6), r1.output);
}

test "reset clears a pending dash" {
    // Design doc §6.6: a pending dash must not survive a round transition.
    var m: AirDashMacro = .{ .enabled = true };
    _ = m.step(input_9ab);
    try testing.expectEqual(MacroState.pending, m.state);

    m.reset();
    try testing.expectEqual(MacroState.idle, m.state);
    try testing.expectEqual(@as(u8, 0), m.dash_dir);

    // After reset, the next frame is treated as a fresh IDLE frame — no
    // spurious dash from the pre-reset trigger.
    const r = m.step(neutral);
    try testing.expectEqual(neutral, r.output);
    try testing.expectEqual(false, r.triggered);
}

test "reset while idle is a no-op" {
    var m: AirDashMacro = .{ .enabled = true };
    m.reset();
    try testing.expectEqual(MacroState.idle, m.state);

    // Sequence still works normally after an idle reset.
    const r0 = m.step(input_7ab);
    try testing.expectEqual(@as(u16, 7), r0.output);
    try testing.expectEqual(true, r0.triggered);
}
