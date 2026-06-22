const std = @import("std");
const builtin = @import("builtin");
const config = @import("common").config;
const logging = @import("common").logging;

const win32 = struct {
    extern "kernel32" fn CreateProcessA(
        lpApplicationName: ?[*:0]const u8,
        lpCommandLine: ?[*:0]u8,
        lpProcessAttributes: ?*anyopaque,
        lpThreadAttributes: ?*anyopaque,
        bInheritHandles: i32,
        dwCreationFlags: u32,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*:0]const u8,
        lpStartupInfo: *StartupInfo,
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
    extern "kernel32" fn GetFullPathNameA(
        lpFileName: [*:0]const u8,
        nBufferLength: u32,
        lpBuffer: [*]u8,
        lpFilePart: ?*?[*:0]u8,
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

    const StartupInfo = extern struct {
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
        // Build command line (writable)
        var cmd_buf: [512]u8 = undefined;
        const cmd_len = std.fmt.bufPrintZ(&cmd_buf, "\"{s}\"", .{cfg.game_exe}) catch return error.PathTooLong;

        var si = std.mem.zeroes(win32.StartupInfo);
        si.cb = @sizeOf(win32.StartupInfo);
        var pi = std.mem.zeroes(win32.ProcessInformation);

        var flags: u32 = win32.CREATE_SUSPENDED;
        if (cfg.high_priority) flags |= win32.HIGH_PRIORITY_CLASS;

        // Create exe path as null-terminated
        var exe_buf: [256]u8 = undefined;
        const exe_z = std.fmt.bufPrintZ(&exe_buf, "{s}", .{cfg.game_exe}) catch return error.PathTooLong;

        log.info("Creating MBAA.exe suspended...", .{});

        if (win32.CreateProcessA(exe_z.ptr, cmd_len.ptr, null, null, 0, flags, null, null, &si, &pi) == 0) {
            log.err("CreateProcess failed: {d}", .{win32.GetLastError()});
            return error.CreateProcessFailed;
        }

        log.info("MBAA.exe created (PID={d})", .{pi.dwProcessId});
        defer _ = win32.CloseHandle(pi.hThread);
        self.process_handle = pi.hProcess;
        self.pid = pi.dwProcessId;

        // Read PE header to find entry point
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

        // Save original 2 bytes at the entry point so we can restore them
        // after the DLL has patched everything in.
        var orig_bytes: [2]u8 = undefined;
        if (win32.ReadProcessMemory(pi.hProcess, @ptrFromInt(entry_point), &orig_bytes, 2, null) == 0) {
            return error.ReadMemoryFailed;
        }
        log.info("Orig bytes: {x:0>2} {x:0>2}", .{ orig_bytes[0], orig_bytes[1] });

        log.info("Injecting {s}...", .{cfg.dll_path});

        var full_dll_buf: [512]u8 = undefined;
        var dll_path_z: [512]u8 = undefined;
        const dll_path_z_slice = std.fmt.bufPrintZ(&dll_path_z, "{s}", .{cfg.dll_path}) catch return error.PathTooLong;
        const full_len = win32.GetFullPathNameA(dll_path_z_slice.ptr, full_dll_buf.len, &full_dll_buf, null);
        const inject_path: []const u8 = if (full_len > 0 and full_len < full_dll_buf.len) blk: {
            // Re-null-terminate the resolved absolute path.
            full_dll_buf[full_len] = 0;
            break :blk full_dll_buf[0..full_len :0];
        } else cfg.dll_path;
        log.info("Injecting (absolute) {s}", .{inject_path});
        if (!injectDll(pi.hProcess, inject_path, log)) {
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

fn injectDll(process: ?*anyopaque, dll_path: []const u8, log: *logging.Logger) bool {
    // Allocate memory in target process for DLL path string
    const remote_str = win32.VirtualAllocEx(process, null, dll_path.len + 1, win32.MEM_COMMIT | win32.MEM_RESERVE, win32.PAGE_READWRITE) orelse {
        log.err("inject: VirtualAllocEx failed (gle={d})", .{win32.GetLastError()});
        return false;
    };
    defer _ = win32.VirtualFreeEx(process, remote_str, 0, win32.MEM_RELEASE);

    // Write DLL path
    if (win32.WriteProcessMemory(process, remote_str, dll_path.ptr, dll_path.len + 1, null) == 0) {
        log.err("inject: WriteProcessMemory failed (gle={d})", .{win32.GetLastError()});
        return false;
    }

    // Get LoadLibraryA address
    const k32 = win32.GetModuleHandleA("kernel32.dll") orelse {
        log.err("inject: GetModuleHandleA(kernel32) failed", .{});
        return false;
    };
    const load_library = win32.GetProcAddress(k32, "LoadLibraryA") orelse {
        log.err("inject: GetProcAddress(LoadLibraryA) failed", .{});
        return false;
    };

    log.info("inject: LoadLibraryA({s}) in remote thread", .{dll_path});

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
                log.err("inject: LoadLibraryA returned 0 — DLL FAILED TO LOAD (path not found in target CWD, or DLL missing a dependency). Path was: {s}", .{dll_path});
                return false;
            }
            log.info("inject: LoadLibraryA returned module handle {x} — DLL loaded OK", .{exit_code});
            return true;
        },
        win32.WAIT_TIMEOUT => {
            log.err("inject: remote thread timed out (10s) — DLL may be stuck in DllMain. Path was: {s}", .{dll_path});
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
