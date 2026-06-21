# `std.Io` — the central abstraction of Zig 0.16

The single biggest change in 0.16. An `Io` value represents *how* a process blocks. Every
API that touches the network, filesystem, clock, randomness, child processes, environment
variables, current working directory, or any kind of wait now takes an `Io` as a parameter.

This is the same shape as `Allocator`: thread it through your code, store it in your
structs, pass it to every function that needs to do anything blocking.

## Table of contents

1. [Why `Io` exists](#why-io-exists)
2. [Io variants](#io-variants)
3. [Obtaining an `Io`](#obtaining-an-io)
4. [`Io.Dir` and `Io.File`](#iodir-and-iofile)
5. [`Io.Reader` and `Io.Writer`](#ioreader-and-iowriter)
6. [Networking](#networking)
7. [Time: `Duration`, `Timestamp`, `Clock`, `Timeout`](#time)
8. [Randomness](#randomness)
9. [Environment variables and process spawning](#environment-variables-and-process-spawning)
10. [Cancellation contract](#cancellation-contract)
11. [Threading `Io` through a codebase](#threading-io-through-a-codebase)

## Why `Io` exists

Before 0.16, Zig had two parallel worlds for blocking operations:

- The "sync" world: `std.fs`, `std.net`, `std.time.sleep`, `std.os.getenv`.
- The hypothetical "async" world: `async`/`await` keywords (removed in 0.15) and
  `std.event.Loop`.

Code written for one could not be reused for the other. The async refactor never landed and
the keywords were removed. In 0.16, both worlds are unified: blocking operations take an
`Io`, and the `Io` decides whether the call blocks an OS thread, parks a coroutine on an
event loop, or queues an io_uring submission.

This gives you "async for free" without bifurcating the std library: write code once
against `Io.Threaded`, switch to `Io.Evented` at startup, and the same code now runs as
M:N coroutines.

## Io variants

| Io              | What it does                                                            | When to use                                            |
|-----------------|-------------------------------------------------------------------------|--------------------------------------------------------|
| `Io.Threaded`   | Default. Each blocking call parks an OS thread.                          | CLI tools, games, services that don't need huge concurrency |
| `Io.Evented`    | M:N coroutines on a worker pool. The closest thing to "async" returns.  | High-concurrency servers, HTTP services               |
| `Io.Uring`      | Linux io_uring backend.                                                  | Linux servers doing many concurrent file/network ops   |
| `Io.Kqueue`     | BSD/macOS kqueue backend.                                                | Same as Uring on BSD/macOS                            |
| `Io.Dispatch`   | Manually driven — you pump the Io's queue yourself.                     | Embedders (e.g. inside a game loop), test runners     |
| `Io.failing`    | Returns every error immediately.                                         | Property-based tests, fuzz harnesses                  |

The Io is *not* a singleton. You can have multiple in one process — common for embedding or
for tests that want isolation.

## Obtaining an `Io`

The canonical way is `std.process.Init`:

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;   // Io.Threaded by default
    // ...
}
```

For tests:

```zig
const std = @import("std");

test "io test" {
    var io_state = std.testing.io;
    const io = &io_state.io;
    // ... use io ...
    try io_state.flush();
}
```

For a custom Io:

```zig
// Evented — M:N coroutines
var evented = try std.Io.Evented.init(gpa);
defer evented.deinit();
const io: std.Io = evented.io;

// Dispatch — you pump it manually (e.g. inside a game loop)
var dispatch: std.Io.Dispatch = .empty;
dispatch.initContext(gpa);
defer dispatch.deinit(gpa);
const io: std.Io = dispatch.io;
// Later, in the frame loop:
try dispatch.pump();
```

## `Io.Dir` and `Io.File`

The old `std.fs.Dir` is replaced by `std.Io.Dir`. The CWD is no longer a global — you ask
the Io for it.

```zig
const io = init.io;

// Get the current working directory
var cwd: std.Io.Dir = .cwd(io);
defer cwd.close(io);

// Open a file
var f = try cwd.openFile("data.bin", .{});
defer f.close(io);

// Read streaming (the canonical read in 0.16 — it can block)
var buf: [4096]u8 = undefined;
const n = try f.readStreaming(io, &buf);

// Read at a specific offset (no seek needed)
const n2 = try f.readPositional(io, &buf, 4096, 0);

// Write
var w = try cwd.createFile("out.bin", .{});
defer w.close(io);
_ = try w.writeStreaming(io, &buf[0..n]);

// Iterate directory entries
var iter = try cwd.iterate(io);
defer iter.close(io);
while (try iter.next(io)) |entry| {
    io.out().print("{s}\n", .{entry.name}) catch {};
}
```

Method rename table — see also [std-fs.md](std-fs.md):

| 0.15 (`std.fs.Dir`)        | 0.16 (`std.Io.Dir`)                        |
|----------------------------|-------------------------------------------|
| `makeDir(path)`            | `createDir(io, path)`                     |
| `makeOpenPath(path, .{})`  | `makeOpenPath(io, path, .{})`             |
| `chmod(mode)`              | `setPermissions(io, mode)`                |
| `deleteFile(path)`         | `deleteFile(io, path)`                    |
| `rename(from, to)`         | `rename(io, from, to)`                    |
| `openFile(path, .{})`      | `openFile(io, path, .{})`                 |
| `read(&buf)`               | `readStreaming(io, &buf)`                 |
| `pread(&buf, offset)`      | `readPositional(io, &buf, len, offset)`   |
| `write(buf)`               | `writeStreaming(io, buf)`                 |
| `close()`                  | `close(io)`                               |

## `Io.Reader` and `Io.Writer`

The non-generic reader/writer refactor finished in 0.16. The interface carries its own
buffer; you don't need a separate `BufferedWriter`.

```zig
// Stdout from main — no buffer needed, the Io owns one
pub fn main(init: std.process.Init) !void {
    const stdout = init.io.out();
    try stdout.print("hello\n", .{});
}

// Writing to a fixed buffer (e.g. for a small string operation)
var buf: [256]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try w.print("x = {d}", .{x});
const written: []const u8 = w.buffered();   // "x = 42"

// Allocating writer — grows as needed
var aw = std.Io.Writer.Allocating.init(gpa);
defer aw.deinit();
try aw.print("list: ", .{});
for (items) |it| try aw.print("{s} ", .{it});
const text = aw.written();
defer gpa.free(text);

// Discarding writer — for counting / dry-runs
var dw: std.Io.Writer = .Discarding;
try dw.print("anything", .{});   // goes nowhere
const bytes_written = dw.fullCount();
```

Reading:

```zig
// Fixed reader from a slice
var r: std.Io.Reader = .fixed("hello\nworld");
const first_line = (try r.takeDelimiter('\n')).?;   // "hello"
const second = (try r.takeDelimiter('\n')).?;       // "world"
const eof = try r.takeDelimiter('\n');              // null

// Reading from a file
var f = try cwd.openFile("data.bin", .{});
defer f.close(io);
var r = f.reader(io, &buf);   // buf is your [4096]u8 stack buffer
const line = try r.takeDelimiter('\n');

// Binary reads
const header = try r.takeStruct(Header, .little);
const count = try r.takeInt(u32, .big);
const leb = try r.takeLeb128(u64);
```

Deprecated / removed in 0.16:
- `BufferedWriter`, `CountingReader`, `FixedBufferStream`, `GenericWriter`, `GenericReader`,
  `AnyWriter`, `AnyReader`, `null_writer` — all gone.
- `std.io.getStdOut().writer()` — use `init.io.out()` instead.
- `std.io.bufferedWriter(w)` — just `w.flush()` if you constructed from a buffer; the Io
  pattern handles buffering for you.

## Networking

`std.net` is gone; everything lives under `std.Io.Net`.

```zig
var net: std.Io.Net = .empty;
net.initContext(io);
defer net.deinit(io);

// TCP connect
var conn = try net.tcpConnect(io, .{ .host = "example.com", .port = 80 });
defer conn.close(io);

var w = conn.writer(io, &buf);
try w.print("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n", .{});
try w.flush();

var r = conn.reader(io, &buf);
const status = (try r.takeDelimiter('\n')).?;
io.out().print("{s}", .{status}) catch {};
```

UDP, Unix sockets, and named pipes all follow the same pattern: construct the subsystem
with `.empty` + `initContext(io)`, use it, `deinit(io)` on cleanup.

## Time

Time was previously a grab-bag of `std.time.*` functions. In 0.16 it's typed:

```zig
const start: Io.Timestamp = io.clock.now();
io.sleep(.{ .ms = 16 });                          // type-safe sleep
const elapsed: Io.Duration = io.clock.now().since(start);
if (elapsed.ms > 20) {
    io.err().print("frame too long: {d}ms\n", .{elapsed.ms}) catch {};
}

// Timeout on an operation
const result = try io.timeout(.{ .seconds = 5 }, fetchResource(io, url));
// returns error.Timeout if it doesn't complete in time
```

Types:
- `Io.Duration` — a length of time (ms, us, ns, seconds).
- `Io.Timestamp` — a point in time on a specific clock.
- `Io.Clock` — which clock (monotonic, wall, etc).
- `Io.Timeout` — wrapper used by `io.timeout(duration, future)`.

## Randomness

`std.crypto.random` is removed; randomness flows through `Io` too. This is critical for
deterministic testing — `Io.failing` lets you stub the RNG.

```zig
var rng = io.rng();
const x = rng.random().int(u64);
const y = rng.random().float(f32);

// Seeded RNG for deterministic tests
var seeded = std.Random.DefaultPrng.init(0xdeadbeef);
const r = seeded.random();
const z = r.int(u64);
```

For **game simulations** that need to be deterministic across machines (rollback netcode!),
use a seeded `DefaultPrng` — never `io.rng()` — and seed it identically on both peers. See
the [rollback-netcode skill](../../rollback-netcode/SKILL.md) for the full treatment.

## Environment variables and process spawning

Environment variables are no longer global. They live on the `Init`.

```zig
pub fn main(init: std.process.Init) !void {
    const home = init.environ_map.get("HOME") orelse "/tmp";
    init.io.out().print("home: {s}\n", .{home}) catch {};
}
```

Spawning a child process:

```zig
var subprocess = try std.process.Child.spawn(io, .{
    .argv = &.{ "git", "status", "--porcelain" },
    .stdout = .pipe,
});
defer subprocess.kill(io) catch {};

var r = subprocess.stdout.?.reader(io, &buf);
const out = (try r.takeDelimiter('\n')).?;
```

The child process inherits the parent's `Io` model: on `Io.Evented`, you can spawn
thousands of concurrent subprocesses without OS thread explosion.

## Cancellation contract

The cancellation contract is the most important — and most subtle — part of the Io model.
Any I/O operation that can block can also be canceled. Cancellation is signaled via
`error.Canceled`.

```zig
var group = io.createGroup(gpa);
defer group.cancelAndWait(io);

const handle = try io.async(group, longOperation, .{io});
// ... later, if user presses Ctrl-C ...
g.cancel(io);
// inside longOperation, the next cancelable I/O call returns error.Canceled

// longOperation should propagate error.Canceled up cleanly:
fn longOperation(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try io.stdin().reader(io, &buf).takeDelimiter('\n');
        // ... process n ...
        // ↑ if canceled mid-read, takeDelimiter returns error.Canceled,
        //   which propagates up to the awaiter
    }
}
```

Rules:
1. `error.Canceled` is in every cancelable I/O error set. Treat it like `error.OutOfMemory`
   — handle it or propagate it.
2. Always `defer g.cancel(io)` after every `io.async` to release the task's resources even
   on success paths.
3. Inside an async task, check `g.isCanceled()` if you have a long compute loop with no
   I/O — otherwise cancellation only triggers at the next I/O call.
4. `group.cancelAndWait(io)` cancels all outstanding tasks and waits for them to drain.
   Use it on shutdown.

## Threading `Io` through a codebase

The pattern is identical to `Allocator`. Every struct that performs I/O stores an `Io`:

```zig
const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    listener: std.Io.Net.Tcp.Listener,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, port: u16) !*Server {
        var net: std.Io.Net = .empty;
        net.initContext(io);
        const listener = try net.tcpListen(io, .{ .port = port });
        const s = try gpa.create(Server);
        s.* = .{ .io = io, .gpa = gpa, .listener = listener, .net = net };
        return s;
    }

    pub fn run(self: *Server) !void {
        var group = self.io.createGroup(self.gpa);
        defer group.cancelAndWait(self.io);
        while (true) {
            const conn = try self.listener.accept(self.io);
            _ = try self.io.async(group, handleConn, .{ self, conn });
        }
    }
};
```

Anti-patterns:
- ❌ Storing a global `Io` in a `var`. Thread it through, like `Allocator`.
- ❌ Calling `std.fs.cwd()` from inside a function. Take `cwd: std.Io.Dir` as a parameter.
- ❌ Using `std.time.milliTimestamp()` for game-loop timing. Use `io.clock.now()` so your
  game can run on a fake clock under tests.

## Further reading

- [async-concurrency.md](async-concurrency.md) — `Io.Group` and `io.async` in depth
- [std-fs.md](std-fs.md) — Filesystem migration guide
- [patterns.md](patterns.md) — Threading `Io` through large codebases, deterministic
  simulation patterns
