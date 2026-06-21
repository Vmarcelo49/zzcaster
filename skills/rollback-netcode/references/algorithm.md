# The rollback algorithm

This file is the algorithm reference. It walks through the full rollback loop, explains
every data structure's role, and shows the canonical main loop in Zig-flavored pseudocode.

## Table of contents

1. [The lockstep baseline](#the-lockstep-baseline)
2. [Prediction: the rollback trick](#prediction-the-rollback-trick)
3. [The per-frame loop in detail](#the-per-frame-loop-in-detail)
4. [The InputQueue](#the-inputqueue)
5. [The StateStore](#the-statestore)
6. [The rollback trigger](#the-rollback-trigger)
7. [Replaying frames](#replaying-frames)
8. [Frame advantage](#frame-advantage)
9. [Input delay vs prediction window](#input-delay-vs-prediction-window)
10. [Spectators](#spectators)
11. [Disconnect handling](#disconnect-handling)

## The lockstep baseline

Before rollback, understand lockstep. In lockstep:

```text
For frame N:
  1. Each peer collects local input for frame N.
  2. Each peer sends its input to every other peer.
  3. Each peer waits until it has received all peers' inputs for frame N.
  4. Each peer advances the sim by one frame using all inputs.
  5. Render. Go to 1.
```

The advantage: dead simple, no prediction, no rollback. The cost: every frame's latency
equals the round-trip time of the slowest peer. At 60 FPS across the continental US,
that's 5-8 frames of input delay. Fighting games need <4 frames. So lockstep doesn't work.

## Prediction: the rollback trick

Rollback observes that the sim is deterministic — given inputs, the next state is
well-defined. So we can:

1. **Predict** missing remote inputs (typically "the remote player keeps doing what they
   did last frame") and advance the sim anyway.
2. **Remember** every state we predicted into.
3. When the real remote input arrives, **check** if our prediction was right.
4. If wrong, **rewind** to the last correct state and **replay** with the correct inputs.

The player's local input is never delayed (much). The remote player's actions might appear
to "snap" to a different state when a rollback happens, but at 60 FPS and a typical
rollback window of 2-4 frames, this is barely perceptible.

## The per-frame loop in detail

Here's the full per-frame loop, annotated:

```zig
fn advanceFrame(self: *Session, local_input: GameInput) !void {
    // --- Phase 1: Local input ---
    // Add the local player's input to their InputQueue at frame = self.frame.
    // This makes it available to the prediction logic and to the network sender.
    try self.inputs[self.local_player].addInput(self.frame, local_input);

    // --- Phase 2: Send to remote peers ---
    // Pack the local input (plus recent history) into a UDP packet and send.
    // The history is critical: if a previous packet was lost, the next packet
    // carries the missing bits.
    try self.network.sendInput(self.io, self.frame, local_input, &self.inputs[self.local_player]);

    // --- Phase 3: Poll network ---
    // Drain any pending UDP packets. For each remote input received, push it
    // into the corresponding player's InputQueue. This may make previously-
    // predicted frames "confirmed" — or "incorrect" if the prediction differs.
    try self.network.pump(self.io, &self.inputs);

    // --- Phase 4: Predict missing remote inputs ---
    // For each remote player, if we don't yet have their input for self.frame,
    // predict it (typically "repeat their last confirmed input"). Build a
    // combined input vector for the frame.
    const frame_inputs = try self.predictInputs(self.frame);

    // --- Phase 5: Save state ---
    // Snapshot the current game state BEFORE advancing. This is the state we'll
    // rewind to if a future rollback targets this frame.
    try self.states.save(self.io, self.gpa, self.frame, &self.game_state);

    // --- Phase 6: Advance ---
    // Step the sim by one frame using the (possibly predicted) inputs.
    try self.callbacks.advance_frame(self.callbacks.ctx, frame_inputs);
    self.frame += 1;

    // --- Phase 7: Check for rollbacks ---
    // If any earlier frame's prediction was wrong (a remote input arrived that
    // differs from what we predicted), rewind and replay.
    if (try self.findIncorrectFrame()) |wrong_frame| {
        try self.rollbackTo(wrong_frame);
    }

    // --- Phase 8: Time sync ---
    // Tell the time sync system how far ahead/behind we are. It may emit an
    // event recommending that the app sleep a bit on the next idle.
    self.time_sync.advanceFrame(self.frame, self.local_player_advantage());
}
```

That's the whole algorithm. The complexity is in the supporting machinery.

## The InputQueue

Each player has an `InputQueue` — a ring buffer of inputs indexed by frame number. It
tracks three things:

1. **Confirmed inputs** — inputs we've received (locally or remotely) and trust.
2. **Predicted inputs** — inputs we've guessed because the real one hasn't arrived.
3. **The first incorrect frame** — the earliest frame where our prediction might be wrong.

```zig
pub const InputQueue = struct {
    head: i32 = 0,                       // next frame to be added
    tail: i32 = 0,                       // oldest frame still in the queue
    length: u16 = 0,                     // number of frames currently stored
    first_incorrect_frame: i32 = -1,     // -1 = no known incorrect prediction
    last_added_frame: i32 = -1,          // last frame addInput was called with
    prediction: ?GameInput = null,       // the most recent prediction
    inputs: [INPUT_QUEUE_LENGTH]GameInput = undefined,
    frame_delay: u8 = 0,                 // local input delay (in frames)

    pub fn addInput(self: *InputQueue, frame: i32, input: GameInput) !void {
        // The new input must be for frame == self.head (after applying delay).
        // If we already have a prediction for this frame, check if it matches.
        if (self.prediction) |pred| {
            if (pred.eql(input)) {
                // Prediction was correct — clear the "incorrect" flag for this frame.
                if (self.first_incorrect_frame == frame) {
                    self.first_incorrect_frame = -1;
                }
            } else {
                // Prediction was wrong — mark this frame as incorrect.
                if (self.first_incorrect_frame < 0 or frame < self.first_incorrect_frame) {
                    self.first_incorrect_frame = frame;
                }
            }
            self.prediction = null;
        }
        // Append the input at head, advance head, possibly evict tail.
        const idx: u16 = @intCast(@as(i64, frame) % INPUT_QUEUE_LENGTH);
        self.inputs[idx] = input;
        self.head = frame + 1;
        self.last_added_frame = frame;
        if (self.length < INPUT_QUEUE_LENGTH) {
            self.length += 1;
        } else {
            self.tail += 1;
        }
    }

    pub fn getInput(self: *const InputQueue, frame: i32) !GameInput {
        // Return the confirmed input for `frame`, or predict if missing.
        if (frame >= self.head) {
            // Future frame — predict by repeating the last known input.
            const last = self.inputs[@intCast(@as(i64, self.last_added_frame) % INPUT_QUEUE_LENGTH)];
            self.prediction = last;
            return last;
        }
        if (frame < self.tail) return error.InputNotInQueue;
        return self.inputs[@intCast(@as(i64, frame) % INPUT_QUEUE_LENGTH)];
    }

    pub fn firstIncorrectFrame(self: *const InputQueue) ?i32 {
        if (self.first_incorrect_frame < 0) return null;
        return self.first_incorrect_frame;
    }
};
```

Key insight: `first_incorrect_frame` is set whenever a prediction is disproven, and only
cleared when the prediction is later confirmed correct (which happens during rollback
replay). The rollback trigger scans all queues for the minimum `first_incorrect_frame`.

## The StateStore

A ring of `MAX_PREDICTION_FRAMES + 2 = 10` saved states, indexed by frame number. Each
slot holds:

- The frame number it was saved at.
- A byte buffer holding the serialized state.
- A checksum of the state (for sync verification).

```zig
pub const StateStore = struct {
    slots: [MAX_PREDICTION_FRAMES + 2]Slot = [_]Slot{.{}} ** (MAX_PREDICTION_FRAMES + 2),

    const Slot = struct {
        frame: i32 = -1,
        buffer: ?[]u8 = null,
        checksum: u64 = 0,
    };

    pub fn save(self: *StateStore, io: std.Io, gpa: std.mem.Allocator, frame: i32, state: *const GameState) !void {
        const idx: u8 = @intCast(@as(u64, @bitCast(frame)) % (MAX_PREDICTION_FRAMES + 2));
        var slot = &self.slots[idx];

        // Reuse the existing buffer if it's big enough; otherwise reallocate.
        var save_buf = SaveBuffer{ .gpa = gpa };
        try state.serialize(io, &save_buf);

        if (slot.buffer) |old| {
            if (old.len < save_buf.written.len) {
                gpa.free(old);
                slot.buffer = try gpa.dupe(u8, save_buf.written);
            } else {
                @memcpy(slot.buffer.?[0..save_buf.written.len], save_buf.written);
                slot.buffer.?.len = save_buf.written.len;
            }
        } else {
            slot.buffer = try gpa.dupe(u8, save_buf.written);
        }

        slot.frame = frame;
        slot.checksum = hashState(save_buf.written);

        save_buf.deinit();
    }

    pub fn load(self: *StateStore, io: std.Io, frame: i32, state: *GameState) !void {
        const idx: u8 = @intCast(@as(u64, @bitCast(frame)) % (MAX_PREDICTION_FRAMES + 2));
        const slot = &self.slots[idx];
        if (slot.frame != frame) return error.StateNotFound;
        try state.deserialize(io, slot.buffer.?);
    }
};
```

The state buffer is allocated once and reused — never allocate per frame. The size of the
saved state must be roughly constant across frames (or at least bounded); if your state
size varies wildly (e.g. dynamic entity count), you have a determinism problem already.

## The rollback trigger

After every `advance_frame`, scan all input queues for the minimum
`first_incorrect_frame`:

```zig
fn findIncorrectFrame(self: *Session) !?i32 {
    var min_incorrect: i32 = std.math.maxInt(i32);
    for (self.inputs[0..self.num_players]) |*q| {
        if (q.first_incorrect_frame) |f| {
            if (f < min_incorrect) min_incorrect = f;
        }
    }
    if (min_incorrect == std.math.maxInt(i32)) return null;
    return min_incorrect;
}
```

If `min_incorrect` is found, that's the frame where the prediction was wrong. We need to
rollback to **one frame before** `min_incorrect` (the last confirmed-correct state), then
replay forward.

## Replaying frames

```zig
fn rollbackTo(self: *Session, target_frame: i32) !void {
    self.rolling_back = true;
    defer self.rolling_back = false;

    // Load the state from target_frame - 1 (the last known correct state).
    const load_frame = target_frame - 1;
    try self.states.load(self.io, load_frame, &self.game_state);

    // Reset the InputQueues' first_incorrect_frame to target_frame (they're about
    // to be replayed with correct inputs).
    for (self.inputs[0..self.num_players]) |*q| {
        q.first_incorrect_frame = -1;
    }

    // Save the current frame so we know how far to replay.
    const replay_to = self.frame - 1;
    self.frame = target_frame;

    // Replay forward, using the now-correct inputs.
    while (self.frame <= replay_to) {
        const inputs = try self.predictInputs(self.frame);
        try self.states.save(self.io, self.gpa, self.frame, &self.game_state);
        try self.callbacks.advance_frame(self.callbacks.ctx, inputs);
        self.frame += 1;
    }

    // Final frame — advance to current.
    const final_inputs = try self.predictInputs(self.frame);
    try self.states.save(self.io, self.gpa, self.frame, &self.game_state);
    try self.callbacks.advance_frame(self.callbacks.ctx, final_inputs);
}
```

Note that during replay, we save state at every frame — even though we just loaded from
`target_frame - 1`. This is because the replay itself might need to be rolled back if
another packet arrives mid-replay with another correction.

The replay loop runs at memory speed (no I/O, no network). For a fighting-game-sized state
(~10 KB), each frame replay is <100 μs. Eight frames of replay is <1 ms. The player never
notices.

## Frame advantage

Frame advantage is "how far ahead of the remote peer am I?" If you're 5 frames ahead and
the remote peer is 3 frames behind, your local actions feel instant but your remote
predictions are stretching further into the future — you're more likely to mispredict.

GGPO computes frame advantage as:

```text
local_advantage  = local_frame  - remote_confirmed_frame
remote_advantage = remote_frame  - local_confirmed_frame
                  = -(local_advantage)   // approximately
```

The `TimeSync` system averages this over a 40-frame window and emits a recommendation to
sleep when local advantage is too high. See [time-sync.md](time-sync.md).

## Input delay vs prediction window

The classic trade-off: how much input delay do you add to shrink the prediction window?

- **Zero input delay** — local input is applied immediately. Local player feels great.
  Remote predictions extend further into the future, so more misprediction, more rollbacks,
  more visual jitter for the remote character.
- **2-3 frames input delay** — local input is buffered for 2-3 frames before being applied.
  Local player feels a tiny bit of lag, but remote predictions are 2-3 frames shorter, so
  fewer rollbacks, smoother remote character.

Fighting games typically use 2 frames of input delay on good connections, scaling up to
4-5 on bad ones. The skill's [time-sync.md](time-sync.md) covers the adaptive delay
strategy.

Set per-player input delay with:

```zig
try session.setFrameDelay(player_handle, 2);
```

Internally, this just bumps `InputQueue.frame_delay`, which shifts where local inputs land
in the queue.

## Spectators

Spectators are a special case: they receive all inputs but produce none. They still run
the sim deterministically, still roll back when predictions (which they always make for
all players) are wrong, but they never call `addLocalInput`.

In practice, spectators are implemented as a 1-player session where the "local" player is
a dummy that always submits "no input", and the network layer fans out received inputs to
the InputQueues of the actual players.

GGPO's `ggpo_start_spectating` API is exactly this. See
[ggpo-ffi.md](references/ggpo-ffi.md#spectating) for the FFI version.

## Disconnect handling

Two timeouts:

- `DEFAULT_DISCONNECT_TIMEOUT_MS = 5000` — if we don't hear from a peer for 5 seconds,
  consider them disconnected. Fire `on_event(Disconnected)`.
- `DEFAULT_DISCONNECT_NOTIFY_START_MS = 750` — at 750 ms of silence, fire
  `on_event(NetworkInterrupted)` so the UI can show "Player 2 disconnected...". This is
  the warning before the hard cut.

During the warning window, the sim keeps running on prediction. If the peer comes back
within 5 seconds, inputs arrive and rollbacks correct the prediction. If not, the session
ends.

```zig
fn checkDisconnects(self: *Session, io: std.Io) !void {
    const now_ms = io.clock.now().ms;
    for (self.peers[0..self.num_players]) |*peer| {
        if (peer.disconnected) continue;
        const silence_ms = now_ms - peer.last_recv_ms;
        if (silence_ms > DEFAULT_DISCONNECT_TIMEOUT_MS) {
            peer.disconnected = true;
            self.callbacks.on_event(self.callbacks.ctx, .{ .disconnected = peer.handle });
        } else if (silence_ms > DEFAULT_DISCONNECT_NOTIFY_START_MS and !peer.notified) {
            peer.notified = true;
            self.callbacks.on_event(self.callbacks.ctx, .{ .network_interrupted = .{
                .player = peer.handle,
                .disconnect_timeout_ms = DEFAULT_DISCONNECT_TIMEOUT_MS,
            } });
        }
    }
}
```

## See also

- [data-structures.md](data-structures.md) — The full Zig implementation of every struct
  mentioned above
- [determinism.md](determinism.md) — How to write the sim that this algorithm runs on
- [network-protocol.md](network-protocol.md) — The wire format that feeds the InputQueues
- [time-sync.md](time-sync.md) — The frame-advantage averaging and sleep recommendation
