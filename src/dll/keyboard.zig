const std = @import("std");
const logging = @import("common").logging;

// Win32 keyboard input
const win32 = struct {
    extern "user32" fn GetKeyState(nVirtKey: i32) callconv(.winapi) i16;
    extern "user32" fn MapVirtualKeyA(uCode: u32, uMapType: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetModuleFileNameA(hModule: ?*anyopaque, lpFilename: [*]u8, nSize: u32) callconv(.winapi) u32;
};

const keyboard_config_offset: u32 = 0x14D2C0;

// MBAA button constants
pub const button_a: u16 = 0x0010;
pub const button_b: u16 = 0x0020;
pub const button_c: u16 = 0x0008;
pub const button_d: u16 = 0x0004;
pub const button_e: u16 = 0x0080;
pub const button_start: u16 = 0x0001;
pub const button_confirm: u16 = 0x0400;
pub const button_cancel: u16 = 0x0800;

// VK codes (will be loaded from MBAA.exe config)
var vk_codes: [10]u32 = [_]u32{0} ** 10;
var initialized: bool = false;
pub fn isInitialized() bool { return initialized; }

const MAPVK_VSC_TO_VK_EX: u32 = 3;

pub fn init(log: *logging.Logger, io: std.Io) void {
    if (initialized) return;

    // Read the 10-byte keyboard config from MBAA.exe
    var exe_path: [260]u8 = undefined;
    const len = win32.GetModuleFileNameA(null, &exe_path, exe_path.len);
    if (len == 0) {
        log.err("KeyboardReader: GetModuleFileNameA failed", .{});
        return;
    }

    const file = std.Io.Dir.cwd().openFile(io, exe_path[0..len], .{}) catch {
        log.err("KeyboardReader: cannot open {s}", .{exe_path[0..len]});
        return;
    };
    defer file.close(io);

    var config: [10]u8 = undefined;
    const read = file.readPositionalAll(io, &config, keyboard_config_offset) catch {
        log.err("KeyboardReader: read failed", .{});
        return;
    };

    if (read < 10) {
        log.err("KeyboardReader: only read {d} bytes", .{read});
        return;
    }

    // Convert scan codes to VK codes
    // [0]=Down, [1]=Up, [2]=Left, [3]=Right
    // [4]=A/Confirm, [5]=B/Cancel, [6]=C, [7]=D, [8]=E, [9]=Start
    for (&vk_codes, 0..) |*vk, i| {
        vk.* = win32.MapVirtualKeyA(config[i], MAPVK_VSC_TO_VK_EX);
    }

    log.info("KeyboardReader: D={x:0>2} U={x:0>2} L={x:0>2} R={x:0>2} A={x:0>2} B={x:0>2} C={x:0>2} D={x:0>2} E={x:0>2} S={x:0>2}", .{
        vk_codes[0], vk_codes[1], vk_codes[2], vk_codes[3],
        vk_codes[4], vk_codes[5], vk_codes[6], vk_codes[7],
        vk_codes[8], vk_codes[9],
    });
    initialized = true;
}

pub fn readInput() u16 {
    if (!initialized) return 0;

    // Read directions
    var up = (win32.GetKeyState(@intCast(vk_codes[1])) & 0x80) != 0;
    var down = (win32.GetKeyState(@intCast(vk_codes[0])) & 0x80) != 0;
    var left = (win32.GetKeyState(@intCast(vk_codes[2])) & 0x80) != 0;
    var right = (win32.GetKeyState(@intCast(vk_codes[3])) & 0x80) != 0;

    // Analog stick — N/A for keyboard, skip

    // SOCD: simultaneous up+down or left+right → neutral
    if (up and down) { up = false; down = false; }
    if (left and right) { left = false; right = false; }

    // Direction to numpad notation (0=neutral, 1-9). Start at 5=neutral so
    // +/-1 yields 4=L, 6=R (starting at 0 would wrap to 65535 on left).
    var direction: u16 = 5;
    if (up) direction = 8 else if (down) direction = 2;
    if (left) direction -|= 1 else if (right) direction +|= 1;
    if (direction == 5) direction = 0;

    // Read buttons
    var buttons: u16 = 0;
    if (isDown(vk_codes[4])) buttons |= button_a;
    if (isDown(vk_codes[5])) buttons |= button_b;
    if (isDown(vk_codes[6])) buttons |= button_c;
    if (isDown(vk_codes[7])) buttons |= button_d;
    if (isDown(vk_codes[8])) buttons |= button_e;
    if (isDown(vk_codes[9])) buttons |= button_start;

    // A doubles as Confirm, B doubles as Cancel
    if (buttons & button_a != 0) buttons |= button_confirm;
    if (buttons & button_b != 0) buttons |= button_cancel;

    return direction | (buttons << 4);
}

fn isDown(vk: u32) bool {
    return (win32.GetKeyState(@intCast(vk)) & 0x80) != 0;
}

