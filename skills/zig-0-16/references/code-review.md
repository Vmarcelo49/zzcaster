# Code review patterns for Zig 0.16

A checklist of patterns to look for when reviewing 0.16 code. Each pattern includes the
"why" — knowing the reason helps you apply judgment, not just pattern-match.

## Table of contents

1. [Io threading](#io-threading)
2. [Allocator smells](#allocator-smells)
3. [Container init](#container-init)
4. [Concurrency](#concurrency)
5. [Comptime](#comptime)
6. [C interop](#c-interop)
7. [Error handling](#error-handling)
8. [Determinism](#determinism)
9. [Style](#style)

## Io threading

### ✅ Look for: `io: std.Io` as a function parameter

Functions that do I/O should take `io: std.Io` as their first non-self parameter. This
matches how `Allocator` is threaded.

```zig
// Good
pub fn loadConfig(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Config {
    // ...
}
```

### ❌ Flag: global `Io`

If you see a `var global_io: std.Io = undefined;` or similar, it breaks testability and
embeddability. Thread the Io through.

### ❌ Flag: `std.fs.cwd()` without an explicit `io`

`std.fs.cwd()` doesn't exist anymore in 0.16. If you see it, the code wasn't fully
migrated. Use `std.Io.Dir.cwd(io)`.

### ❌ Flag: `std.io.getStdOut().writer()`

Same story — should be `init.io.out()` (from `main`) or a passed-in `io.out()`.

### ❌ Flag: missing `defer group.cancelAndWait(io)`

Every `io.createGroup(gpa)` should be paired with a `defer group.cancelAndWait(io)`. If you
see a `createGroup` without one, it's a leak.

### ❌ Flag: `std.time.sleep(ms)`

Should be `io.sleep(.{ .ms = ms })`. The old `std.time.sleep` is removed.

### ❌ Flag: `std.crypto.random`

Should be `io.rng()`. The old `std.crypto.random` is removed.

### ❌ Flag: `std.os.environ`

Should be `init.environ_map`. Environment variables are no longer global.

## Allocator smells

### ✅ Look for: explicit allocator naming

`gpa`, `arena`, `scratch`, `fba` — these names communicate which allocator is in use and
what its lifetime is. Generic `allocator` or `alloc` names hide intent.

### ❌ Flag: `var gpa = std.heap.GeneralPurposeAllocator(.{}){};`

The 0.14/0.15 form. Should be:

```zig
var gpa: std.heap.DebugAllocator(.{}) = .empty;
gpa.initContext(.{});
defer _ = gpa.validate();
```

### ❌ Flag: `ThreadSafeAllocator`

Removed in 0.16. Allocators are thread-safe by default.

### ❌ Flag: per-frame allocation

In a hot loop or game simulation frame, you should not see `gpa.alloc(...)`. Use an arena
that's reset per frame, or pre-allocate.

```zig
// BAD — allocates every frame
fn render(ui: *Ui, gpa: std.mem.Allocator) !void {
    const buf = try gpa.alloc(u8, 4096);
    defer gpa.free(buf);
    // ...
}

// GOOD — uses a frame-scoped arena
fn render(ui: *Ui, frame_arena: *std.heap.ArenaAllocator) !void {
    const buf = try frame_arena.allocator().alloc(u8, 4096);
    // freed when frame_arena resets at end of frame
}
```

### ❌ Flag: allocator not propagated

If a struct has an `allocator: std.mem.Allocator` field but doesn't pass it to children,
that's a smell — the children may be using the wrong allocator.

### ❌ Flag: `arena.deinit()` without `defer`

If the function has multiple return paths, the `deinit` won't be called on early return.
Always pair with `defer`.

## Container init

### ❌ Flag: `Type.init(allocator)`

The 0.14/0.15 form. Should be:

```zig
var list: std.ArrayList(u8) = .empty;
list.initContext(allocator);
```

### ❌ Flag: `AutoArrayHashMap` / `StringArrayHashMap` / `ArrayHashMap`

Removed. Use `std.array_hash_map.Auto` / `.String` / `.Custom`.

### ❌ Flag: `std.BoundedArray`

Moved. Use `std.bounded_array.Bounded`.

### ❌ Flag: `PriorityQueue.add` / `PriorityQueue.remove`

Renamed. Use `push` / `pop`.

### ❌ Flag: missing `defer map.deinit(gpa)`

Every container that's `initContext`'d needs `deinit(gpa)`. If you see `initContext`
without a matching `deinit`, it's a leak.

## Concurrency

### ❌ Flag: `std.Thread.Pool`

Removed. Use `Io.Group` + `io.async`.

### ❌ Flag: `std.Thread.Mutex` / `Condition` / etc.

Moved to `Io.Mutex` / `Io.Condition` / etc. The lock/unlock now take `io`:

```zig
// OLD
mu.lock();
defer mu.unlock();

// NEW
mu.lock(io);
defer mu.unlock(io);
```

### ❌ Flag: `Pool.spawnWg(&wg, ...)`

Old API. Use `io.async(group, ...)`.

### ❌ Flag: fire-and-forget async without `group.cancelAndWait`

If you spawn a task with `io.async` and don't `await` it, the task is still tracked by
the group. The group's `cancelAndWait` will reap it — but only if you call it.

```zig
// BAD — orphan task
_ = try io.async(group, backgroundWork, .{io});
return;   // backgroundWork is still running, group leaked

// GOOD — explicit wait
var group = io.createGroup(gpa);
defer group.cancelAndWait(io);
_ = try io.async(group, backgroundWork, .{io});
// cancelAndWait at defer
```

### ❌ Flag: missing `error.Canceled` handling

If a function does cancelable I/O, it can return `error.Canceled`. Either handle it
explicitly or propagate. Don't silently swallow it.

```zig
// BAD
fn fetch(io: std.Io) ![]u8 {
    return io.tcpRead(...) catch |e| switch (e) {
        error.Canceled => return,   // silent drop — bad
        else => return e,
    };
}

// GOOD
fn fetch(io: std.Io) ![]u8 {
    return io.tcpRead(...);   // propagates error.Canceled to caller
}
```

## Comptime

### ❌ Flag: `@Type(`

Removed. Use the specialized builtins (`@Int`, `@Struct`, `@Union`, `@Enum`, `@Pointer`,
`@Fn`, `@Tuple`, `@EnumLiteral`).

### ❌ Flag: `@setCold`

Replaced by `@branchHint(.cold)`. Other hints: `.hot`, `.likely`, `.unlikely`, `.none`.

### ❌ Flag: `@intFromFloat`

Deprecated. Use `@trunc` (which now does both float→float and float→int).

### ❌ Flag: reifying error sets

Error sets can no longer be reified. Declare them statically and combine with `||`.

### ⚠️ Watch: very large comptime unrolls

`inline for` over a large slice can blow up binary size. If you see `inline for` over
more than ~100 items, ask whether it's necessary.

### ⚠️ Watch: `@compileLog` left in

`@compileLog` is great for debugging but should be removed before merge. It forces
recompilation every time it's hit.

## C interop

### ❌ Flag: `@cImport`

Deprecated. Use `b.addTranslateC` in `build.zig`. See [c-interop.md](c-interop.md).

### ❌ Flag: `@cDefine` / `@cUndef`

Same — moved into the umbrella `c_imports.h`.

### ⚠️ Watch: missing `linkLibC()` / `linkLibCpp()`

If you compile C or C++ with `addCSourceFile`, you must `linkLibC()` (for C) or
`linkLibCpp()` (for C++) on the library or executable.

### ⚠️ Watch: C++ without `extern "C"` shim

You can't `b.addTranslateC` C++ headers directly. You need a hand-written `extern "C"`
wrapper. See [c-interop.md](c-interop.md#c-wrappers-you-still-need-a-hand-written-extern-c-shim).

### ⚠️ Watch: variadic C functions

C variadic functions (like `printf`) are awkward in Zig. Prefer a non-variadic wrapper.

### ⚠️ Watch: string lifetime from C

If a C function returns a `const char*`, it may point to static memory that's invalidated
by the next call. Copy it with `arena.dupe(u8, std.mem.sliceTo(s, 0))` immediately.

## Error handling

### ❌ Flag: `catch unreachable` on I/O errors

`catch unreachable` is for "this truly cannot happen" cases. I/O errors can always happen
(file not found, network down, disk full). Propagate them or handle them.

```zig
// BAD
const f = std.Io.Dir.cwd(io).openFile(io, "config", .{}) catch unreachable;

// GOOD
const f = std.Io.Dir.cwd(io).openFile(io, "config", .{}) catch |err| {
    io.err().print("could not open config: {s}\n", .{@errorName(err)}) catch {};
    return err;
};
```

### ⚠️ Watch: overly broad `catch |e| { ... return e; }`

If you're just propagating, use `try`:

```zig
// BAD
const x = foo() catch |e| {
    // nothing useful happens here
    return e;
};

// GOOD
const x = try foo();
```

### ⚠️ Watch: error sets that should be inferred

Internal helpers should use `!T` (inferred error set). Public API should use explicit
error sets for stability.

### ❌ Flag: swallowing `error.Canceled`

```zig
// BAD — cancellation becomes silent success
defer group.cancelAndWait(io) catch {};
```

`cancelAndWait` doesn't return an error (it's `void`), but tasks inside the group may
return `error.Canceled`. If you spawn a task that returns an error, that error is silently
dropped unless you `await` it.

## Determinism

For games, simulations, and rollback netcode:

### ❌ Flag: `io.rng()` inside `advance_frame`

`io.rng()` is the OS CSPRNG — non-deterministic across runs and across peers. Use a seeded
`std.Random.DefaultPrng` stored in the game state.

### ❌ Flag: floats inside `advance_frame`

Floats are deterministic per-architecture but break across architectures, FMA modes, and
optimization levels. Use fixed-point.

### ❌ Flag: `std.time.milliTimestamp()` inside `advance_frame`

Wall clock is non-deterministic. Use a frame counter or the simulation's internal clock.

### ❌ Flag: raw pointers as entity handles

Pointer values differ between peers (different allocator layouts). Use generational
indices — see [patterns.md](patterns.md#generational-indices-for-entity-pools).

### ❌ Flag: allocation inside `advance_frame`

Per-frame allocation breaks determinism if the allocator's address layout affects pointer
comparisons or hash keys. Pre-allocate entity pools with fixed capacity.

### ⚠️ Watch: `AutoHashMap` iteration affecting game state

Iteration order is unspecified. If you iterate over entities in a way that affects the
simulation, use `ArrayHashMap` (sorted by insertion order) or sort the keys first.

## Style

### ⚠️ Watch: inconsistent `io` parameter ordering

Pick a convention and stick to it. The most common is `io` first, then `gpa`, then
domain-specific params:

```zig
fn doThing(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !void {
    // ...
}
```

### ⚠️ Watch: `@intFromEnum` / `@intFromPtr` / `@intFromBool` (these are unchanged)

These `@intFrom*` builtins still exist in 0.16 — only `@intFromFloat` was removed. Don't
get spooked by them.

### ⚠️ Watch: `@as` casts where coercions work

```zig
// Unnecessary
const x: u32 = @as(u32, 5);

// Better
const x: u32 = 5;
```

Zig has implicit coercions for: comptime integers → any integer type, `T` → `?T`, `*T` →
`[*]T`, `[N]T` → `[]const T`, `[]const T` → `[*:0]const T` (if NUL-terminated), and
small int types → floats.

### ⚠️ Watch: `var` where `const` would do

```zig
// BAD
var x: u32 = 5;

// GOOD
const x: u32 = 5;
```

The compiler will warn about this in debug builds.

### ⚠️ Watch: snake_case in struct fields, CamelCase in types

```zig
// Convention
const MyStruct = struct {
    field_name: u32,

    pub fn methodName(self: *MyStruct) void {}
};
```

### ⚠️ Watch: file imports

Use `@import("file.zig")` for relative paths, `@import("module_name")` for modules
configured in `build.zig`. Don't mix the two.

## Summary

When reviewing 0.16 code, focus on:

1. **Io threading** — is it everywhere it should be?
2. **Allocator hygiene** — correct type, correct naming, correct lifetime.
3. **Container init** — `.empty` + `initContext`, not the old `.init(allocator)`.
4. **Concurrency** — `Io.Group` + `io.async`, not `std.Thread.Pool`.
5. **Comptime** — specialized builtins, not `@Type`.
6. **C interop** — `b.addTranslateC`, not `@cImport`.
7. **Error handling** — propagate, don't swallow; never `catch unreachable` on I/O.
8. **Determinism** (for games/sims) — no `io.rng()`, no floats, no allocation in `advance_frame`.
9. **Style** — consistent parameter order, `const` where possible.

Most of these patterns are also enforced by `zig fmt` and the compiler. The compiler will
catch the outright errors; code review is for the subtler smells.

## See also

- [patterns.md](patterns.md) — The "right way" to write each of these patterns
- [migration-015-016.md](migration-015-016.md) — Step-by-step port from 0.15
