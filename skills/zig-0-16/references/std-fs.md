# Filesystem migration: `std.fs` → `std.Io`

In 0.16 the filesystem module moved wholesale into `std.Io`. The shapes are similar but
the call site is different: every method now takes an `Io` (or the operation is invoked
through an `Io.Dir` / `Io.File` that was constructed from an `Io`).

## Table of contents

1. [Top-level replacements](#top-level-replacements)
2. [`Dir` method rename table](#dir-method-rename-table)
3. [`File` method rename table](#file-method-rename-table)
4. [Common recipes](#common-recipes)
5. [Things that left `std.fs`](#things-that-left-stdfs)

## Top-level replacements

| 0.15                                  | 0.16                                                    |
|---------------------------------------|---------------------------------------------------------|
| `std.fs.cwd()`                        | `std.Io.Dir.cwd(io)` (call `.close(io)` when done)      |
| `std.fs.openFileAbsolute(path, .{})`  | `std.Io.Dir.openFileAbsolute(io, path, .{})`            |
| `std.fs.openDirAbsolute(path, .{})`   | `std.Io.Dir.openDirAbsolute(io, path, .{})`             |
| `std.fs.realpathAlloc(gpa, path)`     | `std.Io.Dir.cwd(io).realpathAlloc(io, gpa, path)`       |
| `std.fs.openSelfExe()`                | `std.Io.openSelfExe(io)`                                |
| `std.fs.selfExePathAlloc(gpa)`        | `std.Io.selfExePathAlloc(io, gpa)`                      |
| `std.fs.deleteFileAbsolute(path)`     | `std.Io.Dir.deleteFileAbsolute(io, path)`               |
| `std.fs.renameAbsolute(from, to)`     | `std.Io.Dir.renameAbsolute(io, from, to)`               |
| `std.fs.makeDirAbsolute(path)`        | `std.Io.Dir.makeDirAbsolute(io, path)`                  |
| `std.fs.readFileAlloc(gpa, path, max)`| `std.Io.Dir.cwd(io).readFileAlloc(io, gpa, path, max)`  |

## `Dir` method rename table

| 0.15                                   | 0.16                                              |
|----------------------------------------|---------------------------------------------------|
| `dir.close()`                          | `dir.close(io)`                                   |
| `dir.makeDir(path)`                    | `dir.createDir(io, path)`                         |
| `dir.makeOpenPath(path, .{})`          | `dir.makeOpenPath(io, path, .{})`                 |
| `dir.makePath(path)`                   | `dir.makeOpenPath(io, path, .{ .make_parents = true })` |
| `dir.deleteDir(path)`                  | `dir.deleteDir(io, path)`                         |
| `dir.deleteFile(path)`                 | `dir.deleteFile(io, path)`                        |
| `dir.deleteTree(path)`                 | `dir.deleteTree(io, path)`                        |
| `dir.rename(from, to)`                 | `dir.rename(io, from, to)`                        |
| `dir.statFile(path)`                   | `dir.statFile(io, path)`                          |
| `dir.chmod(mode)`                      | `dir.setPermissions(io, mode)`                    |
| `dir.openFile(path, .{})`              | `dir.openFile(io, path, .{})`                     |
| `dir.openDir(path, .{})`               | `dir.openDir(io, path, .{})`                      |
| `dir.createFile(path, .{})`            | `dir.createFile(io, path, .{})`                   |
| `dir.iterate()`                        | `dir.iterate(io)`                                 |
| `dir.realpathAlloc(gpa, path)`         | `dir.realpathAlloc(io, gpa, path)`                |
| `dir.readLink(path, buf)`              | `dir.readLink(io, path, buf)`                     |
| `dir.symLink(target, link, .{})`       | `dir.symLink(io, target, link, .{})`              |
| `dir.copyFile(src, dst, .{})`          | `dir.copyFile(io, src, dst, .{})`                 |
| `dir.updateFile(src, dst, .{})`        | `dir.updateFile(io, src, dst, .{})`               |
| `dir.watch(.{})`                       | `dir.watch(io, .{})`                              |

## `File` method rename table

| 0.15                              | 0.16                                            |
|-----------------------------------|-------------------------------------------------|
| `f.close()`                       | `f.close(io)`                                   |
| `f.read(&buf)`                    | `f.readStreaming(io, &buf)`                     |
| `f.readAll(&buf)`                 | `f.readAllStreaming(io, &buf)`                  |
| `f.pread(&buf, offset)`           | `f.readPositional(io, &buf, buf.len, offset)`   |
| `f.preadAll(&buf, offset)`        | `f.readAllPositional(io, &buf, offset)`         |
| `f.write(buf)`                    | `f.writeStreaming(io, buf)`                     |
| `f.writeAll(buf)`                 | `f.writeAllStreaming(io, buf)`                  |
| `f.pwrite(buf, offset)`           | `f.writePositional(io, buf, offset)`            |
| `f.pwriteAll(buf, offset)`        | `f.writeAllPositional(io, buf, offset)`         |
| `f.seekTo(offset)`                | `f.seekTo(io, offset)`                          |
| `f.seekBy(delta)`                 | `f.seekBy(io, delta)`                           |
| `f.getPos()`                      | `f.getPos(io)`                                  |
| `f.getEndPos()`                   | `f.getEndPos(io)`                               |
| `f.reader(&buf)`                  | `f.reader(io, &buf)`                            |
| `f.writer(&buf)`                  | `f.writer(io, &buf)`                            |
| `f.chmod(mode)`                   | `f.setPermissions(io, mode)`                    |
| `f.setEndPos(pos)`                | `f.setEndPos(io, pos)`                          |
| `f.sync()`                        | `f.sync(io)`                                    |

## Common recipes

### Reading a whole file

```zig
// 0.15
const data = try std.fs.cwd().readFileAlloc(gpa, "input.txt", 1 << 20);
defer gpa.free(data);

// 0.16
var cwd: std.Io.Dir = .cwd(io);
defer cwd.close(io);
const data = try cwd.readFileAlloc(io, gpa, "input.txt", 1 << 20);
defer gpa.free(data);
```

### Writing a file

```zig
// 0.15
var f = try std.fs.cwd().createFile("out.txt", .{});
defer f.close();
_ = try f.writeAll("hello\n");

// 0.16
var cwd: std.Io.Dir = .cwd(io);
defer cwd.close(io);
var f = try cwd.createFile(io, "out.txt", .{});
defer f.close(io);
_ = try f.writeAllStreaming(io, "hello\n");
```

### Iterating directory entries

```zig
// 0.15
var dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
defer dir.close();
var iter = dir.iterate();
while (try iter.next()) |entry| {
    std.debug.print("{s}\n", .{entry.name});
}

// 0.16
var cwd: std.Io.Dir = .cwd(io);
defer cwd.close(io);
var dir = try cwd.openDir(io, "src", .{ .iterate = true });
defer dir.close(io);
var iter = try dir.iterate(io);
defer iter.close(io);
while (try iter.next(io)) |entry| {
    io.out().print("{s}\n", .{entry.name}) catch {};
}
```

### Watching a directory for changes

```zig
var cwd: std.Io.Dir = .cwd(io);
defer cwd.close(io);
var watcher = try cwd.watch(io, .{});
defer watcher.close(io);

while (true) {
    const event = try watcher.next(io);
    io.out().print("changed: {s} ({s})\n", .{ event.path, @tagName(event.kind) }) catch {};
}
```

### Atomic file replacement

```zig
var cwd: std.Io.Dir = .cwd(io);
defer cwd.close(io);

var tmp = try cwd.createFile(io, "config.tmp", .{});
defer tmp.close(io);
_ = try tmp.writeAllStreaming(io, new_config_bytes);

// rename onto the real path — atomic on POSIX
try cwd.rename(io, "config.tmp", "config");
```

### Copying a file with progress

```zig
fn copyFile(io: std.Io, src_path: []const u8, dst_path: []const u8) !void {
    var cwd: std.Io.Dir = .cwd(io);
    defer cwd.close(io);

    var src = try cwd.openFile(io, src_path, .{});
    defer src.close(io);
    var dst = try cwd.createFile(io, dst_path, .{});
    defer dst.close(io);

    var buf: [64 * 1024]u8 = undefined;
    var total: u64 = 0;
    while (true) {
        const n = try src.readStreaming(io, &buf);
        if (n == 0) break;
        _ = try dst.writeAllStreaming(io, buf[0..n]);
        total += n;
        io.out().print("\rcopied {d} bytes", .{total}) catch {};
    }
    io.out().print("\n", .{}) catch {};
}
```

## Things that left `std.fs`

These were either reorganized or removed entirely:

- `std.fs.path` — still exists, but the join/basename/dirname helpers moved to
  `std.path`. Update imports.
- `std.fs.Watch` — now `Io.Dir.watch`. The watcher uses the Io's event source (inotify,
  kqueue, ReadDirectoryChangesW) and supports cancellation.
- `std.fs.getStdIn()` / `getStdOut()` / `getStdErr()` — use `init.io.stdin()`,
  `init.io.out()`, `init.io.err()`. They return an `Io.Reader` / `Io.Writer` directly
  (the underlying `Io.File` is held by the Io).
- `std.fs.File.stdout()` / `File.stderr()` — still available, but they're for low-level
  access; the recommended path is `init.io.out()` / `init.io.err()`.

## Gotchas

### Forgetting `close(io)` leaks file descriptors

Every `openFile` / `openDir` / `createFile` returns a handle that owns an OS file
descriptor. The new `close(io)` takes an `Io` because the close itself may need to flush
buffered writes through the Io. The standard `defer f.close(io)` works as long as the
`Io` is still alive at defer time — make sure your Io outlives all your files.

### `readStreaming` may return fewer bytes than asked

Like the old `read`, `readStreaming` may return a short read. If you need exactly N bytes,
use `readAllStreaming`:

```zig
var header_buf: [16]u8 = undefined;
try f.readAllStreaming(io, &header_buf);   // guarantees 16 bytes or error
```

### Positional reads don't move the cursor

`readPositional(io, &buf, len, offset)` is independent of the file's seek position —
use it for parallel reads on the same file from multiple coroutines.

### Symbolic links

`readLink` returns the link target as bytes written into your buffer:

```zig
var target_buf: [std.fs.max_path_bytes]u8 = undefined;
const target = try dir.readLink(io, "shortcut", &target_buf);
```

### Path encoding

Paths are `[]const u8` bytes on POSIX and `[]const u16` (WTF-16) on Windows. Use
`std.os.windows.wToPrefixedWtf8IfNeeded` if you need to bridge. Most code never touches
this — the Io layer handles it transparently.

## See also

- [std-io.md](std-io.md) — The Io abstraction itself
- [migration-015-016.md](migration-015-016.md) — End-to-end migration walkthrough
