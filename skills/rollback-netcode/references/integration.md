# Integrating rollback into a game loop

Rollback doesn't run in isolation — it has to fit into your game's main loop alongside
rendering, audio, input polling, and asset loading. This file covers the frame budget
math, the rendering strategy for rollbacks, audio handling, and the input polling cadence.

## Table of contents

1. [The frame budget](#the-frame-budget)
2. [The integrated loop](#the-integrated-loop)
3. [Rendering after a rollback](#rendering-after-a-rollback)
4. [Audio handling](#audio-handling)
5. [Input polling cadence](#input-polling-cadence)
6. [Asset loading during play](#asset-loading-during-play)
7. [Pause and menu states](#pause-and-menu-states)
8. [Variable refresh rate displays](#variable-refresh-rate-displays)
9. [Multi-window editors and tools](#multi-window-editors-and-tools)

## The frame budget

At 60 FPS you have **16.67 ms per frame**. Rollback eats into this budget:

| Phase                                 | Typical cost    |
|---------------------------------------|-----------------|
| Network pump (receive packets)        | 0.1-0.5 ms      |
| Add local input + send to remote      | 0.05 ms         |
| Predict missing remote inputs         | 0.01 ms         |
| Save state                            | 0.05-0.5 ms     |
| Advance sim                           | 0.5-3 ms        |
| Rollback check + replay (when triggered) | 0.5-5 ms     |
| Time sync                             | 0.01 ms         |
| Render                                | 2-8 ms          |
| Present (vsync)                       | 0-16 ms         |

Total without rollback: ~3-12 ms. Total with rollback: ~4-17 ms. You have headroom, but
not much — a single 10ms rollback replay will eat most of your frame.

### At 120 FPS or 144 FPS

If you're targeting high refresh rates, the budget is much tighter:

- 120 FPS: 8.3 ms per frame
- 144 FPS: 6.9 ms per frame
- 240 FPS: 4.2 ms per frame

Rollback at these rates is challenging because the rollback replay itself takes time. Two
strategies:

1. **Run the sim at 60 FPS, render at 120/144/240.** The sim stays on its 16.67ms budget;
   the renderer interpolates between sim frames. This is the standard approach.
2. **Run the sim at the display refresh rate.** The sim is faster, the rollback window is
   shorter in milliseconds (but same in frames), and the network protocol needs to handle
   the higher packet rate. Possible but rarely worth it.

For fighting games, 60 FPS is the canonical rate — the genre is built around 1-frame
links and 3-frame startup moves, and changing the rate breaks the design.

## The integrated loop

```zig
pub fn run(self: *Game) !void {
    const io = self.io;
    var last_frame_time: std.Io.Timestamp = io.clock.now();
    const target_frame_ms: u32 = 16;   // 60 FPS

    while (self.running) {
        const now = io.clock.now();
        const elapsed_ms = now.since(last_frame_time).ms;
        last_frame_time = now;

        // Accumulate elapsed time. Only advance the sim when we've accrued
        // at least one frame's worth.
        self.accumulator_ms += elapsed_ms;

        // Cap the accumulator to prevent "spiral of death" after a stall.
        if (self.accumulator_ms > 5 * target_frame_ms) {
            self.accumulator_ms = 5 * target_frame_ms;
        }

        // ----- Phase 1: Network pump (always run, even if we don't advance) -----
        try self.session.idle(0);

        // ----- Phase 2: Simulate (possibly multiple frames if we're behind) -----
        while (self.accumulator_ms >= target_frame_ms) {
            self.accumulator_ms -= target_frame_ms;

            // Read local input.
            const input = try self.readLocalInput();

            // Check time sync — might tell us to skip this frame.
            const sleep_frames = self.session.time_sync.recommendSleep();
            if (sleep_frames > 0) {
                // Skip simulating this frame; the sleep brings us back into sync.
                self.skipped_frames += 1;
                continue;
            }

            // Advance the sim. This may trigger a rollback internally.
            try self.session.advanceFrame(input);
            self.last_simulated_frame = self.session.frame;
        }

        // ----- Phase 3: Render -----
        // Render the current state. If a rollback just happened, the state may have
        // changed since the last render; we render the corrected state.
        try self.render(self.last_simulated_frame);

        // ----- Phase 4: Present -----
        try self.present();

        // ----- Phase 5: Yield if we have time left -----
        const frame_used_ms = io.clock.now().since(now).ms;
        if (frame_used_ms < target_frame_ms) {
            const remaining = target_frame_ms - frame_used_ms;
            io.sleep(.{ .ms = remaining });
        }
    }
}
```

### The accumulator

The accumulator pattern decouples wall-clock time from sim time. If the renderer stalls
for 33ms (one frame's worth of vsync skip), the accumulator will trigger two sim advances
in a row. If the renderer is fast (5ms), the accumulator stays at zero and we don't sim.

This is the standard "fix your timestep" pattern. It's important for rollback because the
sim must run at exactly 60 FPS regardless of the display refresh rate.

### The "spiral of death"

If the sim itself takes longer than 16ms (e.g. heavy rollback), the accumulator grows.
Each frame, we sim more times to catch up, which takes longer, which makes the accumulator
grow more, which... spirals.

The cap `if (self.accumulator_ms > 5 * target_frame_ms)` breaks the spiral by accepting
slowdown. The sim drops frames instead of spiraling. Better than hanging.

## Rendering after a rollback

When a rollback happens, the sim state changes mid-frame. By the time we render, the
state is the corrected one — which is what we want. The player sees the corrected state
on the very next frame.

But there's a subtle issue: if the renderer caches anything from the previous frame's
state (e.g. positions for motion blur), that cache is now stale. The renderer must
re-derive everything from the current sim state.

### Don't cache sim state in the renderer

```zig
// BAD — cached positions are wrong after a rollback
const Renderer = struct {
    cached_positions: []Vec3,

    fn render(self: *Renderer, sim: *const Sim) void {
        // Use cached_positions, update every N frames
    }
};

// GOOD — always read from the sim
const Renderer = struct {
    fn render(self: *Renderer, sim: *const Sim) void {
        for (sim.entities) |e| {
            self.drawEntity(e);
        }
    }
};
```

The renderer should be a pure function of the sim state. No caching of sim-derived data.

### Visual interpolation for high refresh rates

If you're rendering at 120 FPS but simulating at 60 FPS, you have 2 render frames per sim
frame. The naive approach renders the same state twice, which looks choppy.

Interpolate between the previous and current sim states:

```zig
fn render(self: *Game, alpha: f32) !void {
    // alpha is 0..1 — how far between previous and current sim frame we are
    for (self.sim.entities, self.prev_sim.entities) |cur, prev| {
        const interp_pos = lerp(prev.pos, cur.pos, alpha);
        try self.drawEntityAt(interp_pos, cur.sprite);
    }
}
```

This requires keeping the previous sim state around. With rollback, "previous" is the
state before the most recent advance — which is the same as the saved state in the
StateStore. Read it from there.

```zig
fn render(self: *Game, alpha: f32) !void {
    const prev_state = self.session.states.get(self.session.frame - 1) orelse {
        // First frame — no previous state.
        try self.renderState(&self.sim, alpha);
        return;
    };
    try self.renderInterpolated(prev_state, &self.sim, alpha);
}
```

### Rollback visual snapping

If a rollback changes the state significantly (e.g. a remote character teleports 2 meters
because their predicted position was wrong), the player will see a visual snap. Mitigations:

1. **Smooth the snap.** Lerp the visual position toward the corrected position over 2-3
   frames. This is purely visual — the sim state is already corrected.
2. **Accept it.** At 60 FPS with a 2-4 frame rollback window, snaps are usually
   imperceptible. Smoothing adds complexity and can hide bugs.
3. **Reduce the prediction window.** Adding 1-2 frames of input delay shrinks the
   prediction window and reduces snap severity.

Most modern fighting games just accept the snap. It's rarely noticeable.

## Audio handling

Audio is tricky because it's time-sensitive — once a sound starts playing, you can't
"un-play" it. If the sim rolls back and the new state shows a different event, the audio
for the old event is already playing.

### Strategy: queue audio with a delay

Buffer audio events for ~100ms before playing them. If a rollback happens within that
window, cancel the queued events:

```zig
const AudioManager = struct {
    pending: std.ArrayList(PendingSound),

    fn queueEvent(self: *AudioManager, event: SoundEvent) !void {
        try self.pending.append(.{
            .event = event,
            .play_at_ms = self.io.clock.now().ms + 100,
        });
    }

    fn pump(self: *AudioManager, current_frame: i32) !void {
        // Cancel any pending events that were queued from a frame that's no longer
        // in the sim's history (i.e. they were rolled back).
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const p = self.pending.items[i];
            if (p.frame > current_frame) {
                // This was queued from a future frame that got rolled back.
                _ = self.pending.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Play any events whose time has come.
        const now_ms = self.io.clock.now().ms;
        i = 0;
        while (i < self.pending.items.len) {
            if (self.pending.items[i].play_at_ms <= now_ms) {
                try self.play(self.pending.items[i].event);
                _ = self.pending.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
};
```

This adds 100ms of audio latency, which is barely perceptible. The payoff: audio never
plays for events that were rolled back.

### Strategy: just accept the stale audio

For non-critical sounds (footsteps, ambient), just play them as they happen. If a
rollback cancels the event, the audio is already playing — but it's a footstep, who
cares.

For critical sounds (hit impacts, voice lines), use the queue strategy.

### Music

Music doesn't depend on sim state — just play it on a separate clock. Don't tie music to
the frame counter; tie it to wall-clock time.

## Input polling cadence

Poll input **once per frame**, not once per render. The sim uses the polled input; the
renderer doesn't need it.

```zig
fn readLocalInput(self: *Game) !GameInput {
    var input: GameInput = .{};
    // Poll keyboard / gamepad state.
    if (self.input.isPressed(.up))    input.setPressed(BUTTON_UP);
    if (self.input.isPressed(.down))  input.setPressed(BUTTON_DOWN);
    if (self.input.isPressed(.left))  input.setPressed(BUTTON_LEFT);
    if (self.input.isPressed(.right)) input.setPressed(BUTTON_RIGHT);
    if (self.input.isPressed(.a))     input.setPressed(BUTTON_A);
    if (self.input.isPressed(.b))     input.setPressed(BUTTON_B);
    return input;
}
```

### Polling at the OS level

Most OSes buffer input events and let you poll the current state. This is what you want —
you don't care about events that happened between frames, you care about the state at
the moment of polling.

If you need event-level precision (e.g. "the button was pressed and released within the
same frame"), use an event queue:

```zig
fn pumpInputEvents(self: *Game) !void {
    while (self.io.input.poll()) |event| {
        try self.input_events.append(event);
    }
}

fn readLocalInput(self: *Game) !GameInput {
    var input: GameInput = .{};
    for (self.input_events.items) |event| {
        switch (event) {
            .key_down => |k| input.setPressed(buttonFor(k)),
            .key_up => |k| input.clearPressed(buttonFor(k)),
        }
    }
    self.input_events.clearRetainingCapacity();
    return input;
}
```

### Input lag from the OS

OS-level input has its own lag:
- Windows: ~2 frames if "mouse keys" are enabled, ~1 frame otherwise.
- macOS: ~1 frame.
- Linux X11: ~2-3 frames depending on compositor.
- Linux Wayland: ~1 frame.

For competitive fighting games, players often use tools to reduce this (e.g. raw input
mode, disabling compositors). Your game can't control this; just document it.

## Asset loading during play

**Never load assets inside `advance_frame`.** Disk I/O has unpredictable latency and
isn't deterministic. Load all assets at startup or during a loading screen.

If you must stream assets during play (e.g. open-world), do it on a background thread
outside the sim:

```zig
const AssetLoader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    pending: std.ArrayList(PendingLoad),
    group: Io.Group,

    fn request(self: *AssetLoader, path: []const u8) !void {
        _ = try self.io.async(self.group, loadAsset, .{ self.io, self.gpa, path });
    }

    fn pump(self: *AssetLoader) !void {
        // Check completed loads and apply them to the renderer.
        // Don't touch the sim.
    }
};

fn loadAsset(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var cwd: std.Io.Dir = .cwd(io);
    defer cwd.close(io);
    return cwd.readFileAlloc(io, gpa, path, 1 << 20);
}
```

Apply loaded assets to the renderer between sim frames, never inside `advance_frame`.

## Pause and menu states

When the player pauses the game, you have two choices:

1. **Pause the sim, not just the rendering.** Both peers stop advancing frames. The
   network keeps sending KeepAlive packets to maintain the connection. When unpaused,
   resume from the same frame.
2. **Keep the sim running, freeze the local input.** The local player's input becomes
   "neutral" while paused, but the remote peer keeps playing. This is what most fighting
   games do during the pause menu — you can't pause online play.

For menus (character select, options), use a separate game state that's not under
rollback. Rollback is for the in-match sim only.

```zig
const GameState = union(enum) {
    menu: MenuState,
    match: MatchState,   // this is what rollback serializes

    fn advance(self: *GameState, inputs: []const GameInput) !void {
        switch (self.*) {
            .menu => |*m| try m.advance(inputs),
            .match => |*m| try m.advance(inputs),
        }
    }

    fn serialize(self: *const GameState, w: anytype) !void {
        // Only serialize the match state — menus aren't part of rollback.
        switch (self.*) {
            .menu => return error.CannotSerializeMenu,
            .match => |m| try m.serialize(w),
        }
    }
};
```

## Variable refresh rate displays

VRR (G-Sync, FreeSync) displays can run at any refresh rate from ~30 to ~144 Hz. The
display matches the frame production rate.

For rollback, VRR is mostly fine — your sim still runs at 60 FPS, the display just
presents each frame as soon as it's ready. The only concern: if the sim stalls (e.g.
heavy rollback), the display's refresh rate drops, which can confuse time sync.

Mitigation: use the accumulator pattern from [the integrated loop](#the-integrated-loop).
The accumulator decouples sim time from wall time, so display refresh rate doesn't affect
the sim.

## Multi-window editors and tools

If your game has an editor mode (e.g. a level editor) with multiple windows, rollback
shouldn't be running. Editors typically:

- Pause the sim.
- Allow direct state manipulation (no determinism required).
- Run a separate "play" mode that re-enables rollback.

In Zig 0.16, you can use `Io.Dispatch` for the editor (manually pumped) and switch to
`Io.Threaded` for play mode. The sim code is the same; only the Io changes.

## See also

- [data-structures.md](data-structures.md) — The structs that fit into this loop
- [time-sync.md](time-sync.md) — How `recommendSleep` is computed
- [determinism.md](determinism.md) — What can and can't run inside `advance_frame`
