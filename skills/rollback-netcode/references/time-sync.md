# Time synchronization: frame advantage and sleep recommendations

Rollback netcode is peer-to-peer: there's no server arbitrating frame timing. If one peer
runs faster than the other, they drift apart — the faster peer keeps predicting further
into the future, the slower peer keeps falling behind. Left unchecked, this would either
overflow the prediction window (`PREDICTION_THRESHOLD` error) or stall the slower peer.

TimeSync is the cooperative system that prevents this. It's not a clock-sync protocol —
both peers use their own local clock — it's a frame-advantage balancing system.

## Table of contents

1. [The problem](#the-problem)
2. [Frame advantage, defined](#frame-advantage-defined)
3. [The averaging window](#the-averaging-window)
4. [Sleep recommendations](#sleep-recommendations)
5. [Why it's cooperative](#why-its-cooperative)
6. [Adaptive input delay](#adaptive-input-delay)
7. [Tuning the constants](#tuning-the-constants)
8. [Spectator time sync](#spectator-time-sync)

## The problem

Two peers, both running at 60 FPS. Peer A's clock is 0.1% faster than B's. After 1 second,
A is 60 frames ahead of where it "should" be. After 10 seconds, A is 6 frames ahead —
which means A is predicting B's input 6 frames into the future on every frame.

After 100 seconds, A is 60 frames ahead — over `MAX_PREDICTION_FRAMES = 8`. A returns
`PREDICTION_THRESHOLD` from `addLocalInput` and the game stalls.

This is unacceptable. The fix: the faster peer slows down a tiny bit.

## Frame advantage, defined

For a 2-player session:

```text
local_advantage  = local_frame  - remote_confirmed_frame
remote_advantage = remote_frame - local_confirmed_frame
                  = -(local_advantage)    (approximately — small drift due to RTT)
```

If `local_advantage` is positive, we're ahead — we're predicting the remote peer's input
further into the future. If negative, we're behind — the remote peer is predicting us.

For an N-player session, you compute the minimum across all remote peers:

```zig
fn localFrameAdvantage(self: *Session) i32 {
    var min_remote: i32 = std.math.maxInt(i32);
    for (0..self.num_players) |p| {
        if (p == self.local_player) continue;
        const confirmed = self.inputs[p].last_added_frame;
        if (confirmed < min_remote) min_remote = confirmed;
    }
    if (min_remote == std.math.maxInt(i32)) return 0;
    return self.frame - min_remote;
}
```

If any peer is far behind, that's the binding constraint — we're predicting that peer the
furthest.

## The averaging window

A single frame-advantage measurement is noisy: it bounces ±2 frames due to network jitter.
TimeSync keeps a 40-frame rolling window (~666 ms at 60 FPS) and averages:

```zig
pub const TimeSync = struct {
    local_advantage_history: [FRAME_WINDOW_SIZE]i32 = [_]i32{0} ** FRAME_WINDOW_SIZE,
    remote_advantage_history: [FRAME_WINDOW_SIZE]i32 = [_]i32{0} ** FRAME_WINDOW_SIZE,
    next: u8 = 0,

    pub fn advanceFrame(self: *TimeSync, frame: i32, local_advantage: i32) void {
        self.local_advantage_history[self.next] = local_advantage;
        self.remote_advantage_history[self.next] = -local_advantage;
        self.next = (self.next + 1) % FRAME_WINDOW_SIZE;
        _ = frame;
    }

    pub fn localAdvantageAvg(self: *const TimeSync) i32 {
        return average(&self.local_advantage_history);
    }

    pub fn remoteAdvantageAvg(self: *const TimeSync) i32 {
        return average(&self.remote_advantage_history);
    }
};
```

The averaged value is much more stable — it doesn't react to a single packet's jitter, but
it does react to a sustained drift.

## Sleep recommendations

When `local_advantage_avg > remote_advantage_avg + MIN_FRAME_ADVANTAGE`, TimeSync emits a
`timesync` event recommending that the app sleep a few frames on the next idle call:

```zig
pub fn recommendSleep(self: *TimeSync) u32 {
    const now_ms = self.io.clock.now().ms;
    if (now_ms - self.last_recommendation_ms < RECOMMENDATION_INTERVAL_MS) return 0;
    self.last_recommendation_ms = now_ms;

    const local = self.localAdvantageAvg();
    const remote = self.remoteAdvantageAvg();

    // Only recommend sleep if we're meaningfully ahead of remote.
    if (local <= remote + MIN_FRAME_ADVANTAGE) return 0;

    // Sleep enough to bring us back to remote + MIN_FRAME_ADVANTAGE.
    const sleep_frames = @as(u32, @intCast(std.math.clamp(
        local - remote - MIN_FRAME_ADVANTAGE,
        0,
        MAX_FRAME_ADVANTAGE,
    )));
    return sleep_frames;
}
```

The app responds:

```zig
fn gameLoop(self: *Game) !void {
    while (true) {
        const sleep_frames = self.session.time_sync.recommendSleep();
        const sleep_ms = sleep_frames * 16;   // ~16ms per frame at 60 FPS

        try self.session.idle(sleep_ms);

        // Only advance the sim if we're not sleeping.
        if (sleep_frames == 0) {
            const input = readLocalInput(self.io);
            try self.session.advanceFrame(input);
        }
    }
}
```

The result: the faster peer voluntarily sleeps ~16ms every few seconds, bringing its
frame-advantage back to the target range. The slower peer doesn't sleep at all and
catches up.

## Why it's cooperative

A natural question: why not just forcibly stall the faster peer (refuse to call
`advanceFrame` until the remote catches up)?

Two reasons:

1. **Player experience.** Forcibly stalling produces visible hitches — the local player's
   input suddenly stops responding. Cooperative sleep is gentler: the sleep is spread
   across multiple idle calls, and the player rarely notices.

2. **Mid-combo preservation.** If the local player is in the middle of a combo and the
   remote peer momentarily falls behind, forcibly stalling would interrupt the combo.
   Cooperative sleep checks whether the local player has been idle (recent inputs are
   empty) and only recommends sleep when it won't disrupt gameplay:

```zig
pub fn recommendSleep(self: *TimeSync) u32 {
    // Don't recommend sleep if the local player is actively inputting.
    if (self.localPlayerIsActive()) return 0;
    // ... rest of the recommendation logic ...
}
```

This is subtle — GGPO's actual implementation tracks the last 10 inputs and only
recommends sleep when they're all "neutral." For a fighting game, this means we sleep
during the idle frames between combos, never during the combo itself.

## Adaptive input delay

The above is "soft" time sync: cooperative sleep. There's also "hard" time sync:
adaptive input delay. The idea: if the network is bad, increase the local input delay so
the prediction window is shorter and rollbacks are less frequent.

```zig
pub fn adaptInputDelay(self: *Session) !void {
    const ping_ms = self.network.pingMs();
    const target_delay: u8 = switch (ping_ms) {
        0...50   => 0,
        51...100 => 1,
        101...150 => 2,
        151...250 => 3,
        else     => 4,
    };
    if (target_delay != self.current_input_delay) {
        try self.setFrameDelay(self.local_player, target_delay);
        self.current_input_delay = target_delay;
        self.callbacks.on_event(self.ctx, .{
            .input_delay_changed = .{ .frames = target_delay },
        });
    }
}
```

This is **controversial** in fighting-game circles. Increasing input delay mid-match
changes how the game feels, which skilled players notice and hate. Most modern fighting
games either:
- Use a fixed input delay set in the menu (player chooses).
- Use a per-match delay negotiated at handshake (no mid-match changes).

GGPO's default is fixed delay, changed only between matches.

## Tuning the constants

The three constants matter:

| Constant                  | Default | Effect of increasing                          |
|---------------------------|---------|-----------------------------------------------|
| `FRAME_WINDOW_SIZE`       | 40      | Smoother averaging but slower reaction time   |
| `MIN_FRAME_ADVANTAGE`     | 3       | Sleep later (more jitter tolerance)           |
| `MAX_FRAME_ADVANTAGE`     | 9       | Sleep longer when triggered (more aggressive) |
| `RECOMMENDATION_INTERVAL_MS` | 240  | Less frequent recommendations (less responsive)|

### For low-latency LAN play

```zig
pub const FRAME_WINDOW_SIZE: u8 = 20;        // 333 ms
pub const MIN_FRAME_ADVANTAGE: i32 = 1;
pub const MAX_FRAME_ADVANTAGE: i32 = 4;
pub const RECOMMENDATION_INTERVAL_MS: u32 = 100;
```

LAN rarely needs time sync at all — both peers run at the same speed. The smaller window
reacts faster to the rare drift event.

### For high-latency transcontinental play

```zig
pub const FRAME_WINDOW_SIZE: u8 = 60;        // 1 second
pub const MIN_FRAME_ADVANTAGE: i32 = 4;
pub const MAX_FRAME_ADVANTAGE: i32 = 12;
pub const RECOMMENDATION_INTERVAL_MS: u32 = 500;
```

Transcontinental play has high jitter; the larger window absorbs it. The higher
`MIN_FRAME_ADVANTAGE` means we tolerate more drift before sleeping (because sleeping
itself adds visible input delay).

### Defaults for fighting games

GGPO's defaults (`FRAME_WINDOW_SIZE=40`, `MIN=3`, `MAX=9`) are well-tuned for
transcontinental fighting-game play (US east-west, EU-US). Don't change them without
testing across a range of connections.

## Spectator time sync

Spectators are pure receivers: they don't produce inputs, so they can't be "ahead" in the
input sense. But they can still drift in wall-clock time — if the spectator's machine is
slower, it falls behind the broadcast.

For spectators, TimeSync uses a different metric: **render queue depth**. The broadcaster
sends frames as fast as it produces them; the spectator buffers them and renders at 60
FPS. If the buffer is growing, the spectator is too slow and should skip frames. If it's
emptying, the spectator should sleep.

```zig
fn spectatorTimeSync(self: *Spectator) u32 {
    const queue_depth = self.frame_queue.len;
    if (queue_depth > 10) return 0;            // we're behind — don't sleep
    if (queue_depth < 3) return 8;             // we're ahead — sleep 8ms
    return 0;
}
```

This is much simpler than peer time sync. Spectator mode is essentially a video stream —
if the spectator falls behind, they just skip frames; there's no input to drop.

## Common pitfalls

### Forgetting to call `time_sync.advanceFrame`

The averaging window needs to be updated every frame. If you only call it occasionally,
the average is over a stale window and the recommendations are wrong.

### Calling `recommendSleep` more often than `RECOMMENDATION_INTERVAL_MS`

The rate limit exists to prevent sleep thrashing — sleeping 1 frame, then 0, then 1,
then 0. The 240ms interval ensures we sleep at most ~4 times per second.

### Using frame advantage as a stall trigger

```zig
// BAD — forcibly stalling breaks gameplay
if (local_advantage > 5) {
    return;   // don't advance this frame
}
```

This produces visible hitches. Always use cooperative sleep via `recommendSleep`.

### Ignoring spectator time sync

A spectator that's too slow will fall behind and the broadcast will grow unbounded.
Always cap the buffer and skip frames if needed:

```zig
fn spectatorLoop(self: *Spectator) !void {
    while (true) {
        try self.network.pump(self.io);
        while (self.frame_queue.len > 30) {
            _ = self.frame_queue.orderedRemove(0);   // drop oldest
        }
        if (self.frame_queue.len > 0) {
            const frame = self.frame_queue.orderedRemove(0);
            try self.renderFrame(frame);
        }
        self.io.sleep(.{ .ms = 16 });
    }
}
```

## See also

- [algorithm.md](algorithm.md#frame-advantage) — Where frame advantage fits in the loop
- [integration.md](integration.md) — Wiring `recommendSleep` into your game loop
- [network-protocol.md](network-protocol.md#quality-reports-and-frame-advantage) — How
  frame advantage is communicated between peers
