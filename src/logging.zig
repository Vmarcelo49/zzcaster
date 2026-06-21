const std = @import("std");

pub const Logger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: ?std.Io.File = null,
    stdout: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Logger {
        // Ensure directory exists. (Zig 0.16: std.fs.cwd().makePath →
        // std.Io.Dir.cwd().createDirPath(io, …).)
        const dir_path = std.fs.path.dirname(path) orelse ".";
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

        // Truncate=false → open-or-create without wiping. createFile truncates
        // by default, so we open existing files first and fall back to create.
        const cwd = std.Io.Dir.cwd();
        // Zig 0.16: OpenFileOptions has no `read` field — use `mode = .write_only`
        // so we can append without truncating an existing log file.
        const f = cwd.openFile(io, path, .{ .mode = .write_only }) catch
            (cwd.createFile(io, path, .{ .truncate = false }) catch return Logger{
                .allocator = allocator,
                .io = io,
            });

        return Logger{
            .allocator = allocator,
            .io = io,
            .file = f,
        };
    }

    pub fn deinit(self: *Logger) void {
        if (self.file) |f| f.close(self.io);
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

        // Write to file (Zig 0.16: File methods take an Io handle).
        if (self.file) |f| {
            f.writeStreamingAll(self.io, level) catch {};
            f.writeStreamingAll(self.io, " ") catch {};
            f.writeStreamingAll(self.io, msg) catch {};
            f.writeStreamingAll(self.io, "\n") catch {};
        }

        // Write to stdout.
        if (self.stdout) {
            const sout = std.Io.File.stdout();
            sout.writeStreamingAll(self.io, level) catch {};
            sout.writeStreamingAll(self.io, " ") catch {};
            sout.writeStreamingAll(self.io, msg) catch {};
            sout.writeStreamingAll(self.io, "\n") catch {};
        }
    }
};
