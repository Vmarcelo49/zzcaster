const std = @import("std");
const logging = @import("common").logging;
const gamepad = @import("gamepad.zig");
const keyboard = @import("keyboard.zig");
const netman = @import("netplay_manager.zig");
const sfx_dedup = @import("sfx_dedup.zig");
const mapper = @import("controller_mapper.zig");
const asm_hacks = @import("asm_hacks.zig");
const frame_step = @import("frame_step.zig");
const state = @import("dll_state.zig");

const game_mode_addr = state.game_mode_addr;
const world_timer_addr = state.world_timer_addr;
const skip_frames_addr = state.skip_frames_addr;
const alive_flag_addr = state.alive_flag_addr;
const app_io_backend = &state.app_io_backend;
const writeInput = state.writeInput;
const fillBothInputsCallback = state.fillBothInputsCallback;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

const win32 = struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetEnvironmentVariableA(
        lpName: [*:0]const u8,
        lpBuffer: [*]u8,
        nSize: u32,
    ) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn ReadFile(
        hFile: ?*anyopaque,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WriteFile(
        hFile: ?*anyopaque,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn PeekNamedPipe(
        hNamedPipe: ?*anyopaque,
        lpBuffer: ?*anyopaque,
        nBufferSize: u32,
        lpBytesRead: ?*u32,
        lpTotalBytesAvail: *u32,
        lpBytesLeftThisMessage: ?*u32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn ExitProcess(uExitCode: u32) callconv(.winapi) noreturn;
    extern "kernel32" fn SetThreadExecutionState(esFlags: u32) callconv(.winapi) u32;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
    extern "kernel32" fn GetModuleFileNameA(hModule: ?*anyopaque, lpFilename: [*]u8, nSize: u32) callconv(.winapi) u32;
    extern "kernel32" fn CreateThread(
        lpThreadAttributes: ?*anyopaque,
        dwStackSize: usize,
        lpStartAddress: ?*const fn (?*anyopaque) callconv(.winapi) u32,
        lpParameter: ?*anyopaque,
        dwCreationFlags: u32,
        lpThreadId: ?*u32,
    ) callconv(.winapi) ?*anyopaque;

    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const OPEN_EXISTING: u32 = 3;
    const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
};

const default_pipe_name = "\\\\.\\pipe\\zzcaster_pipe";

/// Static storage so resolvePipeName can return a slice that outlives the call.
var resolved_pipe_name_buf: [128:0]u8 = [_:0]u8{0} ** 128;

/// Resolve the pipe name. The launcher sets CCCASTER_PIPE per PID so multiple
/// zzcaster.exe instances run side-by-side; falls back to the default.
fn resolvePipeName() [:0]const u8 {
    var name_buf: [64]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "CCCASTER_PIPE", .{}) catch return default_pipe_name_z;
    var buf: [128]u8 = undefined;
    const len = win32.GetEnvironmentVariableA(name_z.ptr, &buf, buf.len);
    if (len == 0 or len >= buf.len) {
        return default_pipe_name_z;
    }
    const prefix = "\\\\.\\pipe\\";
    if (prefix.len + len + 1 > resolved_pipe_name_buf.len) return default_pipe_name_z;
    std.mem.copyForwards(u8, resolved_pipe_name_buf[prefix.len..][0..len], buf[0..len]);
    @memcpy(resolved_pipe_name_buf[0..prefix.len], prefix);
    resolved_pipe_name_buf[prefix.len + len] = 0;
    return resolved_pipe_name_buf[0 .. prefix.len + len :0];
}

const default_pipe_name_z: [:0]const u8 = "\\\\.\\pipe\\zzcaster_pipe";

// Private to dllmain — used only by applyPostLoadHacks.
const damage_level_addr: *u32 = @ptrFromInt(0x553FCC);
const timer_speed_addr: *u32 = @ptrFromInt(0x553FD0);
const win_count_vs_addr: *u32 = @ptrFromInt(0x553FDC);

const mode_startup: u32 = 65535;
const mode_opening: u32 = 3;
const mode_title: u32 = 2;
const mode_main: u32 = 25;
const mode_in_game: u32 = 1;

const button_confirm: u16 = 0x0400;

// ASM address used by applyPostLoadHacks. The hook-install constants live in
// asm_hacks.zig.
const force_goto_addr: *u8 = @ptrFromInt(0x42B475);

var log_storage: logging.Logger = undefined;
var ipc_pipe: ?*anyopaque = null;
// `ipc_connected` is written by the lazy-init worker thread and read by the
// game's main thread inside frameStep — declare it atomic so both threads
// agree on a value without torn reads.
var ipc_connected: std.atomic.Value(bool) = .init(false);
var last_world_timer: u32 = 0;
var prev_game_mode: u32 = 0;

// DLL module handle, captured in PROCESS_ATTACH; used to locate mapping.ini
// next to hook.dll regardless of the process CWD.
var dll_module_handle: ?*anyopaque = null;

var input_diag_logged: bool = false;
// SDL is thread-local; defer SDL_Init to the first frameStep (main thread).
var sdl_init_done: bool = false;
var sdl_initialized: bool = false;

// `config_received` is set by lazyInit (worker thread) and frameStep may set
// it too — protect with an atomic so the cross-thread visibility is well
// defined. The accompanying `is_training/is_netplay/is_spectator` flags are
// only read AFTER `config_received` is observed true, which gives us a
// release/acquire handoff for those flags as well.
var config_received: std.atomic.Value(bool) = .init(false);
var is_training: bool = false;
var is_netplay: bool = false;
var is_spectator: bool = false;

// `dll_initialized` is written by lazyInit (worker thread) and read by
// frameStep (game's main thread). Make it atomic for the same reason.
var dll_initialized: std.atomic.Value(bool) = .init(false);

// === IPC framing state machine ===
//
// The launcher sends: [4-byte LE length][payload of `length` bytes] in two
// separate WriteFile calls. Because the pipe is opened as PIPE_TYPE_BYTE,
// the OS does NOT preserve message boundaries — a ReadFile may return
// fewer bytes than requested, and a subsequent ReadFile will pick up
// where the previous one stopped. The previous implementation consumed
// the 4-byte header even when the full payload hadn't arrived yet, then
// returned without reading the payload; the next poll would then
// interpret the first 4 bytes of payload as a NEW header, corrupting
// the framing permanently.
//
// This state machine buffers partial reads until a full frame is available.
const IpcReader = struct {
    header_buf: [4]u8 = undefined,
    header_read: usize = 0,
    msg_len: u32 = 0,
    payload_buf: [256]u8 = undefined,
    payload_read: usize = 0,

    fn reset(self: *IpcReader) void {
        self.header_read = 0;
        self.msg_len = 0;
        self.payload_read = 0;
    }

    /// Returns true if a full message is in `payload_buf[0..msg_len]`.
    fn poll(self: *IpcReader, pipe: ?*anyopaque) bool {
        // Read header bytes (4 bytes total).
        while (self.header_read < 4) {
            var available: u32 = 0;
            if (win32.PeekNamedPipe(pipe, null, 0, null, &available, null) == 0) {
                self.reset();
                return false;
            }
            if (available == 0) return false;
            const want: u32 = @intCast(4 - self.header_read);
            const to_read: u32 = @min(available, want);
            var got: u32 = 0;
            if (win32.ReadFile(pipe, self.header_buf[self.header_read..].ptr, to_read, &got, null) == 0) {
                self.reset();
                return false;
            }
            if (got == 0) return false;
            self.header_read += got;
        }

        // Header fully read — decode length (only once).
        if (self.msg_len == 0) {
            self.msg_len = std.mem.readInt(u32, &self.header_buf, .little);
            if (self.msg_len == 0 or self.msg_len > self.payload_buf.len) {
                // Invalid framing — reset to resync (best-effort).
                self.reset();
                return false;
            }
        }

        // Read payload bytes.
        while (self.payload_read < self.msg_len) {
            var available: u32 = 0;
            if (win32.PeekNamedPipe(pipe, null, 0, null, &available, null) == 0) {
                self.reset();
                return false;
            }
            if (available == 0) return false;
            const want: u32 = @intCast(self.msg_len - self.payload_read);
            const to_read: u32 = @min(available, want);
            var got: u32 = 0;
            if (win32.ReadFile(pipe, self.payload_buf[self.payload_read..].ptr, to_read, &got, null) == 0) {
                self.reset();
                return false;
            }
            if (got == 0) return false;
            self.payload_read += got;
        }

        return true;
    }
};

var ipc_reader: IpcReader = .{};

pub export fn DllMain(hModule: ?*anyopaque, fdwReason: u32, _: ?*anyopaque) callconv(.winapi) std.os.windows.BOOL {
    switch (fdwReason) {
        1 => { // DLL_PROCESS_ATTACH
            dll_module_handle = hModule;

            state.setFrameCallback(frameStep);
            dll_initialized.store(false, .release);
            // 8MB stack: Zig 0.16's std.Io call chain is deep enough to blow a
            // smaller stack (verified: 256KB still overflowed).
            _ = win32.CreateThread(null, 8 * 1024 * 1024, initThread, null, 0, null);
        },
        0 => { // DLL_PROCESS_DETACH
            // DllMain runs inside the loader lock. Doing heavy work here —
            // tearing down ENet, calling SDL_Quit, calling ExitProcess — is
            // forbidden territory. The OS is already tearing the process
            // down (DETACH on process exit). Just do the minimum: close the
            // IPC handle if we still have it, and let the process die on
            // its own. Killing the host from inside DllMain has been a
            // source of impossible-to-debug crashes in injected-DLL land.
            if (ipc_connected.load(.acquire)) {
                if (ipc_pipe) |p| _ = win32.CloseHandle(p);
                ipc_pipe = null;
                ipc_connected.store(false, .release);
            }
        },
        else => {},
    }
    return .TRUE;
}

fn connectPipe() void {
    if (state.log == null) return;
    const name = resolvePipeName();
    state.log.?.info("Connecting to IPC pipe: {s}", .{name});
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        ipc_pipe = win32.CreateFileA(name.ptr, win32.GENERIC_READ | win32.GENERIC_WRITE, 0, null, win32.OPEN_EXISTING, 0, null);
        if (ipc_pipe != win32.INVALID_HANDLE_VALUE) {
            ipc_connected.store(true, .release);
            state.log.?.info("Connected to IPC pipe", .{});
            return;
        }
        win32.Sleep(100);
    }
    state.log.?.err("Failed to connect to IPC pipe", .{});
}

fn waitForConfig() void {
    if (state.log == null or !ipc_connected.load(.acquire)) return;
    if (config_received.load(.acquire)) return;
    if (ipc_pipe == null) return;

    if (!ipc_reader.poll(ipc_pipe)) return;
    // Full frame received: ipc_reader.payload_buf[0..ipc_reader.msg_len].
    const read: usize = ipc_reader.msg_len;
    const payload = ipc_reader.payload_buf[0..read];

    // [flags][delay][rollback][win_count][host_player][2 peer_port][N peer_addr]
    if (read >= 5) {
        const flags = payload[0];
        is_training = (flags & 0x01) != 0;
        is_netplay = (flags & 0x02) != 0;
        is_spectator = (flags & 0x08) != 0;

        if (is_netplay and read >= 7) {
            // Initialize NetplayManager with config
            state.nm = netman.NetplayManager.init(std.heap.page_allocator, app_io_backend.io(), state.log.?) catch {
                state.log.?.err("NetplayManager init failed", .{});
                is_netplay = false;
                config_received.store(true, .release);
                ipc_reader.reset();
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
            @memcpy(cfg.peer_addr[0..addr_len], payload[7 .. 7 + addr_len]);

            state.nm.?.configure(cfg);
            // `config_received.store(release)` publishes `is_netplay/is_training/...`
            // and `state.nm` to readers that observe the store with .acquire.
            config_received.store(true, .release);
            state.log.?.info("Config: netplay={} host={} training={} spectator={} delay={d} rollback={d} port={d}", .{
                is_netplay, cfg.is_host,  is_training,   is_spectator,
                cfg.delay,  cfg.rollback, cfg.peer_port,
            });
        } else {
            is_training = (flags & 0x01) != 0;
            state.log.?.info("Config: offline training={}", .{is_training});
        }
    }
    config_received.store(true, .release);
    ipc_reader.reset();
}

// applyPreLoadHacks / writeBytes / rel32 etc. live in asm_hacks.zig.
/// Resolve mapping.ini next to the DLL itself (avoids CWD-dependent bugs).
/// The DLL is at `<MBAACC>/zzcaster/hook.dll`, so mapping.ini lives in the
/// same directory. Returns a slice into `buf`, or null.
fn resolveMappingIniPath(buf: []u8) ?[]const u8 {
    var dll_path: [512]u8 = undefined;
    const len = win32.GetModuleFileNameA(dll_module_handle, &dll_path, dll_path.len);
    if (len == 0) return null;

    var last_sep: usize = 0;
    for (dll_path[0..len], 0..) |ch, i| {
        if (ch == '\\' or ch == '/') last_sep = i;
    }
    if (last_sep == 0) return null; // no separator found — shouldn't happen

    const dir = dll_path[0 .. last_sep + 1]; // include trailing separator
    const filename = "mapping.ini";
    if (dir.len + filename.len + 1 > buf.len) return null; // +1 for NUL

    @memcpy(buf[0..dir.len], dir);
    @memcpy(buf[dir.len .. dir.len + filename.len], filename);
    const total = dir.len + filename.len;
    buf[total] = 0; // null-terminate for Win32 APIs
    return buf[0..total];
}

fn applyPostLoadHacks() void {
    if (state.log == null) return;
    state.log.?.info("Applying post-load hacks...", .{});

    if (is_training) {
        var fg: [2]u8 = .{ 0xEB, 0x22 };
        asm_hacks.writeBytes(@intFromPtr(force_goto_addr), &fg);
        state.log.?.info("forceGotoTraining", .{});
    } else {
        var fg: [2]u8 = .{ 0xEB, 0x3F };
        asm_hacks.writeBytes(@intFromPtr(force_goto_addr), &fg);
        state.log.?.info("forceGotoVersus", .{});
    }
    damage_level_addr.* = 2;
    timer_speed_addr.* = 2;
    // Write the user-configured win count to the game's "best-of-N" address
    // (CC_WIN_COUNT_VS_ADDR = 0x553FDC). The launcher's Game Config page
    // sends `win_count` via the IPC config payload, NetplayManager.configure
    // stores it in `config.win_count`. For offline training, `state.nm` is
    // null and win_count is meaningless — fall back to 2 (best-of-3).
    //
    // The previous code hardcoded `2`, which silently ignored the user's
    // Game Config selection (the value was negotiated through the launcher
    // handshake → IPC → DLL config struct, then thrown away).
    const win_count: u32 = if (is_netplay and state.nm != null)
        state.nm.?.config.win_count
    else
        2;
    win_count_vs_addr.* = win_count;
    state.log.?.info("win_count_vs set to {d}", .{win_count});

    // SDL_Init is deferred to initSdlOnMainThread (see below) — SDL is not
    // thread-safe and must run on the main thread.

    // Init keyboard (reads MBAA.exe file, no threading concerns)
    keyboard.init(state.log.?, app_io_backend.io());

    if (is_netplay and state.nm != null) {
        state.nm.?.initEnet() catch {
            state.log.?.err("ENet init failed — netplay disabled", .{});
            is_netplay = false;
        };
    }
}

fn initSdlOnMainThread() void {
    if (sdl_init_done) return;
    sdl_init_done = true;

    if (c.SDL_Init(c.SDL_INIT_GAMECONTROLLER | c.SDL_INIT_JOYSTICK) == 0) {
        sdl_initialized = true;
        state.reader = gamepad.GamepadReader.init(state.log.?);

        var mapping_path_buf: [600]u8 = undefined;
        const mapping_path = resolveMappingIniPath(&mapping_path_buf) orelse "zzcaster/mapping.ini";
        state.log.?.info("Looking for mapping.ini at: {s}", .{mapping_path});

        var p1_mapping: mapper.ControllerMapping = undefined;
        var p2_mapping: mapper.ControllerMapping = undefined;
        var have_mappings: bool = false;
        if (mapper.loadMapping(mapping_path, app_io_backend.io(), state.log.?)) |mappings| {
            p1_mapping = mappings.p1;
            p2_mapping = mappings.p2;
            have_mappings = true;
            state.log.?.info("Custom mapping loaded successfully", .{});
        } else {
            state.log.?.info("No custom mapping found — using GameController API with built-in button layout", .{});
            p1_mapping = mapper.defaultXboxMapping();
            p2_mapping = mapper.defaultXboxMapping();
            p2_mapping.device_index = -1;
        }

        if (have_mappings) {
            state.reader.?.custom_mapping = p1_mapping;
            openMappedJoystick(&state.reader.?, p1_mapping, "P1");
        } else {
            state.log.?.info("P1: using GameController API (no custom mapping)", .{});
        }

        // Apply P2 mapping.
        if (have_mappings or p2_mapping.device_index >= 0) {
            state.reader2 = gamepad.GamepadReader{};
            state.reader2.?.custom_mapping = p2_mapping;
            openMappedJoystick(&state.reader2.?, p2_mapping, "P2");
        } else {
            state.log.?.info("P2: keyboard-only default, no reader2 allocated", .{});
        }

        // wire air dash macro
        state.air_dash_macro_p1.enabled = p1_mapping.air_dash_macro;
        state.air_dash_macro_p2.enabled = p2_mapping.air_dash_macro;
        if (p1_mapping.air_dash_macro or p2_mapping.air_dash_macro) {
            state.log.?.info("Air Dash Macro: P1={} P2={}", .{
                p1_mapping.air_dash_macro, p2_mapping.air_dash_macro,
            });
        }
        if (state.nm) |*n| {
            // Netplay local input always uses the P1 (reader) mapping in the
            // current frame_step path, so the netplay macro follows P1.
            n.air_dash_macro.enabled = p1_mapping.air_dash_macro;
        }
    } else {
        state.log.?.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
    }
}

fn openMappedJoystick(r: *gamepad.GamepadReader, m: mapper.ControllerMapping, label: []const u8) void {
    if (m.device_index < 0) {
        state.log.?.info("{s}: mapping uses keyboard (device=-1)", .{label});
        return;
    }
    var opened: ?*c.SDL_Joystick = c.SDL_JoystickOpen(m.device_index);
    if (opened == null) {
        state.log.?.warn("{s}: joystick {d} not available, trying index 0", .{ label, m.device_index });
        opened = c.SDL_JoystickOpen(0);
    }
    r.mapped_joystick = @ptrCast(opened);
    if (r.mapped_joystick != null) {
        state.log.?.info("{s}: opened joystick for mapping", .{label});
        // Close any GameController that GamepadReader.init() opened for
        // this same physical device — we're using raw joystick API now.
        if (r.controller != null) {
            c.SDL_GameControllerClose(@ptrCast(r.controller));
            r.controller = null;
        }
    } else {
        state.log.?.err("{s}: no joystick available for mapping — input will not work", .{label});
    }
}

fn initThread(_: ?*anyopaque) callconv(.winapi) u32 {
    lazyInit();
    return 0;
}

/// Heavy initialization, deferred from DllMain to the worker thread it
/// spawns. Does the logger setup, IPC connect, ASM hook install, and
/// config read — everything that used to live in DllMain's PROCESS_ATTACH.
/// The worker thread is created with an 8MB stack (see CreateThread in
/// DllMain); Zig 0.16's std.Io call chain is deep enough that the
/// LoadLibraryA remote thread's default 256KB stack overflowed.
fn lazyInit() void {
    if (dll_initialized.load(.acquire)) return;
    dll_initialized.store(true, .release);

    const io = app_io_backend.io();
    var pid_buf: [32]u8 = undefined;
    const pid = win32.GetCurrentProcessId();
    const primary_path = std.fmt.bufPrintZ(&pid_buf, "zzcaster/dll_{d}.log", .{pid}) catch null;

    log_storage = init: {
        if (primary_path) |p| {
            if (logging.Logger.init(std.heap.page_allocator, io, p)) |logger| break :init logger else |_| {}
        }
        // Fallbacks
        var root_buf: [48]u8 = undefined;
        if (std.fmt.bufPrintZ(&root_buf, "dll_{d}.log", .{pid}) catch null) |p| {
            if (logging.Logger.init(std.heap.page_allocator, io, p)) |logger| break :init logger else |_| {}
        }

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
    state.log = &log_storage;
    state.log.?.info("hook.dll: lazyInit (Zig) pid={d}", .{pid});

    _ = win32.SetThreadExecutionState(0x80000000 | 0x00000001 | 0x00000002 | 0x00000004);

    connectPipe();
    asm_hacks.applyPreLoadHacks();

    // Non-blocking: returns immediately if the launcher hasn't sent config
    // yet (frameStep will retry). If it's already here, apply post-load hacks now.
    waitForConfig();
    if (config_received.load(.acquire)) applyPostLoadHacks();
}

fn frameStep() callconv(.c) void {
    if (!dll_initialized.load(.acquire)) return;
    if (state.log == null) return;

    if (!config_received.load(.acquire) and ipc_connected.load(.acquire)) {
        waitForConfig();
        if (config_received.load(.acquire)) {
            applyPostLoadHacks();
        }
    }

    if (config_received.load(.acquire) and !sdl_init_done) {
        initSdlOnMainThread();
    }

    if (config_received.load(.acquire) and sdl_init_done and !input_diag_logged) {
        input_diag_logged = true;

        const input_base_ptr: [*]u8 = @ptrFromInt(0x76E6AC);
        const base_ptr_val = @as(usize, @bitCast(input_base_ptr[0..@sizeOf(usize)].*));
        state.log.?.info("InputDiag: reader={} reader2={} keyboard.init={} base_ptr=0x{x:0>8} game_mode={d} is_netplay={}", .{
            state.reader != null,
            state.reader2 != null,
            keyboard.isInitialized(),
            base_ptr_val,
            game_mode_addr.*,
            is_netplay,
        });
        if (state.reader) |*r| {
            if (r.custom_mapping) |m| {
                state.log.?.info("InputDiag: P1 mapping device={d} a.type={s}", .{ m.device_index, @tagName(m.a.type) });
            } else {
                state.log.?.info("InputDiag: P1 no custom_mapping (will use default Xbox or legacy keyboard)", .{});
            }
        }
        if (state.reader2) |*r| {
            if (r.custom_mapping) |m| {
                state.log.?.info("InputDiag: P2 mapping device={d} a.type={s}", .{ m.device_index, @tagName(m.a.type) });
            }
        }
    }

    const world_timer = world_timer_addr.*;
    if (world_timer == last_world_timer) return;
    last_world_timer = world_timer;

    const game_mode = game_mode_addr.*;

    // Detect game mode changes → state transitions
    if (game_mode != prev_game_mode) {
        if (state.nm) |*n| n.onGameModeChanged(game_mode);
        prev_game_mode = game_mode;
    }

    if (state.nm) |*n| {
        n.checkIntroDone();

        // Watch the round-start counter (incremented by the detectRoundStart
        // ASM hack) for the Skippable → InGame transition. Runs BEFORE
        // checkRoundOver so a new round start takes precedence over a
        // stale round-over signal.
        n.checkRoundStart();

        n.tickRoundOverTimer();
        n.checkRoundOver();

        n.clearIntroStateDuringRollback();
    }

    // Clear inputs
    writeInput(1, 0);
    writeInput(2, 0);

    if (state.nm) |*n| {
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

    frame_step.frameStepInGame(world_timer, game_mode);
}
