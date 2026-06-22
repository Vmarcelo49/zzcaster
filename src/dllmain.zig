const std = @import("std");
const logging = @import("logging.zig");
const gamepad = @import("gamepad.zig");
const keyboard = @import("keyboard.zig");
const netman = @import("netplay_manager.zig");
const sfx_dedup = @import("sfx_dedup.zig");
const mapper = @import("controller_mapper.zig");
const asm_hacks = @import("asm_hacks.zig");
const frame_step = @import("frame_step.zig");

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

// Game memory addresses. Published for cross-file access (asm_hacks.zig
// and frame_step.zig reach these via @import("dllmain.zig")).
pub const game_mode_addr: *u32 = @ptrFromInt(0x54EEE8);
pub const world_timer_addr: *u32 = @ptrFromInt(0x55D1D4);
pub const skip_frames_addr: *u32 = @ptrFromInt(0x55D25C);
pub const alive_flag_addr: *u8 = @ptrFromInt(0x76E650);
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

// ASM addresses used by applyPostLoadHacks (lives here). The hook-install
// constants (loop_start_addr, hook_call1_addr, hook_call2_addr,
// multiple_melty_addr) moved to asm_hacks.zig along with the patch
// installers that use them.
const force_goto_addr: *u8 = @ptrFromInt(0x42B475);

// Zig 0.16: every file/stdout operation needs an Io handle. The DLL runs
// inside the game's process, so we use init_single_threaded to avoid
// spawning worker threads that could interfere with the game.
pub var app_io_backend: std.Io.Threaded = .init_single_threaded;

var frame_callback: ?*const fn () callconv(.c) void = null;
var log_storage: logging.Logger = undefined;
pub var log: ?*logging.Logger = null;
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
pub var reader: ?gamepad.GamepadReader = null;
// Diagnostic: one-shot flag so frameStep logs the input pipeline state on
// the first frame where config_received becomes true. Lets the user
// verify from the log that reader / reader2 / keyboard were set up.
var input_diag_logged: bool = false;
// Periodic input-value logging frame counter.
pub var input_log_frame: u32 = 0;
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
pub var reader2: ?gamepad.GamepadReader = null;
var sdl_initialized: bool = false;

// Netplay
pub var nm: ?netman.NetplayManager = null;
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

// `pub export` so asm_hacks.applyHookMainLoop can take this function's
// address via `&dllmain.zzcasterFrameCallback` when wiring the main-loop
// patches. The `export` also keeps the symbol in the DLL's export table
// (matches the legacy layout).
pub export fn zzcasterFrameCallback() callconv(.c) void {
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

// applyPreLoadHacks / applyHookMainLoop / applyHijackControls /
// applySfxAsmHacks / writeBytes / rel32 moved to asm_hacks.zig (task 2b).
// They're reached via the `asm_hacks` import below. Shared `log` logger is
// accessed by asm_hacks.zig through @import("dllmain.zig").log.

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
        asm_hacks.writeBytes(@intFromPtr(force_goto_addr), &fg);
        log.?.info("forceGotoTraining", .{});
    } else {
        var fg: [2]u8 = .{ 0xEB, 0x3F };
        asm_hacks.writeBytes(@intFromPtr(force_goto_addr), &fg);
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
    asm_hacks.applyPreLoadHacks();

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

    // Watch the intro-state flag every frame for the chara_intro → in_game
    // transition (the second sync barrier). game_mode alone fires during the
    // intro cutscene; the intro flag (CC_INTRO_STATE_ADDR) drops to 0 only
    // when players can actually move. Also enables RNG sync on the
    // intro-done edge. Matches legacy DllMain.cpp:1266 + 1179.
    if (nm) |*n| {
        n.checkIntroDone();
        // Round-over detection: tick the countdown, then check. Drives the
        // InGame→Skippable transition via the no_input_flags (KO/time over),
        // matching legacy checkRoundOver (DllMain.cpp:1200). Only acts while
        // in_game; harmless otherwise.
        n.tickRoundOverTimer();
        n.checkRoundOver();
        // During a rollback re-run past the pre-game intro window, force the
        // intro-state flag to 0 so the re-run stays on the gameplay path.
        // Matches DllMain.cpp:975-976.
        n.clearIntroStateDuringRollback();
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

    // In-game / chara-select branch — extracted to frame_step.zig (task 2b)
    // so dllmain.zig stays focused on per-frame plumbing (init, diag, mode
    // transitions, SFX clear, pre-game). frameStepInGame handles the lazy
    // ENet reconnect, host-side spectator drain, and dispatches to
    // frameStepSpectator / frameStepNetplay / frameStepOffline. All early
    // `return`s inside those helpers exit the helper, which is equivalent to
    // the original inline `return`s from frameStep — frameStep has no code
    // after this call.
    frame_step.frameStepInGame(world_timer, game_mode);
}

// Callback used by SpectatorManager.frameStepSpectators to fill a BothInputs
// packet for a given (index, frame) — we route it back into NetplayManager.
// `pub` so frame_step.frameStepNetplay can pass it to
// n.spectators.?.frameStepSpectators (the host-side BothInputs broadcast).
pub fn fillBothInputsCallback(index: u32, frame: u32, out: []u8) usize {
    if (nm) |*n| {
        return n.fillBothInputsForBroadcast(index, frame, out);
    }
    return 0;
}

// writeInput — `pub` so frame_step.frameStepOffline can call it (it lives
// here rather than in frame_step.zig because it owns the input-struct base
// pointer layout, which is closely tied to the game-mode constants above).
pub fn writeInput(player: u8, input: u16) void {
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

// writeBytes / rel32 moved to asm_hacks.zig (task 2b). They're reached via
// `asm_hacks.writeBytes(...)` and `asm_hacks.rel32(...)` from the patch
// installers in that file, and from applyPostLoadHacks above.
