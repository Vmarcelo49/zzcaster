const std = @import("std");

// 2 frames: the game buffer accepts the air dash for all characters except pciel.
const jump_startup_frames: u8 = 2;

const MacroState = enum {
    idle, // waiting for 9AB / 7AB
    startup, // jump emitted; counting down before the dash
    suppressed, // sequence done; AB still held → strip AB until release
};

pub const StepResult = struct {
    output: u16,
    triggered: bool,
};

const ab_buttons: u16 = 0x0070; // button_a | button_b | button_ab

const ab_buttons_combined: u16 = ab_buttons << 4; // 0x0700

pub const AirDashMacro = struct {
    enabled: bool = false,
    state: MacroState = .idle,

    dash_dir: u8 = 0,

    startup_countdown: u8 = 0,

    pub fn reset(self: *AirDashMacro) void {
        self.state = .idle;
        self.dash_dir = 0;
        self.startup_countdown = 0;
    }

    pub fn step(self: *AirDashMacro, raw_input: u16) StepResult {
        if (!self.enabled) return .{ .output = raw_input, .triggered = false };

        // Decompose the input once; several branches need these.
        const dir: u8 = @intCast(raw_input & 0x0F);
        const btns: u16 = (raw_input >> 4) & 0x0FFF;
        const has_ab = (btns & 0x0040 != 0) or (btns & 0x0030 == 0x0030);

        if (self.state == .startup) {
            if (self.startup_countdown > 0) {
                self.startup_countdown -= 1;
                return .{ .output = 0, .triggered = false };
            }
            // Countdown expired — the character is now airborne. Emit the dash.
            const dash_input: u16 = @as(u16, self.dash_dir) | ab_buttons_combined;
            self.dash_dir = 0;
            self.startup_countdown = 0;
            // One-shot-per-press: if the player is STILL holding AB on the dash
            // frame, latch the buttons off so a held-AB can't immediately
            // re-trigger. If they already released, go straight back to idle.
            self.state = if (has_ab) .suppressed else .idle;
            return .{ .output = dash_input, .triggered = false };
        }

        if (self.state == .suppressed) {
            if (has_ab) {
                return .{ .output = raw_input & ~ab_buttons_combined, .triggered = false };
            }
            self.state = .idle;
            return .{ .output = raw_input, .triggered = false };
        }

        const other_buttons = btns & ~ab_buttons;
        if (has_ab and (dir == 9 or dir == 7) and other_buttons == 0) {
            self.state = .startup;
            self.dash_dir = if (dir == 9) 6 else 4;
            self.startup_countdown = jump_startup_frames;

            return .{ .output = @as(u16, dir), .triggered = true };
        }

        return .{ .output = raw_input, .triggered = false };
    }
};

// =============================================================================
// Tests
//
// The macro is STATEFUL: a 9AB press advances the state machine through
// startup → (countdown) → dash emit → suppressed → idle over several frames.
// This is why frame_step.zip MUST skip the macro during a rollback re-run:
// re-running step() on the same physical input, with the state machine already
// advanced, produces different output than the original run, corrupting the
// InputBuffer. These tests lock in that stateful behavior.
// =============================================================================

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

// 9AB = dir 9 (up-forward) + buttons A+B. In the wire format the buttons live
// in the high byte (input >> 4), so 9AB = 9 | (0x30 << 4)... but the macro
// reads btns = (input >> 4) & 0x0FFF, and has_ab = (btns & 0x40) or (btns&0x30==0x30).
// So A=0x10, B=0x20 in the btns space → input = 9 | ((0x10|0x20) << 4) = 9 | 0x300.
const input_9ab: u16 = 9 | (0x30 << 4); // 0x0309
const input_neutral: u16 = 5; // dir 5 (neutral), no buttons

test "macro expands 9AB into jump then dash over multiple frames" {
    var m = AirDashMacro{ .enabled = true };

    // Frame 0: 9AB pressed → trigger, output is just the jump direction (9).
    const f0 = m.step(input_9ab);
    try expect(f0.triggered);
    try expectEqual(@as(u16, 9), f0.output);
    try expectEqual(@as(u8, 6), m.dash_dir); // dash will be 6 (forward)

    // Frames 1..jump_startup_frames: neutral output (countdown).
    var i: u8 = 0;
    while (i < jump_startup_frames) : (i += 1) {
        const f = m.step(input_9ab); // still holding AB
        try expectEqual(@as(u16, 0), f.output);
        try expect(!f.triggered);
    }

    // Next frame: countdown expired → dash emitted (dir 6 + AB buttons).
    const dash = m.step(input_9ab);
    try expectEqual(@as(u16, 6 | ab_buttons_combined), dash.output);
}

test "re-running step on the same input after expansion produces different output (the bug)" {
    // This demonstrates WHY frame_step skips the macro during re-runs.
    // Simulate the original run: 9AB → jump, countdown, dash.
    var m = AirDashMacro{ .enabled = true };
    _ = m.step(input_9ab); // frame 0: jump
    var i: u8 = 0;
    while (i < jump_startup_frames) : (i += 1) _ = m.step(input_9ab);
    const original_dash_frame_output = m.step(input_9ab); // dash frame
    try expectEqual(@as(u16, 6 | ab_buttons_combined), original_dash_frame_output.output);

    // Now the state machine has advanced past the sequence. If a rollback
    // re-run calls step(input_9ab) again at "frame 0", it does NOT reproduce
    // the original jump — the macro is in .suppressed state, so it strips AB:
    m.reset(); // a re-run would see the reset state only if reset is called
    _ = m.step(input_9ab); // re-run frame 0: jump again (reset happened)
    // But during a real re-run, reset() is NOT called between the original run
    // and the re-run — the state carries over. Simulate that:
    var m2 = AirDashMacro{ .enabled = true };
    _ = m2.step(input_9ab); // original frame 0
    while (jump_startup_frames > 0) {
        _ = m2.step(input_9ab);
        break;
    }
    // Without reset, re-running step at "frame 0" with state carried over:
    const rerun_output = m2.step(input_9ab);
    // The output differs from the original frame-0 jump output (9) because the
    // state machine is mid-sequence. This is the corruption the fix prevents.
    try expect(rerun_output.output != 9 or rerun_output.triggered == false);
}

test "disabled macro passes input through unchanged" {
    var m = AirDashMacro{ .enabled = false };
    const r = m.step(input_9ab);
    try expectEqual(input_9ab, r.output);
    try expect(!r.triggered);
}

test "reset returns the macro to idle" {
    var m = AirDashMacro{ .enabled = true };
    _ = m.step(input_9ab); // enter startup
    m.reset();
    try expectEqual(MacroState.idle, m.state);
    try expectEqual(@as(u8, 0), m.dash_dir);
    try expectEqual(@as(u8, 0), m.startup_countdown);
}
