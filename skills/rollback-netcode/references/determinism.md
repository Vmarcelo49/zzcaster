# Determinism for rollback netcode

Rollback is built on a single assumption: **the simulation is bit-identical across peers,
given identical inputs.** If this assumption is violated — even once every million frames —
the game will desync within seconds and become unplayable.

This file catalogs every common cause of nondeterminism and how to avoid it. Read it
before writing any simulation code that will run under rollback.

## Table of contents

1. [Why determinism is hard](#why-determinism-is-hard)
2. [Floating-point: just don't](#floating-point-just-dont)
3. [Fixed-point arithmetic](#fixed-point-arithmetic)
4. [Random number generators](#random-number-generators)
5. [Allocation and pointer identity](#allocation-and-pointer-identity)
6. [Iteration order](#iteration-order)
7. [System time and I/O](#system-time-and-io)
8. [Uninitialized memory](#uninitialized-memory)
9. [Compiler / platform differences](#compiler-platform-differences)
10. [Hashing state for sync verification](#hashing-state-for-sync-verification)
11. [The determinism audit](#the-determinism-audit)

## Why determinism is hard

The 0.13 release of fighting game *Skullgirls* had a desync bug that took 6 months to
track down. The cause: a particle effect's lifetime was stored as a float, and one peer
had FMA (fused-multiply-add) enabled by the compiler while the other didn't. After 30
seconds of play, the particle's lifetime diverged by 1 ULP, which propagated to a hitbox
calculation, which caused a different combo, which caused different inputs the next frame,
which snowballed into a 30-frame desync.

Determinism is hard because:
- Modern CPUs and compilers have hundreds of small nondeterministic behaviors that don't
  matter for visual fidelity but absolutely matter for bit-identical replay.
- Bugs don't surface immediately — they accumulate over thousands of frames.
- Testing requires running two peers side-by-side and comparing state hashes every frame.

The good news: if you follow the rules in this file from day one, determinism is
achievable. The bad news: retrofitting it to an existing game is a multi-month project.

## Floating-point: just don't

IEEE 754 floating-point is deterministic per-CPU+compiler+flags, but breaks across:

1. **Architectures** — x86, ARM, RISC-V have different FMA support and different rounding
   for subnormals.
2. **Compiler flags** — `-ffast-math`, `-funsafe-math-optimizations`, FMA enable/disable.
3. **Optimization levels** — Debug vs ReleaseFast can produce different instructions.
4. **Library implementations** — `sinf`, `cosf`, `sqrtf` are not bit-identical across
   libm implementations.
5. **NaN payload** — NaN has a 51-bit payload that's implementation-defined.
6. **Subnormal handling** — denormalized floats are flushed to zero on some CPUs (FTZ/DAZ).

For visual rendering, none of this matters — a 1-ULP difference in a particle's lifetime
is invisible. For deterministic simulation, every one of these will eventually cause a
desync.

### The rule

**Don't use floats inside `advance_frame`.** Use fixed-point.

### Exceptions

If you absolutely must use floats:
- Disable FMA in your build (`-ffp-contract=off` in C; in Zig, mark functions
  `@setFloatMode(.strict)`).
- Use the same optimization level on all peers.
- Never call `sinf` / `cosf` / `sqrtf` — use lookup tables or rational approximations
  you control.
- Never compare floats with `==`; always compare with a small epsilon.
- Hash your state with a hash that's stable across float representations (Wyhash works).

But really, just don't.

## Fixed-point arithmetic

Fixed-point is integers with a convention for where the decimal point goes. The most
common format is Q16.16 — a 32-bit signed integer with 16 bits of integer and 16 bits of
fraction.

```zig
pub const Fixed = struct {
    v: i32,

    pub const ZERO: Fixed = .{ .v = 0 };
    pub const ONE: Fixed = .{ .v = 1 << 16 };

    pub fn fromInt(x: i32) Fixed {
        return .{ .v = x << 16 };
    }

    pub fn toInt(self: Fixed) i32 {
        return self.v >> 16;
    }

    pub fn fromF32(x: f32) Fixed {
        return .{ .v = @intFromFloat(x * @as(f32, 1 << 16)) };
    }

    pub fn toF32(self: Fixed) f32 {
        return @as(f32, @floatFromInt(self.v)) / @as(f32, 1 << 16);
    }

    pub fn add(a: Fixed, b: Fixed) Fixed {
        return .{ .v = a.v + b.v };
    }

    pub fn sub(a: Fixed, b: Fixed) Fixed {
        return .{ .v = a.v - b.v };
    }

    pub fn mul(a: Fixed, b: Fixed) Fixed {
        // i64 to avoid overflow, then shift back.
        return .{ .v = @intCast((@as(i64, a.v) * @as(i64, b.v)) >> 16) };
    }

    pub fn div(a: Fixed, b: Fixed) Fixed {
        return .{ .v = @intCast((@as(i64, a.v) << 16) / @as(i64, b.v)) };
    }

    pub fn abs(self: Fixed) Fixed {
        return .{ .v = if (self.v < 0) -self.v else self.v };
    }

    pub fn lt(a: Fixed, b: Fixed) bool {
        return a.v < b.v;
    }

    pub fn eql(a: Fixed, b: Fixed) bool {
        return a.v == b.v;
    }
};
```

Q16.16 gives you a range of ±32768 with 1/65536 (~15 μs at 60 FPS) precision. That's plenty
for game physics. If you need more range, use Q32.32 with `i64`. If you need less, use
Q8.24 with `i32` for higher precision.

### Trig functions

For sin/cos, use a lookup table:

```zig
const SIN_TABLE: [1024]Fixed = blk: {
    @setEvalBranchQuota(100_000);
    var t: [1024]Fixed = undefined;
    for (0..1024) |i| {
        const angle = @as(f32, @floatFromInt(i)) * (std.math.pi / 512.0);
        t[i] = Fixed.fromF32(@sin(angle));
    }
    break :blk t;
};

pub fn sin(x: Fixed) Fixed {
    // x is in radians; map to 0..1024 (one full revolution)
    const idx = @as(u32, @intCast((x.v >> 6) & 1023));
    return SIN_TABLE[idx];
}
```

1024 entries gives ~0.35 degree resolution. For most game physics, that's overkill. For
hitboxes, use rational approximations instead (e.g., Bhaskara I's approximation).

### Square root

```zig
pub fn sqrt(x: Fixed) Fixed {
    if (x.v <= 0) return Fixed.ZERO;
    // Newton-Raphson in fixed-point
    var guess = x;
    var prev: Fixed = .{ .v = 0 };
    var iter: u8 = 0;
    while (!guess.eql(prev) and iter < 16) : (iter += 1) {
        prev = guess;
        guess = Fixed.div(Fixed.add(guess, Fixed.div(x, guess)), Fixed.fromInt(2));
    }
    return guess;
}
```

16 iterations is overkill for most inputs but it converges quickly.

## Random number generators

`io.rng()` is the OS CSPRNG. **Never use it inside `advance_frame`** — it returns
different values on different peers.

Use a seeded PRNG stored in your game state:

```zig
const GameState = struct {
    prng: std.Random.DefaultPrng,
    // ...

    pub fn init(seed: u64) GameState {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn advance(self: *GameState, inputs: []const GameInput) !void {
        const r = self.prng.random();
        // ... use r.int(u32), r.float(f32) (but cast to Fixed), r.bytes(&buf) ...
    }
};
```

Both peers must initialize the PRNG with the same seed. The session handshake
(synchronizing phase) should negotiate this — typically both peers hash the initial
state and use that as the seed, or use a fixed seed agreed at the protocol level.

### What "random" means in a deterministic sim

A common confusion: if both peers use the same PRNG with the same seed and call it the
same number of times, they produce the same sequence. So why call it "random" at all?

Because the *sequence* is deterministic, but the *distribution* looks random — uniform,
uncorrelated, etc. This is fine for: AI behavior variation, particle effects (visual only),
procedural generation (do at load time, not per frame), hit roll mechanics.

It's not fine for: anything that should differ between peers (e.g. connection IDs — use
`io.rng()` for those, outside the sim).

## Allocation and pointer identity

If your entity handles are raw pointers, two peers will have different pointer values for
"the same" entity — even with identical allocation order, the OS hands out different
addresses.

**Use generational indices instead.** An `EntityId = struct { index: u32, generation: u32 }`
is a value type that's identical across peers.

```zig
pub const EntityId = struct {
    index: u32,
    generation: u32,
};

pub const EntityPool = struct {
    const Slot = struct {
        generation: u32,
        alive: bool,
        entity: Entity,
    };

    slots: [MAX_ENTITIES]Slot,
    free_list: std.ArrayList(u32),

    pub fn spawn(self: *EntityPool, e: Entity) !EntityId {
        const idx = self.free_list.pop() orelse return error.OutOfMemory;
        const slot = &self.slots[idx];
        slot.generation +%= 1;
        slot.alive = true;
        slot.entity = e;
        return .{ .index = idx, .generation = slot.generation };
    }

    pub fn get(self: *EntityPool, id: EntityId) ?*Entity {
        const slot = &self.slots[id.index];
        if (slot.generation != id.generation or !slot.alive) return null;
        return &slot.entity;
    }
};
```

The pool has a fixed capacity — `MAX_ENTITIES` slots, allocated at startup. No per-frame
allocation. The `generation` counter distinguishes a despawned-and-respawned slot from
the original.

### No per-frame allocation

`advance_frame` should not allocate. Pre-allocate everything:

```zig
const GameState = struct {
    entities: [MAX_ENTITIES]Entity,
    bullets: [MAX_BULLETS]Bullet,
    particles: [MAX_PARTICLES]Particle,
    // ...
};
```

If you must have dynamic collections, use a `BoundedArray` with a fixed capacity:

```zig
const active_bullets: std.bounded_array.Bounded(Bullet, MAX_BULLETS) = .empty;
```

`BoundedArray` never allocates from the heap; it lives inline in the parent struct.

## Iteration order

`AutoHashMap`, `StringHashMap`, and `AutoArrayHashMap` (now `array_hash_map.Auto`) all
have unspecified iteration order — it depends on the hash of keys, which depends on the
hash seed, which may be randomized.

If you iterate over a hash map and the iteration order affects the simulation (e.g., you
process entities in iteration order and the order changes which entity is "first"), you
have a determinism bug.

### Solutions

1. **Don't iterate hash maps in the sim.** Use them for lookup only. Iterate arrays.
2. **Use `ArrayHashMap` (insertion-order) and never reorder.** This is deterministic but
   fragile — re-inserting a key after removal changes the order.
3. **Sort before iterating.** If you must iterate a hash map, copy the keys to an array
   and sort:
   ```zig
   var keys: std.ArrayList(u32) = .empty;
   keys.initContext(scratch);
   defer keys.deinit(scratch);
   var it = map.iterator();
   while (it.next()) |entry| try keys.append(scratch, entry.key_ptr.*);
   std.mem.sort(u32, keys.items, {}, std.sort.asc(u32));
   for (keys.items) |k| {
       const v = map.get(k).?;
       // ... process in deterministic order ...
   }
   ```

## System time and I/O

Never inside `advance_frame`:

- `io.clock.now()` — wall clock is non-deterministic.
- `io.rng()` — OS CSPRNG is non-deterministic.
- File reads — disk I/O has unpredictable latency and the file content might differ.
- Environment variables — different on different machines.
- `std.Thread.getCurrentId()` — different per process.

All of these should happen **outside** the sim, at startup or in the render layer. The
sim's notion of time is the **frame counter** — `self.frame` — not wall clock.

```zig
// BAD
fn updatePhysics(state: *GameState, io: std.Io) void {
    const dt = io.clock.now().ms - state.last_update_ms;
    state.last_update_ms = io.clock.now().ms;
    for (state.entities) |*e| {
        e.x += e.vx * Fixed.fromF32(dt);
    }
}

// GOOD
fn updatePhysics(state: *GameState) void {
    const dt: Fixed = Fixed.fromInt(1);   // 1 frame
    for (state.entities) |*e| {
        e.x = Fixed.add(e.x, Fixed.mul(e.vx, dt));
    }
}
```

The sim is **always** one frame. Wall-clock dt is a render-layer concern, not a sim
concern. (Some games use variable-timestep sims, but those are not deterministic and
cannot use rollback.)

## Uninitialized memory

`var buf: [4096]u8 = undefined;` is dangerous in a saved state. If you serialize the
buffer's full 4096 bytes including the uninitialized tail, two peers will have different
bytes there.

### Solutions

1. **Zero-initialize everything that's saved:**
   ```zig
   var buf: [4096]u8 = std.mem.zeroes([4096]u8);
   ```
2. **Only serialize the live portion:**
   ```zig
   try serialize(buf[0..live_len]);
   ```
3. **Use `std.mem.zeroes` for any struct field that might be padding:**
   ```zig
   const Bullet = struct {
       x: Fixed,
       y: Fixed,
       _padding: u32 = 0,   // explicit padding, always zero
   };
   ```

Zig will help you here: structs default to `undefined` unless you use `= std.mem.zeroes`,
and `std.mem.zeroes` is the safe default for any state that will be hashed or serialized.

## Compiler / platform differences

Even with the above rules, you can hit compiler-level nondeterminism:

1. **`@panic` behavior** — different on different platforms. Don't panic inside the sim.
2. **Field order in packed structs** — should be deterministic but check.
3. **`@sizeOf` and `@alignOf`** — same on all platforms for the same type, but if your
   saved state includes a struct, the struct's layout must be identical on all peers.
   Use `extern struct` for any struct that's saved.
4. **Endianness** — x86 is little-endian, some ARM is bi-endian. If you serialize ints
   to bytes, use explicit endianness: `std.mem.writeInt(u32, buf, value, .little)`.

### Cross-platform builds

If you ship on Windows, macOS, and Linux, you must verify determinism across all three.
The easiest way: run a sync test (see [sync-test.md](sync-test.md)) on each platform and
compare the resulting state hashes.

For fighting games that target consoles (PS5, Xbox Series), the situation is worse — the
console's compiler may differ from the PC compiler. The standard solution is to write the
sim in a portable subset of C/C++/Zig that's known to behave identically across
compilers, and verify with extensive sync testing.

## Hashing state for sync verification

To verify two peers have the same state, hash the serialized state and compare:

```zig
fn stateChecksum(buf: []const u8) u64 {
    return std.hash.Wyhash.hash(0, buf);
}

// In Session.saveState:
try self.states.save(self.io, self.gpa, self.frame, self.ctx, self.callbacks.save_game_state);
const checksum = self.states.getChecksum(self.frame).?;

// Send checksum to remote peer in next QualityReport packet.
// If they disagree, request a state sync (or accept the desync and disconnect).
```

### Wyhash vs other hashes

Wyhash is fast and has good distribution. For determinism verification, you don't need
cryptographic strength — you need speed and stability. Wyhash delivers both.

Don't use `std.hash.CityHash` (deprecated) or `std.hash.MurmurHash3` (slower). Wyhash is
the recommended default in Zig 0.16.

### Hashing floats

If you ignored the advice and used floats, hashing is tricky because NaN ≠ NaN and +0.0
= -0.0 have different bit representations but compare equal. The standard trick:

```zig
fn hashFloat(h: *std.hash.Wyhash, x: f32) void {
    // Normalize: NaN → 0, -0 → +0
    if (std.math.isNan(x)) {
        h.update(std.mem.asBytes(&@as(f32, 0)));
    } else if (x == 0.0) {
        const zero: f32 = 0;
        h.update(std.mem.asBytes(&zero));
    } else {
        h.update(std.mem.asBytes(&x));
    }
}
```

Or just convert to fixed-point before hashing.

## The determinism audit

Before writing any sim code, audit your existing sim for these issues:

```text
[ ] All physics math uses Fixed, not f32/f64
[ ] All trig uses lookup tables or rational approximations
[ ] All random numbers come from a seeded DefaultPrng in GameState
[ ] No io.rng() / io.clock.now() / file reads inside advance_frame
[ ] Entity handles are EntityId (generational index), not *Entity
[ ] No per-frame allocation (use pre-allocated pools)
[ ] No iteration of AutoHashMap / StringHashMap affecting sim state
[ ] All saved state is zero-initialized or only the live portion is serialized
[ ] All saved structs are extern struct
[ ] All integer serialization uses explicit endianness
[ ] No float comparisons with == (or convert to Fixed and compare)
```

Run a sync test (see [sync-test.md](sync-test.md)) after fixing each item. The test
should run for at least 1000 frames before you trust it.

## See also

- [sync-test.md](sync-test.md) — The harness that catches determinism bugs
- [data-structures.md](data-structures.md) — Where `EntityId` and `Fixed` plug in
- [patterns.md](patterns.md) — More determinism patterns
- The [zig-0-16 skill's patterns.md](../../zig-0-16/references/patterns.md#deterministic-simulation-patterns)
  for the Zig-side conventions
