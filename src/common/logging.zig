const std = @import("std");

pub const Logger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: ?std.Io.File = null,
    // Tracks the current write offset within `file`. The Zig 0.16 `std.Io.File`
    // API does NOT expose a `seek()` — instead it offers `writePositionalAll`,
    // which writes at an explicit offset without disturbing the file's
    // internal cursor. We track the offset ourselves so we can append safely.
    write_offset: u64 = 0,
    stdout: bool = false,

    /// Open (or create) `path` for APPEND-style logging: every new process
    /// run appends to the existing file rather than overwriting it.
    ///
    /// The previous implementation opened with `.mode = .write_only` on an
    /// existing file (which positions the cursor at offset 0, so subsequent
    /// writes overwrite the start of the file), and `.truncate = false` on
    /// the createFile fallback (which suggested append intent but didn't
    /// actually seek to end). The combined behavior was implementation-
    /// dependent and effectively "truncate-on-open" for files opened via
    /// openFile.
    ///
    /// Now we open for read+write (no truncation), stat to find the existing
    /// size, and use `writePositionalAll` for every write so each write goes
    /// to the tracked end-of-file offset.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Logger {
        const dir_path = std.fs.path.dirname(path) orelse ".";
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};

        const cwd = std.Io.Dir.cwd();
        // Open existing file for read+write (no truncation), otherwise create.
        const f = cwd.openFile(io, path, .{ .mode = .read_write }) catch
            (cwd.createFile(io, path, .{ .truncate = false }) catch return Logger{
                .allocator = allocator,
                .io = io,
            });

        // Determine current size so subsequent writes append (not overwrite).
        const initial_offset: u64 = blk: {
            const stat = f.stat(io) catch break :blk 0;
            break :blk stat.size;
        };

        return Logger{
            .allocator = allocator,
            .io = io,
            .file = f,
            .write_offset = initial_offset,
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

        if (self.file) |f| {
            // Build the full line in a scratch buffer so we can do a single
            // positional write (cheaper than 4 separate writePositionalAll
            // calls and avoids interleaving with other threads' writes if
            // logging ever becomes multi-threaded).
            var line_buf: [1100]u8 = undefined;
            var line_len: usize = 0;
            const append = struct {
                fn it(out: []u8, len: *usize, src: []const u8) void {
                    const n = @min(src.len, out.len - len.*);
                    @memcpy(out[len.* .. len.* + n], src[0..n]);
                    len.* += n;
                }
            };
            append.it(&line_buf, &line_len, level);
            append.it(&line_buf, &line_len, " ");
            append.it(&line_buf, &line_len, msg);
            append.it(&line_buf, &line_len, "\n");

            const written = line_buf[0..line_len];
            f.writePositionalAll(self.io, written, self.write_offset) catch {};
            self.write_offset += written.len;
        }

        if (self.stdout) {
            const sout = std.Io.File.stdout();
            sout.writeStreamingAll(self.io, level) catch {};
            sout.writeStreamingAll(self.io, " ") catch {};
            sout.writeStreamingAll(self.io, msg) catch {};
            sout.writeStreamingAll(self.io, "\n") catch {};
        }
    }
};
