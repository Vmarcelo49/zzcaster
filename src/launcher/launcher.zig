const std = @import("std");
const builtin = @import("builtin");
const config = @import("common").config;
const logging = @import("common").logging;
const common_win32 = @import("common").win32;

const win32 = struct {
    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*:0]const u16,
        lpCommandLine: ?[*:0]u16,
        lpProcessAttributes: ?*anyopaque,
        lpThreadAttributes: ?*anyopaque,
        bInheritHandles: i32,
        dwCreationFlags: u32,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*:0]const u16,
        lpStartupInfo: *StartupInfoW,
        lpProcessInformation: *ProcessInformation,
    ) callconv(.winapi) i32;

    extern "kernel32" fn ResumeThread(hThread: ?*anyopaque) callconv(.winapi) u32;
    extern "kernel32" fn SuspendThread(hThread: ?*anyopaque) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetExitCodeProcess(hProcess: ?*anyopaque, lpExitCode: *u32) callconv(.winapi) i32;
    extern "kernel32" fn TerminateProcess(hProcess: ?*anyopaque, uExitCode: u32) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn VirtualAllocEx(
        hProcess: ?*anyopaque,
        lpAddress: ?*anyopaque,
        dwSize: usize,
        flAllocationType: u32,
        flProtect: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn VirtualFreeEx(
        hProcess: ?*anyopaque,
        lpAddress: ?*anyopaque,
        dwSize: usize,
        dwFreeType: u32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn WriteProcessMemory(
        hProcess: ?*anyopaque,
        lpBaseAddress: ?*const anyopaque,
        lpBuffer: ?*const anyopaque,
        nSize: usize,
        lpNumberOfBytesWritten: ?*usize,
    ) callconv(.winapi) i32;
    extern "kernel32" fn ReadProcessMemory(
        hProcess: ?*anyopaque,
        lpBaseAddress: ?*const anyopaque,
        lpBuffer: ?*anyopaque,
        nSize: usize,
        lpNumberOfBytesRead: ?*usize,
    ) callconv(.winapi) i32;
    extern "kernel32" fn VirtualProtectEx(
        hProcess: ?*anyopaque,
        lpAddress: ?*const anyopaque,
        dwSize: usize,
        flNewProtect: u32,
        lpflOldProtect: *u32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn FlushInstructionCache(
        hProcess: ?*anyopaque,
        lpBaseAddress: ?*const anyopaque,
        dwSize: usize,
    ) callconv(.winapi) i32;
    extern "kernel32" fn CreateRemoteThread(
        hProcess: ?*anyopaque,
        lpThreadAttributes: ?*anyopaque,
        dwStackSize: u32,
        lpStartAddress: ?*const anyopaque,
        lpParameter: ?*anyopaque,
        dwCreationFlags: u32,
        lpThreadId: ?*u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WaitForSingleObject(hHandle: ?*anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeThread(hThread: ?*const anyopaque, lpExitCode: *u32) callconv(.winapi) i32;
    extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: ?*const anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn GetThreadContext(hThread: ?*const anyopaque, lpContext: *Context) callconv(.winapi) i32;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    extern "kernel32" fn SetEnvironmentVariableA(
        lpName: [*:0]const u8,
        lpValue: [*:0]const u8,
    ) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
    extern "kernel32" fn GetEnvironmentVariableA(
        lpName: [*:0]const u8,
        lpBuffer: [*]u8,
        nSize: u32,
    ) callconv(.winapi) u32;
    extern "kernel32" fn GetFullPathNameW(
        lpFileName: [*:0]const u16,
        nBufferLength: u32,
        lpBuffer: [*]u16,
        lpFilePart: ?*?[*:0]u16,
    ) callconv(.winapi) u32;

    const CREATE_SUSPENDED: u32 = 0x00000004;
    const HIGH_PRIORITY_CLASS: u32 = 0x00000080;
    const MEM_COMMIT: u32 = 0x00001000;
    const MEM_RESERVE: u32 = 0x00002000;
    const MEM_RELEASE: u32 = 0x8000;
    const PAGE_READWRITE: u32 = 0x04;
    const PAGE_EXECUTE_READWRITE: u32 = 0x40;
    const STILL_ACTIVE: u32 = 259;
    const INFINITE: u32 = 0xFFFFFFFF;
    const WAIT_OBJECT_0: u32 = 0;
    const WAIT_TIMEOUT: u32 = 0x00000102;
    const CONTEXT_CONTROL: u32 = 0x100001;

    const StartupInfoW = extern struct {
        cb: u32,
        lpReserved: ?*anyopaque = null,
        lpDesktop: ?*anyopaque = null,
        lpTitle: ?*anyopaque = null,
        dwX: u32 = 0,
        dwY: u32 = 0,
        dwXSize: u32 = 0,
        dwYSize: u32 = 0,
        dwXCountChars: u32 = 0,
        dwYCountChars: u32 = 0,
        dwFillAttribute: u32 = 0,
        dwFlags: u32 = 0,
        wShowWindow: u16 = 0,
        cbReserved2: u16 = 0,
        lpReserved2: ?*anyopaque = null,
        hStdInput: ?*anyopaque = null,
        hStdOutput: ?*anyopaque = null,
        hStdError: ?*anyopaque = null,
    };

    const ProcessInformation = extern struct {
        hProcess: ?*anyopaque,
        hThread: ?*anyopaque,
        dwProcessId: u32,
        dwThreadId: u32,
    };

    const Context = extern struct {
        ContextFlags: u32,
        Dr0: u32 = 0,
        Dr1: u32 = 0,
        Dr2: u32 = 0,
        Dr3: u32 = 0,
        Dr6: u32 = 0,
        Dr7: u32 = 0,
        FloatSave: [112]u8 = [_]u8{0} ** 112,
        SegGs: u32 = 0,
        SegFs: u32 = 0,
        SegEs: u32 = 0,
        SegDs: u32 = 0,
        Edi: u32 = 0,
        Esi: u32 = 0,
        Ebx: u32 = 0,
        Edx: u32 = 0,
        Ecx: u32 = 0,
        Eax: u32 = 0,
        Ebp: u32 = 0,
        Eip: u32 = 0,
        SegCs: u32 = 0,
        EFlags: u32 = 0,
        Esp: u32 = 0,
        SegSs: u32 = 0,
    };
};

const image_base: u32 = 0x400000;
const skip_config_patch1: u32 = 0x04A1D42;
const skip_config_patch2: u32 = 0x04A1D4A;

pub const LaunchConfig = struct {
    game_exe: []const u8,
    dll_path: []const u8,
    high_priority: bool = true,
};

pub const WindowsLauncher = struct {
    process_handle: ?*anyopaque = null,
    pid: u32 = 0,

    pub fn launch(self: *WindowsLauncher, cfg: LaunchConfig, log: *logging.Logger) !u32 {
        // Convert UTF-8 exe path to UTF-16LE for CreateProcessW
        var exe_wide: [512]u16 = undefined;
        const exe_wide_len = std.unicode.utf8ToUtf16Le(&exe_wide, cfg.game_exe) catch return error.PathTooLong;
        exe_wide[exe_wide_len] = 0;

        // Build command line as wide string: "\"<exe>\""
        var cmd_wide: [600]u16 = undefined;
        cmd_wide[0] = '"';
        @memcpy(cmd_wide[1 .. 1 + exe_wide_len], exe_wide[0..exe_wide_len]);
        cmd_wide[1 + exe_wide_len] = '"';
        cmd_wide[2 + exe_wide_len] = 0;

        var si = std.mem.zeroes(win32.StartupInfoW);
        si.cb = @sizeOf(win32.StartupInfoW);
        var pi = std.mem.zeroes(win32.ProcessInformation);

        var flags: u32 = win32.CREATE_SUSPENDED;
        if (cfg.high_priority) flags |= win32.HIGH_PRIORITY_CLASS;

        log.info("Creating MBAA.exe suspended...", .{});

        const exe_z: [*:0]const u16 = exe_wide[0..exe_wide_len :0];
        const cmd_z: [*:0]u16 = cmd_wide[0 .. 2 + exe_wide_len :0];
        if (win32.CreateProcessW(exe_z, cmd_z, null, null, 0, flags, null, null, &si, &pi) == 0) {
            log.err("CreateProcess failed: {d}", .{win32.GetLastError()});
            return error.CreateProcessFailed;
        }

        log.info("MBAA.exe created (PID={d})", .{pi.dwProcessId});
        defer _ = win32.CloseHandle(pi.hThread);
        self.process_handle = pi.hProcess;
        self.pid = pi.dwProcessId;

        // Parse the PE header to log the entry point. This is diagnostic
        // only (it identifies the MBAACC build, useful when debugging
        // "wrong version" crashes) and validates that we attached to a
        // real PE image — the patches below write to hardcoded addresses
        // and would silently corrupt a non-PE target.
        //
        // INTENTIONAL DIVERGENCE FROM CCCaster (tools/Launcher.cpp:57-183):
        // CCCaster saves the original 2 bytes at the entry point, writes
        // `lock_code = 0xfeeb` (EB FE = JMP -2 = infinite loop) there,
        // busy-loops ResumeThread/Sleep/SuspendThread/GetThreadContext
        // until EIP == entry_point (main thread trapped on the loop),
        // injects the DLL + applies patches, then restores the original
        // bytes and FlushInstructionCache before the final ResumeThread.
        //
        // zzcaster achieves the same ordering guarantee (DLL loaded +
        // patches applied before the main thread executes any of its
        // entry-point code) more simply: CREATE_SUSPENDED pauses the main
        // thread before it runs at all, injectDllW blocks on
        // WaitForSingleObject(remote_thread, 10s) so DllMain completes
        // before we ResumeThread. No entry-point manipulation needed, so
        // no orig_bytes save/restore either. The PE parse below is kept
        // purely for the diagnostic log line + PE-signature early-fail.
        var dos_header: [0x40]u8 = undefined;
        if (win32.ReadProcessMemory(pi.hProcess, @ptrFromInt(image_base), &dos_header, dos_header.len, null) == 0) {
            log.err("Failed to read DOS header", .{});
            return error.ReadMemoryFailed;
        }

        const pe_offset = std.mem.readInt(u32, dos_header[0x3C..][0..4], .little);
        var pe_header: [0x30]u8 = undefined;
        if (win32.ReadProcessMemory(pi.hProcess, @ptrFromInt(image_base + pe_offset), &pe_header, pe_header.len, null) == 0) {
            log.err("Failed to read PE header", .{});
            return error.ReadMemoryFailed;
        }

        if (pe_header[0] != 'P' or pe_header[1] != 'E') {
            log.err("Invalid PE signature", .{});
            return error.InvalidPE;
        }

        const entry_rva = std.mem.readInt(u32, pe_header[40..][0..4], .little);
        const entry_point = image_base + entry_rva;
        log.info("Entry point: 0x{x:0>8}", .{entry_point});

        log.info("Injecting {s}...", .{cfg.dll_path});

        // Resolve absolute path using GetFullPathNameW (Unicode-safe)
        var dll_path_wide: [512]u16 = undefined;
        const dll_wide_len = std.unicode.utf8ToUtf16Le(&dll_path_wide, cfg.dll_path) catch return error.PathTooLong;
        dll_path_wide[dll_wide_len] = 0;

        var full_dll_wide: [512]u16 = undefined;
        const full_len = win32.GetFullPathNameW(@ptrCast(dll_path_wide[0..dll_wide_len :0]), full_dll_wide.len, &full_dll_wide, null);
        const inject_wide: []const u16 = if (full_len > 0 and full_len < full_dll_wide.len) blk: {
            full_dll_wide[full_len] = 0;
            break :blk full_dll_wide[0..full_len];
        } else dll_path_wide[0..dll_wide_len];

        // Log the inject path as UTF-8 for readability
        var inject_utf8_buf: [512]u8 = undefined;
        const inject_utf8_len = std.unicode.utf16LeToUtf8(&inject_utf8_buf, inject_wide) catch 0;
        log.info("Injecting (absolute) {s}", .{inject_utf8_buf[0..inject_utf8_len]});

        if (!injectDllW(pi.hProcess, inject_wide, log)) {
            log.err("Failed to inject {s}", .{cfg.dll_path});
            return error.InjectFailed;
        }
        log.info("hook.dll injected successfully", .{});

        // Patch config dialog skip
        const patch1 = [_]u8{ 0xEB, 0x0E };
        const patch2 = [_]u8{0xEB};
        _ = patchMemory(pi.hProcess, skip_config_patch1, &patch1);
        _ = patchMemory(pi.hProcess, skip_config_patch2, &patch2);

        // Resume the main thread — let the game run normally.
        log.info("Resuming MBAA.exe...", .{});
        _ = win32.ResumeThread(pi.hThread);

        log.info("Launch complete (PID={d})", .{pi.dwProcessId});
        return pi.dwProcessId;
    }

    pub fn isAlive(self: *WindowsLauncher) bool {
        if (self.process_handle == null) return false;
        var exit_code: u32 = 0;
        if (win32.GetExitCodeProcess(self.process_handle, &exit_code) == 0) return false;
        return exit_code == win32.STILL_ACTIVE;
    }

    pub fn terminate(self: *WindowsLauncher) void {
        if (self.process_handle) |h| {
            if (self.isAlive()) {
                _ = win32.TerminateProcess(h, 0);
            }
            _ = win32.CloseHandle(h);
            self.process_handle = null;
        }
        self.pid = 0;
    }
};

fn patchMemory(process: ?*anyopaque, addr: u32, data: []const u8) bool {
    var old_protect: u32 = 0;
    if (win32.VirtualProtectEx(process, @ptrFromInt(addr), data.len, win32.PAGE_EXECUTE_READWRITE, &old_protect) == 0)
        return false;
    const ok = win32.WriteProcessMemory(process, @ptrFromInt(addr), data.ptr, data.len, null) != 0;
    var dummy: u32 = 0;
    _ = win32.VirtualProtectEx(process, @ptrFromInt(addr), data.len, old_protect, &dummy);
    _ = win32.FlushInstructionCache(process, @ptrFromInt(addr), data.len);
    return ok;
}

/// Inject a DLL into the target process using the Unicode (W) API.
/// `dll_path_wide` is a UTF-16LE slice (without null terminator); the
/// function writes it + null into the remote process and calls LoadLibraryW.
fn injectDllW(process: ?*anyopaque, dll_path_wide: []const u16, log: *logging.Logger) bool {
    const byte_len = (dll_path_wide.len + 1) * @sizeOf(u16); // +1 for null terminator

    // Allocate memory in target process for the wide DLL path string
    const remote_str = win32.VirtualAllocEx(process, null, byte_len, win32.MEM_COMMIT | win32.MEM_RESERVE, win32.PAGE_READWRITE) orelse {
        log.err("inject: VirtualAllocEx failed (gle={d})", .{win32.GetLastError()});
        return false;
    };
    defer _ = win32.VirtualFreeEx(process, remote_str, 0, win32.MEM_RELEASE);

    // Write wide DLL path (including null terminator)
    // Build a null-terminated copy in a local buffer
    var local_wide: [512]u16 = undefined;
    if (dll_path_wide.len >= local_wide.len) {
        log.err("inject: DLL path too long ({d} chars)", .{dll_path_wide.len});
        return false;
    }
    @memcpy(local_wide[0..dll_path_wide.len], dll_path_wide);
    local_wide[dll_path_wide.len] = 0;

    if (win32.WriteProcessMemory(process, remote_str, @ptrCast(&local_wide), byte_len, null) == 0) {
        log.err("inject: WriteProcessMemory failed (gle={d})", .{win32.GetLastError()});
        return false;
    }

    // Get LoadLibraryW address
    const k32 = win32.GetModuleHandleA("kernel32.dll") orelse {
        log.err("inject: GetModuleHandleA(kernel32) failed", .{});
        return false;
    };
    const load_library = win32.GetProcAddress(k32, "LoadLibraryW") orelse {
        log.err("inject: GetProcAddress(LoadLibraryW) failed", .{});
        return false;
    };

    log.info("inject: LoadLibraryW in remote thread", .{});

    // Create remote thread
    const thread = win32.CreateRemoteThread(process, null, 0, load_library, remote_str, 0, null) orelse {
        log.err("inject: CreateRemoteThread failed (gle={d})", .{win32.GetLastError()});
        return false;
    };
    const wait_res = win32.WaitForSingleObject(thread, 10000);

    var exit_code: u32 = 0;
    _ = win32.GetExitCodeThread(thread, &exit_code);
    _ = win32.CloseHandle(thread);

    switch (wait_res) {
        win32.WAIT_OBJECT_0 => {
            if (exit_code == 0) {
                log.err("inject: LoadLibraryW returned 0 — DLL FAILED TO LOAD (path not found or DLL missing dependency, gle={d})", .{win32.GetLastError()});
                return false;
            }
            log.info("inject: LoadLibraryW returned module handle {x} — DLL loaded OK", .{exit_code});
            return true;
        },
        win32.WAIT_TIMEOUT => {
            log.err("inject: remote thread timed out (10s) — DLL may be stuck in DllMain", .{});
            return false;
        },
        else => {
            log.err("inject: WaitForSingleObject returned {d} (gle={d})", .{ wait_res, win32.GetLastError() });
            return false;
        },
    }
}

/// Set a Win32 environment variable (so child processes inherit it).
pub fn setenv_win32(name: []const u8, value: []const u8) void {
    var name_buf: [128]u8 = undefined;
    var value_buf: [256]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch return;
    const value_z = std.fmt.bufPrintZ(&value_buf, "{s}", .{value}) catch return;
    _ = win32.SetEnvironmentVariableA(name_z.ptr, value_z.ptr);
}

/// Get current Win32 process ID. (Wraps GetCurrentProcessId kernel32 call;
/// needed because std.os.linux.getpid is a direct Linux syscall that won't
/// run under Wine.)
pub fn getCurrentProcessId_win32() u32 {
    return win32.GetCurrentProcessId();
}

/// Resolve the log file path to an absolute, user-writable location.
///
/// Returns `%LOCALAPPDATA%\zzcaster\debug.log` on Windows. If
/// `%LOCALAPPDATA%` is not set (very unusual — it's set by default on
/// every Windows install since Vista), falls back to `zzcaster/debug.log`
/// relative to CWD so the log still works in some form.
///
/// `buf` receives the null-terminated path. The returned slice is a
/// substring of `buf`.
pub fn resolveLogPath(buf: []u8) []const u8 {
    // Try to read %LOCALAPPDATA% from the environment.
    var env_buf: [260]u8 = undefined;
    const env_len = win32.GetEnvironmentVariableA("LOCALAPPDATA", &env_buf, env_buf.len);

    if (env_len == 0 or env_len >= env_buf.len) {
        // LOCALAPPDATA not set or too long — fall back to CWD-relative path.
        const fallback = "zzcaster/debug.log";
        if (fallback.len + 1 <= buf.len) {
            @memcpy(buf[0..fallback.len], fallback);
            buf[fallback.len] = 0;
            return buf[0..fallback.len];
        }
        return "zzcaster/debug.log";
    }

    // Build "%LOCALAPPDATA%\zzcaster\debug.log"
    const result = std.fmt.bufPrint(buf, "{s}\\zzcaster\\debug.log", .{env_buf[0..env_len]}) catch {
        // Buffer too small — fall back.
        const fallback = "zzcaster/debug.log";
        if (fallback.len + 1 <= buf.len) {
            @memcpy(buf[0..fallback.len], fallback);
            buf[fallback.len] = 0;
            return buf[0..fallback.len];
        }
        return "zzcaster/debug.log";
    };
    return result;
}
