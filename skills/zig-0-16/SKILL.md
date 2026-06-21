---
name: zig-0-16
description: Up-to-date Zig programming language patterns for version 0.16.0 (released April 14, 2026). Use whenever writing, reviewing, refactoring, or debugging Zig code, working with build.zig / build.zig.zon, integrating C libraries, or using comptime metaprogramming. Critical for avoiding outdated 0.14/0.15 patterns that no longer compile in 0.16 — especially the new `std.Io` threading requirement, `pub fn main(init: std.process.Init)` signature, removed `@Type` (replaced by 8 specialized builtins), deprecated `@cImport` (use `b.addTranslateC`), removed `std.Thread.Pool` (use `Io.Group`), `.empty` container initialization, non-generic `std.Io.Reader/Writer`, removed `heap.ThreadSafeAllocator` (ArenaAllocator is now lock-free), deprecated `@intFromFloat` (use `@trunc`), and `build.zig.zon` `fingerprint` requirement. Trigger this skill on ANY Zig code question even if the user does not specify version — assume 0.16 unless they explicitly say otherwise.
---

# Zig Language Reference (v0.16.0)

Zig 0.16.0 shipped April 14, 2026, eight months after 0.15.0. It is the largest std-library
rewrite in Zig's history: virtually every blocking or nondeterministic API now threads an
`Io` value the same way code already threads an `Allocator`. Training data is dominated by
0.13/0.14 patterns and will produce code that fails to compile. This skill documents the new
shape of the language and std lib so generated code is correct on the first try.

The golden rule of 0.16: **if it touches the network, the filesystem, the clock, randomness,
child processes, environment variables, current working directory, or any kind of wait — it
takes an `Io` parameter**. Read [references/std-io.md](references/std-io.md) before writing
any code that does any of those things.

## Critical: New `main` signature

The old `pub fn main() !void` is gone. The new signature is:

```zig
// WRONG — 0.15 style, no longer compiles
pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("hi\n", .{});
}

// CORRECT — 0.16
pub fn main(init: std.process.Init) !void {
    const stdout = init.io.out();  // gives you an std.Io.Writer (no buffer needed)
    try stdout.print("hi\n", .{});
}
```

`std.process.Init` carries everything a process needs at startup:

| Field             | Type                       | What it gives you                                            |
|-------------------|----------------------------|--------------------------------------------------------------|
| `gpa`             | `std.mem.Allocator`        | General-purpose debug allocator                              |
| `io`              | `std.Io`                   | The Io instance for this process (default `Io.Threaded`)     |
| `arena`           | `std.mem.Allocator`        | Bump allocator, freed on exit                                |
| `environ_map`     | `std.process.EnvMap`       | Environment variables (replaces global `std.os.environ`)     |
| `preopens`        | `[]const std.fs.Dir`       | Pre-opened dirs (WASI-style) for sandboxed execution         |

Environment variables and CLI args are **no longer global**. The historical `std.os.environ`
is removed. Use `init.environ_map` or `std.process.argsAlloc(init.gpa)`.

If you need a custom Io (e.g. evented, or a test Io), construct it explicitly via
`std.testing.io` for tests or `std.Io.Evented.init(gpa)` for cooperative M:N coroutines.

## Critical: `std.Io` is the new central abstraction

Every blocking API in std takes an `Io` value as a parameter. The `Io` controls *how* the
operation blocks — thread, coroutine, io_uring, kqueue, or simulated failure.

```zig
// WRONG — 0.15 style, no Io
const f = try std.fs.cwd().openFile("data.bin", .{});
defer f.close();
const n = try f.read(&buf);

// CORRECT — 0.16
const io = init.io;
var dir: std.Io.Dir = .cwd(io);          // cwd is now an Io.Dir, not std.fs.Dir
defer dir.close(io);
var f = try dir.openFile("data.bin", .{});
defer f.close(io);
const n = try f.readStreaming(io, &buf);
```

Io variants shipped with 0.16:

| Io                | Behavior                                                     |
|-------------------|--------------------------------------------------------------|
| `Io.Threaded`     | Default — one OS thread per blocking call (classic 1:1)     |
| `Io.Evented`      | M:N coroutines (the long-awaited "async" returns)           |
| `Io.Uring`        | Linux io_uring backend                                       |
| `Io.Kqueue`       | BSD/macOS kqueue backend                                     |
| `Io.Dispatch`     | Manually driven — for embedders and test runners            |
| `Io.failing`      | Returns every error immediately — for property-based tests  |

See [references/std-io.md](references/std-io.md) for the complete Io model.

## Critical: `std.Thread.Pool` removed — use `Io.Group`

The old `std.Thread.Pool` + `WaitGroup.spawnWg` pattern is gone. Concurrency now flows
through the Io layer:

```zig
// WRONG — 0.15
var pool: std.Thread.Pool = .{ .allocator = gpa };
defer pool.deinit();
var wg: std.Thread.WaitGroup = .{};
try pool.spawnWg(&wg, doWork, .{arg});
pool.waitAndWork(&wg);

// CORRECT — 0.16
var group = io.createGroup(gpa);
defer group.cancelAndWait(io);

const handle = try io.async(group, doWork, .{arg});
defer g.cancel(io);   // releases the task; handles error.Canceled
const result = try handle.await(io);
```

`Io.Group` cooperates with the Io implementation: on `Io.Evented`, tasks are coroutines on
the Io's worker pool; on `Io.Threaded`, they spawn OS threads. Either way, the lifecycle is
`async` → `await` or `cancel`. `error.Canceled` is in every cancelable I/O error set.

Read [references/async-concurrency.md](references/async-concurrency.md) for the full concurrency
model, including the cancellation contract.

## Critical: `@Type` removed — use the 8 specialized builtins

The big reflective builtin `@Type` (reify any type at comptime) is gone. It was a
kitchen-sink that complicated the compiler. Replaced by 8 focused builtins:

| New builtin   | Reifies                                                  |
|---------------|----------------------------------------------------------|
| `@Int`        | Integer types (signed/unsigned, bit widths)             |
| `@Tuple`      | Tuple types                                              |
| `@Pointer`    | Pointer types (with all the qualifiers)                  |
| `@Fn`         | Function types                                           |
| `@Struct`     | Struct types                                             |
| `@Union`      | Union types                                              |
| `@Enum`       | Enum types                                               |
| `@EnumLiteral`| Enum literal types (new — for compile-time tag types)    |

Error sets can no longer be reified at all — they must be declared by name.

```zig
// WRONG — 0.15
const T = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = 16 } });

// CORRECT — 0.16
const T = @Int(.unsigned, 16);
```

See [references/comptime.md](references/comptime.md) for the full comptime model.

## Critical: `@cImport` deprecated — use `b.addTranslateC`

`@cImport` is still alive in 0.16 but now backed by Aro (the new C parser) and is on the
chopping block. The supported path is `b.addTranslateC` in `build.zig`:

```zig
// build.zig
const mod = b.addTranslateC(.{
    .root_source_file = b.path("src/c_imports.h"),
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("c", mod);
```

```c
// src/c_imports.h
#include <stdint.h>
#include "my_c_library.h"
```

```zig
// src/main.zig
const c = @import("c");
```

This caches the translation as a separate Zig module and lets the compiler parallelize C
parsing. `@cImport` still works as a transition aid but emits a deprecation warning. Read
[references/c-interop.md](references/c-interop.md) for the full migration including how to
deal with C++ wrappers (ImGui, etc.) that need a hand-written `extern "C"` shim.

## Critical: Container init convention `.empty`

Every std container now uses `.empty` as the zero state and a separate `initContext(...)`
to attach the allocator. This makes them trivially stashable in `static` (comptime-known)
slots, and removes the awkward allocator-less `init()` form.

```zig
// WRONG — 0.15
var list = std.ArrayList(u8).init(gpa);
var map = std.StringHashMap(u32).init(gpa);
var pq = std.PriorityQueue(u32, lessThan).init(gpa);

// CORRECT — 0.16
var list: std.ArrayList(u8) = .empty;
list.initContext(gpa);

var map: std.StringHashMap(u32) = .empty;
map.initContext(gpa);

var pq: std.PriorityQueue(u32, lessThan) = .empty;
pq.initContext(gpa);
```

`AutoArrayHashMap`, `StringArrayHashMap`, and `ArrayHashMap` are removed — use
`std.array_hash_map.Auto`, `.String`, or `.Custom` instead. The `add` / `remove` methods on
priority queues are renamed `push` / `pop` to match the rest of the std.

## Critical: `std.Io.Reader` / `std.Io.Writer` non-generic refactor completed

The multi-year "Writergate" refactor finished in 0.16. The new `Reader` and `Writer` are
non-generic, the buffer lives *inside* the interface, and you no longer need
`BufferedWriter` / `FixedBufferStream` / `GenericReader` / `AnyWriter` / `CountingReader`.

```zig
// Reading
var r: std.Io.Reader = .fixed("hello\nworld");
const line = (try r.takeDelimiter('\n')).?;     // "hello"

// Writing into a fixed buffer
var buf: [256]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try w.print("Hello {d}", .{42});
const written = w.buffered();                   // "Hello 42"

// Allocating writer (grows as needed)
var aw = std.Io.Writer.Allocating.init(gpa);
defer aw.deinit();
try aw.print("x={d}", .{x});
const s = aw.written();
```

LEB128 is now `reader.takeLeb128(T)` instead of `reader.readIntLeb128`. See
[references/std-io.md](references/std-io.md#reader-and-writer) for the full new API.

## Critical: `heap.ThreadSafeAllocator` removed — `ArenaAllocator` is now lock-free

You no longer wrap allocators in `ThreadSafeAllocator`. Both `ArenaAllocator` and
`DebugAllocator` are thread-safe / lock-free by default.

```zig
// WRONG — 0.15
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var thread_safe = std.heap.ThreadSafeAllocator{ .child_allocator = arena.allocator() };
const a = thread_safe.allocator();

// CORRECT — 0.16
var arena: std.heap.ArenaAllocator = .empty;
arena.initContext(std.heap.page_allocator);
const a = arena.allocator();  // already thread-safe
```

Read [references/allocators.md](references/allocators.md) for the full allocator story,
including when to prefer `FixedBufferAllocator`, `DebugAllocator`, `smp_allocator`, and the
new `ArenaAllocator` semantics around reset.

## Critical: `@intFromFloat` deprecated — use `@trunc`

`@intFromFloat` is removed. `@trunc` (which previously truncated a float to a float) now
also does float→int conversion. The intent is to consolidate truncating operations under
one builtin. Small integer types (`u24`, `u20`, etc.) now coerce *to* floats implicitly;
the reverse still needs `@trunc`.

```zig
// WRONG — 0.15
const i: u32 = @intFromFloat(3.7);   // 3
const t: f32 = @trunc(3.7);          // 3.0

// CORRECT — 0.16
const i: u32 = @trunc(3.7);          // 3 (and the conversion is type-driven)
const t: f32 = @trunc(3.7);          // 3.0 (still works for float→float)
```

`@floatFromInt` still exists and is the inverse.

## Critical: `build.zig.zon` requires `fingerprint`

The `fingerprint` field is now required at the top level of `build.zig.zon`. Legacy hash
formats are dropped. The `name` field now requires an enum-literal style identifier (no
hyphens in package names — use underscores).

```zig
// WRONG — 0.15
.{
    .name = "my-package",
    .version = "0.1.0",
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}

// CORRECT — 0.16
.{
    .name = .my_package,            // enum-literal, not string
    .fingerprint = 0x123456789abcdef0,  // required — see scripts/gen-fingerprint.sh
    .version = "0.1.0",
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}
```

Packages fetch into `./zig-pkg/` (not `.zig-cache/dep/` or the old `.zig-cache/`). The
`fingerprint` is a u64 — generate one with `scripts/gen-fingerprint.sh` in this skill.

## Critical: New build system flags

| Flag                              | Purpose                                                            |
|-----------------------------------|--------------------------------------------------------------------|
| `zig build -fincremental --watch` | Near-instant compile errors as you save (LLVM backend supported)   |
| `zig build --fork=<path>`         | Locally override any package across the entire dependency tree     |
| `zig build --test-timeout=500ms`  | Surface hung tests                                                 |
| `zig build --error-style=minimal` | Compact error output (replaces removed `--prominent-compile-errors`) |

Incremental compilation is much more stable than 0.15 (still off by default but recommended
for development). The new ELF linker is 66% faster on incremental updates.

## Critical: Removed / renamed APIs — quick table

| Removed / deprecated in 0.16            | Replacement                                          |
|-----------------------------------------|------------------------------------------------------|
| `std.Thread.Pool`                       | `Io.Group` + `io.async(...)`                         |
| `std.Thread.Mutex` / `Condition` / etc. | `Io.Mutex` / `Io.Condition` / `Io.ResetEvent` / etc. |
| `std.os.environ` (global)               | `std.process.Init.environ_map`                       |
| `std.fs.Dir`                            | `std.Io.Dir`                                         |
| `std.fs.cwd()`                          | `std.Io.Dir.cwd(io)`                                 |
| `file.close()`                          | `file.close(io)`                                     |
| `Dir.makeDir` / `chmod` / `read`        | `Dir.createDir` / `setPermissions` / `readStreaming`  |
| `file.read` / `file.pread`              | `file.readStreaming(io, ...)` / `file.readPositional(io, ...)` |
| `@Type`                                 | `@Int` / `@Tuple` / `@Pointer` / `@Fn` / `@Struct` / `@Union` / `@Enum` / `@EnumLiteral` |
| `@intFromFloat`                         | `@trunc`                                             |
| `@cImport`                              | `b.addTranslateC(...)` in `build.zig`                |
| `AutoArrayHashMap` / `StringArrayHashMap` | `std.array_hash_map.Auto` / `.String`              |
| `ArrayHashMap`                          | `std.array_hash_map.Custom`                          |
| `PriorityQueue.init(allocator, lessFn)` | `PriorityQueue: .empty` + `initContext(lessCtx)`     |
| `PriorityQueue.add` / `.remove`         | `.push` / `.pop`                                     |
| `heap.ThreadSafeAllocator`              | (no-op — allocators are now thread-safe)             |
| `std.io.getStdOut().writer()`           | `init.io.out()` or `std.fs.File.stdout().writer(&buf)` |
| `BufferedWriter` / `GenericWriter` / `AnyWriter` / `FixedBufferStream` / `CountingReader` | `std.Io.Writer` / `std.Io.Reader` (+ `.fixed` / `.Allocating` / `.Discarding`) |
| `std.BoundedArray`                      | `std.bounded_array.Bounded` (re-export location moved)|
| `usingnamespace` (since 0.15)           | explicit re-export                                   |
| `async` / `await` keywords (since 0.15) | `io.async(...)` / `Future.await(io)`                 |
| `--prominent-compile-errors`            | `--error-style=minimal` (renamed)                    |

For each, see the corresponding reference file. The migration checklist at
[references/migration-015-016.md](references/migration-015-016.md) walks through porting a
real 0.15 project step by step.

## Critical: Async / await status

The `async` and `await` keywords remain removed from the language (they were removed in
0.15). Concurrency returns *through the Io layer*:

```zig
// Run a function as a task on the Io
const handle = try io.async(group, fetchAndDecode, .{ url, io });
// ... do other work ...
const result = try handle.await(io);   // blocks until done, returns FetchResult

// Cancel a long-running task
g.cancel(io);
// inside fetchAndDecode, any cancelable I/O call returns error.Canceled
```

This is a structural change: "async" in 0.16 is a property of the Io, not of the function.
On `Io.Threaded`, async spawns an OS thread; on `Io.Evented`, it schedules a coroutine on
the Io's worker pool. The same code runs both ways.

See [references/async-concurrency.md](references/async-concurrency.md) for the full model.

## Quick Reference: Allocator selection

| Allocator                | Use for                                                          |
|--------------------------|------------------------------------------------------------------|
| `DebugAllocator`         | Debug builds — leak detection, use-after-free, double-free       |
| `ArenaAllocator`         | Per-request / per-frame / per-CLI-invocation bulk allocation     |
| `smp_allocator`          | Release-fast multithreaded, general purpose                      |
| `FixedBufferAllocator`   | Stack-bounded buffers — no heap involvement, deterministic       |
| `page_allocator`         | One-shot bootstrap, never inside a hot path                      |
| `StackFallbackAllocator` | Try a stack buffer first, fall back to a heap allocator          |

Naming convention (inherited from 0.15 skill, still authoritative): use `gpa` for the
debug/ general-purpose allocator, `arena` for arena allocators, `scratch` for fixed-buffer
scratch space. Do not use generic `allocator` or `alloc` as variable names — it hides which
allocator you actually mean.

## Quick Reference: Io idioms

```zig
// Logging (stdout, no buffering)
const stdout = init.io.out();
try stdout.print("frame {d}\n", .{frame});

// Logging to stderr
const stderr = init.io.err();
try stderr.print("warn: {s}\n", .{msg});

// Reading a whole file
const bytes = try std.Io.Dir.cwd(io).readFileAlloc(gpa, "path.txt", 1 << 20);
defer gpa.free(bytes);

// Sleeping
io.sleep(.{ .ms = 16 });   // 16 ms — type-safe duration

// Wall clock
const now: Io.Timestamp = io.clock.now();
const elapsed = now.since(start);   // returns Io.Duration

// Random
var rng = io.rng();
const x = rng.random().int(u64);
```

## Module Reference

The following reference files cover each subsystem in depth. Read the one that matches the
task — do not load them all at once.

- [references/std-io.md](references/std-io.md) — The `std.Io` abstraction, Io variants,
  Reader/Writer, Dir/File, Duration/Timestamp, sleep, rng, env access. **Read this first
  for any I/O code.**
- [references/std-fs.md](references/std-fs.md) — Filesystem migration from `std.fs` to
  `std.Io.Dir/File`. Method rename table, examples for each common operation.
- [references/async-concurrency.md](references/async-concurrency.md) — `Io.Group`,
  `io.async`, `Future.await`, `error.Canceled`, replacement for `std.Thread.Pool` /
  `WaitGroup`, sync primitives under Io.
- [references/allocators.md](references/allocators.md) — Allocator landscape in 0.16,
  thread-safety defaults, when to use arena vs debug vs fixed-buffer, lifecycle.
- [references/comptime.md](references/comptime.md) — `@Type` removal, the 8 new
  specialized builtins, `@branchHint`, `@setCold` removal, comptime error sets.
- [references/c-interop.md](references/c-interop.md) — `@cImport` → `b.addTranslateC`
  migration, C++ wrapper patterns, struct layout, callback FFI.
- [references/build-system.md](references/build-system.md) — `build.zig` API, `build.zig.zon`
  fingerprint requirement, `-fincremental --watch`, `--fork`, new test runner.
- [references/std-lib-changes.md](references/std-lib-changes.md) — Container init (`.empty`),
  `array_hash_map` rename, `PriorityQueue` push/pop, `BoundedArray` move, small-int float
  coercion, AES-SIV / Ascon / deflate additions, `Io.Duration` / `Io.Timestamp` / `Io.Clock`.
- [references/patterns.md](references/patterns.md) — Modern 0.16 idioms: threading Io
  through a codebase, error set ergonomics, tagged unions as state machines, generational
  indices for entity pools, deterministic simulation patterns.
- [references/migration-015-016.md](references/migration-015-016.md) — Step-by-step port
  from a 0.15 codebase: build.zig.zon changes, `Init` signature, Io threading, allocator
  cleanup, container init sweep, `@Type` rewrite.
- [references/code-review.md](references/code-review.md) — Patterns to look for when
  reviewing 0.16 code, common mistakes, what to flag in PRs.

## Scripts

- `scripts/gen-fingerprint.sh` — generate a fresh u64 fingerprint for `build.zig.zon`.
- `scripts/init-project.sh` — scaffold a 0.16 project skeleton with `main(init: Init)`,
  an `Io.Group`, an `ArenaAllocator`, and a smoke test.
- `scripts/migrate-015.sh` — best-effort mechanical migration of a 0.15 codebase to 0.16
  (renames, signature changes). Always review output manually.

## Version

This skill targets **Zig 0.16.0** (released April 14, 2026) and tracks master through the
0.17 cycle. Patterns documented here will continue to work in 0.17 with deprecation warnings
where noted. The 0.17 cycle is described as "short" and will finalize the separation of the
build runner from `build.zig`.
