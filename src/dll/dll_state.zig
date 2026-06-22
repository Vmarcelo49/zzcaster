// dll_state.zig — shared state for hook.dll, extracted from dllmain.zig to
// break the circular import between dllmain ↔ {asm_hacks, frame_step}.
//
// WHY THIS EXISTS
// ---------------
// asm_hacks.zig and frame_step.zig previously reached shared state (the
// logger, netplay manager, gamepad readers, game-memory addresses, the I/O
// backend, and a few helper functions) via `@import("dllmain.zig")`. That
// created a circular import: dllmain imports asm_hacks/frame_step, and they
// import dllmain back. Zig resolves cycles at compile time so it worked, but
// it prevented those helpers from being analyzed independently and kept all
// shared state coupled to the DLL entry-point file.
//
// Now the shared state lives HERE, and all three files (dllmain, asm_hacks,
// frame_step) import it in ONE direction:
//
//     dllmain.zig ──┐
//     asm_hacks.zig ─┼──> dll_state.zig
//     frame_step.zig ┘
//
// dllmain.zig still OWNS the lifecycle: it creates/destroys the logger, the
// netplay manager, the gamepad readers, and wires frame_callback → frameStep
// during DllMain(PROCESS_ATTACH). It assigns into the `pub var`s declared
// below; asm_hacks/frame_step only READ through them.
//
// WHAT'S HERE (11 symbols, exactly what the two consumers touch)
// -------------------------------------------------------------
//   Group A — game memory addresses (pure data, no init order)
//   Group B — runtime state vars (default null/0, populated by dllmain)
//   Group C — I/O backend (init_single_threaded — see comment below)
//   Group D — functions + their private deps (frame trampoline, writeInput,
//             fillBothInputsCallback)
const std = @import("std");
const logging = @import("common").logging;
const netman = @import("netplay_manager.zig");
const gamepad = @import("gamepad.zig");

// ============================================================================
// Group A — Game memory addresses (read/written each frame)
// ============================================================================
//
// These are fixed offsets into the MBAACC process's virtual address space
// (a 32-bit game). They are comptime-known pointers, so there is no
// initialization-order concern — they're valid the moment the DLL loads.

/// Game's current mode code (startup/title/in-game/etc). Read each frame to
/// detect mode transitions.
pub const game_mode_addr: *u32 = @ptrFromInt(0x54EEE8);

/// Per-frame world timer; used as the per-frame tick to gate logic.
pub const world_timer_addr: *u32 = @ptrFromInt(0x55D1D4);

/// Game's skip-frames flag; written 1 (skip) or 0 (advance).
pub const skip_frames_addr: *u32 = @ptrFromInt(0x55D25C);

/// Game's "alive" flag; writing 0 forces MBAA to exit (used for clean
/// shutdown on disconnect/timeout).
pub const alive_flag_addr: *u8 = @ptrFromInt(0x76E650);

// --- Input-write layout (private deps of writeInput below) ---
//
// ptr_to_write_input_addr points to a usize holding the base address of the
// game's input struct. On 64-bit targets the host address is 4-byte aligned
// but usize wants 8, so we read through a u8 pointer and bit-cast the result.
const ptr_to_write_input_addr: [*]u8 = @ptrFromInt(0x76E6AC);
const p1_off_dir: u32 = 0x18;
const p1_off_btn: u32 = 0x24;
const p2_off_dir: u32 = 0x2C;
const p2_off_btn: u32 = 0x38;

// ============================================================================
// Group B — Runtime state (mutable globals, populated by dllmain's lifecycle)
// ============================================================================
//
// All default to null/0 at declaration and are assigned later by dllmain.zig
// (lazyInit sets `log`; waitForConfig sets `nm`; initSdlOnMainThread sets
// `reader`/`reader2`; frameStep bumps `input_log_frame`). asm_hacks and
// frame_step only read through these.

/// Pointer to the active logger. Set by lazyInit to &log_storage (which
/// remains private in dllmain.zig — it owns the backing storage).
pub var log: ?*logging.Logger = null;

/// Netplay manager instance; null in offline mode. Created in waitForConfig.
pub var nm: ?netman.NetplayManager = null;

/// Primary (P1) gamepad reader; allocated in initSdlOnMainThread.
pub var reader: ?gamepad.GamepadReader = null;

/// Offline-Versus P2 reader; null in netplay/spectator modes (P2 input comes
/// from the network there). Built in applyPostLoadHacks.
pub var reader2: ?gamepad.GamepadReader = null;

/// Counter for periodic input-value logging in frameStepOffline.
pub var input_log_frame: u32 = 0;

// ============================================================================
// Group C — I/O backend
// ============================================================================
//
// The DLL runs inside the game's process, so we use init_single_threaded to
// avoid spawning worker threads that could interfere with the game. There are
// no cross-thread Io operations — all logging/config reads happen on MBAA's
// main thread (via frameStep) or the lazyInit worker thread.
pub var app_io_backend: std.Io.Threaded = .init_single_threaded;

// ============================================================================
// Group D — Functions + their private state
// ============================================================================

/// The per-frame callback wired into the game's main loop. Set by DllMain
/// (PROCESS_ATTACH) to dllmain.frameStep. asm_hacks takes the address of
/// zzcasterFrameCallback (below) when installing the main-loop patches.
var frame_callback: ?*const fn () callconv(.c) void = null;

/// Trampoline the ASM patches call each main-loop iteration. `pub export` so
/// asm_hacks.applyHookMainLoop can take this function's address via
/// `&dll_state.zzcasterFrameCallback`. The `export` also keeps the symbol in
/// the DLL's export table (matches the legacy layout).
pub export fn zzcasterFrameCallback() callconv(.c) void {
    if (frame_callback) |cb| cb();
}

/// Wire the per-frame callback. Called once from DllMain(PROCESS_ATTACH) with
/// `frameStep` as the target. Lives here (not in dllmain) so that
/// zzcasterFrameCallback + frame_callback are co-located and dllmain doesn't
/// need to be imported to reach them.
pub fn setFrameCallback(cb: *const fn () callconv(.c) void) void {
    frame_callback = cb;
}

/// Write a combined dir/btn input word for player 1 or 2 into the game's
/// input struct. Owns the base-pointer layout (Group A constants above).
/// Called from dllmain.frameStep (pre-game confirm presses) and
/// frame_step.frameStepOffline (offline P1/P2 input).
pub fn writeInput(player: u8, input: u16) void {
    const base_ptr = @as(usize, @bitCast(ptr_to_write_input_addr[0..@sizeOf(usize)].*));
    if (base_ptr == 0) return;
    const base: [*]u8 = @ptrFromInt(base_ptr);
    const dir_off: u32 = if (player == 1) p1_off_dir else p2_off_dir;
    const btn_off: u32 = if (player == 1) p1_off_btn else p2_off_btn;
    // COMBINE_INPUT(dir, btn) = dir | (btn << 4); write both halves as u16
    // to match the legacy C++ DLL (see DllProcessManager.cpp::writeGameInput).
    // Writing u8 here leaves the high byte of each u16 slot at whatever
    // the game last stored there, which flips unrelated button bits.
    const dir_ptr: *u16 = @ptrCast(@alignCast(base + dir_off));
    const btn_ptr: *u16 = @ptrCast(@alignCast(base + btn_off));
    dir_ptr.* = input & 0x0F;
    btn_ptr.* = (input >> 4) & 0x0FFF;
}

/// Callback used by SpectatorManager.frameStepSpectators to fill a BothInputs
/// packet for a given (index, frame) — routes back into NetplayManager.
/// Called from frame_step.frameStepNetplay (host-side BothInputs broadcast).
pub fn fillBothInputsCallback(index: u32, frame: u32, out: []u8) usize {
    if (nm) |*n| {
        return n.fillBothInputsForBroadcast(index, frame, out);
    }
    return 0;
}
