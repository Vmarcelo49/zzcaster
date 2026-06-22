const std = @import("std");
const config = @import("config.zig");
const logging = @import("logging.zig");

// Win32 externs for IPC (named pipe)
const win32 = struct {
    extern "kernel32" fn CreateNamedPipeA(
        lpName: [*:0]const u8, dwOpenMode: u32, dwPipeMode: u32,
        nMaxInstances: u32, nOutBufferSize: u32, nInBufferSize: u32,
        nDefaultTimeOut: u32, lpSecurityAttributes: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn ConnectNamedPipe(hNamedPipe: ?*anyopaque, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;
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
    extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CreateEventA(
        lpEventAttributes: ?*anyopaque, bManualReset: i32, bInitialState: i32,
        lpName: ?[*:0]const u8,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetOverlappedResult(
        hFile: ?*anyopaque, lpOverlapped: *Overlapped, lpNumberOfBytesTransferred: *u32, bWait: i32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;

    const Overlapped = extern struct {
        Internal: usize,
        InternalHigh: usize,
        Offset: u32,
        OffsetHigh: u32,
        hEvent: ?*anyopaque,
    };

    const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
    const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
    const PIPE_TYPE_BYTE: u32 = 0x00000000;
    const PIPE_WAIT: u32 = 0x00000000;
    const ERROR_PIPE_CONNECTED: u32 = 535;
    const ERROR_IO_PENDING: u32 = 997;
    const INVALID_HANDLE_VALUE: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
};

pub const IpcServer = struct {
    pipe_handle: ?*anyopaque = null,
    connect_event: ?*anyopaque = null,
    connect_overlapped: win32.Overlapped = std.mem.zeroes(win32.Overlapped),
    connected: bool = false,
    recv_buf: [65536]u8 = undefined,
    recv_len: usize = 0,

    pub fn listen(name: []const u8) !IpcServer {
        var name_buf: [256]u8 = undefined;
        const name_z = std.fmt.bufPrintZ(&name_buf, "\\\\.\\pipe\\{s}", .{name}) catch return error.NameTooLong;

        const handle = win32.CreateNamedPipeA(
            name_z.ptr,
            win32.PIPE_ACCESS_DUPLEX | win32.FILE_FLAG_OVERLAPPED,
            win32.PIPE_TYPE_BYTE | win32.PIPE_WAIT,
            1,      // max instances
            65536,  // out buffer
            65536,  // in buffer
            0,      // default timeout
            null,
        );
        if (handle == win32.INVALID_HANDLE_VALUE or handle == null) return error.CreatePipeFailed;

        // Create an event for overlapped ConnectNamedPipe + auto-reset=false (manual).
        const ev = win32.CreateEventA(null, 1, 0, null) orelse return error.CreateEventFailed;

        var server = IpcServer{
            .pipe_handle = handle,
            .connect_event = ev,
            .connect_overlapped = std.mem.zeroes(win32.Overlapped),
        };
        server.connect_overlapped.hEvent = ev;

        // Start listening with overlapped I/O — returns immediately with
        // ERROR_IO_PENDING. The pipe transitions to PIPE_CONNECTED when a
        // client calls CreateFile. waitForConnection() will block on the
        // event until that happens.
        const rc = win32.ConnectNamedPipe(handle, &server.connect_overlapped);
        if (rc == 0 and win32.GetLastError() != win32.ERROR_IO_PENDING and
            win32.GetLastError() != win32.ERROR_PIPE_CONNECTED)
        {
            return error.ConnectPipeFailed;
        }

        return server;
    }

    pub fn waitForConnection(self: *IpcServer) !void {
        if (self.pipe_handle == null) return error.NotListening;
        if (self.connected) return;

        var bytes: u32 = 0;
        const rc = win32.GetOverlappedResult(self.pipe_handle, &self.connect_overlapped, &bytes, 1);
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
        if (win32.WriteFile(self.pipe_handle, &header, 4, &written, null) == 0) return false;
        if (win32.WriteFile(self.pipe_handle, data.ptr, @intCast(data.len), &written, null) == 0) return false;
        return true;
    }

    pub fn poll(self: *IpcServer) ?[]const u8 {
        if (!self.connected or self.pipe_handle == null) return null;

        // Check if data is available
        var available: u32 = 0;
        if (win32.PeekNamedPipe(self.pipe_handle, null, 0, null, &available, null) == 0) {
            self.connected = false;
            return null;
        }
        if (available == 0) return null;

        // Read available data
        var read: u32 = 0;
        if (win32.ReadFile(self.pipe_handle, &self.recv_buf, available, &read, null) == 0) {
            self.connected = false;
            return null;
        }

        self.recv_len = read;
        return self.recv_buf[0..read];
    }

    pub fn close(self: *IpcServer) void {
        if (self.connected) {
            _ = win32.DisconnectNamedPipe(self.pipe_handle);
            self.connected = false;
        }
        if (self.pipe_handle) |h| {
            _ = win32.CloseHandle(h);
            self.pipe_handle = null;
        }
        if (self.connect_event) |e| {
            _ = win32.CloseHandle(e);
            self.connect_event = null;
        }
    }
};
