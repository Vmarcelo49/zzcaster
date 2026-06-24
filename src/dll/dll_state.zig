// Shared state for hook.dll. dllmain owns the lifecycle; asm_hacks and
// frame_step only read through these pub vars.
const std = @import("std");
const logging = @import("common").logging;
const netman = @import("netplay_manager.zig");
const gamepad = @import("gamepad.zig");
const air_dash = @import("air_dash_macro.zig");

// Fixed offsets into the MBAACC process's 32-bit address space (comptime-known).

/// Game's current mode code. Read each frame to detect mode transitions.
pub const game_mode_addr: *u32 = @ptrFromInt(0x54EEE8);

/// Per-frame world timer; gates per-frame logic.
pub const world_timer_addr: *u32 = @ptrFromInt(0x55D1D4);

/// Skip-frames flag; set to N to skip N frames of rendering, 0 to advance.
pub const skip_frames_addr: *u32 = @ptrFromInt(0x55D25C);

/// "Alive" flag; writing 0 forces MBAA to exit.
pub const alive_flag_addr: *u8 = @ptrFromInt(0x76E650);

// ptr_to_write_input_addr points to the base of the game's input struct.
// Read through a u8 pointer and bit-cast (defensive pattern; on the forced
// 32-bit target usize=u32 and the field is 4-byte aligned, so a direct *u32
// read would also be valid).
const ptr_to_write_input_addr: [*]u8 = @ptrFromInt(0x76E6AC);
const p1_off_dir: u32 = 0x18;
const p1_off_btn: u32 = 0x24;
const p2_off_dir: u32 = 0x2C;
const p2_off_btn: u32 = 0x38;

/// Active logger (set by lazyInit; storage owned by dllmain).
pub var log: ?*logging.Logger = null;

/// Netplay manager; null in offline mode (set by waitForConfig).
pub var nm: ?netman.NetplayManager = null;

/// P1 gamepad reader (set by initSdlOnMainThread).
pub var reader: ?gamepad.GamepadReader = null;

/// Offline-Versus P2 reader; null in netplay/spectator (P2 comes from network).
pub var reader2: ?gamepad.GamepadReader = null;

/// Per-player Air Dash Macro state machines for offline mode. Netplay uses
/// NetplayManager's own air_dash_macro field. See air_dash_macro.zig.
pub var air_dash_macro_p1: air_dash.AirDashMacro = .{};
pub var air_dash_macro_p2: air_dash.AirDashMacro = .{};

/// Counter for periodic input-value logging in frameStepOffline.
pub var input_log_frame: u32 = 0;

// init_single_threaded: no cross-thread Io; the DLL runs in the game process.
pub var app_io_backend: std.Io.Threaded = .init_single_threaded;

/// Per-frame callback wired into the game's main loop (set by DllMain).
var frame_callback: ?*const fn () callconv(.c) void = null;

/// Trampoline the ASM patches call each main-loop iteration.
pub export fn zzcasterFrameCallback() callconv(.c) void {
    if (frame_callback) |cb| cb();
}

pub fn setFrameCallback(cb: *const fn () callconv(.c) void) void {
    frame_callback = cb;
}

/// Write a combined dir/btn input word for player 1 or 2. Writes both halves
/// as u16 to match the legacy layout (u8 writes leave stale high bytes).
pub fn writeInput(player: u8, input: u16) void {
    const base_ptr = @as(usize, @bitCast(ptr_to_write_input_addr[0..@sizeOf(usize)].*));
    if (base_ptr == 0) return;
    const base: [*]u8 = @ptrFromInt(base_ptr);
    const dir_off: u32 = if (player == 1) p1_off_dir else p2_off_dir;
    const btn_off: u32 = if (player == 1) p1_off_btn else p2_off_btn;
    const dir_ptr: *u16 = @ptrCast(@alignCast(base + dir_off));
    const btn_ptr: *u16 = @ptrCast(@alignCast(base + btn_off));
    dir_ptr.* = input & 0x0F;
    btn_ptr.* = (input >> 4) & 0x0FFF;
}

/// Routes SpectatorManager.frameStepSpectators into NetplayManager.
pub fn fillBothInputsCallback(index: u32, frame: u32, out: []u8) usize {
    if (nm) |*n| {
        return n.fillBothInputsForBroadcast(index, frame, out);
    }
    return 0;
}

/// Routes SpectatorManager.frameStepSpectators' RNG-lookup callback into
/// NetplayManager.getCachedRngState. Returns true if the host has a cached
/// RNG state for the given transition index (i.e., the host has captured
/// and sent RNG for that round), false otherwise.
pub fn getCachedRngCallback(index: u32, out: []u8) bool {
    if (nm) |*n| {
        return n.getCachedRngState(index, out);
    }
    return false;
}
