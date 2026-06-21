# Migration guide: 0.15 → 0.16

A step-by-step walkthrough for porting a 0.15 codebase to 0.16. Each step is
self-contained — you can do them in order or cherry-pick. The checklist at the end
summarizes everything.

## Table of contents

1. [Phase 0: Snapshot your code](#phase-0-snapshot-your-code)
2. [Phase 1: `build.zig.zon` and `build.zig`](#phase-1-buildzigzon-and-buildzig)
3. [Phase 2: `main` signature](#phase-2-main-signature)
4. [Phase 3: Threading `Io` through your code](#phase-3-threading-io-through-your-code)
5. [Phase 4: Allocator cleanup](#phase-4-allocator-cleanup)
6. [Phase 5: Container init sweep](#phase-5-container-init-sweep)
7. [Phase 6: Filesystem migration](#phase-6-filesystem-migration)
8. [Phase 7: Concurrency migration](#phase-7-concurrency-migration)
9. [Phase 8: Comptime rewrites](#phase-8-comptime-rewrites)
10. [Phase 9: C interop migration](#phase-9-c-interop-migration)
11. [Phase 10: Final sweep](#phase-10-final-sweep)
12. [Checklist](#checklist)

## Phase 0: Snapshot your code

Before doing anything else:

```bash
git checkout -b zig-0.16-migration
git tag v0.15-last-good
```

This gives you a stable fallback. If you get stuck on phase 5 and need to ship a fix to
the 0.15 version, you can.

Also delete `.zig-cache/` — the cache format changed:

```bash
rm -rf .zig-cache zig-out
```

## Phase 1: `build.zig.zon` and `build.zig`

### Update `build.zig.zon`

```zig
// BEFORE
.{
    .name = "my-package",
    .version = "0.1.0",
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}

// AFTER
.{
    .name = .my_package,                                // enum-literal
    .fingerprint = 0x9a3c1f8b7e2d4a01,                  // required
    .version = "0.1.0",
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}
```

Generate a fingerprint:

```bash
openssl rand -hex 8
```

If you have dependencies, their hashes may also have changed. Re-fetch:

```bash
zig fetch --save <url>
```

### Update `build.zig`

If you have any `addExecutable(.{ .root_source_file = ... })`, change to `root_module`:

```zig
// BEFORE
const exe = b.addExecutable(.{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});

// AFTER
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = exe_mod,
});
```

Run `zig build` and fix any remaining build system errors before moving on. At this point
the build *might* still succeed if your code uses 0.15 patterns — let's see.

## Phase 2: `main` signature

The very first compile error you'll hit is `main`'s signature.

```zig
// BEFORE
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("hi\n", .{});
}

// AFTER
pub fn main(init: std.process.Init) !void {
    const stdout = init.io.out();
    try stdout.print("hi\n", .{});
}
```

For tests, use `std.testing.io`:

```zig
// BEFORE
test "..." {
    // ...
}

// AFTER (no change to test signature, but inside tests you may want Io)
test "..." {
    var io_state = std.testing.io;
    const io = &io_state.io;
    // ... use io ...
    try io_state.flush();
}
```

## Phase 3: Threading `Io` through your code

This is the biggest phase. Every function that does I/O needs an `Io` parameter.

Strategy: start from the top (your `main`) and work down. Each function that does I/O
takes `io: std.Io` as its first non-self parameter. Add it to every struct that performs
I/O.

```zig
// BEFORE
const Loader = struct {
    gpa: std.mem.Allocator,

    pub fn loadFile(self: *Loader, path: []const u8) ![]u8 {
        return std.fs.cwd().readFileAlloc(self.gpa, path, 1 << 20);
    }
};

// AFTER
const Loader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    pub fn loadFile(self: *Loader, path: []const u8) ![]u8 {
        var cwd: std.Io.Dir = .cwd(self.io);
        defer cwd.close(self.io);
        return cwd.readFileAlloc(self.io, self.gpa, path, 1 << 20);
    }
};
```

Don't try to do this with sed. The compiler will tell you exactly which functions need
the parameter — just keep fixing errors and rebuilding.

Tip: enable `-fincremental --watch` for this phase — it'll save you a lot of waiting:

```bash
zig build -fincremental --watch
```

## Phase 4: Allocator cleanup

### Remove `ThreadSafeAllocator`

```zig
// BEFORE
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var thread_safe = std.heap.ThreadSafeAllocator{ .child_allocator = arena.allocator() };
const a = thread_safe.allocator();

// AFTER
var arena: std.heap.ArenaAllocator = .empty;
arena.initContext(std.heap.page_allocator);
defer arena.deinit();
const a = arena.allocator();   // already thread-safe
```

### Rename GPA → DebugAllocator (if you haven't already)

```zig
// BEFORE (already deprecated in 0.15)
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

// AFTER
var gpa: std.heap.DebugAllocator(.{}) = .empty;
gpa.initContext(.{});
defer _ = gpa.validate();
const a = gpa.allocator();
```

### Use the `init.gpa` from `Init`

If your `main` is using `pub fn main(init: std.process.Init)`, then `init.gpa` is already
a `DebugAllocator`-backed `Allocator`:

```zig
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    // ...
}
```

## Phase 5: Container init sweep

Replace `Type.init(allocator)` with `Type: .empty` + `initContext(allocator)`:

```zig
// BEFORE
var list = std.ArrayList(u8).init(gpa);
var map = std.StringHashMap(u32).init(gpa);
var set = std.AutoHashMap(u32, void).init(gpa);
var pq = std.PriorityQueue(u32, lessThan).init(gpa);

// AFTER
var list: std.ArrayList(u8) = .empty;
list.initContext(gpa);

var map: std.StringHashMap(u32) = .empty;
map.initContext(gpa);

var set: std.AutoHashMap(u32, void) = .empty;
set.initContext(gpa);

var pq: std.PriorityQueue(u32, lessThan) = .empty;
pq.initContext(gpa);
```

Also rename:

- `AutoArrayHashMap(K, V)` → `std.array_hash_map.Auto(K, V)`
- `StringArrayHashMap(V)` → `std.array_hash_map.String(V)`
- `ArrayHashMap(K, V, ctx)` → `std.array_hash_map.Custom(K, V, ctx)`
- `std.BoundedArray(T, n)` → `std.bounded_array.Bounded(T, n)`
- `PriorityQueue.add` → `PriorityQueue.push`
- `PriorityQueue.remove` → `PriorityQueue.pop`

The mechanical script `scripts/migrate-015.sh` does most of these substitutions, but
review its output — context matters.

## Phase 6: Filesystem migration

Replace `std.fs.*` calls with `std.Io.*` equivalents. The method rename table is in
[std-fs.md](std-fs.md).

Most common changes:

```zig
// BEFORE
const f = try std.fs.cwd().openFile("data.bin", .{});
defer f.close();
const n = try f.read(&buf);

// AFTER
var cwd: std.Io.Dir = .cwd(io);
defer cwd.close(io);
var f = try cwd.openFile(io, "data.bin", .{});
defer f.close(io);
const n = try f.readStreaming(io, &buf);
```

```zig
// BEFORE
const stdout = std.io.getStdOut().writer();
try stdout.print("hi\n", .{});

// AFTER
const stdout = init.io.out();
try stdout.print("hi\n", .{});
```

```zig
// BEFORE
const contents = try std.fs.cwd().readFileAlloc(gpa, "data.txt", 1 << 20);

// AFTER
var cwd: std.Io.Dir = .cwd(io);
defer cwd.close(io);
const contents = try cwd.readFileAlloc(io, gpa, "data.txt", 1 << 20);
```

## Phase 7: Concurrency migration

Replace `std.Thread.Pool` + `WaitGroup` with `Io.Group` + `io.async`:

```zig
// BEFORE
var pool: std.Thread.Pool = .{ .allocator = gpa };
defer pool.deinit();
try pool.init(.{ .n_jobs = 8 });

var wg: std.Thread.WaitGroup = .{};
for (items) |it| {
    try pool.spawnWg(&wg, processItem, .{ gpa, it });
}
pool.waitAndWork(&wg);

// AFTER
var group = io.createGroup(gpa);
defer group.cancelAndWait(io);

var sem: Io.Semaphore = .{ .permits = 8 };
for (items) |it| {
    try sem.acquire(io);
    _ = try io.async(group, processItem, .{ io, gpa, it, &sem });
}

fn processItem(io: std.Io, gpa: std.mem.Allocator, it: Item, sem: *Io.Semaphore) !void {
    defer sem.release(io);
    // ...
}
```

Replace sync primitives:

- `std.Thread.Mutex` → `Io.Mutex` (use `.lock(io)` / `.unlock(io)`)
- `std.Thread.Condition` → `Io.Condition`
- `std.Thread.ResetEvent` → `Io.ResetEvent`
- `std.Thread.RwLock` → `Io.RwLock`
- `std.Thread.Semaphore` → `Io.Semaphore`
- `std.Thread.Futex` → `Io.Futex`

See [async-concurrency.md](async-concurrency.md) for the full model.

## Phase 8: Comptime rewrites

### Replace `@Type`

Search for `@Type(` and replace each call with the appropriate specialized builtin:
`@Int`, `@Tuple`, `@Pointer`, `@Fn`, `@Struct`, `@Union`, `@Enum`, or `@EnumLiteral`.
See [comptime.md](comptime.md) for examples.

If you were reifying error sets, you can't anymore — declare them statically and combine
with `||`.

### Replace `@setCold`

```zig
// BEFORE
@setCold(true);

// AFTER
@branchHint(.cold);
```

### Replace `@intFromFloat`

```zig
// BEFORE
const i: u32 = @intFromFloat(3.7);

// AFTER
const i: u32 = @trunc(3.7);
```

## Phase 9: C interop migration

Move every `@cImport` block into a single `c_imports.h` and use `b.addTranslateC`:

```bash
# Step 1: collect all your @cImport blocks
grep -rn "@cImport" src/
```

```c
// src/c_imports.h
#include <stdint.h>
#include "vendor/foo.h"
#include "vendor/bar.h"
```

```zig
// build.zig
const c_mod = b.addTranslateC(.{
    .root_source_file = b.path("src/c_imports.h"),
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("c", c_mod);
```

```zig
// src/main.zig
const c = @import("c");
```

If you have `@cDefine` / `@cUndef`, move them into `c_imports.h` as `#define` / `#undef`.

For C++ libraries, write an `extern "C"` shim — see [c-interop.md](c-interop.md#c-wrappers-you-still-need-a-hand-written-extern-c-shim).

## Phase 10: Final sweep

After all the above, do a final pass:

1. Search for `std.io.getStdOut` / `getStdIn` / `getStdErr` — should all be `init.io.out()`
   / `init.io.stdin()` / `init.io.err()`.
2. Search for `std.time.milliTimestamp` — should be `io.clock.now().ms`.
3. Search for `std.time.sleep` — should be `io.sleep(.{ .ms = ... })`.
4. Search for `std.crypto.random` — should be `io.rng()`.
5. Search for `std.os.environ` — should be `init.environ_map`.
6. Search for `std.Thread` (any non-`Id`/`getCurrentId` usage) — should be `Io.*`.
7. Search for `@cImport` — should be gone (use `b.addTranslateC`).
8. Search for `@Type(` — should be gone (use the specialized builtins).
9. Search for `@setCold` — should be `@branchHint(.cold)`.
10. Search for `@intFromFloat` — should be `@trunc`.
11. Search for `root_source_file` in `build.zig` (inside `addExecutable` / `addLibrary` /
    `addTest`) — should be `root_module`.
12. Search for `BufferedWriter`, `GenericWriter`, `AnyWriter`, `FixedBufferStream`,
    `CountingReader` — all gone.
13. Search for `std.fs.cwd()` — should be `std.Io.Dir.cwd(io)`.
14. Search for `std.heap.ThreadSafeAllocator` — gone.
15. Search for `AutoArrayHashMap`, `StringArrayHashMap`, `ArrayHashMap` — use
    `std.array_hash_map.*`.
16. Search for `std.BoundedArray` — use `std.bounded_array.Bounded`.

Run `zig build test` and fix anything that fails.

## Checklist

A condensed version of the migration:

```text
[ ] Phase 0: git tag v0.15-last-good; rm -rf .zig-cache zig-out
[ ] Phase 1: build.zig.zon (name as enum-literal, fingerprint u64)
[ ] Phase 1: build.zig (root_source_file → root_module)
[ ] Phase 2: main signature (init: std.process.Init)
[ ] Phase 3: Io threaded through every I/O-doing struct and function
[ ] Phase 4: ThreadSafeAllocator removed
[ ] Phase 4: GeneralPurposeAllocator → DebugAllocator
[ ] Phase 5: Container init: .empty + initContext
[ ] Phase 5: array_hash_map.* rename
[ ] Phase 5: BoundedArray → bounded_array.Bounded
[ ] Phase 5: PriorityQueue.add/remove → push/pop
[ ] Phase 6: std.fs.cwd() → std.Io.Dir.cwd(io)
[ ] Phase 6: file.read → file.readStreaming(io, ...)
[ ] Phase 6: std.io.getStdOut().writer() → init.io.out()
[ ] Phase 7: std.Thread.Pool → Io.Group + io.async
[ ] Phase 7: std.Thread.Mutex → Io.Mutex (.lock(io) / .unlock(io))
[ ] Phase 8: @Type → specialized builtins
[ ] Phase 8: @setCold → @branchHint(.cold)
[ ] Phase 8: @intFromFloat → @trunc
[ ] Phase 9: @cImport → b.addTranslateC in build.zig
[ ] Phase 10: final sweep (see above)
[ ] zig build test passes
[ ] git commit
```

## Common gotchas during migration

### "cannot use 'io' of type 'std.Io' as 'std.Io'"

You have two different `std.Io` types — probably because you're importing `std` differently
in two files. Use `@import("std")` consistently everywhere.

### "function signature changed during migration"

If you add an `io` parameter to a function, every caller needs to pass it. The compiler
will show you each one. Resist the temptation to use a global `Io` — it'll bite you in
tests.

### "deprecated: @cImport"

This is just a warning, not an error. `@cImport` still works in 0.16. But the warning will
become an error in 0.17, so do the migration now.

### "container init did not set allocator"

You're using the old `Type.init(allocator)` form. Change to `.empty` + `initContext(allocator)`.

### "expected .*Io.Dir, found .*std.fs.Dir"

You forgot to migrate a `std.fs` call. The compiler is your friend — follow the type
mismatch to the source.

### "function 'main' takes 0 arguments but received 1"

Your `main` signature is the old `pub fn main() !void`. Change to
`pub fn main(init: std.process.Init) !void`.

## See also

- [std-io.md](std-io.md) — The Io abstraction
- [std-fs.md](std-fs.md) — Filesystem migration
- [async-concurrency.md](async-concurrency.md) — Concurrency migration
- [comptime.md](comptime.md) — `@Type` removal
- [c-interop.md](c-interop.md) — `@cImport` migration
- [build-system.md](build-system.md) — Build system changes
