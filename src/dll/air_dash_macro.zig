// air_dash_macro.zig — optional "Air Dash Macro" input transformation.
//
// Detects `9AB` (up-forward + A+B) or `7AB` (up-back + A+B) and expands it
// into a multi-frame sequence: jump on frame N, neutral during the jump's
// startup frames, then air-dash once the character is airborne. This lets
// players who can't reliably hit the jump→dash window perform an air-dash off
// a single button press.
//
// MBAACC jumps are not instantaneous: the character enters a startup phase
// (still grounded, in pre-jump animation) for `jump_startup_frames` frames
// before becoming airborne. An air-dash input during startup is ignored — the
// character isn't in the air yet. So the macro must wait out the startup
// before emitting the dash:
//
//   Frame N:                9     (jump input — enters startup)
//   Frame N+1 .. N+3:       0     (startup — 3 frames, character grounded)
//   Frame N+4:              6AB   (character airborne — air dash fires)
//
// For 7AB the dash direction is 4 instead of 6.
//
// The macro is a pure, stateless-except-for-its-own-machine transform on a
// `u16` input. It knows nothing about frames, the InputBuffer, netplay, or
// rollback. Callers feed it the post-state-filter local input each frame and
// store whatever it returns. Because the expanded sequence is what enters the
// InputBuffer, it is automatically what gets sent over the network and what a
// rollback re-run replays — no rollback-awareness is required here.
//
// Once the macro commits to a sequence (detects 9AB/7AB), the entire sequence
// plays out regardless of what the player presses in subsequent frames — the
// jump already happened on frame N, and the dash must follow on frame N+4.
// The player's input during the startup/neutral frames is overridden to
// neutral. Holding 9AB across multiple frames triggers a new sequence every
// `jump_startup_frames + 2` frames. The macro only fires on A+B with no other
// buttons held and only for diagonals 9/7 (8AB / 6AB do not trigger it).
//
// Input encoding (combined u16 = dir | (btns << 4)):
//   dir nibble (bits 0-3): numpad notation (9=up-right, 7=up-left, ...)
//   btns (bits 4-15): A=0x0010, B=0x0020, AB=0x0040  → in the combined u16
//                     these land at 0x0100 / 0x0200 / 0x0400.
//   9AB = 0x0709, 7AB = 0x0707, 6AB = 0x0706, 4AB = 0x0704.
const std = @import("std");

/// Number of startup frames a jump has before the character leaves the ground
/// and can air-dash. In MBAACC this is 3 — the jump input is registered on
/// frame N, the character is grounded for frames N+1..N+3, and becomes
/// airborne on frame N+4. Emitting the dash before frame N+4 would feed it
/// into the grounded startup where air-dashes are not accepted, so the dash
/// would silently fail.
const jump_startup_frames: u8 = 3;

const MacroState = enum {
    idle, // waiting for 9AB / 7AB
    startup, // jump emitted; counting down startup frames before the dash
};

/// Result of a single `step` call. `triggered` is true only on the frame where
/// the macro detects 9AB/7AB and starts a sequence — callers log it for
/// debugging desync reports (design doc §5.5). The subsequent neutral/ dash
/// emissions are the committed tail of that trigger, so `triggered` is false
/// there.
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
    /// Dash direction to inject after the startup countdown (6 after 9AB,
    /// 4 after 7AB). Only meaningful while `state == .startup`.
    dash_dir: u8 = 0,
    /// Frames remaining before the dash fires. Set to `jump_startup_frames`
    /// when a trigger is detected; counts down by 1 each frame. When it
    /// reaches 0 the next `step` emits the dash and returns to idle.
    startup_countdown: u8 = 0,

    /// Clear the state machine. Called on round transitions and whenever the
    /// game leaves the in-game state, so a pending sequence from the end of
    /// one round can't leak into the first frame of the next (design doc §6.6).
    pub fn reset(self: *AirDashMacro) void {
        self.state = .idle;
        self.dash_dir = 0;
        self.startup_countdown = 0;
    }

    /// Advance the state machine by one frame.
    ///
    /// `raw_input` is the post-state-filter local input (i.e. after
    /// `getNetplayInput`). The returned `output` is what should be stored in
    /// the InputBuffer / written to game memory for THIS frame.
    pub fn step(self: *AirDashMacro, raw_input: u16) StepResult {
        if (!self.enabled) return .{ .output = raw_input, .triggered = false };

        // STARTUP: we committed to a jump last frame (or are still counting
        // down). Emit neutral until the countdown expires, then fire the dash.
        // The player's input is overridden for the entire committed sequence —
        // the jump already happened on frame N, and the dash must follow on
        // frame N+4 regardless of what the player presses meanwhile.
        if (self.state == .startup) {
            if (self.startup_countdown > 0) {
                self.startup_countdown -= 1;
                return .{ .output = 0, .triggered = false };
            }
            // Countdown expired — the character is now airborne. Emit the dash.
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
            self.state = .startup;
            self.dash_dir = if (dir == 9) 6 else 4;
            self.startup_countdown = jump_startup_frames;
            // Frame N: just the jump direction, no buttons. Emitting the bare
            // diagonal here (rather than e.g. 9AB) is what makes the later
            // dash a true air-dash: the game sees the character leave the
            // ground on frame N, and after the startup countdown reads a
            // dash while the character is airborne.
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

/// Total length of an air-dash sequence: 1 jump + startup_frames neutral + 1 dash.
const sequence_len: u8 = 1 + jump_startup_frames + 1;

test "disabled macro is a pure passthrough" {
    var m: AirDashMacro = .{ .enabled = false };
    // Same input, same output, no trigger — even for a would-be trigger.
    try testing.expectEqual(@as(u16, 0x0709), m.step(input_9ab).output);
    try testing.expectEqual(false, m.step(input_9ab).triggered);
    // And it stays idle, so enabling later starts from a clean slate.
    try testing.expectEqual(MacroState.idle, m.state);
}

test "9AB expands to jump, startup neutrals, then forward dash" {
    var m: AirDashMacro = .{ .enabled = true };

    // Frame N: trigger fires, emit just the jump diagonal.
    const r0 = m.step(input_9ab);
    try testing.expectEqual(@as(u16, 9), r0.output);
    try testing.expectEqual(true, r0.triggered);
    try testing.expectEqual(MacroState.startup, m.state);

    // Frames N+1 .. N+3: startup — emit neutral each frame.
    var i: u8 = 0;
    while (i < jump_startup_frames) : (i += 1) {
        const r = m.step(neutral);
        try testing.expectEqual(@as(u16, 0), r.output);
        try testing.expectEqual(false, r.triggered);
    }

    // Frame N+4: character airborne — committed forward dash.
    const rdash = m.step(neutral);
    try testing.expectEqual(dashWithDir(6), rdash.output);
    try testing.expectEqual(false, rdash.triggered);
    try testing.expectEqual(MacroState.idle, m.state);
}

test "7AB expands to jump, startup neutrals, then back dash" {
    var m: AirDashMacro = .{ .enabled = true };

    const r0 = m.step(input_7ab);
    try testing.expectEqual(@as(u16, 7), r0.output);
    try testing.expectEqual(true, r0.triggered);

    var i: u8 = 0;
    while (i < jump_startup_frames) : (i += 1) {
        try testing.expectEqual(@as(u16, 0), m.step(neutral).output);
    }

    const rdash = m.step(neutral);
    try testing.expectEqual(dashWithDir(4), rdash.output);
}

test "dash fires on frame N+4 even if buttons released" {
    // The macro commits to the full sequence once triggered — the jump
    // already happened on frame N, so the dash must follow on frame N+4
    // regardless of whether the player is still holding the buttons.
    var m: AirDashMacro = .{ .enabled = true };
    _ = m.step(input_9ab);
    // Player releases everything immediately after frame N.
    var i: u8 = 0;
    while (i < jump_startup_frames) : (i += 1) {
        try testing.expectEqual(@as(u16, 0), m.step(neutral).output);
    }
    const r = m.step(neutral);
    try testing.expectEqual(dashWithDir(6), r.output);
}

test "direction change mid-sequence is ignored" {
    // Pressing 7AB during the startup of a forward-dash sequence does NOT
    // switch the dash to back-dash. The sequence committed by the frame-N 9AB
    // plays out in full; the player must wait for idle to start a back-dash.
    var m: AirDashMacro = .{ .enabled = true };
    _ = m.step(input_9ab);
    // Feed 7AB during every startup frame.
    var i: u8 = 0;
    while (i < jump_startup_frames) : (i += 1) {
        try testing.expectEqual(@as(u16, 0), m.step(input_7ab).output);
    }
    // The dash is still forward (6), not back (4).
    try testing.expectEqual(dashWithDir(6), m.step(input_7ab).output);
    try testing.expectEqual(MacroState.idle, m.state);
}

test "holding 9AB produces one jump-dash cycle per sequence length" {
    var m: AirDashMacro = .{ .enabled = true };

    // Frame 0: trigger, jump.
    try testing.expectEqual(@as(u16, 9), m.step(input_9ab).output);
    // Frames 1..3: startup neutrals.
    var i: u8 = 0;
    while (i < jump_startup_frames) : (i += 1) {
        try testing.expectEqual(@as(u16, 0), m.step(input_9ab).output);
    }
    // Frame 4: dash.
    try testing.expectEqual(dashWithDir(6), m.step(input_9ab).output);
    // Frame 5: still holding → NEW trigger, jump again.
    const r = m.step(input_9ab);
    try testing.expectEqual(@as(u16, 9), r.output);
    try testing.expectEqual(true, r.triggered);
}

test "sequence length matches jump_startup_frames + 2" {
    // Sanity: from the trigger frame, exactly sequence_len frames are consumed
    // before the machine returns to idle (1 jump + startup + 1 dash).
    var m: AirDashMacro = .{ .enabled = true };
    _ = m.step(input_9ab); // frame 0 — trigger

    var frames_until_idle: u8 = 0;
    while (m.state != .idle) {
        _ = m.step(neutral);
        frames_until_idle += 1;
        // Guard against an infinite loop if the state machine is broken.
        try testing.expect(frames_until_idle <= sequence_len * 2);
    }
    // frames_until_idle counts the neutral frames + the dash frame.
    try testing.expectEqual(jump_startup_frames + 1, frames_until_idle);
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

    var i: u8 = 0;
    while (i < jump_startup_frames) : (i += 1) {
        try testing.expectEqual(@as(u16, 0), m.step(neutral).output);
    }
    try testing.expectEqual(dashWithDir(6), m.step(neutral).output);
}

test "reset clears an in-progress sequence" {
    // A pending startup must not survive a round transition.
    var m: AirDashMacro = .{ .enabled = true };
    _ = m.step(input_9ab);
    try testing.expectEqual(MacroState.startup, m.state);
    try testing.expect(m.startup_countdown > 0);

    m.reset();
    try testing.expectEqual(MacroState.idle, m.state);
    try testing.expectEqual(@as(u8, 0), m.dash_dir);
    try testing.expectEqual(@as(u8, 0), m.startup_countdown);

    // After reset, the next frame is treated as a fresh IDLE frame — no
    // spurious dash from the pre-reset trigger.
    const r = m.step(neutral);
    try testing.expectEqual(neutral, r.output);
    try testing.expectEqual(false, r.triggered);
}

test "reset mid-startup does not emit a dash" {
    // Reset partway through the startup countdown: the remaining neutrals
    // and the dash are all cancelled. The next trigger starts fresh.
    var m: AirDashMacro = .{ .enabled = true };
    _ = m.step(input_9ab); // countdown = 3
    _ = m.step(neutral); // countdown = 2

    m.reset();

    // Should be idle — no dash leaks out.
    const r = m.step(neutral);
    try testing.expectEqual(neutral, r.output);
    try testing.expectEqual(MacroState.idle, m.state);
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
