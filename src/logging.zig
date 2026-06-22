const std = @import("std");

// Win32 externs for thread-safe file I/O. We use these instead of
// std.Io.File.writeStreamingAll because the Io backend may be
// single-threaded (init_single_threaded), and using it from a different
// thread (e.g. the session thread) causes a null pointer dereference in
// Zig's thread-local I/O state. Win32 WriteFile is thread-safe and
// doesn't depend on any Io handle.
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
    extern "kernel32" fn GetModuleFileNameA(hModule: ?*anyopaque, lpFilename: [*]u8, nSize: u32) callconv(.winapi) u32;
};

const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const OPEN_ALWAYS: u32 = 4;
const FILE_APPEND_DATA: u32 = 0x0004;

pub const Logger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // Win32 file handle (HANDLE). Null if the log file couldn't be opened.
    // Stored as ?*anyopaque to avoid importing Windows type defs.
    file_handle: ?*anyopaque = null,
    stdout: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Logger {
        // Ensure directory exists using std.Io (runs on main thread — safe).
        const dir_path = std.fs.path.dirname(path) orelse ".";
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

        // Open the log file with Win32 CreateFileA directly. This gives us
        // a HANDLE we can use with WriteFile from any thread, without
        // depending on the (potentially single-threaded) std.Io backend.
        // FILE_APPEND_DATA ensures writes append to the end of the file.
        var path_buf: [512]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return Logger{
            .allocator = allocator,
            .io = io,
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
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

        // Build the full log line: "[LEVEL] message\n"
        var line_buf: [1200]u8 = undefined;
        var line_len: usize = 0;

        // Copy level prefix
        if (level.len + 1 <= line_buf.len - line_len) {
            @memcpy(line_buf[line_len..][0..level.len], level);
            line_len += level.len;
            line_buf[line_len] = ' ';
            line_len += 1;
        }

        // Copy message
        const copy_len = @min(msg.len, line_buf.len - line_len);
        @memcpy(line_buf[line_len..][0..copy_len], msg[0..copy_len]);
        line_len += copy_len;

        // Newline
        if (line_len < line_buf.len) {
            line_buf[line_len] = '\n';
            line_len += 1;
        }

        // Write to file using Win32 WriteFile (thread-safe, no Io handle needed).
        if (self.file_handle) |h| {
            var written: u32 = 0;
            _ = win32.WriteFile(h, line_buf[0..line_len].ptr, @intCast(line_len), &written, null);
        }

        // Write to stdout if enabled.
        if (self.stdout) {
            const sout = std.Io.File.stdout();
            sout.writeStreamingAll(self.io, line_buf[0..line_len]) catch {};
        }
    }
};
