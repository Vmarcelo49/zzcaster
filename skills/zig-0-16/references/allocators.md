# Allocators in Zig 0.16

The allocator landscape in 0.16 is simpler than ever: `ArenaAllocator` and `DebugAllocator`
are both thread-safe / lock-free by default, `heap.ThreadSafeAllocator` is removed, and
`.empty` is the universal zero state.

## Table of contents

1. [The five production allocators](#the-five-production-allocators)
2. [`.empty` + `initContext` convention](#empty--initcontext-convention)
3. [`DebugAllocator` deep dive](#debugallocator-deep-dive)
4. [`ArenaAllocator` deep dive](#arenaallocator-deep-dive)
5. [`FixedBufferAllocator` deep dive](#fixedbufferallocator-deep-dive)
6. [`smp_allocator` and release builds](#smp_allocator-and-release-builds)
7. [Choosing an allocator](#choosing-an-allocator)
8. [Custom allocators](#custom-allocators)
9. [Deterministic allocation for simulations](#deterministic-allocation-for-simulations)

## The five production allocators

| Allocator                | When to use                                              | Thread-safe? | Cost     |
|--------------------------|----------------------------------------------------------|--------------|----------|
| `DebugAllocator`         | Debug builds — detects leaks, use-after-free, double-free | Yes         | Slow     |
| `ArenaAllocator`         | Per-request / per-frame / per-CLI bulk allocation         | Yes (lock-free) | Fast |
| `smp_allocator`          | Release-fast multithreaded, general purpose              | Yes         | Fast     |
| `FixedBufferAllocator`   | Stack-bounded buffers — no heap involvement               | No          | Fastest  |
| `page_allocator`         | Bootstrap only — never inside a hot path                  | Yes         | Slow     |

Auxiliary:
- `StackFallbackAllocator` — try a stack buffer first, fall back to a heap allocator.
- `TestingAllocator` — for tests; verifies all allocations are freed.

## `.empty` + `initContext` convention

Every std container and every allocator in 0.16 follows the same pattern: a comptime-known
`.empty` value and a separate `initContext(...)` to attach the runtime context (allocator,
less-than function, etc.). This makes containers trivially stashable in `static` slots,
removes the awkward allocator-less `init()` form, and simplifies generic code.

```zig
// WRONG — 0.15 style
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const a = arena.allocator();

var list = std.ArrayList(u8).init(a);

// CORRECT — 0.16 style
var arena: std.heap.ArenaAllocator = .empty;
arena.initContext(std.heap.page_allocator);
defer arena.deinit();
const a = arena.allocator();

var list: std.ArrayList(u8) = .empty;
list.initContext(a);
```

The same applies to `std.mem.Allocator` itself: there's no `Allocator.init()` — you receive
one from `init.gpa`, `arena.allocator()`, etc.

## `DebugAllocator` deep dive

`DebugAllocator` (formerly `GeneralPurposeAllocator`, renamed in 0.15) is the default for
debug builds. It:

- Tracks every allocation in a hash map.
- On `free`, verifies the pointer was allocated and not already freed.
- Fills freed memory with `0xaa` bytes to make use-after-free visible.
- At program exit (or `validate()`), reports any leaks with the source location of the
  allocation.
- Has a `retention_capacity` knob — by default it keeps freed memory in a quarantine to
  delay reuse, making use-after-free more detectable.

```zig
var gpa: std.heap.DebugAllocator(.{}) = .empty;
gpa.initContext(.{});
defer {
    const leaked = gpa.validate();
    if (leaked) @panic("memory leaked");
}

const a = gpa.allocator();
```

In 0.16, `DebugAllocator` is thread-safe and lock-free. You no longer need to wrap it in
`ThreadSafeAllocator` (which is removed).

### Tuning knobs

`DebugAllocator(.config)` takes a config struct:

```zig
const config = std.heap.DebugAllocator.Config{
    .stack_trace_frames = 8,
    .safety = true,
    .thread_safe = true,          // default; can be false for single-threaded perf
    .never_unmap = false,         // keep pages mapped (faster, more memory)
    .retain_metadata = true,      // keep metadata after free (catches double-free)
    .verbose_log = false,
};
var gpa: std.heap.DebugAllocator(config) = .empty;
```

## `ArenaAllocator` deep dive

`ArenaAllocator` is the workhorse of short-lived bulk allocation. In 0.16 it is thread-safe
and lock-free — multiple threads can concurrently allocate without contention.

```zig
var arena: std.heap.ArenaAllocator = .empty;
arena.initContext(std.heap.page_allocator);
defer arena.deinit();
const a = arena.allocator();

// Allocate freely — no need to free each allocation
for (items) |it| {
    const s = try a.dupe(u8, it);
    io.out().print("{s}\n", .{s}) catch {};
}
// All freed at once by arena.deinit()
```

### Reset instead of deinit

For long-running processes that do per-request arenas, `reset()` reuses the memory instead
of freeing and re-mapping pages:

```zig
var arena: std.heap.ArenaAllocator = .empty;
arena.initContext(std.heap.page_allocator);
defer arena.deinit();

while (running) {
    const a = arena.allocator();
    // ... handle request, allocate freely ...
    handleRequest(io, a);
    _ = arena.reset(.{ .retain_with_limit = 4 * 1024 * 1024 });   // keep up to 4 MB
}
```

`reset` returns the number of bytes actually freed. The `.retain_with_limit` mode keeps
the most-recently-allocated pages up to the limit, avoiding the cost of re-mapping them
on the next request.

### Thread safety

The lock-free arena uses a per-thread "chunk" model: each thread bumps within its own
chunk, and only synchronizes when it needs a new chunk. This means concurrent allocations
are essentially uncontended. Frees are no-ops (the whole arena is freed at once).

The catch: `arena.allocator()` returns a single `Allocator` value that's safe to share
across threads. You don't need to wrap it.

## `FixedBufferAllocator` deep dive

`FixedBufferAllocator` allocates from a caller-provided byte buffer. It's the fastest
allocator in std and the only one that never touches the heap — perfect for hot paths,
deterministic simulations, and embedded systems.

```zig
var buf: [16 * 1024]u8 align(16) = undefined;
var fba: std.heap.FixedBufferAllocator = .{ .buffer = &buf };
const a = fba.allocator();

const s = try a.dupe(u8, "hello");
// s lives in buf[0..5]

// Allocate from the end for stack-style LIFO
fba.reset();   // frees everything
```

Properties:
- Not thread-safe. Wrap in your own mutex if needed (or use a per-thread FBA).
- Returns `error.OutOfMemory` when the buffer is full — there's no growth.
- Alignment is handled by skipping bytes; pass an aligned buffer for best utilization.
- `fba.reset()` is O(1) — just resets the offset.

### Two-ended allocation

A common pattern: allocate long-lived data from the front, scratch from the end:

```zig
const End = enum { front, back };
var fba: std.heap.FixedBufferAllocator = .{ .buffer = &buf };

const persistent = try fba.allocEnd(.front, u8, 1024);
const scratch = try fba.allocEnd(.back, u8, 256);
// scratch can be freed without affecting persistent
```

The actual API in 0.16 uses `fba.allocator()` for front allocation and `fba.alignedAllocator(.back)` for back — check the std source for the exact names.

## `smp_allocator` and release builds

For release builds where you want a general-purpose allocator that's fast and
multithreaded, use `smp_allocator`. It's a slab-based allocator with per-CPU caches.

```zig
const a: std.mem.Allocator = .smp_allocator;
// (smp_allocator is a singleton; no init/deinit needed)

// Use it directly
const buf = try a.alloc(u8, 1024);
defer a.free(buf);
```

`smp_allocator` is appropriate when:
- You're in a release build (debug builds should use `DebugAllocator`).
- You don't have a clear arena scope (e.g. a long-running daemon).
- You have many short-lived allocations across threads.

For daemons with a clear per-request scope, prefer per-request `ArenaAllocator` over
`smp_allocator` — arenas are dramatically faster.

## Choosing an allocator

Decision tree:

```text
Is this a debug build?
├─ Yes → DebugAllocator (default in std.debug.GPA)
└─ No
   Is there a clear lifetime scope (per-request, per-frame, per-CLI)?
   ├─ Yes → ArenaAllocator, reset() per scope
   └─ No
      Need O(1) worst-case allocation with fixed memory?
      ├─ Yes → FixedBufferAllocator
      └─ No → smp_allocator
```

### Common setups

**CLI tool:**

```zig
pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .empty;
    arena.initContext(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Use a for everything; freed on exit
}
```

**HTTP server:**

```zig
fn handleRequest(io: std.Io, req: *Request) !void {
    var arena: std.heap.ArenaAllocator = .empty;
    arena.initContext(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // ... allocate per-request data ...
}
```

**Game loop:**

```zig
// Per-frame scratch — reset every frame
var frame_arena: std.heap.ArenaAllocator = .empty;
frame_arena.initContext(std.heap.page_allocator);
defer frame_arena.deinit();

while (running) {
    _ = frame_arena.reset(.retain_with_limit = 1 * 1024 * 1024);
    const scratch = frame_arena.allocator();

    // ... per-frame allocations ...
}
```

**Deterministic simulation** (for rollback netcode — see [rollback-netcode](../../rollback-netcode/SKILL.md)):

```zig
// Pre-allocated entity pool, no per-frame allocation
const Entities = struct {
    pool: [MAX_ENTITIES]Entity,
    free_list: [MAX_ENTITIES]u32,
    free_count: u32,

    fn spawn(self: *Entities) *Entity {
        const idx = self.free_list[self.free_count];
        self.free_count -= 1;
        return &self.pool[idx];
    }

    fn despawn(self: *Entities, e: *Entity) void {
        const idx = @intFromPtr(e) - @intFromPtr(&self.pool[0]);
        self.free_count += 1;
        self.free_list[self.free_count] = @intCast(idx);
    }
};
```

## Custom allocators

`std.mem.Allocator` is a vtable. You can implement your own:

```zig
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    count: u64 = 0,

    const vtable: std.mem.Allocator.Vtable = .{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    };

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, log2_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.count += 1;
        return self.backing.rawAlloc(len, log2_align, ret_addr);
    }

    fn resize(ctx: *anyopaque, buf: []u8, log2_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.backing.rawResize(buf, log2_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, log2_align: u8, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, log2_align, ret_addr);
    }
};
```

Useful for: counting allocations (testing), capturing allocations (replay debugging),
forcing determinism (sort by size, not address), and injecting failures (fuzzing).

## Deterministic allocation for simulations

For rollback netcode and other deterministic simulations, allocation *address* can leak
into game state if you're not careful. Common pitfalls:

1. **Pointer identity**: two saved states compare equal only if pointers match. Use
   generational indices (a `u32` entity ID + a `u32` generation counter) instead of raw
   pointers.
2. **Hash maps keyed by pointer**: the hash depends on the address. Use ID keys.
3. **Allocation order affecting iteration**: `AutoHashMap` iteration order is unspecified
   and can differ between runs. Use a sorted structure or `ArrayHashMap` if you iterate
   in a way that affects game state.

The cleanest pattern is a **pre-allocated pool with generational indices** — see
[patterns.md](patterns.md#generational-indices-for-entity-pools) for the full code.

## See also

- [patterns.md](patterns.md) — Deterministic simulation patterns
- [code-review.md](code-review.md) — Allocator smells to look for in PRs
