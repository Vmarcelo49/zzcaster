# Standard library changes in 0.16

This is the catch-all reference for std library changes that don't have their own file.
Each section is independent — jump to what you need.

## Table of contents

1. [Container init: `.empty` + `initContext`](#container-init-empty--initcontext)
2. [`array_hash_map` reorganization](#array_hash_map-reorganization)
3. [`PriorityQueue`: `push` / `pop` and `.empty`](#priorityqueue-push--pop-and-empty)
4. [`BoundedArray` moved to `bounded_array`](#boundedarray-moved-to-bounded_array)
5. [`@intFromFloat` → `@trunc`](#intfromfloat--trunc)
6. [Small integer types now coerce to floats](#small-integer-types-now-coerce-to-floats)
7. [New crypto: AES-SIV, AES-GCM-SIV, Ascon-AEAD](#new-crypto-aes-siv-aes-gcm-siv-ascon-aead)
8. [Deflate compression added](#deflate-compression-added)
9. [`Io.Duration`, `Io.Timestamp`, `Io.Clock`, `Io.Timeout`](#ioduration-iotimestamp-ioclock-iotimeout)
10. [Windows: fully NtDll-based std lib](#windows-fully-ntdll-based-std-lib)
11. [`std.Random` and `Io.rng`](#stdrandom-and-iorng)
12. [Removed APIs (final)](#removed-apis-final)

## Container init: `.empty` + `initContext`

Every std container in 0.16 follows the same shape:

```zig
var list: std.ArrayList(u8) = .empty;
list.initContext(gpa);

var map: std.StringHashMap(u32) = .empty;
map.initContext(gpa);

var set: std.AutoHashMap(u32, void) = .empty;
set.initContext(gpa);

var queue: std.PriorityQueue(u32, lessThan) = .empty;
queue.initContext(gpa);

var ring: std.RingBuffer(u8) = .empty;
ring.initContext(gpa);
```

`.empty` is the comptime-known zero state. `initContext(ctx)` attaches the runtime context
(allocator, less-than function, etc.). The split makes containers stashable in static
slots and simplifies generic code.

The old `Type.init(allocator)` form is removed for these containers. (Some types still
keep an `init` if they don't have an allocator — e.g. `Mutex.init()` is unchanged.)

## `array_hash_map` reorganization

`AutoArrayHashMap`, `StringArrayHashMap`, and `ArrayHashMap` are removed. Use the new
`std.array_hash_map` namespace:

| Old (0.15)                          | New (0.16)                              |
|-------------------------------------|-----------------------------------------|
| `std.AutoArrayHashMap(K, V)`        | `std.array_hash_map.Auto(K, V)`         |
| `std.StringArrayHashMap(V)`         | `std.array_hash_map.String(V)`          |
| `std.ArrayHashMap(K, V, ctx)`       | `std.array_hash_map.Custom(K, V, ctx)`  |

The behavior is the same — these are hash maps that maintain insertion order in a parallel
array. Use them when you need deterministic iteration order.

```zig
var map: std.array_hash_map.String(u32) = .empty;
map.initContext(gpa);
defer map.deinit(gpa);

try map.put(gpa, "alice", 1);
try map.put(gpa, "bob", 2);

// Iteration order matches insertion
for (map.keys(), map.values()) |k, v| {
    io.out().print("{s} = {d}\n", .{k, v}) catch {};
}
// Output:
// alice = 1
// bob = 2
```

## `PriorityQueue`: `push` / `pop` and `.empty`

`PriorityQueue` was the last holdout using `add`/`remove` for FIFO semantics. It's now
`push`/`pop` to match the rest of std.

```zig
// 0.15
var pq = std.PriorityQueue(u32, lessThan).init(gpa);
defer pq.deinit();
try pq.add(5);
try pq.add(1);
try pq.add(3);
const top = pq.remove();

// 0.16
var pq: std.PriorityQueue(u32, lessThan) = .empty;
pq.initContext(gpa);
defer pq.deinit(gpa);
try pq.push(gpa, 5);
try pq.push(gpa, 1);
try pq.push(gpa, 3);
const top = try pq.pop(gpa);
```

`peek()` is unchanged. The context (the `lessThan` function's `ctx` parameter, if any)
moves into `initContext`.

## `BoundedArray` moved to `bounded_array`

`std.BoundedArray(T, n)` is now `std.bounded_array.Bounded(T, n)`. The old location is
removed.

```zig
// 0.15
var buf = std.BoundedArray(u8, 256){};
try buf.append('h');

// 0.16
var buf: std.bounded_array.Bounded(u8, 256) = .empty;
try buf.append('h');
```

The API is otherwise unchanged — `append`, `appendSlice`, `slice`, `len`, `capacity` all
work the same.

## `@intFromFloat` → `@trunc`

See [comptime.md](comptime.md#intfromfloat-deprecated--use-trunc) for the full story.

```zig
// 0.15
const i: u32 = @intFromFloat(3.7);
const t: f32 = @trunc(3.7);

// 0.16
const i: u32 = @trunc(3.7);          // 3
const t: f32 = @trunc(3.7);          // 3.0
```

`@trunc` now does both float→float and float→int conversion based on context. `@intFromFloat`
emits a deprecation warning.

## Small integer types now coerce to floats

Integer types smaller than `f32`'s mantissa width (24 bits) now coerce *to* floats
implicitly. The reverse direction still needs an explicit conversion.

```zig
// 0.16 — these all work without explicit casts
const x: u24 = 1000;
const f: f32 = x;        // implicit — u24 fits in f32's mantissa

const y: u8 = 255;
const g: f32 = y;        // implicit

// Reverse direction — still explicit
const h: f32 = 1.5;
const z: u8 = @trunc(h);   // 1 — needs @trunc
```

This change eliminates a class of annoying `@as` casts. Larger integer types (`u32` and
up) still need explicit conversion because they'd lose precision.

## New crypto: AES-SIV, AES-GCM-SIV, Ascon-AEAD

Three new AEAD ciphers added:

- **AES-SIV** (RFC 5297) — misuse-resistant authenticated encryption. Use when you might
  accidentally reuse a nonce; an attacker doesn't get to forge messages.
- **AES-GCM-SIV** (RFC 8452) — high-performance variant of GCM with the misuse-resistance
  of SIV.
- **Ascon-AEAD** — NIST's lightweight cryptography standard. Use for constrained devices
  (microcontrollers, IoT).

```zig
const std = @import("std");

// AES-GCM-SIV
const AesGcmSiv = std.crypto.aead.aes_gcm_siv.Aes256GcmSiv;
var key: [AesGcmSiv.key_length]u8 = ...;
var nonce: [AesGcmSiv.nonce_length]u8 = ...;
var tag: [AesGcmSiv.tag_length]u8 = undefined;

AesGcmSiv.encrypt(&ciphertext, &tag, plaintext, ad, nonce, key);

// Ascon
const Ascon = std.crypto.aead.ascon.Ascon128a;
// ...
```

For HMAC, SHA-2, SHA-3, BLAKE2/3 — these are unchanged. `std.crypto.random` is removed;
use `io.rng()` instead (or a seeded `DefaultPrng` for determinism).

## Deflate compression added

`std.compress.flate` now has both inflate (decode) and deflate (encode):

```zig
const std = @import("std");

// Compress
var compressed: std.ArrayList(u8) = .empty;
compressed.initContext(gpa);
defer compressed.deinit(gpa);
try std.compress.flate.deflate.compress(io, data, compressed.writer(), .{ .level = .default });

// Decompress
var r: std.Io.Reader = .fixed(compressed.items);
var decompressor = std.compress.flate.deflate.decompressor(io, &r);
const result = try decompressor.reader(io).readAllAlloc(gpa, max_size);
```

The new implementation is ~10% faster than zlib's reference, with the same format
compatibility.

`std.compress.gzip` wraps deflate with gzip framing. `std.compress.zlib` wraps it with
zlib framing.

## `Io.Duration`, `Io.Timestamp`, `Io.Clock`, `Io.Timeout`

Time types moved from `std.time` into `Io`:

| 0.15                              | 0.16                                                |
|-----------------------------------|-----------------------------------------------------|
| `std.time.milliTimestamp()`       | `io.clock.now().ms` (an `Io.Timestamp`)             |
| `std.time.nanoTimestamp()`        | `io.clock.now().ns`                                 |
| `std.time.sleep(ms)`              | `io.sleep(.{ .ms = ms })`                           |
| `std.time.Timer.start()`          | `Io.Timestamp` + `.since(start)`                    |
| `std.time.epoch.*`                | `Io.Timestamp.epoch(...)` (calendars)               |

```zig
const start: Io.Timestamp = io.clock.now();
// ... do work ...
const elapsed: Io.Duration = io.clock.now().since(start);
io.out().print("took {d} ms\n", .{elapsed.ms}) catch {};

// Sleep 16 ms
io.sleep(.{ .ms = 16 });

// Or with a timeout
const result = try io.timeout(.{ .seconds = 5 }, fetchResource(io, url));
```

For game-loop timing, use `Io.Clock.monotonic` (the default for `io.clock.now()`). For wall
clock, use `Io.Clock.wall` (e.g. for logging timestamps). For high-precision benchmarking,
use `Io.Clock.high_resolution`.

## Windows: fully NtDll-based std lib

On Windows, the std library no longer requires `ws2_32.dll` for networking, and std lib
in general is fully NtDll/syscall-based. This means:

- Smaller binaries (no link-time dependency on Winsock).
- More consistent behavior across Windows versions.
- Better support for sandboxed / restricted environments.

Existing code that linked `ws2_32` explicitly should remove it. The std library handles
Windows syscalls internally.

For `extern "C"` calls into Windows APIs (rare in 0.16), the translation layer still uses
the standard Windows headers.

## `std.Random` and `Io.rng`

`std.Random` is unchanged — it's still the trait interface. What changed is where you get
your RNG:

- `io.rng()` — returns an `Io.Rng`, backed by the OS CSPRNG on `Io.Threaded` and
  `Io.Evented`. Use this for crypto, session IDs, anything security-sensitive.
- `std.Random.DefaultPrng.init(seed)` — for seeded deterministic RNG (games, tests).

```zig
// Security-sensitive
var rng = io.rng();
const token: [32]u8 = rng.random().bytes(&buf);

// Deterministic (e.g. for game simulation)
var prng = std.Random.DefaultPrng.init(0xdeadbeef);
const r = prng.random();
const x = r.int(u64);
```

`std.crypto.random` is removed; it was the old way to get the OS CSPRNG.

## Removed APIs (final)

This list is the comprehensive "removed in 0.16" set. Each has a replacement documented
elsewhere in this skill:

- `std.Thread.Pool` → `Io.Group` + `io.async`
- `std.Thread.WaitGroup` → `Io.Group` lifecycle
- `std.Thread.Mutex`, `.Condition`, `.ResetEvent`, `.RwLock`, `.Semaphore`, `.Futex` → `Io.*` equivalents
- `std.heap.ThreadSafeAllocator` (allocators are now thread-safe by default)
- `std.io.getStdOut().writer()` → `init.io.out()`
- `BufferedWriter`, `CountingReader`, `FixedBufferStream`, `GenericWriter`, `GenericReader`, `AnyWriter`, `AnyReader`, `null_writer` → `std.Io.Writer` / `std.Io.Reader` (+ `.fixed` / `.Allocating` / `.Discarding`)
- `std.fs.Dir`, `std.fs.File`, `std.fs.cwd()` → `std.Io.Dir`, `std.Io.File`, `std.Io.Dir.cwd(io)`
- `std.os.environ` (global) → `std.process.Init.environ_map`
- `std.BoundedArray` → `std.bounded_array.Bounded`
- `std.AutoArrayHashMap`, `std.StringArrayHashMap`, `std.ArrayHashMap` → `std.array_hash_map.*`
- `@Type` → `@Int` / `@Tuple` / `@Pointer` / `@Fn` / `@Struct` / `@Union` / `@Enum` / `@EnumLiteral`
- `@intFromFloat` → `@trunc`
- `@cImport` (deprecated; backed by Aro) → `b.addTranslateC`
- `@setCold` → `@branchHint(.cold)`
- `usingnamespace` (since 0.15)
- `async` / `await` keywords (since 0.15)
- `--prominent-compile-errors` → `--error-style=minimal`
- `root_source_file` field on `addExecutable` / `addLibrary` / `addTest` → `root_module`

If you encounter something not on this list, check the relevant module reference file —
the change might be a rename rather than a removal.

## See also

- [std-io.md](std-io.md) — The Io abstraction
- [std-fs.md](std-fs.md) — Filesystem migration
- [comptime.md](comptime.md) — `@Type` removal and the new builtins
- [allocators.md](allocators.md) — Allocator changes
- [async-concurrency.md](async-concurrency.md) — `Io.Group`, `io.async`
- [migration-015-016.md](migration-015-016.md) — End-to-end port
