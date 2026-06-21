# Testing rollback systems

Rollback netcode has more ways to fail than any other game subsystem. This file covers
the testing strategies that catch the failure modes that SyncTest alone can't.

## Table of contents

1. [The testing pyramid](#the-testing-pyramid)
2. [Unit tests for data structures](#unit-tests-for-data-structures)
3. [Property-based testing](#property-based-testing)
4. [Injecting network faults](#injecting-network-faults)
5. [Two-process integration tests](#two-process-integration-tests)
6. [Fuzzing the determinism invariant](#fuzzing-the-determinism-invariant)
7. [Replay regression tests](#replay-regression-tests)
8. [Load testing](#load-testing)
9. [Test fixtures](#test-fixtures)

## The testing pyramid

```text
                    ┌──────────────────┐
                    │  Cross-machine   │
                    │   replay tests   │     few, slow, catch platform bugs
                    └──────────────────┘
                ┌──────────────────────┐
                │  Two-process network │
                │       tests          │   medium, catch integration bugs
                └──────────────────────┘
            ┌──────────────────────────┐
            │  Property-based + fuzz   │   many, catch invariant bugs
            └──────────────────────────┘
        ┌──────────────────────────────┐
        │     SyncTest in CI           │   every PR, catches determinism bugs
        └──────────────────────────────┘
    ┌──────────────────────────────────┐
    │      Unit tests (data structs)   │   every save, catch algorithm bugs
    └──────────────────────────────────┘
```

Each layer catches different bugs. Skipping any layer means bugs slip through to the next
layer (or to production).

## Unit tests for data structures

The smallest tests. Each test exercises one struct in isolation.

```zig
const std = @import("std");
const rollback = @import("rollback");

test "InputQueue addInput records frame" {
    var io_state = std.testing.io;
    const io = &io_state.io;

    var q = rollback.InputQueue.init(io);
    var input: rollback.GameInput = .{};
    input.setPressed(0);
    try q.addInput(input);

    const got = try q.getInput(0);
    try std.testing.expect(got.isPressed(0));
}

test "InputQueue prediction falls back to last input" {
    var io_state = std.testing.io;
    const io = &io_state.io;

    var q = rollback.InputQueue.init(io);
    var input: rollback.GameInput = .{};
    input.setPressed(2);
    try q.addInput(input);

    // Predict frame 1 (future) — should repeat the last input.
    const predicted = try q.getInput(1);
    try std.testing.expect(predicted.isPressed(2));
    try std.testing.expectEqual(@as(i32, 1), q.first_incorrect_frame.?);
}

test "InputQueue correct prediction clears incorrect frame" {
    var io_state = std.testing.io;
    const io = &io_state.io;

    var q = rollback.InputQueue.init(io);
    var input: rollback.GameInput = .{};
    input.setPressed(0);
    try q.addInput(input);

    // Predict frame 1
    _ = try q.getInput(1);
    try std.testing.expectEqual(@as(i32, 1), q.first_incorrect_frame.?);

    // Add correct input for frame 1 — should clear the flag.
    try q.addInput(input);
    try std.testing.expect(q.first_incorrect_frame == null);
}

test "InputQueue wrong prediction sets incorrect frame" {
    var io_state = std.testing.io;
    const io = &io_state.io;

    var q = rollback.InputQueue.init(io);
    var input: rollback.GameInput = .{};
    input.setPressed(0);
    try q.addInput(input);

    // Predict frame 1 — last input was button 0.
    _ = try q.getInput(1);

    // Add wrong input for frame 1 — button 1 instead.
    var wrong: rollback.GameInput = .{};
    wrong.setPressed(1);
    try q.addInput(wrong);

    try std.testing.expectEqual(@as(i32, 1), q.first_incorrect_frame.?);
}

test "StateStore save and load roundtrip" {
    var io_state = std.testing.io;
    const io = &io_state.io;
    const gpa = std.testing.allocator;

    var store = rollback.StateStore.init(gpa);
    defer store.deinit();

    var state = TestState{ .x = 42, .y = 100 };
    try store.save(io, gpa, 0, @ptrCast(&state), testSaveFn);

    state.x = 0;
    state.y = 0;
    try store.load(io, 0, @ptrCast(&state), testLoadFn);

    try std.testing.expectEqual(@as(u32, 42), state.x);
    try std.testing.expectEqual(@as(u32, 100), state.y);
}

test "StateStore ring buffer reuses slots" {
    var io_state = std.testing.io;
    const io = &io_state.io;
    const gpa = std.testing.allocator;

    var store = rollback.StateStore.init(gpa);
    defer store.deinit();

    var state = TestState{ .x = 0, .y = 0 };

    // Save more states than the ring size — old slots get overwritten.
    for (0..30) |i| {
        state.x = @intCast(i);
        try store.save(io, gpa, @intCast(i), @ptrCast(&state), testSaveFn);
    }

    // Frame 5 should be gone (slot reused by frame 5 + ring_size).
    try std.testing.expectError(error.StateNotFound, store.load(io, 5, @ptrCast(&state), testLoadFn));

    // Frame 29 should be present.
    try store.load(io, 29, @ptrCast(&state), testLoadFn);
    try std.testing.expectEqual(@as(u32, 29), state.x);
}
```

These tests are fast (<1 ms each) and catch regressions in the data structures
themselves.

## Property-based testing

Property-based testing generates random inputs and verifies invariants hold across all
of them. For rollback, the key invariants are:

1. **Round-trip**: `save(state); load(buf); save(state)` produces the same buffer both
   times.
2. **Determinism**: advancing the same state with the same input twice produces the same
   resulting state.
3. **Rollback correctness**: after a rollback, the state matches what would have been
   produced if we'd had the correct inputs all along.

```zig
const pb = @import("property_based");

test "save-load roundtrip is stable" {
    var prng = std.Random.DefaultPrng.init(0xabcd);
    const r = prng.random();

    for (0..100) |_| {
        var state = randomState(r);
        var buf1: std.ArrayList(u8) = .empty;
        buf1.initContext(std.testing.allocator);
        defer buf1.deinit(std.testing.allocator);

        try serializeState(&state, &buf1);

        var state2: TestState = undefined;
        try deserializeState(&state2, buf1.items);

        var buf2: std.ArrayList(u8) = .empty;
        buf2.initContext(std.testing.allocator);
        defer buf2.deinit(std.testing.allocator);
        try serializeState(&state2, &buf2);

        try std.testing.expectEqualSlices(u8, buf1.items, buf2.items);
    }
}

test "advance is deterministic" {
    var prng = std.Random.DefaultPrng.init(0x1234);
    const r = prng.random();

    for (0..100) |_| {
        const state1 = randomState(r);
        const state2 = state1;
        const input = randomInput(r);

        var s1 = state1;
        var s2 = state2;
        advanceState(&s1, input);
        advanceState(&s2, input);

        try std.testing.expect(stateEquals(s1, s2));
    }
}

test "rollback produces correct final state" {
    // Set up a session with two players.
    // 1. Predict player 2's input as "no input" for 5 frames.
    // 2. After 5 frames, inject the actual input.
    // 3. Verify the final state matches a non-rollback run with the same inputs.
    var prng = std.Random.DefaultPrng.init(0x5678);
    const r = prng.random();

    for (0..50) |_| {
        const inputs: [10]GameInput = blk: {
            var arr: [10]GameInput = undefined;
            for (&arr) |*in| in.* = randomInput(r);
            break :blk arr;
        };

        // Run 1: with rollback (delayed inputs)
        var session_with_rollback = try createTestSession(.{ .delay_remote_inputs = 5 });
        defer session_with_rollback.deinit();
        for (inputs) |in| {
            try session_with_rollback.advanceFrame(in);
            try session_with_rollback.deliverDelayedRemoteInputs();
        }
        const state_with_rollback = session_with_rollback.currentState();

        // Run 2: without rollback (immediate inputs)
        var session_no_rollback = try createTestSession(.{ .delay_remote_inputs = 0 });
        defer session_no_rollback.deinit();
        for (inputs) |in| {
            try session_no_rollback.advanceFrame(in);
            try session_no_rollback.deliverDelayedRemoteInputs();
        }
        const state_no_rollback = session_no_rollback.currentState();

        // Final states must match.
        try std.testing.expect(stateEquals(state_with_rollback, state_no_rollback));
    }
}
```

The third property is the most valuable: it proves that rollback produces the same result
as lockstep (given the same inputs). If this ever fails, your rollback logic has a bug.

## Injecting network faults

Real networks drop, reorder, and delay packets. Your rollback layer must handle all three.
Test by injecting faults into a fake transport:

```zig
const FaultyTransport = struct {
    inner: *UdpTransport,
    drop_rate: f32,           // 0..1
    reorder_rate: f32,        // 0..1
    delay_ms: u32,
    prng: std.Random.DefaultPrng,

    pub fn sendInput(self: *FaultyTransport, io: std.Io, frame: i32, input: GameInput,
                     queue: *const InputQueue) !void {
        const r = self.prng.random().float(f32);
        if (r < self.drop_rate) return;   // drop this packet

        if (r < self.drop_rate + self.reorder_rate) {
            // Delay the packet — send it later.
            try self.pending.append(.{ .frame = frame, .input = input, .send_at_ms = io.clock.now().ms + self.delay_ms });
        } else {
            try self.inner.sendInput(io, frame, input, queue);
        }
    }

    pub fn pump(self: *FaultyTransport, io: std.Io, session: *Session) !void {
        // Send any delayed packets whose time has come.
        var i: usize = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].send_at_ms <= io.clock.now().ms) {
                const p = self.pending.swapRemove(i);
                try self.inner.sendInput(io, p.frame, p.input, &session.inputs[0]);
            } else {
                i += 1;
            }
        }

        try self.inner.pump(io, session);
    }
};

test "rollback survives 10% packet loss" {
    var io_state = std.testing.io;
    const io = &io_state.io;
    const gpa = std.testing.allocator;

    var inner = try UdpTransport.init(io, gpa, 7000, &.{});
    defer inner.deinit(io);

    var faulty = FaultyTransport{
        .inner = &inner,
        .drop_rate = 0.10,
        .reorder_rate = 0.05,
        .delay_ms = 50,
        .prng = std.Random.DefaultPrng.init(42),
    };

    var session = try Session.init(.{
        .io = io, .gpa = gpa, .callbacks = ..., .ctx = ...,
        .num_players = 2, .local_player = 0,
        .local_port = 7001, .remote_addrs = &.{},
    });
    defer session.deinit();

    // Run 1000 frames with the faulty transport.
    for (0..1000) |frame| {
        var input: GameInput = .{};
        input.setPressed(@intCast(frame % 8));
        try session.advanceFrame(input);
        try faulty.pump(io, &session);
    }

    // The session should still be alive and have the correct state.
    try std.testing.expect(session.frame == 1000);
}
```

Vary the drop rate, reorder rate, and delay to find the failure thresholds. Most rollback
implementations handle 5% drop easily, start struggling at 15%, and fail entirely above
30%.

## Two-process integration tests

Unit tests run in one process. Real netcode runs across two. To test the network path
end-to-end, spawn two processes and have them play against each other:

```zig
const std = @import("std");

test "two-process match: 1000 frames" {
    const gpa = std.testing.allocator;

    // Spawn player A
    var child_a = try std.process.Child.spawn(.{
        .argv = &.{ "zig-out/bin/game", "--headless", "--player=0", "--port=7000", "--remote=127.0.0.1:7001", "--frames=1000" },
    });
    defer _ = child_a.kill() catch {};

    // Spawn player B
    var child_b = try std.process.Child.spawn(.{
        .argv = &.{ "zig-out/bin/game", "--headless", "--player=1", "--port=7001", "--remote=127.0.0.1:7000", "--frames=1000" },
    });
    defer _ = child_b.kill() catch {};

    // Wait for both to finish
    const result_a = try child_a.wait();
    const result_b = try child_b.wait();

    try std.testing.expectEqual(@as(u8, 0), result_a.Exited);
    try std.testing.expectEqual(@as(u8, 0), result_b.Exited);

    // Compare final state checksums — they must match.
    const checksum_a = try readFileChecksum(gpa, "/tmp/player_a_state.bin");
    const checksum_b = try readFileChecksum(gpa, "/tmp/player_b_state.bin");
    try std.testing.expectEqual(checksum_a, checksum_b);
}
```

This catches integration bugs that single-process tests miss:
- Wire format mismatches.
- Endianness issues across platforms.
- Disconnect handling under real network timing.
- Race conditions in the network pump.

For cross-platform testing, run one process on Windows and one on Linux (via CI matrix).

## Fuzzing the determinism invariant

Fuzzing generates random input sequences and runs them through SyncTest. If SyncTest
ever fails, you have a determinism bug.

```zig
const std = @import("std");

test "fuzz determinism" {
    const gpa = std.testing.allocator;

    var prng = std.Random.DefaultPrng.init(0xfuzz);
    const r = prng.random();

    for (0..1000) |_| {
        const seed = r.int(u64);
        const frames = r.intRangeAtMost(u32, 100, 10000);

        var sync_test = SyncTest.init(.{
            .io = std.testing.io, .gpa = gpa,
            .callbacks = ..., .ctx = ...,
            .num_players = 2, .check_distance = 1, .seed = seed,
        });
        defer sync_test.deinit();

        for (0..frames) |_| {
            try sync_test.advanceFrame();
        }
    }
}
```

Use a coverage-guided fuzzer (`libfuzzer`, `afl`) if you want to go further. The
determinism invariant is a perfect fuzz target — if the fuzzer ever finds a sequence that
desyncs, you have a real bug.

## Replay regression tests

Record inputs from a real play session and replay them through SyncTest every PR. If the
checksums change, your PR broke determinism (or changed sim behavior, which is itself
worth flagging).

```zig
test "replay: real_match_2024_03_15" {
    const inputs = try loadReplayFile(std.testing.allocator, "replays/real_match_2024_03_15.json");
    defer std.testing.allocator.free(inputs);

    var sync_test = SyncTest.init(.{
        .io = std.testing.io, .gpa = std.testing.allocator,
        .callbacks = ..., .ctx = ...,
        .num_players = 2, .check_distance = 1, .seed = 42,
    });
    defer sync_test.deinit();

    for (inputs) |input| {
        try sync_test.setInput(input);
        try sync_test.advanceFrame();
    }

    const final_checksum = sync_test.currentChecksum();
    try std.testing.expectEqual(@as(u64, 0x1234567890abcdef), final_checksum);
}
```

If the checksum changes:
- If you intended to change sim behavior, update the expected checksum.
- If you didn't, you have a regression — investigate.

This is the most valuable test in your suite. It catches:
- Floating-point changes from compiler upgrades.
- Logic changes that subtly alter sim behavior.
- Accidental determinism breakage (e.g. someone adds `io.rng()` inside `advance_frame`).

## Load testing

Rollback has a worst-case cost: a deep rollback with many replayed frames. Test that
your game sustains this without dropping below 60 FPS:

```zig
test "worst-case rollback sustains 60 FPS" {
    var io_state = std.testing.io;
    const io = &io_state.io;
    const gpa = std.testing.allocator;

    var session = try Session.init(.{
        .io = io, .gpa = gpa, .callbacks = ..., .ctx = ...,
        .num_players = 2, .local_player = 0,
        .local_port = 7000, .remote_addrs = &.{},
    });
    defer session.deinit();

    // Simulate worst-case: remote peer 8 frames behind (max prediction window).
    try session.setRemoteDelay(8);

    var total_ms: u64 = 0;
    const iterations: u32 = 1000;

    for (0..iterations) |_| {
        const start = io.clock.now();
        var input: GameInput = .{};
        input.setPressed(0);
        try session.advanceFrame(input);
        try session.deliverDelayedRemoteInput();
        total_ms += io.clock.now().since(start).ms;
    }

    const avg_ms = total_ms / iterations;
    // Must be well under 16ms to leave time for rendering.
    try std.testing.expect(avg_ms < 10);
}
```

If this fails, your state save/load is too slow, or your `advance_frame` is too slow.
Profile and optimize.

## Test fixtures

Common helpers:

```zig
const fixtures = struct {
    pub fn createTestSession(opts: SessionOpts) !Session {
        var io_state = std.testing.io;
        const io = &io_state.io;
        return Session.init(.{
            .io = io, .gpa = std.testing.allocator,
            .callbacks = opts.callbacks, .ctx = opts.ctx,
            .num_players = opts.num_players, .local_player = opts.local_player,
            .local_port = 7000, .remote_addrs = &.{},
        });
    }

    pub fn randomState(r: std.Random) TestState {
        return .{
            .x = r.int(u32),
            .y = r.int(u32),
            .vx = r.int(i32),
            .vy = r.int(i32),
        };
    }

    pub fn randomInput(r: std.Random) GameInput {
        var input: GameInput = .{};
        for (&input.bits) |*b| b.* = r.int(u8);
        return input;
    }

    pub fn stateEquals(a: TestState, b: TestState) bool {
        return std.meta.eql(a, b);
    }
};
```

Keep these in `tests/fixtures.zig` so every test can import them.

## See also

- [sync-test.md](sync-test.md) — The SyncTest harness
- [determinism.md](determinism.md) — What the tests are checking for
- [integration.md](integration.md) — How the loop under test fits together
