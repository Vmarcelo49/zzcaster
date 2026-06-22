const std = @import("std");

// Win32 externs for thread-safe file I/O and thread identification.
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

    extern "kernel32" fn WriteFile(
        hFile: ?*anyopaque,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: u32,
        lpNumberOfBytesWritten: *u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;

    extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
};

const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const OPEN_ALWAYS: u32 = 4;
const FILE_APPEND_DATA: u32 = 0x0004;

pub const Logger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file_handle: ?*anyopaque = null,
    stdout: bool = false,
    // Thread ID of the thread that created this Logger. Only that thread
    // is allowed to write log entries. Other threads (e.g. the netplay
    // session thread) silently skip logging — their log calls would crash
    // under Wine because std.fmt / std.Io access thread-local state that
    // doesn't exist on non-main threads.
    main_thread_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Logger {
        const dir_path = std.fs.path.dirname(path) orelse ".";
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

        var path_buf: [512]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return Logger{
            .allocator = allocator,
            .io = io,
            .main_thread_id = win32.GetCurrentThreadId(),
        };

        const handle = win32.CreateFileA(
            path_z.ptr,
            GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null,
            OPEN_ALWAYS,
            FILE_APPEND_DATA,
            null,
        );

        return Logger{
            .allocator = allocator,
            .io = io,
            .file_handle = handle,
            .main_thread_id = win32.GetCurrentThreadId(),
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file_handle) |h| {
            _ = win32.CloseHandle(h);
            self.file_handle = null;
        }
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log("[INFO]", fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log("[WARN]", fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log("[ERROR]", fmt, args);
    }

    fn log(self: *Logger, level: []const u8, comptime fmt: []const u8, args: anytype) void {
        // THREAD SAFETY: Only log from the thread that created this Logger.
        // The launcher spawns a background session thread for host()/join()
        // which calls self.log.info() throughout. Under Wine's wow64 layer,
        // std.fmt.bufPrint and std.Io access thread-local state that only
        // exists on the main thread, causing null pointer dereferences:
        //   'page fault on read access to 0x00000010'
        //   instruction: movl 0x10(%esi), %eax with ESI=0
        // By checking the thread ID, we ensure all formatting + I/O happens
        // only on the main thread. The session thread's log calls are
        // silently dropped — the session's .state field communicates results
        // to the UI thread, not the log.
        if (win32.GetCurrentThreadId() != self.main_thread_id) return;

        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

        // Build the full log line: "[LEVEL] message\n"
        var line_buf: [1200]u8 = undefined;
        var line_len: usize = 0;

        if (level.len + 1 <= line_buf.len - line_len) {
            @memcpy(line_buf[line_len..][0..level.len], level);
            line_len += level.len;
            line_buf[line_len] = ' ';
            line_len += 1;
        }

        const copy_len = @min(msg.len, line_buf.len - line_len);
        @memcpy(line_buf[line_len..][0..copy_len], msg[0..copy_len]);
        line_len += copy_len;

        if (line_len < line_buf.len) {
            line_buf[line_len] = '\n';
            line_len += 1;
        }

        if (self.file_handle) |h| {
            var written: u32 = 0;
            _ = win32.WriteFile(h, line_buf[0..line_len].ptr, @intCast(line_len), &written, null);
        }

        if (self.stdout) {
            const sout = std.Io.File.stdout();
            sout.writeStreamingAll(self.io, line_buf[0..line_len]) catch {};
        }
    }
};
