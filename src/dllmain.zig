const std = @import("std");
const logging = @import("logging.zig");
const gamepad = @import("gamepad.zig");
const keyboard = @import("keyboard.zig");
const netman = @import("netplay_manager.zig");
const sfx_dedup = @import("sfx_dedup.zig");
const mapper = @import("controller_mapper.zig");

// SDL2
const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

// Win32 externs
const win32 = struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32, hTemplateFile: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetEnvironmentVariableA(
        lpName: [*:0]const u8, lpBuffer: [*]u8, nSize: u32,
    ) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn ReadFile(
        hFile: ?*anyopaque, lpBuffer: [*]u8, nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(
        hFile: ?*anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: ?*anyopaque, lpBuffer: ?*anyopaque, nBufferSize: u32,
        lpBytesRead: ?*u32, lpTotalBytesAvail: *u32, lpBytesLeftThisMessage: ?*u32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn ExitProcess(uExitCode: u32) callconv(.winapi) noreturn;
    extern "kernel32" fn SetThreadExecutionState(esFlags: u32) callconv(.winapi) u32;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
    extern "kernel32" fn GetModuleFileNameA(hModule: ?*anyopaque, lpFilename: [*]u8, nSize: u32) callconv(.winapi) u32;
    extern "kernel32" fn CreateThread(
        lpThreadAttributes: ?*anyopaque, dwStackSize: usize,
        lpStartAddress: ?*const fn (?*anyopaque) callconv(.winapi) u32,
        lpParameter: ?*anyopaque, dwCreationFlags: u32, lpThreadId: ?*u32,
    ) callconv(.winapi) ?*anyopaque;

    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const OPEN_EXISTING: u32 = 3;
    const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
};

const default_pipe_name = "\\\\.\\pipe\\zzcaster_pipe";

/// Static storage for the resolved pipe name. The function returns a
/// slice into this buffer so the caller's pointer stays valid after the
/// helper returns (a stack-local buffer would be reused by the caller).
var resolved_pipe_name_buf: [128:0]u8 = [_:0]u8{0} ** 128;

/// Resolve the pipe name to connect to. The launcher sets CCCASTER_PIPE
/// to a unique name (per launcher PID) so multiple zzcaster.exe processes
/// can run side-by-side. Falls back to the historical default if the env
/// var is missing (e.g. when the DLL is loaded by an older launcher).
fn resolvePipeName() [:0]const u8 {
    var name_buf: [64]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "CCCASTER_PIPE", .{}) catch return default_pipe_name_z;
    var buf: [128]u8 = undefined;
    const len = win32.GetEnvironmentVariableA(name_z.ptr, &buf, buf.len);
    if (len == 0 or len >= buf.len) {
        return default_pipe_name_z;
    }
    // buf currently holds just "zzcaster_<pid>_pipe" (no \\.\pipe\ prefix).
    // Prepend the prefix.
    const prefix = "\\\\.\\pipe\\";
    if (prefix.len + len + 1 > resolved_pipe_name_buf.len) return default_pipe_name_z;
    // Slide the existing content right by prefix.len, then write the prefix.
    std.mem.copyForwards(u8, resolved_pipe_name_buf[prefix.len..][0..len], buf[0..len]);
    @memcpy(resolved_pipe_name_buf[0..prefix.len], prefix);
    resolved_pipe_name_buf[prefix.len + len] = 0;
    return resolved_pipe_name_buf[0 .. prefix.len + len :0];
}

const default_pipe_name_z: [:0]const u8 = "\\\\.\\pipe\\zzcaster_pipe";

// Game memory addresses
const game_mode_addr: *u32 = @ptrFromInt(0x54EEE8);
const world_timer_addr: *u32 = @ptrFromInt(0x55D1D4);
const skip_frames_addr: *u32 = @ptrFromInt(0x55D25C);
const alive_flag_addr: *u8 = @ptrFromInt(0x76E650);
const damage_level_addr: *u32 = @ptrFromInt(0x553FCC);
const timer_speed_addr: *u32 = @ptrFromInt(0x553FD0);
const win_count_vs_addr: *u32 = @ptrFromInt(0x553FDC);
// Zig 0.16: 64-bit alignment check rejects `@ptrFromInt(0x76E6AC)` for `*usize`
// (4-byte aligned, but *usize needs 8 on 64-bit). Cast through a [*]u8
// pointer instead — the legacy game memory address is 4-byte aligned by
// design (MBAA is a 32-bit process) so we read a usize via @ptrFromInt on
// a u8 pointer.
const ptr_to_write_input_addr: [*]u8 = @ptrFromInt(0x76E6AC);
const p1_off_dir: u32 = 0x18;
const p1_off_btn: u32 = 0x24;
const p2_off_dir: u32 = 0x2C;
const p2_off_btn: u32 = 0x38;

const mode_startup: u32 = 65535;
const mode_opening: u32 = 3;
const mode_title: u32 = 2;
const mode_main: u32 = 25;
const mode_in_game: u32 = 1;

const button_confirm: u16 = 0x0400;

// ASM addresses
const loop_start_addr: u32 = 0x40D330;
const hook_call1_addr: u32 = 0x40D032;
const hook_call2_addr: u32 = 0x40D411;
const multiple_melty_addr: *u8 = @ptrFromInt(0x40D25A);
const force_goto_addr: *u8 = @ptrFromInt(0x42B475);

// Zig 0.16: every file/stdout operation needs an Io handle. The DLL runs
// inside the game's process, so we use init_single_threaded to avoid
// spawning worker threads that could interfere with the game.
var app_io_backend: std.Io.Threaded = .init_single_threaded;

var frame_callback: ?*const fn () callconv(.c) void = null;
var log_storage: logging.Logger = undefined;
var log: ?*logging.Logger = null;
var ipc_pipe: ?*anyopaque = null;
var ipc_connected: bool = false;
var last_world_timer: u32 = 0;
var prev_game_mode: u32 = 0;
// The DLL's own module handle, captured in DllMain(PROCESS_ATTACH).
// Used to resolve the DLL's own file path via GetModuleFileNameA, so we
// can find mapping.ini in the same directory as hook.dll regardless of
// the process's current working directory. Without this, the relative
// path "zzcaster/mapping.ini" resolves against MBAA.exe's CWD, which may
// not be the MBAACC root (e.g. if launched from a shortcut).
var dll_module_handle: ?*anyopaque = null;
var reader: ?gamepad.GamepadReader = null;
// Diagnostic: one-shot flag so frameStep logs the input pipeline state on
// the first frame where config_received becomes true. Lets the user
// verify from the log that reader / reader2 / keyboard were set up.
var input_diag_logged: bool = false;
// Periodic input-value logging frame counter.
var input_log_frame: u32 = 0;
// SDL must be initialized on the SAME thread that polls it. lazyInit runs
// on a worker thread, so we defer SDL_Init + controller open to the first
// frameStep call (which runs on MBAA's main thread). Without this, all
// SDL_GameControllerGetButton / SDL_JoystickGetButton calls return 0
// because SDL's internal state is thread-local.
var sdl_init_done: bool = false;
// Second reader for offline Versus P2. Null in netplay/spectator modes
// (P2 input comes from the network there). Built in applyPostLoadHacks
// from the [Player2] section of zzcaster/mapping.ini. Without this, P2
// in offline Versus is hard-locked to neutral every frame — the GUI
// saves P2 bindings but the DLL threw them away.
var reader2: ?gamepad.GamepadReader = null;
var sdl_initialized: bool = false;

// Netplay
var nm: ?netman.NetplayManager = null;
var config_received: bool = false;
var is_training: bool = false;
var is_netplay: bool = false;
var is_spectator: bool = false;

// Lazy init flag. DllMain(PROCESS_ATTACH) runs on the remote LoadLibraryA
// thread, which under Wine has a SMALL stack (~64KB-1MB). Zig 0.16's std.Io
// machinery (used by logging.Logger.init → createDirPath → openFile) is deep
// enough to blow that stack → EXCEPTION_STACK_OVERFLOW (0xc00000fd) → loader
// returns 0 from the attach → DLL silently unloaded. So DllMain does the
// bare minimum (wire frame_callback + set this flag) and ALL heavy init
// (logger, IPC pipe, ASM hacks, config wait) runs lazily on the first
// frameStep — on MBAA.exe's main thread, which has a full-size stack.
var dll_initialized: bool = false;

export fn zzcasterFrameCallback() callconv(.c) void {
    if (frame_callback) |cb| cb();
}

// Zig 0.16: DllMain must return std.os.windows.BOOL (was `callconv(.c) i32`
// before — the standard library now expects the proper Win32 BOOL type).
pub export fn DllMain(hModule: ?*anyopaque, fdwReason: u32, _: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL {
    switch (fdwReason) {
        1 => { // DLL_PROCESS_ATTACH
            // Capture the DLL's own module handle so we can resolve its file
            // path later (GetModuleFileNameA(dll_module_handle, ...)). This
            // lets us find mapping.ini in the same directory as hook.dll
            // regardless of the process CWD.
            dll_module_handle = hModule;
            // BARE MINIMUM only. This runs on the remote LoadLibraryA thread,
            // which under Wine has a small stack (~64KB-1MB) — any heavy
            // Zig 0.16 std.Io work here blows the stack
            // (EXCEPTION_STACK_OVERFLOW, 0xc00000fd) and the loader unloads
            // us before any hook fires. So we just:
            //   (a) wire frame_callback → frameStep (used once hooks install)
            //   (b) spawn a worker thread with a 256KB stack to run lazyInit,
            //       which installs the ASM hooks; after that the game's main
            //       loop calls frameStep, which waits on dll_initialized.
            frame_callback = frameStep;
            dll_initialized = false;
            // 8MB stack: Zig 0.16's std.Io call chain (Logger.init →
            // createDirPath → openFile → …) is deep enough to blow a smaller
            // stack (verified: 256KB still threw EXCEPTION_STACK_OVERFLOW).
            // 8MB matches the Linux default thread stack and is safely large.
            _ = win32.CreateThread(null, 8 * 1024 * 1024, initThread, null, 0, null);
        },
        0 => { // DLL_PROCESS_DETACH
            if (log) |l| {
                l.info("hook.dll: DLL_PROCESS_DETACH", .{});
                if (nm) |*n| n.deinit();
                if (ipc_connected) _ = win32.CloseHandle(ipc_pipe);
                if (reader) |*r| r.deinit();
                if (sdl_initialized) c.SDL_Quit();
                l.deinit();
            }
            win32.ExitProcess(0);
        },
        else => {},
    }
    return .TRUE;
}

fn connectPipe() void {
    if (log == null) return;
    const name = resolvePipeName();
    log.?.info("Connecting to IPC pipe: {s}", .{name});
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        ipc_pipe = win32.CreateFileA(name.ptr, win32.GENERIC_READ | win32.GENERIC_WRITE, 0, null, win32.OPEN_EXISTING, 0, null);
        if (ipc_pipe != win32.INVALID_HANDLE_VALUE) {
            ipc_connected = true;
            log.?.info("Connected to IPC pipe", .{});
            return;
        }
        win32.Sleep(100);
    }
    log.?.err("Failed to connect to IPC pipe", .{});
}

fn waitForConfig() void {
    if (log == null or !ipc_connected) return;
    log.?.info("Waiting for config...", .{});

    // Use PeekNamedPipe to check if the launcher has sent anything yet.
    // If we just called ReadFile here we'd block the DLL_PROCESS_ATTACH
    // thread, which in turn blocks the launcher's WaitForSingleObject for
    // LoadLibraryA — causing a deadlock while the launcher waits for us
    // to return so it can call ipc_server.send().
    //
    // Instead, do a single non-blocking check. If the launcher hasn't sent
    // yet, return early (with config_received=false) and let frameStep
    // pick up the config later.
    var available: u32 = 0;
    if (win32.PeekNamedPipe(ipc_pipe, null, 0, null, &available, null) == 0) return;
    if (available < 4) return;

    var header: [4]u8 = undefined;
    var read: u32 = 0;
    if (win32.ReadFile(ipc_pipe, &header, 4, &read, null) == 0) return;
    const msg_len = std.mem.readInt(u32, &header, .little);
    if (msg_len == 0 or msg_len > 256) return;

    if (win32.PeekNamedPipe(ipc_pipe, null, 0, null, &available, null) == 0) return;
    if (available < msg_len) return;

    var payload: [256]u8 = undefined;
    if (win32.ReadFile(ipc_pipe, &payload, msg_len, &read, null) == 0) return;
    if (read == 0) return;

    // Parse config: [1 byte flags] [1 byte delay] [1 byte rollback] [1 byte win_count]
    // [1 byte host_player] [2 bytes peer_port] [N bytes peer_addr]
    // flags bit0=training, bit1=netplay, bit2=host, bit3=spectator
    if (read >= 5) {
        const flags = payload[0];
        is_training = (flags & 0x01) != 0;
        is_netplay = (flags & 0x02) != 0;
        is_spectator = (flags & 0x08) != 0;

        if (is_netplay and read >= 7) {
            // Initialize NetplayManager with config
            nm = netman.NetplayManager.init(std.heap.page_allocator, app_io_backend.io(), log.?) catch {
                log.?.err("NetplayManager init failed", .{});
                is_netplay = false;
                config_received = true;
                return;
            };

            var cfg = netman.NetplayConfig{};
            cfg.is_host = (flags & 0x04) != 0;
            cfg.is_training = is_training;
            cfg.is_spectator = is_spectator;
            cfg.is_netplay = true;
            cfg.delay = payload[1];
            cfg.rollback = payload[2];
            cfg.win_count = payload[3];
            cfg.host_player = payload[4];
            cfg.local_player = if (cfg.is_host) cfg.host_player else (3 - cfg.host_player);
            cfg.remote_player = 3 - cfg.local_player;
            cfg.peer_port = std.mem.readInt(u16, payload[5..7], .little);

            const addr_len = @min(read - 7, cfg.peer_addr.len);
            @memcpy(cfg.peer_addr[0..addr_len], payload[7..7 + addr_len]);

            nm.?.configure(cfg);
            config_received = true;
            log.?.info("Config: netplay={} host={} training={} spectator={} delay={d} rollback={d} port={d}", .{
                is_netplay, cfg.is_host, is_training, is_spectator,
                cfg.delay, cfg.rollback, cfg.peer_port,
            });
        } else {
            is_training = (flags & 0x01) != 0;
            log.?.info("Config: offline training={}", .{is_training});
        }
    }
    config_received = true;
}

fn applyPreLoadHacks() void {
    if (log == null) return;
    log.?.info("Applying pre-load ASM hacks...", .{});
    applyHookMainLoop();
    var multi_melty: [1]u8 = .{0xEB};
    writeBytes(@intFromPtr(multiple_melty_addr), &multi_melty);
    applyHijackControls();
    // Apply SFX dedup ASM hooks (filter repeated SFX + cancel muted SFX).
    // These wire the game's SFX play path into our sfx_filter_array /
    // sfx_mute_array so that rollback re-runs don't replay stale sounds.
    applySfxAsmHacks();
    log.?.info("Pre-load hacks applied", .{});
}

fn applyHookMainLoop() void {
    const callback_addr: u32 = @intCast(@intFromPtr(&zzcasterFrameCallback));

    // Patch 1 (at hook_call1_addr):
    //   E8 <rel32>   call zzcasterFrameCallback  (5 bytes)
    //   E9 <rel32>   jmp hook_call2_addr         (5 bytes)
    var p1: [10]u8 = undefined;
    p1[0] = 0xE8;
    std.mem.writeInt(u32, p1[1..5], rel32(callback_addr, hook_call1_addr + 0, 5), .little);
    p1[5] = 0xE9;
    // The E9 sits at hook_call1_addr + 5. next_ip = hook_call1_addr + 10.
    std.mem.writeInt(u32, p1[6..10], rel32(hook_call2_addr, hook_call1_addr + 5, 5), .little);
    writeBytes(hook_call1_addr, &p1);

    // Patch 2 (at hook_call2_addr):
    //   6A 01        push 1
    //   6A 00        push 0
    //   6A 00        push 0
    //   E9 <rel32>   jmp loop_start_addr + 6     (past the patch at loop_start)
    // Total: 2 + 2 + 2 + 5 = 11 bytes.
    //
    // Why +6? The legacy comment says "jmp LOOP_START+6 (AFTER)". The flow
    // is: HOOK_CALL1 calls our callback → jmps to HOOK_CALL2 → pushes args
    // → jmps to loop_start+6 (the original loop body, AFTER our 6-byte
    // hook patch). The original loop body eventually loops back and calls
    // HOOK_CALL1 again. Jumping to loop_start itself would infinite-loop
    // through our own 5-byte jmp and overflow the stack from the 3 pushes.
    var p2: [11]u8 = .{ 0x6A, 0x01, 0x6A, 0x00, 0x6A, 0x00, 0xE9, 0, 0, 0, 0 };
    // The E9 sits at hook_call2_addr + 6. next_ip = hook_call2_addr + 11.
    std.mem.writeInt(u32, p2[7..11], rel32(loop_start_addr + 6, hook_call2_addr + 6, 5), .little);
    writeBytes(hook_call2_addr, &p2);
    log.?.info("hookCall2 bytes: {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
        p2[0], p2[1], p2[2], p2[3], p2[4], p2[5], p2[6], p2[7], p2[8], p2[9], p2[10],
    });

    // Patch 3 (at loop_start_addr):
    //   E9 <rel32>   jmp hook_call1_addr         (5 bytes)
    //   90           nop                          (1 byte)
    var p3: [6]u8 = .{ 0xE9, 0, 0, 0, 0, 0x90 };
    // The E9 sits at loop_start_addr + 0. next_ip = loop_start_addr + 5.
    std.mem.writeInt(u32, p3[1..5], rel32(hook_call1_addr, loop_start_addr + 0, 5), .little);
    writeBytes(loop_start_addr, &p3);

    log.?.info("hookMainLoop applied (callback=0x{x:0>8})", .{callback_addr});
}

fn applyHijackControls() void {
    const nops = [_]struct { addr: u32, len: u32 }{
        .{ .addr = 0x41F098, .len = 2 }, .{ .addr = 0x41F0A0, .len = 3 },
        .{ .addr = 0x4A024E, .len = 2 }, .{ .addr = 0x4A027F, .len = 3 },
        .{ .addr = 0x4A0291, .len = 3 }, .{ .addr = 0x4A02A2, .len = 3 },
        .{ .addr = 0x4A02B4, .len = 3 }, .{ .addr = 0x4A02E9, .len = 2 },
        .{ .addr = 0x4A02F2, .len = 3 },
    };
    for (nops) |n| {
        var buf: [3]u8 = .{ 0x90, 0x90, 0x90 };
        writeBytes(n.addr, buf[0..n.len]);
    }
    var zeros: [20]u8 = [_]u8{0} ** 20;
    writeBytes(0x54D2C0, &zeros);
}

// SFX dedup ASM hooks. Ported from legacy_unused/targets/DllAsmHacks.cpp:
//   filterRepeatedSfx — intercepts the SFX play loop, checks sfxMuteArray
//     and sfxFilterArray to suppress repeated/muted playbacks.
//   muteSpecificSfx — when the game does play an SFX marked as mute=1,
//     override the volume with DX_MUTED_VOLUME (effectively silent) and
//     clear the mute flag so subsequent plays are normal.
//
// The two patches together let us "cancel" a stale queued SFX by writing
// 1 to CC_SFX_ARRAY[i] AND 1 to sfxMuteArray[i] — the play hook fires but
// produces no audio, dequeuing the sound without artifact.
fn applySfxAsmHacks() void {
    if (log == null) return;
    const filter_arr = @intFromPtr(&sfx_dedup.sfx_filter_array);
    const mute_arr = @intFromPtr(&sfx_dedup.sfx_mute_array);
    const sfx_len = sfx_dedup.sfx_array_len;
    const muted_vol = sfx_dedup.dx_muted_volume;

    // --- filterRepeatedSfx (5 patches, must be applied in order) ---
    // Patch site 0x4DD836: mov eax, sfxMuteArray ; jmp 0x4DD8B6
    // Length = 7 bytes (B8 + DWORD + EB 79). next_ip = 0x4DD83D;
    // target 0x4DD8B6 → rel8 = 0x4DD8B6 - 0x4DD83D = 0x79.
    var p0: [7]u8 = undefined;
    p0[0] = 0xB8; // mov eax, imm32
    std.mem.writeInt(u32, p0[1..5], @intCast(mute_arr), .little);
    p0[5] = 0xEB; // jmp rel8
    p0[6] = 0x79;
    writeBytes(0x4DD836, &p0);

    // 0x4DD8B6: cmp byte ptr [eax+esi], 0 ; jmp 0x4DDB73
    // Length = 9 bytes (4 cmp + 5 jmp). next_ip = 0x4DD8BF;
    // rel32 = 0x4DDB73 - 0x4DD8BF = 0x2B4.
    var p1: [9]u8 = .{ 0x80, 0x3C, 0x30, 0x00, 0xE9, 0, 0, 0, 0 };
    std.mem.writeInt(u32, p1[5..9], 0x4DDB73 -% 0x4DD8BF, .little);
    writeBytes(0x4DD8B6, &p1);

    // 0x4DDB73: je 0x4DDEB3 ; pop eax ; jmp 0x4DDFA4
    // Length = 12 bytes (6 je + 1 pop + 5 jmp).
    // je:  next_ip = 0x4DDB79; rel32 = 0x4DDEB3 - 0x4DDB79 = 0x33A.
    // jmp: next_ip = 0x4DDB7F; rel32 = 0x4DDFA4 - 0x4DDB7F = 0x425.
    var p2: [12]u8 = .{0} ** 12;
    p2[0] = 0x0F; p2[1] = 0x84; // je rel32
    std.mem.writeInt(u32, p2[2..6], 0x4DDEB3 -% 0x4DDB79, .little);
    p2[6] = 0x58; // pop eax
    p2[7] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p2[8..12], 0x4DDFA4 -% 0x4DDB7F, .little);
    writeBytes(0x4DDB73, &p2);

    // 0x4DDEB3: mov eax, sfxFilterArray ; add byte ptr [eax+esi], 1 ; jmp 0x4DDF32
    // Length = 11 bytes (5 mov + 4 add + 2 jmp).
    // jmp: next_ip = 0x4DDEBE; rel8 = 0x4DDF32 - 0x4DDEBE = 0x74.
    var p3: [11]u8 = undefined;
    p3[0] = 0xB8; // mov eax, imm32
    std.mem.writeInt(u32, p3[1..5], @intCast(filter_arr), .little);
    p3[5] = 0x80; p3[6] = 0x04; p3[7] = 0x30; p3[8] = 0x01; // add byte ptr [eax+esi], 1
    p3[9] = 0xEB; // jmp rel8
    p3[10] = 0x74;
    writeBytes(0x4DDEB3, &p3);

    // 0x4DDF32: cmp byte ptr [eax+esi], 1 ; pop eax ; ja 0x4DE223 ; jmp 0x4DDFA4
    // Length = 13 bytes (4 cmp + 1 pop + 6 ja + 2 jmp).
    // ja:  next_ip = 0x4DDF3D; rel32 = 0x4DE223 - 0x4DDF3D = 0x2E6.
    // jmp: next_ip = 0x4DDF3F; rel8 = 0x4DDFA4 - 0x4DDF3F = 0x65.
    var p4: [13]u8 = .{0} ** 13;
    p4[0] = 0x80; p4[1] = 0x3C; p4[2] = 0x30; p4[3] = 0x01; // cmp byte ptr [eax+esi], 1
    p4[4] = 0x58; // pop eax
    p4[5] = 0x0F; p4[6] = 0x87; // ja rel32
    std.mem.writeInt(u32, p4[7..11], 0x4DE223 -% 0x4DDF3D, .little);
    p4[11] = 0xEB; // jmp rel8
    p4[12] = 0x65;
    writeBytes(0x4DDF32, &p4);

    // 0x4DDFA4: mov edi, [esi*4 + 0x76C6F8] ; jmp 0x4DE217 (PLAY_SFX)
    // Length = 12 bytes (7 mov + 5 jmp).
    // jmp: next_ip = 0x4DDFB0; rel32 = 0x4DE217 - 0x4DDFB0 = 0x267.
    var p5: [12]u8 = undefined;
    p5[0] = 0x8B; p5[1] = 0x3C; p5[2] = 0xB5; // mov edi, [esi*4 + imm32]
    std.mem.writeInt(u32, p5[3..7], 0x76C6F8, .little);
    p5[7] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p5[8..12], 0x4DE217 -% 0x4DDFB0, .little);
    writeBytes(0x4DDFA4, &p5);

    // 0x4DE210: push eax ; jmp 0x4DD836 (last — has dependencies)
    // Length = 6 bytes (1 push + 5 jmp). The 7th byte (nop) is left untouched.
    // jmp: next_ip = 0x4DE216; rel32 = 0x4DD836 - 0x4DE216 = -0x9E0 = 0xFFFFF620.
    var p6: [6]u8 = .{0} ** 6;
    p6[0] = 0x50; // push eax
    p6[1] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p6[2..6], @as(u32, 0x4DD836) -% (@as(u32, 0x4DE210) + 6), .little);
    writeBytes(0x4DE210, &p6);

    // --- muteSpecificSfx (6 patches) ---
    // 0x40EEA1: mov edx, [esp] ; cmp edx, SFX_LEN ; jmp 0x40F1D1
    // Length = 14 bytes (3 mov + 6 cmp + 5 jmp).
    // jmp: next_ip = 0x40EEAF; rel32 = 0x40F1D1 - 0x40EEAF = 0x322.
    var m0: [14]u8 = undefined;
    m0[0] = 0x8B; m0[1] = 0x14; m0[2] = 0x24; // mov edx, [esp]
    m0[3] = 0x81; m0[4] = 0xFA; // cmp edx, imm32
    std.mem.writeInt(u32, m0[5..9], @intCast(sfx_len), .little);
    m0[9] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m0[10..14], @as(u32, 0x40F1D1) -% (@as(u32, 0x40EEA1) + 14), .little);
    writeBytes(0x40EEA1, &m0);

    // 0x40F1D1: jnl 0x40F398 (AFTER) ; jmp 0x40F392
    // Length = 11 bytes (6 jnl + 5 jmp).
    // jnl: next_ip = 0x40F1D7; rel32 = 0x40F398 - 0x40F1D7 = 0x1C1.
    // jmp: next_ip = 0x40F1DC; rel32 = 0x40F392 - 0x40F1DC = 0x1B6.
    var m1: [11]u8 = .{0} ** 11;
    m1[0] = 0x0F; m1[1] = 0x8D; // jnl rel32
    std.mem.writeInt(u32, m1[2..6], @as(u32, 0x40F398) -% (@as(u32, 0x40F1D1) + 6), .little);
    m1[6] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m1[7..11], @as(u32, 0x40F392) -% (@as(u32, 0x40F1D1) + 11), .little);
    writeBytes(0x40F1D1, &m1);

    // 0x40F392: jne 0x40F462 ; (AFTER:) mov edx, [eax+3C] ; push ecx ; push esi ; jmp 0x40F3D5
    // Length = 13 bytes (6 jne + 3 mov + 1 push + 1 push + 2 jmp).
    // jne: next_ip = 0x40F398; rel32 = 0x40F462 - 0x40F398 = 0xCA.
    // jmp: next_ip = 0x40F39F; rel8 = 0x40F3D5 - 0x40F39F = -0xCA → 0x36 (sign-extended).
    //   Wait: 0x40F3D5 - 0x40F39F = -0x6A = 0xFF96, so as rel8 = 0x96. But legacy uses 0x3B.
    //   Let me recompute: legacy patch is 13 bytes. next_ip after EB = 0x40F392 + 13 = 0x40F39F.
    //   0x40F3D5 - 0x40F39F = -0x6A → as u8 = 0x96. Hmm, legacy uses 0x3B which means
    //   target = 0x40F39F + 0x3B = 0x40F3DA. That's 0x40F3D5 + 5, the instruction after
    //   the jmp at 0x40F3D5. So 0x3B is actually a jmp PAST the 0x40F3D5 patch (which is
    //   5 bytes, E9 + rel32). So target = 0x40F3D5 + 5 = 0x40F3DA. Yes, that's correct.
    var m2: [13]u8 = .{0} ** 13;
    m2[0] = 0x0F; m2[1] = 0x85; // jne rel32
    std.mem.writeInt(u32, m2[2..6], @as(u32, 0x40F462) -% (@as(u32, 0x40F392) + 6), .little);
    m2[6] = 0x8B; m2[7] = 0x50; m2[8] = 0x3C; // mov edx, [eax+3C]
    m2[9] = 0x51; // push ecx
    m2[10] = 0x56; // push esi
    m2[11] = 0xEB; // jmp rel8
    m2[12] = 0x3B; // legacy value — jumps to 0x40F3DA (past the 0x40F3D5 patch)
    writeBytes(0x40F392, &m2);

    // 0x40F462: lea edx, [edx + sfxMuteArray] ; jmp 0x40FAE5
    // Length = 11 bytes (6 lea + 5 jmp).
    // jmp: next_ip = 0x40F46D; rel32 = 0x40FAE5 - 0x40F46D = 0x678.
    var m3: [11]u8 = undefined;
    m3[0] = 0x8D; m3[1] = 0x92; // lea edx, [edx + imm32]
    std.mem.writeInt(u32, m3[2..6], @intCast(mute_arr), .little);
    m3[6] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m3[7..11], @as(u32, 0x40FAE5) -% (@as(u32, 0x40F462) + 11), .little);
    writeBytes(0x40F462, &m3);

    // 0x40FAE5: cmp byte ptr [edx], 0 ; mov byte ptr [edx], 0 ; jmp 0x40FB01
    // Length = 8 bytes (3 cmp + 3 mov + 2 jmp).
    // jmp: next_ip = 0x40FAED; rel8 = 0x40FB01 - 0x40FAED = 0x14.
    var m4: [8]u8 = .{0} ** 8;
    m4[0] = 0x80; m4[1] = 0x3A; m4[2] = 0x00; // cmp byte ptr [edx], 0
    m4[3] = 0xC6; m4[4] = 0x02; m4[5] = 0x00; // mov byte ptr [edx], 0
    m4[6] = 0xEB; m4[7] = 0x14; // jmp rel8
    writeBytes(0x40FAE5, &m4);

    // 0x40FB01: je 0x40FB03 (DONE_MUTE) ; mov ecx, DX_MUTED_VOLUME ; (DONE_MUTE:) jmp 0x40F398 (AFTER)
    // Length = 12 bytes (2 je + 5 mov + 5 jmp).
    // je:  next_ip = 0x40FB03; rel8 = 0x40FB03 - 0x40FB03 = 0 → skip the mov.
    // jmp: next_ip = 0x40FB0D; rel32 = 0x40F398 - 0x40FB0D = -0x775 = 0xFFFFF88B.
    var m5: [12]u8 = .{0} ** 12;
    m5[0] = 0x74; m5[1] = 0x05; // je +5 (DONE_MUTE, just past the mov ecx)
    m5[2] = 0xB9; // mov ecx, imm32
    std.mem.writeInt(u32, m5[3..7], muted_vol, .little);
    m5[7] = 0xE9; // jmp rel32 (DONE_MUTE label)
    std.mem.writeInt(u32, m5[8..12], @as(u32, 0x40F398) -% (@as(u32, 0x40FB01) + 12), .little);
    writeBytes(0x40FB01, &m5);

    // 0x40F3D5: jmp 0x40EEA1 (last — has dependencies)
    // Length = 5 bytes (E9 + rel32).
    // jmp: next_ip = 0x40F3DA; rel32 = 0x40EEA1 - 0x40F3DA = -0x539 = 0xFFFFFAC7.
    var m6: [5]u8 = undefined;
    m6[0] = 0xE9;
    std.mem.writeInt(u32, m6[1..5], @as(u32, 0x40EEA1) -% (@as(u32, 0x40F3D5) + 5), .little);
    writeBytes(0x40F3D5, &m6);

    log.?.info("SFX dedup ASM hooks applied (filter_array=0x{x:0>8} mute_array=0x{x:0>8})", .{
        filter_arr, mute_arr,
    });
}

/// Resolve the path to mapping.ini relative to the DLL's own directory.
///
/// The DLL is typically installed at `<MBAACC>/zzcaster/hook.dll`, so
/// mapping.ini lives at `<MBAACC>/zzcaster/mapping.ini` — same directory.
/// Using the DLL's own path (via GetModuleFileNameA) avoids CWD-dependent
/// resolution bugs: if the user launches zzcaster.exe from a shortcut or
/// a different working directory, MBAA.exe inherits that CWD, and the
/// relative path "zzcaster/mapping.ini" won't resolve. The DLL's own path
/// is always correct regardless of CWD.
///
/// Returns a slice into the provided buffer, or null if the path can't be
/// resolved (e.g. GetModuleFileNameA failed or the buffer is too small).
fn resolveMappingIniPath(buf: []u8) ?[]const u8 {
    var dll_path: [512]u8 = undefined;
    const len = win32.GetModuleFileNameA(dll_module_handle, &dll_path, dll_path.len);
    if (len == 0) return null;

    // Find the last path separator and replace everything after it with
    // "mapping.ini". e.g. "C:\MBAACC\zzcaster\hook.dll" → "C:\MBAACC\zzcaster\mapping.ini"
    var last_sep: usize = 0;
    for (dll_path[0..len], 0..) |ch, i| {
        if (ch == '\\' or ch == '/') last_sep = i;
    }
    if (last_sep == 0) return null; // no separator found — shouldn't happen

    const dir = dll_path[0 .. last_sep + 1]; // include trailing separator
    const filename = "mapping.ini";
    if (dir.len + filename.len + 1 > buf.len) return null; // +1 for NUL

    @memcpy(buf[0..dir.len], dir);
    @memcpy(buf[dir.len..dir.len + filename.len], filename);
    const total = dir.len + filename.len;
    buf[total] = 0; // null-terminate for Win32 APIs
    return buf[0..total];
}

fn applyPostLoadHacks() void {
    if (log == null) return;
    log.?.info("Applying post-load hacks...", .{});

    if (is_training) {
        var fg: [2]u8 = .{ 0xEB, 0x22 };
        writeBytes(@intFromPtr(force_goto_addr), &fg);
        log.?.info("forceGotoTraining", .{});
    } else {
        var fg: [2]u8 = .{ 0xEB, 0x3F };
        writeBytes(@intFromPtr(force_goto_addr), &fg);
        log.?.info("forceGotoVersus", .{});
    }
    damage_level_addr.* = 2;
    timer_speed_addr.* = 2;
    win_count_vs_addr.* = 2;

    // NOTE: SDL_Init + controller open is deferred to initSdlOnMainThread(),
    // which runs on MBAA's main thread (via frameStep). SDL is NOT thread-safe
    // — initializing it on the worker thread and polling on the main thread
    // causes all SDL_GameControllerGetButton / SDL_JoystickGetButton calls to
    // return 0, making controllers appear dead.

    // Init keyboard (reads MBAA.exe file, no threading concerns)
    keyboard.init(log.?, app_io_backend.io());

    // Init ENet connection for netplay
    if (is_netplay and nm != null) {
        // Don't block in DllMain waiting for the peer — under Wine that
        // appears to stall the game's main thread. Instead, ENet setup
        // runs to completion synchronously here, but the wait-for-connect
        // happens lazily in frameStep (see NetplayManager.connect_attempts).
        nm.?.initEnet() catch {
            log.?.err("ENet init failed — netplay disabled", .{});
            is_netplay = false;
        };
    }
}

/// Initialize SDL2 and open controllers/gamepads. MUST be called on MBAA's
/// main thread (i.e. from frameStep), because SDL is not thread-safe and
/// all subsequent SDL_GameControllerGetButton / SDL_PollEvent calls happen
/// on that thread. Called once on the first frameStep after config is
/// received.
fn initSdlOnMainThread() void {
    if (sdl_init_done) return;
    sdl_init_done = true;

    if (c.SDL_Init(c.SDL_INIT_GAMECONTROLLER | c.SDL_INIT_JOYSTICK) == 0) {
        sdl_initialized = true;
        reader = gamepad.GamepadReader.init(log.?);

        // Load custom controller mappings if available. If no mapping.ini
        // exists, fall back to the SDL_GameController API with built-in
        // button layout (works for any XInput-compatible controller).
        //
        // Path resolution: use the DLL's own directory (robust against
        // CWD mismatches), falling back to "zzcaster/mapping.ini".
        var mapping_path_buf: [600]u8 = undefined;
        const mapping_path = resolveMappingIniPath(&mapping_path_buf) orelse "zzcaster/mapping.ini";
        log.?.info("Looking for mapping.ini at: {s}", .{mapping_path});

        var p1_mapping: mapper.ControllerMapping = undefined;
        var p2_mapping: mapper.ControllerMapping = undefined;
        var have_mappings: bool = false;
        if (mapper.loadMapping(mapping_path, app_io_backend.io(), log.?)) |mappings| {
            p1_mapping = mappings.p1;
            p2_mapping = mappings.p2;
            have_mappings = true;
            log.?.info("Custom mapping loaded successfully", .{});
        } else {
            log.?.info("No custom mapping found — using GameController API with built-in button layout", .{});
            p1_mapping = mapper.defaultXboxMapping();
            p2_mapping = mapper.defaultXboxMapping();
            p2_mapping.device_index = -1;
        }

        // Apply P1 mapping. ONLY set custom_mapping + open raw joystick
        // when the user has explicitly saved a mapping.ini. Without a
        // saved mapping, leave reader.custom_mapping = null so
        // readGameController() handles input via the GameController API.
        if (have_mappings) {
            reader.?.custom_mapping = p1_mapping;
            openMappedJoystick(&reader.?, p1_mapping, "P1");
        } else {
            log.?.info("P1: using GameController API (no custom mapping)", .{});
        }

        // Apply P2 mapping.
        if (have_mappings or p2_mapping.device_index >= 0) {
            reader2 = gamepad.GamepadReader{};
            reader2.?.custom_mapping = p2_mapping;
            openMappedJoystick(&reader2.?, p2_mapping, "P2");
        } else {
            log.?.info("P2: keyboard-only default, no reader2 allocated", .{});
        }
    } else {
        log.?.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
    }
}

/// Open the SDL_Joystick referenced by `m.device_index` and attach it to
/// `r.mapped_joystick`. If `device_index < 0` the mapping is keyboard-only
/// and nothing is opened. If the requested index can't be opened, falls
/// back to joystick 0 so the mapping still works instead of silently
/// disabling input.
///
/// Closes any existing `r.controller` once a raw joystick is successfully
/// attached, because the custom-mapping path uses SDL_Joystick* API and
/// having both APIs open on the same device produces duplicate input.
fn openMappedJoystick(r: *gamepad.GamepadReader, m: mapper.ControllerMapping, label: []const u8) void {
    if (m.device_index < 0) {
        log.?.info("{s}: mapping uses keyboard (device=-1)", .{label});
        return;
    }
    var opened: ?*c.SDL_Joystick = c.SDL_JoystickOpen(m.device_index);
    if (opened == null) {
        log.?.warn("{s}: joystick {d} not available, trying index 0", .{ label, m.device_index });
        opened = c.SDL_JoystickOpen(0);
    }
    r.mapped_joystick = @ptrCast(opened);
    if (r.mapped_joystick != null) {
        log.?.info("{s}: opened joystick for mapping", .{label});
        // Close any GameController that GamepadReader.init() opened for
        // this same physical device — we're using raw joystick API now.
        if (r.controller != null) {
            c.SDL_GameControllerClose(@ptrCast(r.controller));
            r.controller = null;
        }
    } else {
        log.?.err("{s}: no joystick available for mapping — input will not work", .{label});
    }
}

/// Worker thread entry point: runs lazyInit on a thread with a real stack.
/// DllMain(PROCESS_ATTACH) can't do heavy init itself — the remote
/// LoadLibraryA thread under Wine has a small stack that Zig 0.16's std.Io
/// blows (EXCEPTION_STACK_OVERFLOW). So DllMain spawns THIS thread with a
/// 256KB stack, it does all the real init (logger, IPC, ASM hooks, config),
/// and once the ASM hooks are installed the game's main loop starts calling
/// frameStep. frameStep waits on dll_initialized before doing anything else.
fn initThread(_: ?*anyopaque) callconv(.winapi) u32 {
    lazyInit();
    return 0;
}

/// Heavy initialization, deferred from DllMain to the worker thread it
/// spawns. Runs on a thread with a 256KB stack, where Zig 0.16's std.Io
/// (used by logging.Logger.init) won't blow the stack the way it does on
/// the remote LoadLibraryA thread. Does the logger setup, IPC connect,
/// ASM hook install, and config read — everything that used to live in
/// DllMain's PROCESS_ATTACH.
fn lazyInit() void {
    if (dll_initialized) return;
    dll_initialized = true;

    const io = app_io_backend.io();
    var pid_buf: [32]u8 = undefined;
    const pid = win32.GetCurrentProcessId();
    const primary_path = std.fmt.bufPrintZ(&pid_buf, "zzcaster/dll_{d}.log", .{pid}) catch null;

    // Logger init with a fallback chain: never let a logging failure prevent
    // the DLL from initializing (a FALSE return from DllMain would unload us,
    // and a missing log makes such a failure invisible). Try the canonical
    // zzcaster/dll_<pid>.log first, then the CWD root, then %TEMP%.
    log_storage = init: {
        if (primary_path) |p| {
            if (logging.Logger.init(std.heap.page_allocator, io, p)) |logger| break :init logger else |_| {}
        }
        // Fallback: same filename in the CWD root (no zzcaster/ subdir).
        var root_buf: [48]u8 = undefined;
        if (std.fmt.bufPrintZ(&root_buf, "dll_{d}.log", .{pid}) catch null) |p| {
            if (logging.Logger.init(std.heap.page_allocator, io, p)) |logger| break :init logger else |_| {}
        }
        // Fallback: Windows %TEMP% (always writable).
        var temp_buf: [300]u8 = undefined;
        const temp_len = win32.GetTempPathA(temp_buf.len, &temp_buf);
        if (temp_len > 0 and temp_len < temp_buf.len) {
            var full_temp: [320]u8 = undefined;
            if (std.fmt.bufPrintZ(&full_temp, "{s}zzcaster_dll_{d}.log", .{ temp_buf[0..temp_len], pid }) catch null) |p| {
                if (logging.Logger.init(std.heap.page_allocator, io, p)) |logger| break :init logger else |_| {}
            }
        }
        break :init logging.Logger{ .allocator = std.heap.page_allocator, .io = io };
    };
    log = &log_storage;
    log.?.info("hook.dll: lazyInit (Zig) pid={d}", .{pid});

    _ = win32.SetThreadExecutionState(0x80000000 | 0x00000001 | 0x00000002 | 0x00000004);

    connectPipe();
    applyPreLoadHacks();

    // Non-blocking: returns immediately if the launcher hasn't sent config
    // yet (frameStep will retry). If it's already here, apply post-load hacks now.
    waitForConfig();
    if (config_received) applyPostLoadHacks();
}

fn frameStep() callconv(.c) void {
    // The heavy init (logger, IPC, ASM hooks, config) runs on the worker
    // thread spawned by DllMain. frameStep is only ever called once those
    // ASM hooks are installed — i.e. after lazyInit has run far enough. But
    // there's a window between "hooks installed" and "lazyInit fully done";
    // during it, bail out until dll_initialized is set. (We deliberately do
    // NOT call lazyInit() here — it must not run on two threads at once.)
    if (!dll_initialized) return;
    if (log == null) return;

    // If DllMain returned before the launcher sent the config (the
    // non-blocking waitForConfig path), pick it up here and apply the
    // post-load hacks lazily. After this, frameStep behaves the same
    // as if config had arrived during DllMain.
    if (!config_received and ipc_connected) {
        waitForConfig();
        if (config_received) {
            applyPostLoadHacks();
        }
    }

    // SDL must be initialized on MBAA's main thread (this thread). The
    // worker thread's applyPostLoadHacks deferred SDL init to here. This
    // runs once on the first frameStep after config is received.
    if (config_received and !sdl_init_done) {
        initSdlOnMainThread();
    }

    // One-shot diagnostic: log the input pipeline state once, right after
    // SDL init has run. This lets the user check the log to see whether
    // the custom mapping was loaded and whether reader/reader2 were
    // allocated. If reader is null here, frameStep will fall back to
    // keyboard.readInput() which uses MBAA's built-in config.
    if (config_received and sdl_init_done and !input_diag_logged) {
        input_diag_logged = true;
        const base_ptr_val = @as(usize, @bitCast(ptr_to_write_input_addr[0..@sizeOf(usize)].*));
        log.?.info("InputDiag: reader={} reader2={} keyboard.init={} base_ptr=0x{x:0>8} game_mode={d} is_netplay={}", .{
            reader != null,
            reader2 != null,
            keyboard.isInitialized(),
            base_ptr_val,
            game_mode_addr.*,
            is_netplay,
        });
        if (reader) |*r| {
            if (r.custom_mapping) |m| {
                log.?.info("InputDiag: P1 mapping device={d} a.type={s}", .{ m.device_index, @tagName(m.a.type) });
            } else {
                log.?.info("InputDiag: P1 no custom_mapping (will use default Xbox or legacy keyboard)", .{});
            }
        }
        if (reader2) |*r| {
            if (r.custom_mapping) |m| {
                log.?.info("InputDiag: P2 mapping device={d} a.type={s}", .{ m.device_index, @tagName(m.a.type) });
            }
        }
    }

    const world_timer = world_timer_addr.*;
    if (world_timer == last_world_timer) return;
    last_world_timer = world_timer;

    const game_mode = game_mode_addr.*;

    // Detect game mode changes → state transitions
    if (game_mode != prev_game_mode) {
        if (nm) |*n| n.onGameModeChanged(game_mode);
        prev_game_mode = game_mode;
    }

    // Clear inputs
    writeInput(1, 0);
    writeInput(2, 0);

    // Clear SFX dedup filter array at the start of each frame, UNLESS we're
    // in the middle of a rollback re-run. The filter array is used to
    // suppress duplicate SFX during a single re-run pass; without clearing
    // it per-frame, the filter accumulates indefinitely and the ASM hook
    // (which skips playback when filter[i] > 1) mutes every SFX after its
    // 2nd play — causing "some SFX plays only once" (issue #3).
    //
    // During a rollback re-run, the filter is managed by
    // SfxDedup.applyRollbackFilter / saveRerunSounds / finishedRerun —
    // clearing it here would destroy the 0x80 sentinels that track which
    // pre-rollback sounds need cancellation.
    //
    // In offline mode (nm == null), there is no rollback, so we always
    // clear. In netplay mode, we clear only when not re-running.
    if (nm) |*n| {
        if (!n.isRerunning()) {
            @memset(&sfx_dedup.sfx_filter_array, 0);
            @memset(&sfx_dedup.sfx_mute_array, 0);
        }
    } else {
        // Offline — no NetplayManager, no rollback. Always clear.
        @memset(&sfx_dedup.sfx_filter_array, 0);
        @memset(&sfx_dedup.sfx_mute_array, 0);
    }

    // Check if game is exiting
    if (alive_flag_addr.* == 0) return;

    const is_pre_game = (game_mode == mode_startup or game_mode == mode_opening or
        game_mode == mode_title or game_mode == mode_main);

    if (is_pre_game) {
        skip_frames_addr.* = 1;
        if (world_timer % 2 == 0) {
            writeInput(1, button_confirm << 4);
        }
        return;
    }

    // === In-game / chara-select ===
    skip_frames_addr.* = 0;

        if (nm) |*n| {
            // If ENet isn't connected yet (connection setup was deferred from
            // DllMain so the main thread can keep ticking), poll for the
            // connect event here with a short timeout.
            //
            // The launcher already validated the peer via its own handshake
            // before opening the game, so this reconnect should succeed in
            // well under a second. We cap at ~15s (300 × 50ms) — if the peer
            // doesn't reconnect by then something is genuinely wrong (firewall
            // killed the post-launch UDP path, or the peer's game crashed).
            if (!n.enet_connected and !n.connect_attempts_exhausted) {
                if (n.connect_attempts == 0) {
                    log.?.info("ENet reconnecting (peer already confirmed by launcher)...", .{});
                }
                n.connect_attempts += 1;
                n.pollAndDispatch(50);
                if (!n.enet_connected and n.connect_attempts > 300) {
                    // Stage-0 diag (netcode-test-plan.md Stage 0.3): distinguish
                    // "no peer ever responded" (silent timeout) from "the peer
                    // actively refused us" (disconnects observed) from "we
                    // received unexpected packets instead of a CONNECT". The
                    // diag_* counters are maintained in pollEnet and reset
                    // only on a successful connect — so their values here are
                    // exactly what we saw across the ~15s connect window.
                    if (n.diag_connect_disconnects > 0) {
                        log.?.err("No opponent reconnected after ~15s — peer REFUSED/disconnected (disconnects={d}, stray_packets={d})", .{
                            n.diag_connect_disconnects, n.diag_connect_receives,
                        });
                    } else {
                        log.?.err("No opponent reconnected after ~15s — silent timeout (no CONNECT/REFUSE event; stray_packets={d})", .{
                            n.diag_connect_receives,
                        });
                    }
                    n.connect_attempts_exhausted = true;
                }
            }

            // === HOST: drain spectator events (accept new spectators, timeouts) ===
            if (n.config.is_host and n.enet_connected) {
                n.drainSpectatorEvents();
            }

            if (n.config.is_spectator) {
                // === SPECTATOR MODE ===
                // No local input reading — both players' inputs come from the host.
                n.updateFrame();

                // Poll for BothInputs packet from host via pollAndDispatch,
                // which routes type 0x20 to applyBothInputsPacket internally.
                n.pollAndDispatch(3);

                // Check for disconnect
                if (!n.enet_connected) {
                    log.?.err("Host disconnected — spectator exiting", .{});
                    alive_flag_addr.* = 0;
                    return;
                }

                // Spectator never rolls back — just write both inputs.
                n.writeGameInputs();
                return;
            }

            // === NORMAL NETPLAY MODE (player 1 host or player 2 client) ===
            // Read local input
            const raw_input: u16 = blk: {
                if (reader) |*r| {
                    r.update();
                    if (r.hasGamepad()) break :blk r.readInput();
                }
                break :blk keyboard.readInput();
            };

            // Apply per-state input filtering (catch-up mash, mask Cancel in
            // chara-select, only Confirm/Cancel in loading/intro/skippable).
            // This is the Zig equivalent of CCCaster's getInput(player) dispatch.
            const local_input: u16 = n.getNetplayInput(raw_input);

            n.updateFrame();

            // Set local input (with delay)
            n.setLocalInput(local_input);

            // Send local inputs to peer
            n.sendLocalInputs();

            // Sync RNG (host only, once per round — onStateTransition resets
            // rng_synced so the host re-sends at the start of each round).
            n.syncRngState();

            // Poll for remote messages (inputs, RNG, TransitionIndex)
            n.pollAndDispatch(3);

            // Check for disconnect — only if we WERE connected and now aren't.
            if (n.was_connected and !n.enet_connected and n.config.is_netplay) {
                log.?.err("Peer disconnected during game!", .{});
                alive_flag_addr.* = 0; // force exit
                return;
            }

            // Heartbeat check: if no packet received in 20s, the peer is dead.
            // This catches crashes/kills that don't generate a DISCONNECT event.
            if (n.enet_connected and n.checkHeartbeat()) {
                log.?.err("Peer heartbeat timeout (20s no packets) — forcing disconnect", .{});
                n.enet_connected = false;
                alive_flag_addr.* = 0;
                return;
            }

            // Wait for remote inputs. This is the lockstep gate: the game
            // frame cannot advance until we have the remote's input for
            // (our_index, our_frame + delay). While waiting, we keep polling
            // and periodically resend our inputs (in case of packet loss).
            //
            // This blocks the game's main thread — that's intentional and
            // correct for lockstep netcode. On localhost the wait is
            // sub-frame; over the internet it introduces jitter equal to
            // the ping.
            //
            // TIMEOUT: if the remote doesn't respond within 10s (matching
            // CCCaster's MAX_WAIT_INPUTS_INTERVAL), we force-exit the game
            // instead of hanging forever.
            if (!n.isRemoteInputReady()) {
                const wait_start = std.Io.Clock.now(.real, app_io_backend.io()).toMilliseconds();
                var last_resend = wait_start;
                var warned = false;
                while (!n.isRemoteInputReady()) {
                    n.pollAndDispatch(10);
                    const now = std.Io.Clock.now(.real, app_io_backend.io()).toMilliseconds();

                    // Resend inputs every 100ms while waiting (matches
                    // legacy RESEND_INPUTS_INTERVAL).
                    if (now - last_resend > 100) {
                        n.sendLocalInputs();
                        last_resend = now;
                    }

                    // Check for disconnect during wait
                    if (n.was_connected and !n.enet_connected) {
                        log.?.err("Peer disconnected while waiting for input!", .{});
                        alive_flag_addr.* = 0;
                        return;
                    }

                    // Heartbeat check during wait
                    if (n.enet_connected and n.checkHeartbeat()) {
                        log.?.err("Peer heartbeat timeout during input wait", .{});
                        n.enet_connected = false;
                        alive_flag_addr.* = 0;
                        return;
                    }

                    // Log after 5s but keep waiting
                    if (!warned and now - wait_start > 5000) {
                        log.?.warn("Waiting for remote input... (5s elapsed)", .{});
                        warned = true;
                    }

                    // TIMEOUT after 10s — force exit (matches CCCaster)
                    if (now - wait_start > 10000) {
                        log.?.err("Timed out waiting for remote input (10s) — forcing exit", .{});
                        alive_flag_addr.* = 0;
                        return;
                    }
                }
            }

            // Check rollback
            if (n.checkRollback()) {
                skip_frames_addr.* = 1;
                return;
            }

            // Check rerun completion
            if (n.isRerunning()) {
                _ = n.checkRerunComplete();
                return;
            }

            // Decrement rollback timer
            if (n.rollback_timer < n.min_rollback_spacing) {
                n.rollback_timer +%= 1;
                if (n.rollback_timer == 0) n.rollback_timer = n.min_rollback_spacing;
            }

            // Save state for this frame
            _ = n.state_pool.saveState(n.indexed_frame.frame, n.indexed_frame.index);
            // Snapshot SFX filter into history ring (for future rollback dedup).
            if (n.sfx_dedup) |*sd| sd.snapshotToHistory(n.indexed_frame.frame);

            // Write both players' inputs
            n.writeGameInputs();

            // === HOST: broadcast BothInputs to spectators ===
            if (n.config.is_host and n.spectators != null) {
                n.spectators.?.frameStepSpectators(
                    n.indexed_frame.index,
                    n.indexed_frame.frame,
                    world_timer,
                    fillBothInputsCallback,
                );
            }
    } else {
        // === OFFLINE MODE ===
        // P1 input — uses reader (with custom_mapping from [Player1]),
        // falling back to the legacy keyboard reader only if reader is
        // null/uninitialized. The legacy keyboard.readInput() polls
        // MBAA.exe's built-in config at offset 0x14D2C0 — it's a
        // last-resort fallback, not the primary path.
        const p1_input: u16 = blk: {
            if (reader) |*r| {
                r.update();
                if (r.hasGamepad()) break :blk r.readInput();
            }
            break :blk keyboard.readInput();
        };
        // P2 input — uses reader2 (with custom_mapping from [Player2]).
        // reader2 is null in netplay/spectator modes (P2 input comes
        // from the network there) and may be null if the user never
        // saved a [Player2] section in mapping.ini. When null, P2 stays
        // at neutral (0) — there's no legacy keyboard reader for P2
        // because MBAA.exe's config table is single-player.
        const p2_input: u16 = blk: {
            if (reader2) |*r| {
                r.update();
                if (r.hasGamepad()) break :blk r.readInput();
            }
            break :blk 0;
        };
        writeInput(1, p1_input);
        writeInput(2, p2_input);

        // Periodic diagnostic: log P1/P2 input values every 300 frames
        // (~5s at 60fps). If p1_input is always 0 even when the user
        // presses keys, the binding poll is failing — check whether
        // reader.custom_mapping loaded correctly (see InputDiag above).
        // If p1_input is non-zero but the game still doesn't respond,
        // the issue is in writeInput (wrong base ptr, wrong offsets, or
        // MBAA's own polling clobbering our writes).
        input_log_frame +%= 1;
        if (input_log_frame % 300 == 0) {
            log.?.info("InputFrame {d}: P1=0x{x:0>4} P2=0x{x:0>4} mode={d}", .{
                input_log_frame, p1_input, p2_input, game_mode,
            });
        }
    }
}

// Callback used by SpectatorManager.frameStepSpectators to fill a BothInputs
// packet for a given (index, frame) — we route it back into NetplayManager.
fn fillBothInputsCallback(index: u32, frame: u32, out: []u8) usize {
    if (nm) |*n| {
        return n.fillBothInputsForBroadcast(index, frame, out);
    }
    return 0;
}

fn writeInput(player: u8, input: u16) void {
    // ptr_to_write_input_addr points to a usize holding the base address of
    // the game's input struct. On 64-bit targets the host address is
    // 4-byte aligned but usize wants 8, so we read through a u8 pointer
    // and bit-cast the result.
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

fn writeBytes(addr: u32, data: []const u8) void {
    const ptr: [*]u8 = @ptrFromInt(addr);
    var old: u32 = 0;
    const k32 = struct {
        extern "kernel32" fn VirtualProtect(lpAddress: ?*anyopaque, dwSize: usize, flNewProtect: u32, lpflOldProtect: *u32) callconv(.winapi) i32;
        extern "kernel32" fn FlushInstructionCache(hProcess: ?*anyopaque, lpBaseAddress: ?*const anyopaque, dwSize: usize) callconv(.winapi) i32;
    };
    _ = k32.VirtualProtect(ptr, data.len, 0x40, &old);
    @memcpy(ptr[0..data.len], data);
    _ = k32.VirtualProtect(ptr, data.len, old, &old);
    _ = k32.FlushInstructionCache(null, ptr, data.len);
}

// rel32(target, source, instr_len) returns the rel32 displacement for a
// `jmp`/`call` instruction at `source` whose next_ip (source + instr_len)
// should land on `target`. Result is bitcast to u32 for use with writeInt.
// Handles wraparound for backward jumps.
fn rel32(target: u32, source: u32, instr_len: u32) u32 {
    const t: i64 = @intCast(target);
    const s: i64 = @intCast(source);
    const l: i64 = @intCast(instr_len);
    return @bitCast(@as(i32, @intCast(t - (s + l))));
}
