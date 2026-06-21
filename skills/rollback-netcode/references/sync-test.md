# SyncTest mode: catch determinism bugs before netplay

SyncTest is the single most valuable tool in the rollback toolbox. It runs every frame
**twice** — once "live," then once replayed from the saved state — and compares the
checksums. Any divergence is reported immediately, with the exact frame and inputs that
caused it.

If you take only one thing from this skill: **add SyncTest to your CI.** It catches
determinism bugs that would otherwise take hours of netplay to surface and weeks to
diagnose.

## Table of contents

1. [What SyncTest does](#what-synctest-does)
2. [The algorithm](#the-algorithm)
3. [Implementation in Zig](#implementation-in-zig)
4. [Running it in CI](#running-it-in-ci)
5. [Common bugs SyncTest catches](#common-bugs-synctest-catches)
6. [Beyond SyncTest: replay testing](#beyond-synctest-replay-testing)
7. [When SyncTest passes but netplay still desyncs](#when-synctest-passes-but-netplay-still-desyncs)

## What SyncTest does

A SyncTest session has one player (the local one) but runs the sim twice per frame:

1. **Live run**: collect local input, save state, advance frame. Record the post-advance
   checksum as `live_checksum`.
2. **Replay run**: load the saved state from before the live run, advance with the same
   input, record the post-advance checksum as `replay_checksum`.
3. **Compare**: if `live_checksum != replay_checksum`, raise a `DesyncDetected` event
   with the frame number and both checksums.

The two runs use the same input, the same starting state, the same code. The only thing
that should differ is... nothing. If the checksums disagree, your sim is non-deterministic.

### The `check_distance` parameter

GGPO's SyncTest has a `check_distance` parameter: how many frames between checks. The
default is 1 (check every frame). For large games, you might use a higher value to reduce
CPU time:

- `check_distance = 1` — catches every determinism bug. Most expensive. Use in dev and
  CI.
- `check_distance = 10` — checks every 10th frame. Cheaper. Use in long-running smoke
  tests.
- `check_distance = 0` — disables checking entirely. Useless except for performance
  baseline.

Always use `check_distance = 1` in CI. Always.

## The algorithm

```text
For each frame N:
  1. Collect local input for frame N.
  2. Save state (this is the "pre-advance" state for frame N).
  3. Run advance_frame with the input. Record post-advance state checksum as C1.
  4. Load the pre-advance state we just saved.
  5. Run advance_frame again with the same input. Record post-advance state checksum as C2.
  6. If C1 != C2: report desync at frame N.
  7. Restore the live state (so the next iteration starts from the correct state).
```

Note step 7: after the replay run, we have to restore the live state. The reason is that
the replay run might have allocated memory or touched global state in ways that differ
from the live run — but if the simulation is deterministic, the *visible* state (the part
that's serialized) is identical.

### Why this works

The two runs use identical:
- Starting state (loaded from the same save buffer)
- Input
- Code

So if they produce different output, **something non-deterministic happened**. Common
causes (see [determinism.md](determinism.md)):
- Uninitialized memory in the saved state.
- Floating-point math that differs across runs (FMA, optimization level).
- Random numbers from a non-seeded source.
- Iteration order of a hash map that changed between runs.
- System time or file I/O inside `advance_frame`.
- Pointer comparisons that differ because of allocator addresses.

SyncTest catches all of these — except cross-architecture ones (because both runs are on
the same machine, same compiler). For that, you need cross-platform replay testing.

## Implementation in Zig

```zig
pub const SyncTest = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    callbacks: SessionCallbacks,
    ctx: *anyopaque,
    num_players: u8,
    check_distance: u32 = 1,

    frame: i32 = 0,
    last_state: ?[]u8 = null,
    last_checksum: u64 = 0,
    rng: std.Random.DefaultPrng,
    input_history: std.ArrayList(GameInput),

    pub const Init = struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        callbacks: SessionCallbacks,
        ctx: *anyopaque,
        num_players: u8,
        check_distance: u32 = 1,
        seed: u64 = 0xdeadbeef,
    };

    pub fn init(opts: Init) SyncTest {
        var s: SyncTest = .{
            .io = opts.io,
            .gpa = opts.gpa,
            .callbacks = opts.callbacks,
            .ctx = opts.ctx,
            .num_players = opts.num_players,
            .check_distance = opts.check_distance,
            .rng = std.Random.DefaultPrng.init(opts.seed),
            .input_history = .empty,
        };
        s.input_history.initContext(opts.gpa);
        return s;
    }

    pub fn deinit(self: *SyncTest) void {
        if (self.last_state) |buf| self.gpa.free(buf);
        self.input_history.deinit(self.gpa);
    }

    pub fn advanceFrame(self: *SyncTest) !void {
        // Generate a random input for each player (or take from a script).
        var inputs: [MAX_PLAYERS]GameInput = undefined;
        for (0..self.num_players) |p| {
            inputs[p] = self.randomInput();
            inputs[p].frame = self.frame;
        }

        try self.input_history.append(self.gpa, inputs[0]);

        // Save state BEFORE advancing.
        var pre_buf: std.ArrayList(u8) = .empty;
        pre_buf.initContext(self.gpa);
        defer pre_buf.deinit(self.gpa);
        try self.callbacks.save_game_state(self.io, self.ctx, &pre_buf);

        // ----- Live run -----
        try self.callbacks.advance_frame(self.ctx, &inputs);

        var live_post: std.ArrayList(u8) = .empty;
        live_post.initContext(self.gpa);
        defer live_post.deinit(self.gpa);
        try self.callbacks.save_game_state(self.io, self.ctx, &live_post);
        const live_checksum = std.hash.Wyhash.hash(0, live_post.items);

        // Only check every check_distance frames.
        if (@as(u32, @intCast(self.frame)) % self.check_distance == 0) {
            // ----- Replay run -----
            try self.callbacks.load_game_state(self.io, self.ctx, pre_buf.items);
            try self.callbacks.advance_frame(self.ctx, &inputs);

            var replay_post: std.ArrayList(u8) = .empty;
            replay_post.initContext(self.gpa);
            defer replay_post.deinit(self.gpa);
            try self.callbacks.save_game_state(self.io, self.ctx, &replay_post);
            const replay_checksum = std.hash.Wyhash.hash(0, replay_post.items);

            if (live_checksum != replay_checksum) {
                self.callbacks.on_event(self.ctx, .{
                    .desync = .{
                        .frame = self.frame,
                        .live_checksum = live_checksum,
                        .replay_checksum = replay_checksum,
                    },
                });
                return error.DesyncDetected;
            }
        }

        // ----- Restore live state -----
        // (If we didn't, the next frame would start from the replay's post-advance state,
        //  which may have allocator-level differences from the live one.)
        try self.callbacks.load_game_state(self.io, self.ctx, live_post.items);

        self.frame += 1;
    }

    fn randomInput(self: *SyncTest) GameInput {
        var input: GameInput = .{};
        const r = self.rng.random();
        for (&input.bits) |*b| b.* = r.int(u8);
        return input;
    }
};
```

### Usage

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var game = Game.init(io, gpa);
    defer game.deinit();

    var sync_test = SyncTest.init(.{
        .io = io,
        .gpa = gpa,
        .callbacks = game.callbacks(),
        .ctx = @ptrCast(&game),
        .num_players = 2,
        .check_distance = 1,
        .seed = 0xdeadbeef,
    });
    defer sync_test.deinit();

    const frames_to_test: u32 = 10_000;
    for (0..frames_to_test) |_| {
        try sync_test.advanceFrame();
    }

    io.out().print("SyncTest passed: {d} frames\n", .{frames_to_test}) catch {};
}
```

Run it. If it passes, your sim is deterministic on this machine. If it fails, you have a
bug — the `DesyncDetected` event tells you which frame, and you can binary-search from
there.

## Running it in CI

SyncTest should run on every PR. It's fast (10,000 frames in <1 second for a
typical game) and catches the worst class of bugs.

### GitHub Actions example

```yaml
name: SyncTest
on: [push, pull_request]
jobs:
  synctest:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.16.0
      - run: zig build synctest
      - run: ./zig-out/bin/synctest --frames=100000 --seed=42
      - run: ./zig-out/bin/synctest --frames=100000 --seed=1234
      - run: ./zig-out/bin/synctest --frames=100000 --seed=9999
```

Run with multiple seeds — different seeds exercise different code paths through your sim
and may surface different bugs.

### Fuzzing

For real paranoia, fuzz the SyncTest with random seeds and random input sequences:

```zig
test "fuzz synctest" {
    var prng = std.Random.DefaultPrng.init(0xabc);
    const r = prng.random();

    for (0..100) |_| {
        const seed = r.int(u64);
        var sync_test = SyncTest.init(.{
            .io = std.testing.io,
            .gpa = std.testing.allocator,
            .callbacks = ...,
            .ctx = ...,
            .num_players = 2,
            .check_distance = 1,
            .seed = seed,
        });
        defer sync_test.deinit();

        for (0..1000) |_| {
            try sync_test.advanceFrame();
        }
    }
}
```

## Common bugs SyncTest catches

In rough order of frequency:

1. **Uninitialized memory in saved state** — the saved buffer includes bytes that were
   never written. Two runs produce different garbage in those bytes.
   Fix: `std.mem.zeroes` or only serialize the live portion.

2. **Iteration order affecting sim state** — iterating a hash map and the order changes
   between runs (because the hash seed was randomized).
   Fix: use `ArrayHashMap` or sort before iterating. See [determinism.md](determinism.md#iteration-order).

3. **Hidden global state** — a static `var` in your sim that one run modifies and the
   other inherits. Common in C++ code; rare in Zig.
   Fix: move the state into `GameState`.

4. **Floating-point nondeterminism** — FMA, subnormals, NaN payloads.
   Fix: switch to fixed-point. See [determinism.md](determinism.md#floating-point-just-dont).

5. **Random numbers from `io.rng()` or `std.crypto.random`** — non-deterministic by
   design.
   Fix: use a seeded `DefaultPrng` in `GameState`.

6. **Pointer comparisons** — `if (entity_a == entity_b)` compares addresses, which differ
   between runs (different allocator layouts).
   Fix: use generational indices.

7. **System time / file I/O inside `advance_frame`** — wall clock or file content affects
   the sim.
   Fix: move outside the sim.

8. **NaN payload differences** — two NaNs with different payloads compare equal but hash
   differently.
   Fix: normalize NaNs before hashing, or convert to fixed-point.

9. **Padding in structs** — `extern struct` may have padding bytes that aren't zeroed.
   Fix: `std.mem.zeroes` the struct before filling, or use `packed struct`.

10. **Compiler optimization differences** — Debug vs ReleaseFast may produce different
    floating-point results.
    Fix: build both modes in CI and run SyncTest in both.

## Beyond SyncTest: replay testing

SyncTest runs the sim twice in the same process. Replay testing runs it in two
**different** processes (or two different builds, or two different machines) and compares
the resulting state hashes.

This catches cross-architecture and cross-compiler bugs that SyncTest can't:

```bash
# On machine A:
./game --replay-mode --input-script=script.json --output-state=state_a.bin
# On machine B:
./game --replay-mode --input-script=script.json --output-state=state_b.bin
# Compare:
diff state_a.bin state_b.bin   # or hash them and compare hashes
```

For a real production game, you'd:
1. Record input scripts from real play sessions.
2. Run them through SyncTest in CI (catches within-machine bugs).
3. Run them through replay testing across Windows/macOS/Linux (catches cross-platform
   bugs).
4. For console releases, run them on dev kits.

### Input script format

```json
{
  "name": "basic_combo_test",
  "seed": 42,
  "frames": [
    { "player": 0, "bits": [1, 0] },
    { "player": 0, "bits": [1, 0] },
    { "player": 0, "bits": [3, 0] },
    { "player": 0, "bits": [2, 0] },
    null,
    { "player": 1, "bits": [0, 1] }
  ]
}
```

`null` means "no input this frame" (player keeps previous input). `bits` is the same
format as `GameInput.bits`.

## When SyncTest passes but netplay still desyncs

This happens. The cause is almost always **a difference between SyncTest's environment
and netplay's environment**:

1. **Compiler flags differ** — netplay build uses `-Doptimize=ReleaseFast`, SyncTest uses
   `Debug`. Floating-point code can differ.
   Fix: run SyncTest in ReleaseFast too.

2. **Platform differs** — SyncTest runs on Linux dev box, netplay runs on Windows client.
   Fix: cross-platform replay testing.

3. **Game state size differs** — SyncTest uses a fixed seed for the PRNG, netplay uses a
   negotiated seed. If your PRNG seeding touches global state, this can diverge.
   Fix: audit your PRNG setup.

4. **Network packets arrive out-of-order** — SyncTest doesn't exercise the rollback path.
   SyncTest only tests determinism, not the rollback machinery itself. To test rollback,
   you need a separate test that injects fake packet loss / reordering. See
   [testing.md](testing.md#injecting-network-faults).

5. **Save/load has a bug** — SyncTest saves and loads immediately, so a serialization bug
   that "round-trips" correctly is invisible. Netplay may save at frame N and load at
   frame N+5, exposing the bug.
   Fix: in SyncTest, occasionally load a state from many frames ago and verify the
   checksum matches the original.

For (5), here's a useful SyncTest variant:

```zig
// Every 100 frames, load a state from 50 frames ago and verify checksum.
if (self.frame % 100 == 0 and self.frame >= 50) {
    const old_state = self.input_history.items[self.input_history.items.len - 50];
    try self.callbacks.load_game_state(self.io, self.ctx, old_state.saved_state);
    // Run the 50 frames of inputs forward.
    for (self.input_history.items[self.input_history.items.len - 50..]) |input| {
        try self.callbacks.advance_frame(self.ctx, &.{input});
    }
    // Now compare the checksum to what we recorded at this frame.
    var post: std.ArrayList(u8) = .empty;
    post.initContext(self.gpa);
    defer post.deinit(self.gpa);
    try self.callbacks.save_game_state(self.io, self.ctx, &post);
    const checksum = std.hash.Wyhash.hash(0, post.items);
    if (checksum != self.recorded_checksum_at_frame) {
        return error.LateDesync;
    }
}
```

This catches "works in round-trip but breaks over time" bugs.

## See also

- [determinism.md](determinism.md) — The rules SyncTest enforces
- [testing.md](testing.md) — Property-based testing and fault injection
- [ggpo-ffi.md](ggpo-ffi.md) — The C++ GGPO SDK has its own SyncTest mode
