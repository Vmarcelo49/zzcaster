---
name: rollback-netcode
description: Authoritative guide to implementing rollback netcode (GGPO-style) for deterministic peer-to-peer multiplayer games, written from scratch in Zig 0.16. Use whenever the user mentions rollback, GGPO, netcode, fighting game networking, peer-to-peer multiplayer, deterministic simulation, frame synchronization, input delay, prediction, state save/restore, sync test, or wants to add online multiplayer to a game loop. Covers the full algorithm (InputQueue, StateStore, Session, prediction, rollback trigger, time sync), the wire protocol (UDP packet format, reliability-via-repetition, ack strategy), a from-scratch Zig implementation (~1000 LOC), a SyncTest harness for determinism verification, and an FFI bridge to the C++ GGPO SDK for projects that need to drop into an existing ecosystem. Critical for avoiding the well-known determinism pitfalls (floating-point, RNG, allocation, pointer identity) that silently desync peers after 30 seconds of play. Trigger this skill on ANY rollback/netcode question even if the user does not mention Zig — the algorithm material is language-agnostic and the Zig code is illustrative.
---

# Rollback Netcode (GGPO-style) in Zig 0.16

Rollback netcode is the algorithm that powers Fightcade, modern fighting games (Skullgirls,
Killer Instinct, Mortal Kombat 11+, Riot's Project L), and most other latency-sensitive
peer-to-peer multiplayer. The canonical implementation is Tony Cannon's GGPO (Good Game
Peace Out), released as open source after his GDC 2006 talk "Back to the Past".

This skill teaches you to implement rollback from scratch in Zig 0.16. It assumes you've
read the [zig-0-16 skill](../zig-0-16/SKILL.md) and are fluent with `Io`, `ArenaAllocator`,
comptime, and the new container init conventions.

## What rollback netcode actually is

Rollback is a refinement of **lockstep** netcode. In lockstep, every peer must receive
every other peer's input for frame N before simulating frame N. This is dead simple but
adds the round-trip latency of the slowest peer to every frame — at 60 FPS across the US
east-west, that's 5-8 frames of input delay, which is unplayable for fighting games.

Rollback observes that the simulation is **deterministic** — same inputs produce same
state — and uses this to **predict** remote inputs, advance the sim anyway, and **rewind +
replay** when the real inputs arrive.

The full loop, run every frame:

```text
1. Collect local input for frame N.
2. Send local input (and recent history) to all remote peers over UDP.
3. Receive remote inputs for frames ≤ N (and possibly > N if they're predicting us).
4. If we have all inputs for frame N, advance the sim by one frame.
   Otherwise, predict the missing remote inputs (typically: "they keep doing what they
   did last frame") and advance anyway.
5. After advancing, check: did any earlier frame's prediction turn out wrong?
   If yes, load the saved state from before the wrong frame, replay with correct inputs
   up to current. This is the "rollback".
6. Save the new state for future rollbacks.
7. Render. Go to 1.
```

The trick is that step 5 is invisible to the player if it happens fast enough. At 60 FPS
you have 16.6 ms to: receive packets, detect mismatch, load state, replay 1-8 frames,
re-render. Modern hardware does this in <1 ms for a fighting-game-sized state.

## When to use this skill

Use rollback when:
- You have a deterministic, fixed-step simulation (60 FPS, 30 FPS, doesn't matter).
- You need very low input latency (≤4 frames from button press to on-screen effect).
- The game state is small enough to snapshot quickly (a few KB to a few MB).
- The simulation can be re-run many times per frame without breaking.

Don't use rollback for:
- MMOs (thousands of entities, no determinism guarantee across regions).
- RTS games with hundreds of units (snapshot too large, lockstep works fine).
- Server-authoritative shooters (use client prediction + server reconciliation instead).
- Card games / turn-based (lockstep is plenty; you don't need 60 FPS).

## The critical invariant: determinism

If your simulation is not bit-identical across peers, rollback will desync within seconds
and the game will diverge into garbage. **Everything in your `advance_frame` function must
be deterministic.** The big killers:

1. **Floating-point math** — IEEE 754 is deterministic per-CPU+compiler, but breaks across
   architectures, FMA modes, and optimization levels. Use fixed-point. See
   [determinism.md](references/determinism.md).
2. **Random numbers** — `io.rng()` is the OS CSPRNG, non-deterministic. Use a seeded
   `DefaultPrng` stored in your game state.
3. **Allocation addresses** — if you store raw pointers as entity handles, two peers will
   have different pointer values for the "same" entity. Use generational indices.
4. **Iteration order** — `AutoHashMap` iteration order is unspecified. Use `ArrayHashMap`
   or sort before iterating.
5. **System time / file I/O** — never inside `advance_frame`. Read files at startup;
   capture timestamps outside the sim.

Read [determinism.md](references/determinism.md) before writing any simulation code. The
rollback layer is built on the assumption that your sim is deterministic — if it isn't,
no amount of netcode cleverness will save you.

## Module map

This skill is structured as a tutorial that builds the rollback system layer by layer. Read
the SKILL.md first for the big picture, then the reference files in order as you implement.

- [references/algorithm.md](references/algorithm.md) — The full algorithm: input queues,
  prediction, rollback trigger, frame advantage, the canonical main loop. Start here.
- [references/data-structures.md](references/data-structures.md) — `InputQueue`,
  `StateStore`, `Session`, `TimeSync`, `UdpTransport`. The five structs that make up the
  core. With Zig 0.16 code.
- [references/determinism.md](references/determinism.md) — How to write a deterministic
  simulation. Floating-point vs fixed-point, RNG, allocation, iteration order, hashing
  for sync verification.
- [references/network-protocol.md](references/network-protocol.md) — The UDP wire format.
  Packet types (Input, Sync, InputAck, QualityReport, KeepAlive), reliability-via-
  repetition, ack strategy, NAT considerations.
- [references/sync-test.md](references/sync-test.md) — SyncTest mode: run every frame twice
  and compare checksums. The killer feature for catching determinism bugs before netplay.
  Should be in CI.
- [references/time-sync.md](references/time-sync.md) — Frame advantage averaging, the
  cooperative sleep recommendation, and why GGPO doesn't forcibly stall the sim.
- [references/integration.md](references/integration.md) — Wiring rollback into a real
  game loop. Frame budget math, render interpolation, audio, input polling cadence.
- [references/ggpo-ffi.md](references/ggpo-ffi.md) — If you don't want to write from
  scratch: how to call the C++ GGPO SDK from Zig via `extern "C"`. Callback contract,
  threading model, the missing `user_data` parameter problem.
- [references/testing.md](references/testing.md) — Property-based testing for rollback.
  Injecting packet loss, latency, reordering. Fuzzing the determinism invariant.
- [references/patterns.md](references/patterns.md) — Production patterns: state
  serialization, save-ring sizing, input compression, disconnect handling, spectator
  mode.
- [references/examples.md](references/examples.md) — Two worked examples: a 2-player Pong
  with rollback, and a 4-player co-op brawler.

## The 30-second pitch (for the impatient)

```zig
const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    inputs: [MAX_PLAYERS]InputQueue,
    states: StateStore,
    frame: i32 = 0,
    rolling_back: bool = false,

    pub fn advanceFrame(self: *Session, local_input: GameInput) !void {
        // 1. Add local input at the current frame
        const local_player = self.local_player;
        try self.inputs[local_player].addInput(self.frame, local_input);

        // 2. Send local input to remote peers
        try self.network.sendInput(self.frame, local_input);

        // 3. Poll network — drain remote inputs into their queues
        try self.network.pump(self.io, &self.inputs);

        // 4. Predict missing remote inputs (typically "repeat last frame")
        const frame_inputs = self.predictInputs(self.frame);

        // 5. Save state BEFORE advancing (so we can rollback to here)
        try self.states.save(self.io, self.gpa, self.frame, &self.game_state);

        // 6. Advance the sim with these (possibly predicted) inputs
        try self.game_state.advanceFrame(frame_inputs);
        self.frame += 1;

        // 7. Check if any earlier frame's prediction was wrong
        if (self.findIncorrectFrame()) |wrong_frame| {
            try self.rollbackTo(wrong_frame);
        }
    }

    fn rollbackTo(self: *Session, target_frame: i32) !void {
        self.rolling_back = true;
        defer self.rolling_back = false;

        // Load state from target_frame - 1 (the last confirmed-correct state)
        try self.states.load(self.io, target_frame - 1, &self.game_state);
        self.frame = target_frame;

        // Re-run from target_frame to current, using the now-correct inputs
        const current = self.lastConfirmedFrame();
        while (self.frame <= current) {
            const inputs = self.predictInputs(self.frame);   // now 100% correct
            try self.game_state.advanceFrame(inputs);
            self.frame += 1;
        }
    }
};
```

The rest of this skill fills in the details: how `InputQueue` tracks prediction state, how
`StateStore` is a ring buffer of `MAX_PREDICTION_FRAMES + 2 = 10` snapshots, how
`findIncorrectFrame` works, how to handle the network, how to test all of this.

## Key constants

These are the constants GGPO uses. They're well-tuned by years of fighting-game
deployment — change them only if you have a specific reason.

```zig
pub const MAX_PLAYERS: u8 = 4;
pub const MAX_SPECTATORS: u8 = 32;
pub const MAX_PREDICTION_FRAMES: u8 = 8;    // ~133 ms at 60 FPS
pub const INPUT_QUEUE_LENGTH: u16 = 128;    // 2+ seconds of input history at 60 FPS
pub const FRAME_WINDOW_SIZE: u8 = 40;       // ~666 ms advantage averaging window
pub const MIN_FRAME_ADVANTAGE: i32 = 3;
pub const MAX_FRAME_ADVANTAGE: i32 = 9;
pub const DEFAULT_DISCONNECT_TIMEOUT_MS: u32 = 5000;
pub const DEFAULT_DISCONNECT_NOTIFY_START_MS: u32 = 750;
pub const RECOMMENDATION_INTERVAL_MS: u32 = 240;
```

`MAX_PREDICTION_FRAMES = 8` is the empirical limit before misprediction becomes
unplayable. If a peer is more than 8 frames behind, GGPO returns `PREDICTION_THRESHOLD`
from `addLocalInput` and the app gracefully stalls like lockstep.

## Quick reference: the seven callbacks

If you're using the C++ GGPO SDK or porting its API, your game must implement seven
callbacks. The same seven are required by the Zig from-scratch implementation:

| Callback            | Purpose                                                        |
|---------------------|----------------------------------------------------------------|
| `begin_game`        | One-time init after session starts.                            |
| `advance_frame`     | Step the sim by one frame with the given inputs.               |
| `save_game_state`   | Serialize the sim state into a buffer for later restore.       |
| `load_game_state`   | Deserialize a previously-saved buffer back into the sim.       |
| `free_buffer`       | Free a buffer previously allocated by `save_game_state`.       |
| `log_game_state`    | Debug logging — pretty-print the state.                        |
| `on_event`          | Async notifications (connected, disconnected, timesync, etc.). |

In Zig, these are typically a `SessionCallbacks` struct of function pointers:

```zig
pub const SessionCallbacks = struct {
    begin_game: *const fn(ctx: *anyopaque, info: BeginGameInfo) anyerror!void,
    advance_frame: *const fn(ctx: *anyopaque, inputs: []const GameInput) anyerror!void,
    save_game_state: *const fn(ctx: *anyopaque, frame: i32, out: *SaveBuffer) anyerror!void,
    load_game_state: *const fn(ctx: *anyopaque, buf: []const u8) anyerror!void,
    free_buffer: *const fn(ctx: *anyopaque, buf: []u8) void,
    log_game_state: *const fn(ctx: *anyopaque, label: []const u8, inputs: []const GameInput) void,
    on_event: *const fn(ctx: *anyopaque, event: Event) void,
};
```

The `ctx: *anyopaque` is your game state — the same pointer you passed to
`Session.init`. (The original C++ GGPO lacks this parameter, which is why most serious
downstream users fork it to add one. See [ggpo-ffi.md](references/ggpo-ffi.md#the-missing-user_data-parameter).)

## How to read this skill

If you're implementing rollback for the first time:
1. Read this SKILL.md end-to-end.
2. Read [algorithm.md](references/algorithm.md) end-to-end.
3. Read [determinism.md](references/determinism.md) end-to-end. Don't skip — this is
   where most projects die.
4. Implement a SyncTest harness first ([sync-test.md](references/sync-test.md)) and run
   your sim through it for a few thousand frames before touching the network.
5. Implement the data structures ([data-structures.md](references/data-structures.md)).
6. Wire up the network ([network-protocol.md](references/network-protocol.md)).
7. Add time sync ([time-sync.md](references/time-sync.md)).
8. Integrate into your game loop ([integration.md](references/integration.md)).

If you're porting an existing game from lockstep to rollback:
- Skip to [integration.md](references/integration.md) for the migration patterns.
- Then [determinism.md](references/determinism.md) to audit your sim.
- Then [sync-test.md](references/sync-test.md) to verify the audit.

If you just want to use the C++ GGPO SDK from Zig without writing your own:
- Skip to [ggpo-ffi.md](references/ggpo-ffi.md). You still need
  [determinism.md](references/determinism.md) — the SDK doesn't save you from a
  non-deterministic sim.

## Version

This skill targets **Zig 0.16.0** and references the [zig-0-16 skill](../zig-0-16/SKILL.md)
for language-level patterns. The algorithm material is language-agnostic; the code samples
are Zig. References to GGPO are based on the C# reference at
[github.com/otac0n/GGPO](https://github.com/otac0n/GGPO) and the original GDC 2006 paper.
