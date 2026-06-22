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
