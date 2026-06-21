# Async & concurrency: `Io.Group`, `io.async`, `Future.await`

`async` and `await` keywords are still removed from the language (since 0.15). They are
replaced by `io.async(...)` / `Future.await(io)`, which live on the `Io` value. This means
the same code can run on `Io.Threaded` (one OS thread per blocking op) or `Io.Evented`
(M:N coroutines on a worker pool) without changes — the choice is made at startup by
selecting an `Io` implementation.

## Table of contents

1. [The mental model](#the-mental-model)
2. [Spawning tasks](#spawning-tasks)
3. [Awaiting and canceling](#awaiting-and-canceling)
4. [`Io.Group` lifecycle](#iogroup-lifecycle)
5. [Synchronization primitives](#synchronization-primitives)
6. [Selecting between tasks](#selecting-between-tasks)
7. [Backpressure and rate limiting](#backpressure-and-rate-limiting)
8. [Pattern: HTTP server](#pattern-http-server)
9. [Pattern: game loop with background I/O](#pattern-game-loop-with-background-io)
10. [Migration from `std.Thread.Pool`](#migration-from-stdthreadpool)

## The mental model

```text
io.async(group, func, args)  ──▶  Future(T)
                                     │
                                     │   (on Io.Threaded: OS thread)
                                     │   (on Io.Evented: coroutine)
                                     ▼
                                  runs func(args)
                                     │
                                     ▼
future.await(io)  ──▶  T  (or error, including error.Canceled)
```

Three things to internalize:

1. **The function signature is unchanged.** You don't write `async fn` or annotate your
   functions. Any function that takes an `Io` can be spawned as a task.
2. **Cancellation is cooperative.** `g.cancel(io)` marks the group as canceled; the next
   cancelable I/O operation inside any task in that group returns `error.Canceled`. There
   is no thread kill.
3. **A task is owned by a `Group`, not by the spawner.** When the spawner returns, the task
   keeps running until it finishes, is canceled, or the group is destroyed.

## Spawning tasks

```zig
const io = init.io;
var group = io.createGroup(gpa);
defer group.cancelAndWait(io);

// Spawn a function with no arguments
const h1 = try io.async(group, heartbeat, .{io});

// Spawn a function with arguments (passed as a tuple)
const h2 = try io.async(group, fetchUrl, .{ io, "https://example.com" });

// The result type is inferred from the function's return type
// h1: Future(void)
// h2: Future([]u8)   (assuming fetchUrl returns ![]u8)
```

The async function takes a `Group` so the runtime knows where to track the task. The
arguments tuple is captured by reference, so they must outlive the spawn — usually by
living in the caller's stack frame or in the arena.

## Awaiting and canceling

```zig
const result = try h2.await(io);          // blocks until done, returns []u8
defer gpa.free(result);

// Don't want to wait? Drop the handle and let it finish on its own.
// But you must still cancel via the group on shutdown.

// Cancel the whole group:
group.cancel(io);
group.wait(io);   // wait for all tasks to drain
```

### Cancellation in detail

Inside the spawned function, cancellation surfaces as `error.Canceled`:

```zig
fn fetchUrl(io: std.Io, url: []const u8) ![]u8 {
    var net: std.Io.Net = .empty;
    net.initContext(io);
    defer net.deinit(io);

    var conn = try net.tcpConnect(io, .{ .url = url });   // can return error.Canceled
    defer conn.close(io);

    var r = conn.reader(io, &buf);
    const line = try r.takeDelimiter('\n');                // can return error.Canceled
    return try gpa.dupe(u8, line);
}
```

If the function has a long compute loop with no I/O, you should check for cancellation
explicitly:

```zig
fn computeHeavy(io: std.Io, group: *Io.Group, data: []u8) !void {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (group.isCanceled()) return error.Canceled;
        data[i] = process(data[i]);
    }
}
```

## `Io.Group` lifecycle

| Method                              | What it does                                              |
|-------------------------------------|-----------------------------------------------------------|
| `io.createGroup(gpa)`               | Allocate a group on `gpa`. Returns `Io.Group`.            |
| `group.cancel(io)`                  | Signal cancellation to all tasks in the group.            |
| `group.wait(io)`                    | Block until all tasks finish.                             |
| `group.cancelAndWait(io)`           | Convenience: cancel + wait. Use this in `defer`.          |
| `group.isCanceled()`                | Cheap poll — true if `cancel` has been called.            |
| `group.activeTaskCount()`           | Number of tasks still running.                            |

Anti-patterns:
- ❌ `var group = io.createGroup(gpa);` without a `defer group.cancelAndWait(io)` — leaks
  tasks if the function returns early on error.
- ❌ Spawning into one group but awaiting from another — `Future.await` works fine across
  groups, but cancellation flows through the group the task was spawned into.

## Synchronization primitives

All the old `std.Thread` sync primitives are gone or moved. The replacements live on `Io`
and cooperate with the Io's event source (so on `Io.Evented`, waiting on a mutex parks the
coroutine rather than blocking the OS thread).

| 0.15                            | 0.16                          |
|---------------------------------|-------------------------------|
| `std.Thread.Mutex`              | `Io.Mutex`                    |
| `std.Thread.Condition`          | `Io.Condition`                |
| `std.Thread.ResetEvent`         | `Io.ResetEvent`               |
| `std.Thread.RwLock`             | `Io.RwLock`                   |
| `std.Thread.Semaphore`          | `Io.Semaphore`                |
| `std.Thread.Futex`              | `Io.Futex`                    |
| `std.atomic`                    | `std.atomic` (unchanged)      |

Usage:

```zig
const Shared = struct {
    io: std.Io,
    mu: Io.Mutex = .{},
    items: std.ArrayList(Item) = .empty,

    pub fn push(self: *Shared, item: Item) !void {
        self.mu.lock(self.io);
        defer self.mu.unlock(self.io);
        try self.items.append(self.gpa, item);
    }
};
```

The `.lock(io)` / `.unlock(io)` signatures look unusual but they're necessary: on
`Io.Evented`, the lock needs the Io to park the current coroutine. On `Io.Threaded`, it's
just an OS futex.

## Selecting between tasks

`Io.Group` exposes a `select` primitive for racing multiple futures:

```zig
const h1 = try io.async(group, fetchUrl, .{ io, "https://a.example" });
const h2 = try io.async(group, fetchUrl, .{ io, "https://b.example" });

const result = try group.select(io, &.{ h1.anyfuture(), h2.anyfuture() });
// result: union(enum) { first: []u8, second: []u8 }
switch (result) {
    .first => |body| io.out().print("A won: {d} bytes\n", .{body.len}) catch {},
    .second => |body| io.out().print("B won: {d} bytes\n", .{body.len}) catch {},
}
// The losing task is still running — cancel it if you don't need it:
group.cancel(io);
```

For "first success" semantics, use `trySelect` which returns the first non-error result.

## Backpressure and rate limiting

Groups don't have a built-in concurrency limit. For HTTP servers you typically want one:

```zig
const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    semaphore: Io.Semaphore,

    pub fn run(self: *Server) !void {
        var group = self.io.createGroup(self.gpa);
        defer group.cancelAndWait(self.io);

        self.semaphore = .{ .permits = 100 };   // max 100 concurrent handlers

        while (true) {
            const conn = try self.listener.accept(self.io);

            // Acquire a permit before spawning — blocks if all 100 are taken
            try self.semaphore.acquire(self.io);
            _ = try self.io.async(group, handleConn, .{ self, conn });
        }
    }

    fn handleConn(self: *Server, conn: std.Io.Net.Tcp.Conn) !void {
        defer self.semaphore.release(self.io);
        defer conn.close(self.io);
        // ... handle request ...
    }
};
```

## Pattern: HTTP server

```zig
const std = @import("std");
const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var net: Io.Net = .empty;
    net.initContext(io);
    defer net.deinit(io);

    var listener = try net.tcpListen(io, .{ .port = 8080 });
    defer listener.close(io);

    var group = io.createGroup(gpa);
    defer group.cancelAndWait(io);

    io.out().print("listening on :8080\n", .{}) catch {};

    while (true) {
        const conn = try listener.accept(io);
        _ = try io.async(group, handle, .{ io, gpa, conn });
    }
}

fn handle(io: Io, gpa: std.mem.Allocator, conn: Io.Net.Tcp.Conn) !void {
    defer conn.close(io);
    var buf: [4096]u8 = undefined;
    var r = conn.reader(io, &buf);
    var w = conn.writer(io, &buf);

    const line = (try r.takeDelimiter('\n')) orelse return;
    try w.print("you said: {s}\n", .{line});
    try w.flush();
}
```

The same code on `Io.Evented`:

```zig
pub fn main(init: std.process.Init) !void {
    var evented = try std.Io.Evented.init(init.gpa);
    defer evented.deinit();
    const io: std.Io = evented.io;
    // ... identical server code ...
}
```

## Pattern: game loop with background I/O

A game typically uses `Io.Dispatch` — you manually pump the Io once per frame so all I/O
progresses in lockstep with the simulation:

```zig
pub fn main(init: std.process.Init) !void {
    var dispatch: std.Io.Dispatch = .empty;
    dispatch.initContext(init.gpa);
    defer dispatch.deinit(init.gpa);
    const io: std.Io = dispatch.io;

    var group = io.createGroup(init.gpa);
    defer group.cancelAndWait(io);

    // Kick off an asset load in the background
    const tex_handle = try io.async(group, loadTexture, .{ io, "player.png" });

    var last_frame: Io.Timestamp = io.clock.now();
    while (game_running) {
        const now = io.clock.now();
        const dt = now.since(last_frame);
        last_frame = now;

        // Pump the Io — runs any ready coroutines, processes completions
        try dispatch.pump();

        // Check if the texture finished loading
        if (tex_handle.poll()) |result| {
            player_tex = try result;
        }

        simulate(dt);
        render();
        present();

        // Cooperative yield — give other tasks a chance
        io.yield_();
    }
}
```

## Migration from `std.Thread.Pool`

| Pattern                                       | 0.15                                   | 0.16                                                  |
|-----------------------------------------------|----------------------------------------|-------------------------------------------------------|
| Spawn and wait                                | `pool.spawnWg(&wg, fn, args)` + `pool.waitAndWork(&wg)` | `h = io.async(group, fn, args)` + `h.await(io)` |
| Spawn and forget                              | `pool.spawnWg(&wg, fn, args)` (no wait) | `_= io.async(group, fn, args)` (still needs `group.cancelAndWait`) |
| WaitGroup tracking                            | `WaitGroup`                            | `Io.Group.activeTaskCount()`                          |
| Blocking mutex                                | `std.Thread.Mutex`                     | `Io.Mutex`                                            |
| Condition variable                            | `std.Thread.Condition`                 | `Io.Condition`                                        |
| Pool size limit                               | `Pool{ .allocator = gpa }` (no built-in)| `Io.Semaphore{ .permits = N }`                       |

Concrete port:

```zig
// 0.15 — pool + waitgroup
var pool: std.Thread.Pool = .{ .allocator = gpa };
defer pool.deinit();
try pool.init(.{ .n_jobs = 8 });

var wg: std.Thread.WaitGroup = .{};
for (items) |it| {
    try pool.spawnWg(&wg, processItem, .{ gpa, it });
}
pool.waitAndWork(&wg);

// 0.16 — group + semaphore
var group = io.createGroup(gpa);
defer group.cancelAndWait(io);

var sem: Io.Semaphore = .{ .permits = 8 };
for (items) |it| {
    try sem.acquire(io);
    _ = try io.async(group, processItem, .{ io, gpa, it, &sem });
}

// processItem releases the semaphore on exit
fn processItem(io: std.Io, gpa: std.mem.Allocator, it: Item, sem: *Io.Semaphore) !void {
    defer sem.release(io);
    // ... process ...
}
```

## Further reading

- [std-io.md](std-io.md) — The Io abstraction itself
- [patterns.md](patterns.md) — Threading Io through large codebases
