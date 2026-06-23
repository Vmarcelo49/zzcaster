const std = @import("std");
const config = @import("config.zig");
const logging = @import("logging.zig");

// Win32 externs for IPC (named pipe)
const win32 = struct {
    extern "kernel32" fn CreateNamedPipeA(
        lpName: [*:0]const u8,
        dwOpenMode: u32,
        dwPipeMode: u32,
        nMaxInstances: u32,
        nOutBufferSize: u32,
        nInBufferSize: u32,
        nDefaultTimeOut: u32,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn ConnectNamedPipe(hNamedPipe: ?*anyopaque, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;
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
    extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
    const PIPE_TYPE_BYTE: u32 = 0x00000000;
    const PIPE_WAIT: u32 = 0x00000000;
    const ERROR_PIPE_CONNECTED: u32 = 535;
    const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
};

// IMPORTANT: FILE_FLAG_OVERLAPPED was REMOVED from CreateNamedPipeA.
//
// The previous implementation opened the pipe with FILE_FLAG_OVERLAPPED so
// that ConnectNamedPipe could return immediately with ERROR_IO_PENDING and
// the launcher could do work (launch MBAA.exe + inject DLL) between listen()
// and waitForConnection(). The launcher then called WriteFile(..., null) in
// send() to deliver the config payload.
//
// This is **undefined behavior on real Windows**: when a handle is opened
// with FILE_FLAG_OVERLAPPED, the lpOverlapped parameter of WriteFile MUST
// point to a valid OVERLAPPED structure. MSDN explicitly warns:
//
//   "If hFile was opened with FILE_FLAG_OVERLAPPED, the lpOverlapped
//    parameter must point to a valid and unique OVERLAPPED structure.
//    Otherwise, the function can incorrectly report that the write
//    operation is complete."
//
// In practice on Windows 10/11, WriteFile on an overlapped handle with
// NULL lpOverlapped returns FALSE with GetLastError() == ERROR_INVALID_PARAMETER
// (87). The config is silently dropped. The DLL never receives the config,
// applyPostLoadHacks() never runs, forceGotoTraining/forceGotoVersus are
// never written, and MBAA.exe sits in the menu forever — which users
// perceive as "zzcaster crashed".
//
// Wine's named-pipe implementation is more lenient: it accepts NULL
// lpOverlapped on overlapped handles and treats the call as synchronous.
// That's why this bug never surfaced under Wine.
//
// The legacy C++ CCCaster (the project being ported) creates the pipe
// WITHOUT FILE_FLAG_OVERLAPPED and uses synchronous I/O throughout
// (ProcessManager.cpp:130-138). This Zig port now matches the legacy
// behavior line-for-line. The launcher's flow is:
//   1. listen()           — CreateNamedPipeA (synchronous, returns immediately)
//   2. WindowsLauncher.launch() — CreateProcess + inject DLL + resume
//   3. waitForConnection() — ConnectNamedPipe(handle, NULL) blocks until
//                            the DLL calls CreateFileA on the pipe
//   4. send()              — WriteFile(handle, buf, len, &written, NULL)
//                            (correct synchronous call on a non-overlapped
//                            handle)
//
// The launcher doesn't need to do anything between waitForConnection() and
// send(), so blocking on ConnectNamedPipe is fine. There's no benefit to
// overlapped I/O for this one-shot 11-byte config send.

pub const IpcServer = struct {
    pipe_handle: ?*anyopaque = null,
    connected: bool = false,
    // Filled in by send() on failure so the caller can log a meaningful
    // error (Win32 GetLastError code, or 0xFFFFFFFF for partial write).
    // 0 = no error / never attempted. 109 = ERROR_BROKEN_PIPE (client gone).
    // 87 = ERROR_INVALID_PARAMETER (should never happen now that the pipe
    // is non-overlapped; if it does, the pipe handle is corrupt).
    last_send_error: u32 = 0,
    // NOTE: recv_buf/recv_len were removed along with poll() — they only
    // existed to back that dead method. If a future caller needs to RECEIVE
    // data on the server side, add a framing-aware reader modeled on the
    // DLL's IpcReader.

    pub fn listen(name: []const u8) !IpcServer {
        var name_buf: [256]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "\\\\.\\pipe\\{s}", .{name}) catch return error.NameTooLong;

        // Synchronous pipe (no FILE_FLAG_OVERLAPPED). Matches the legacy
        // C++ CCCaster ProcessManager::openGame.
        const handle = win32.CreateNamedPipeA(
            name_z.ptr,
            win32.PIPE_ACCESS_DUPLEX,
            win32.PIPE_TYPE_BYTE | win32.PIPE_WAIT,
            1, // max instances
            65536, // out buffer
            65536, // in buffer
            0, // default timeout
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE or handle == null) return error.CreatePipeFailed;

        // Do NOT call ConnectNamedPipe here — on a synchronous pipe it would
        // block until a client connects, but the launcher needs to launch
        // MBAA.exe + inject the DLL FIRST so the DLL can be the client.
        // waitForConnection() is the blocking call; it's invoked after
        // WindowsLauncher.launch() returns.
        return IpcServer{ .pipe_handle = handle };
    }

    pub fn waitForConnection(self: *IpcServer) !void {
        if (self.pipe_handle == null) return error.NotListening;
        if (self.connected) return;

        // Synchronous ConnectNamedPipe: blocks until a client (the injected
        // hook.dll) calls CreateFileA on the pipe. lpOverlapped = NULL is
        // the correct call for a non-overlapped handle.
        //
        // Return value:
        //   != 0  → success (client connected)
        //   == 0  → failure, UNLESS GetLastError() == ERROR_PIPE_CONNECTED
        //           (535), which means a client connected between
        //           CreateNamedPipe and ConnectNamedPipe — also a success.
        const rc = win32.ConnectNamedPipe(self.pipe_handle, null);
        if (rc == 0 and win32.GetLastError() != win32.ERROR_PIPE_CONNECTED) {
            return error.ConnectPipeFailed;
        }
        self.connected = true;
    }

    pub fn send(self: *IpcServer, data: []const u8) bool {
        if (!self.connected or self.pipe_handle == null) return false;

        // Length-prefix framing: 4-byte LE length + payload
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(data.len), .little);

        var written: u32 = 0;
        // WriteFile on a non-overlapped PIPE_WAIT BYTE-mode pipe blocks until
        // the write completes (the OS buffers it in the pipe's 64KB kernel
        // buffer). For our 11-byte config payload this is essentially
        // instant — BUT only if the client handle is still open. If the DLL
        // has already exited or closed its handle (race at process
        // shutdown), WriteFile returns 0 with GetLastError() ==
        // ERROR_BROKEN_PIPE (109). Surface that as a distinct return code
        // instead of silently dropping the config.
        if (win32.WriteFile(self.pipe_handle, &header, 4, &written, null) == 0) {
            self.last_send_error = win32.GetLastError();
            return false;
        }
        if (written != 4) {
            self.last_send_error = 0xFFFFFFFF; // partial write sentinel
            return false;
        }
        if (win32.WriteFile(self.pipe_handle, data.ptr, @intCast(data.len), &written, null) == 0) {
            self.last_send_error = win32.GetLastError();
            return false;
        }
        if (written != data.len) {
            self.last_send_error = 0xFFFFFFFF; // partial write sentinel
            return false;
        }
        return true;
    }

    // The previous `pub fn poll(self: *IpcServer) ?[]const u8` was REMOVED:
    //   - It was unused anywhere in the codebase.
    //   - It read raw bytes via PeekNamedPipe+ReadFile without honoring the
    //     length-prefix framing that `send()` emits. If it had been called,
    //     it would have desynchronized the protocol exactly the way the
    //     DLL-side reader used to before this PR fixed it.
    // The DLL-side `IpcReader` in src/dll/dllmain.zig is the canonical
    // framing-aware reader; if a server-side poll is ever needed again,
    // port that state machine here rather than resurrecting this stub.

    pub fn close(self: *IpcServer) void {
        if (self.connected) {
            _ = win32.DisconnectNamedPipe(self.pipe_handle);
            self.connected = false;
        }
        if (self.pipe_handle) |h| {
            _ = win32.CloseHandle(h);
            self.pipe_handle = null;
        }
    }
};
