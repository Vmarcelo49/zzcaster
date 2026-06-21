# Worked examples: Pong and a 4-player brawler

Two complete, runnable examples that exercise the full rollback stack. The code is
illustrative — you'll need to fill in platform-specific bits (rendering, input) — but the
rollback machinery is real.

## Table of contents

1. [Example 1: 2-player Pong](#example-1-2-player-pong)
2. [Example 1: The game state](#example-1-the-game-state)
3. [Example 1: Save and load](#example-1-save-and-load)
4. [Example 1: The seven callbacks](#example-1-the-seven-callbacks)
5. [Example 1: Main loop](#example-1-main-loop)
6. [Example 1: SyncTest](#example-1-synctest)
7. [Example 2: 4-player brawler](#example-2-4-player-brawler)
8. [Example 2: Entity pool](#example-2-entity-pool)
9. [Example 2: Collision detection](#example-2-collision-detection)
10. [Example 2: Spectator support](#example-2-spectator-support)

## Example 1: 2-player Pong

The simplest possible rollback game: two paddles, one ball, first to 11 points wins.

### Why Pong

- Tiny state (~100 bytes) — save/load is trivial.
- Deterministic — physics is just addition and bouncing.
- Two players — minimal InputQueue setup.
- Visually obvious when rollback happens (the ball "snaps").

### The game state

```zig
const std = @import("std");
const rollback = @import("rollback");

const PongState = extern struct {
    frame: i32 = 0,
    ball_x: Fixed,
    ball_y: Fixed,
    ball_vx: Fixed,
    ball_vy: Fixed,
    paddle_left_y: Fixed,
    paddle_right_y: Fixed,
    score_left: u8 = 0,
    score_right: u8 = 0,
    rng_state: [32]u8 = std.mem.zeroes([32]u8),  // PRNG state for serves

    const WIDTH: Fixed = Fixed.fromInt(320);
    const HEIGHT: Fixed = Fixed.fromInt(240);
    const PADDLE_HEIGHT: Fixed = Fixed.fromInt(40);
    const PADDLE_WIDTH: Fixed = Fixed.fromInt(8);
    const BALL_RADIUS: Fixed = Fixed.fromInt(4);
    const PADDLE_SPEED: Fixed = Fixed.fromInt(4);
    const BALL_SPEED: Fixed = Fixed.fromInt(3);

    pub fn init() PongState {
        var s: PongState = .{
            .ball_x = Fixed.div(WIDTH, Fixed.fromInt(2)),
            .ball_y = Fixed.div(HEIGHT, Fixed.fromInt(2)),
            .ball_vx = BALL_SPEED,
            .ball_vy = BALL_SPEED,
            .paddle_left_y = Fixed.div(HEIGHT, Fixed.fromInt(2)),
            .paddle_right_y = Fixed.div(HEIGHT, Fixed.fromInt(2)),
        };
        // Seed the PRNG identically on both peers.
        s.rng_state = std.mem.zeroes([32]u8);
        return s;
    }

    pub fn advance(self: *PongState, inputs: []const rollback.GameInput) void {
        // Move paddles based on inputs.
        if (inputs[0].isPressed(BUTTON_UP)) {
            self.paddle_left_y = Fixed.sub(self.paddle_left_y, PADDLE_SPEED);
        }
        if (inputs[0].isPressed(BUTTON_DOWN)) {
            self.paddle_left_y = Fixed.add(self.paddle_left_y, PADDLE_SPEED);
        }
        if (inputs[1].isPressed(BUTTON_UP)) {
            self.paddle_right_y = Fixed.sub(self.paddle_right_y, PADDLE_SPEED);
        }
        if (inputs[1].isPressed(BUTTON_DOWN)) {
            self.paddle_right_y = Fixed.add(self.paddle_right_y, PADDLE_SPEED);
        }

        // Clamp paddles.
        self.paddle_left_y = clamp(self.paddle_left_y, PADDLE_HEIGHT, Fixed.sub(HEIGHT, PADDLE_HEIGHT));
        self.paddle_right_y = clamp(self.paddle_right_y, PADDLE_HEIGHT, Fixed.sub(HEIGHT, PADDLE_HEIGHT));

        // Move ball.
        self.ball_x = Fixed.add(self.ball_x, self.ball_vx);
        self.ball_y = Fixed.add(self.ball_y, self.ball_vy);

        // Bounce off top/bottom.
        if (self.ball_y.v < BALL_RADIUS.v) {
            self.ball_y.v = BALL_RADIUS.v;
            self.ball_vy.v = -self.ball_vy.v;
        }
        if (self.ball_y.v > Fixed.sub(HEIGHT, BALL_RADIUS).v) {
            self.ball_y.v = Fixed.sub(HEIGHT, BALL_RADIUS).v;
            self.ball_vy.v = -self.ball_vy.v;
        }

        // Bounce off paddles.
        if (self.ball_vx.v < 0 and self.ball_x.v < Fixed.add(PADDLE_WIDTH, BALL_RADIUS).v) {
            const paddle_top = Fixed.sub(self.paddle_left_y, Fixed.div(PADDLE_HEIGHT, Fixed.fromInt(2)));
            const paddle_bot = Fixed.add(self.paddle_left_y, Fixed.div(PADDLE_HEIGHT, Fixed.fromInt(2)));
            if (self.ball_y.v >= paddle_top.v and self.ball_y.v <= paddle_bot.v) {
                self.ball_vx.v = -self.ball_vx.v;
                // Add some english based on where it hit.
                const offset = Fixed.sub(self.ball_y, self.paddle_left_y);
                self.ball_vy = Fixed.add(self.ball_vy, Fixed.div(offset, Fixed.fromInt(4)));
            }
        }
        // (Same for right paddle — omitted for brevity.)

        // Score.
        if (self.ball_x.v < 0) {
            self.score_right += 1;
            self.resetBall();
        }
        if (self.ball_x.v > WIDTH.v) {
            self.score_left += 1;
            self.resetBall();
        }

        self.frame += 1;
    }

    fn resetBall(self: *PongState) void {
        self.ball_x = Fixed.div(WIDTH, Fixed.fromInt(2));
        self.ball_y = Fixed.div(HEIGHT, Fixed.fromInt(2));
        // Random direction using the seeded PRNG.
        var prng = std.Random.DefaultPrng.init(@intCast(std.mem.readInt(u64, self.rng_state[0..8], .little)));
        const r = prng.random();
        self.ball_vx = if (r.boolean()) BALL_SPEED : Fixed.sub(Fixed.ZERO, BALL_SPEED);
        self.ball_vy = if (r.boolean()) BALL_SPEED : Fixed.sub(Fixed.ZERO, BALL_SPEED);
        // Update PRNG state.
        const new_seed = prng.random().int(u64);
        std.mem.writeInt(u64, self.rng_state[0..8], new_seed, .little);
    }
};

fn clamp(x: Fixed, lo: Fixed, hi: Fixed) Fixed {
    if (x.v < lo.v) return lo;
    if (x.v > hi.v) return hi;
    return x;
}

const BUTTON_UP: u8 = 0;
const BUTTON_DOWN: u8 = 1;
```

Note:
- All physics uses `Fixed`, never `f32`.
- The PRNG state is part of the game state — saved and loaded with everything else.
- The state is an `extern struct` with no padding, so it can be memcpy'd.

### Save and load

Because the state is an `extern struct` with no pointers, save/load is just memcpy:

```zig
fn saveGameState(io: std.Io, ctx: *anyopaque, out: *std.ArrayList(u8)) !void {
    _ = io;
    const state: *const PongState = @ptrCast(@alignCast(ctx));
    try out.appendSlice(std.mem.asBytes(state));
}

fn loadGameState(io: std.Io, ctx: *anyopaque, buf: []const u8) !void {
    _ = io;
    const state: *PongState = @ptrCast(@alignCast(ctx));
    if (buf.len != @sizeOf(PongState)) return error.WrongStateSize;
    @memcpy(std.mem.asBytes(state), buf);
}
```

That's it. No serializer, no field-by-field copy.

### The seven callbacks

```zig
fn beginGame(ctx: *anyopaque, info: rollback.BeginGameInfo) !void {
    _ = ctx;
    _ = info;
    // Nothing to do — state is initialized at startup.
}

fn advanceFrame(ctx: *anyopaque, inputs: []const rollback.GameInput) !void {
    const state: *PongState = @ptrCast(@alignCast(ctx));
    state.advance(inputs);
}

fn saveGameStateCb(io: std.Io, ctx: *anyopaque, out: *std.ArrayList(u8)) !void {
    try saveGameState(io, ctx, out);
}

fn loadGameStateCb(io: std.Io, ctx: *anyopaque, buf: []const u8) !void {
    try loadGameState(io, ctx, buf);
}

fn freeBuffer(ctx: *anyopaque, buf: []u8) void {
    _ = ctx;
    // We use ArrayList which manages its own memory; nothing to free here.
    _ = buf;
}

fn logGameState(ctx: *anyopaque, label: []const u8, inputs: []const rollback.GameInput) void {
    const state: *const PongState = @ptrCast(@alignCast(ctx));
    std.debug.print("[{s}] frame={d} ball=({d},{d}) score={d}-{d}\n", .{
        label, state.frame, state.ball_x.toInt(), state.ball_y.toInt(),
        state.score_left, state.score_right,
    });
    _ = inputs;
}

fn onEvent(ctx: *anyopaque, event: rollback.Event) void {
    _ = ctx;
    switch (event) {
        .connected => |info| std.debug.print("Player {d} connected\n", .{info.player}),
        .synchronizing => |info| std.debug.print("Syncing player {d}: {d}/{d}\n", .{info.player, info.count, info.total}),
        .synchronized => |info| std.debug.print("Player {d} synced\n", .{info.player}),
        .disconnected => |info| std.debug.print("Player {d} disconnected\n", .{info.player}),
        .network_interrupted => |info| std.debug.print("Player {d} network interrupted\n", .{info.player}),
        .network_resumed => |info| std.debug.print("Player {d} network resumed\n", .{info.player}),
        .timesync => |info| std.debug.print("TimeSync: sleep {d} frames\n", .{info.frames_ahead}),
    }
}
```

### Main loop

```zig
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var state = PongState.init();

    const args = try std.process.argsAlloc(init.gpa);
    defer std.process.argsFree(init.gpa, args);

    const local_player: u8 = if (args.len > 1 and std.mem.eql(u8, args[1], "--host")) 0 else 1;
    const local_port: u16 = if (local_player == 0) 7000 else 7001;
    const remote_port: u16 = if (local_player == 0) 7001 else 7000;

    var session = try rollback.Session.init(.{
        .io = io,
        .gpa = gpa,
        .callbacks = .{
            .begin_game = beginGame,
            .advance_frame = advanceFrame,
            .save_game_state = saveGameStateCb,
            .load_game_state = loadGameStateCb,
            .free_buffer = freeBuffer,
            .log_game_state = logGameState,
            .on_event = onEvent,
        },
        .ctx = @ptrCast(&state),
        .num_players = 2,
        .local_player = local_player,
        .local_port = local_port,
        .remote_addrs = &.{try std.net.Address.parseIp("127.0.0.1", remote_port)},
    });
    defer session.deinit();

    // Wait for sync.
    while (session.synchronizing) {
        try session.idle(16);
    }

    // Main loop.
    var last_frame_time: std.Io.Timestamp = io.clock.now();
    const target_frame_ms: u32 = 16;

    while (state.score_left < 11 and state.score_right < 11) {
        const now = io.clock.now();
        const elapsed = now.since(last_frame_time).ms;
        last_frame_time = now;

        if (elapsed >= target_frame_ms) {
            // Read local input.
            var input: rollback.GameInput = .{};
            if (isKeyPressed(.w)) input.setPressed(BUTTON_UP);
            if (isKeyPressed(.s)) input.setPressed(BUTTON_DOWN);

            try session.advanceFrame(input);
        } else {
            try session.idle(0);
        }

        renderPong(&state);
    }

    io.out().print("Final score: {d}-{d}\n", .{state.score_left, state.score_right}) catch {};
}
```

`isKeyPressed` and `renderPong` are platform-specific — fill them in with your favorite
windowing library.

### SyncTest

```zig
test "pong sync test, 10000 frames" {
    const gpa = std.testing.allocator;
    var io_state = std.testing.io;
    const io = &io_state.io;

    var state = PongState.init();

    var sync_test = rollback.SyncTest.init(.{
        .io = io,
        .gpa = gpa,
        .callbacks = .{
            .begin_game = beginGame,
            .advance_frame = advanceFrame,
            .save_game_state = saveGameStateCb,
            .load_game_state = loadGameStateCb,
            .free_buffer = freeBuffer,
            .log_game_state = logGameState,
            .on_event = onEvent,
        },
        .ctx = @ptrCast(&state),
        .num_players = 2,
        .check_distance = 1,
        .seed = 0xdeadbeef,
    });
    defer sync_test.deinit();

    for (0..10000) |_| {
        try sync_test.advanceFrame();
    }
}
```

If this test ever fails, Pong's `advance` function is non-deterministic. Fix it before
shipping.

## Example 2: 4-player brawler

A more realistic example: four players, dynamic entities (projectiles, hitboxes),
generational indices for entity handles.

### Game state

```zig
const BrawlerState = struct {
    frame: i32 = 0,
    prng: std.Random.DefaultPrng,
    players: [4]Player,
    projectiles: ProjectilePool,
    hitboxes: HitboxPool,
    match_time_ms: u32 = 0,

    const MAX_PROJECTILES: u32 = 64;
    const MAX_HITBOXES: u32 = 128;

    pub fn init() BrawlerState {
        return .{
            .prng = std.Random.DefaultPrng.init(0xfeedface),
            .players = [_]Player{.{}} ** 4,
            .projectiles = ProjectilePool.init(),
            .hitboxes = HitboxPool.init(),
        };
    }

    pub fn advance(self: *BrawlerState, inputs: []const rollback.GameInput) void {
        // Update players.
        for (&self.players, 0..) |*p, i| {
            p.advance(inputs[i], self);
        }

        // Update projectiles.
        self.projectiles.updateAll(self);

        // Update hitboxes.
        self.hitboxes.updateAll(self);

        // Resolve collisions.
        self.resolveCollisions();

        self.frame += 1;
        self.match_time_ms += 16;
    }
};

const Player = struct {
    pos: Vec2 = .{ .x = Fixed.ZERO, .y = Fixed.ZERO },
    vel: Vec2 = .{ .x = Fixed.ZERO, .y = Fixed.ZERO },
    facing: i8 = 1,
    health: i16 = 100,
    state: PlayerState = .idle,
    state_timer: u8 = 0,
    attack_id: u8 = 0,    // incremented each new attack — for hitbox dedup

    fn advance(self: *Player, input: rollback.GameInput, game: *BrawlerState) void {
        switch (self.state) {
            .idle => self.advanceIdle(input, game),
            .attacking => self.advanceAttacking(game),
            .hit_stun => self.advanceHitStun(),
            .knocked_down => self.advanceKnockedDown(),
        }
    }

    fn advanceIdle(self: *Player, input: rollback.GameInput, game: *BrawlerState) void {
        // Movement
        const speed: Fixed = Fixed.fromInt(3);
        if (input.isPressed(BUTTON_LEFT)) {
            self.vel.x = Fixed.sub(Fixed.ZERO, speed);
            self.facing = -1;
        } else if (input.isPressed(BUTTON_RIGHT)) {
            self.vel.x = speed;
            self.facing = 1;
        } else {
            self.vel.x = Fixed.ZERO;
        }

        if (input.isPressed(BUTTON_JUMP)) {
            self.vel.y = Fixed.fromInt(8);
        }

        // Apply velocity
        self.pos.x = Fixed.add(self.pos.x, self.vel.x);
        self.pos.y = Fixed.add(self.pos.y, self.vel.y);
        // Gravity
        self.vel.y = Fixed.sub(self.vel.y, Fixed.fromInt(1) catch unreachable);

        if (input.isPressed(BUTTON_ATTACK) and self.state_timer == 0) {
            self.state = .attacking;
            self.state_timer = 12;   // 12 frames of attack
            self.attack_id +%= 1;
            // Spawn a hitbox
            game.hitboxes.spawn(.{
                .owner = self.handle,
                .pos = self.pos,
                .offset_x = Fixed.mul(Fixed.fromInt(self.facing), Fixed.fromInt(20)),
                .radius = Fixed.fromInt(15),
                .lifetime = 4,
                .attack_id = self.attack_id,
            });
        }
    }
};

const Vec2 = struct {
    x: Fixed,
    y: Fixed,
};

const PlayerState = enum {
    idle,
    attacking,
    hit_stun,
    knocked_down,
};
```

### Entity pool

Projectiles use a generational-index pool:

```zig
const ProjectilePool = struct {
    slots: [BrawlerState.MAX_PROJECTILES]Slot = undefined,
    free_list: [BrawlerState.MAX_PROJECTILES]u32 = undefined,
    free_count: u32 = 0,

    const Slot = struct {
        generation: u32 = 0,
        alive: bool = false,
        projectile: Projectile = .{},
    };

    pub fn init() ProjectilePool {
        var p: ProjectilePool = undefined;
        for (&p.slots) |*s| s.* = .{};
        for (0..BrawlerState.MAX_PROJECTILES) |i| {
            p.free_list[i] = @intCast(BrawlerState.MAX_PROJECTILES - 1 - i);
        }
        p.free_count = BrawlerState.MAX_PROJECTILES;
        return p;
    }

    pub fn spawn(self: *ProjectilePool, proj: Projectile) ?ProjectileId {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const idx = self.free_list[self.free_count];
        const slot = &self.slots[idx];
        slot.generation +%= 1;
        slot.alive = true;
        slot.projectile = proj;
        return .{ .index = idx, .generation = slot.generation };
    }

    pub fn despawn(self: *ProjectilePool, id: ProjectileId) void {
        const slot = &self.slots[id.index];
        if (slot.generation != id.generation) return;
        slot.alive = false;
        self.free_list[self.free_count] = id.index;
        self.free_count += 1;
    }

    pub fn updateAll(self: *ProjectilePool, game: *BrawlerState) void {
        for (&self.slots) |*slot| {
            if (!slot.alive) continue;
            slot.projectile.update(game);
            if (slot.projectile.lifetime == 0) {
                slot.alive = false;
                self.free_list[self.free_count] = @intCast(@intFromPtr(slot) - @intFromPtr(&self.slots[0]));
                self.free_count += 1;
            }
        }
    }
};

const ProjectileId = struct {
    index: u32,
    generation: u32,
};

const Projectile = struct {
    pos: Vec2 = .{ .x = Fixed.ZERO, .y = Fixed.ZERO },
    vel: Vec2 = .{ .x = Fixed.ZERO, .y = Fixed.ZERO },
    lifetime: u8 = 60,
    damage: u8 = 10,
    owner: u8 = 0,

    fn update(self: *Projectile, _: *BrawlerState) void {
        self.pos.x = Fixed.add(self.pos.x, self.vel.x);
        self.pos.y = Fixed.add(self.pos.y, self.vel.y);
        self.lifetime -|= 1;
    }
};
```

The hitbox pool is similar — fixed capacity, generational indices, no per-frame allocation.

### Collision detection

```zig
fn resolveCollisions(self: *BrawlerState) void {
    // For each alive hitbox, check intersection with each player (except owner).
    for (self.hitboxes.slots) |*hb_slot| {
        if (!hb_slot.alive) continue;
        const hb = hb_slot.hitbox;

        for (&self.players, 0..) |*player, i| {
            if (i == hb.owner) continue;
            if (player.state == .hit_stun) continue;   // already hit

            const dx = Fixed.sub(player.pos.x, Fixed.add(hb.pos.x, hb.offset_x));
            const dy = Fixed.sub(player.pos.y, hb.pos.y);
            const dist_sq = Fixed.add(Fixed.mul(dx, dx), Fixed.mul(dy, dy));
            const radius_sum = Fixed.add(hb.radius, Fixed.fromInt(20));   // player radius 20

            if (dist_sq.v < Fixed.mul(radius_sum, radius_sum).v) {
                // Hit!
                player.health -= hb.damage;
                player.state = .hit_stun;
                player.state_timer = 20;
                // Apply knockback
                player.vel.x = Fixed.mul(Fixed.fromInt(hb.knockback_x), Fixed.fromInt(@as(i32, if (hb.pos.x.v < player.pos.x.v) 1 else -1)));
                player.vel.y = Fixed.fromInt(hb.knockback_y);

                // Despawn the hitbox (single-hit)
                self.hitboxes.despawn(.{ .index = ..., .generation = ... });
            }
        }
    }
}
```

Key points:
- No allocation in collision detection.
- Iteration over a fixed array — order is deterministic.
- `Fixed` everywhere — no floating-point nondeterminism.
- `player.attack_id` ensures the same hitbox can't hit the same player twice.

### Spectator support

For 4-player matches with spectators, use a relay:

```zig
const Relay = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    socket: std.Io.Net.Udp.Socket,
    spectators: std.ArrayList(std.net.Address),

    pub fn broadcastInput(self: *Relay, frame: i32, input: rollback.GameInput) !void {
        const pkt = InputPacket{
            .header = .{ .magic = 0xFEED, .kind = .input, .seq = ... },
            .start_frame = frame,
            .ack_frame = -1,
            .bytes_per_input = rollback.MAX_INPUT_BYTES,
            .num_inputs = 1,
            .input_bits = input.bits,
            .history = undefined,
        };
        for (self.spectators.items) |addr| {
            try self.socket.sendTo(self.io, addr, std.mem.asBytes(&pkt));
        }
    }
};
```

The relay runs on the host player's machine (or a separate VPS). It receives inputs from
all 4 players and forwards them to all spectators.

For large spectator counts (100+), use a tree topology: the host broadcasts to 4 relay
nodes, each relay broadcasts to 25 spectators. This avoids the host's bandwidth becoming
the bottleneck.

### SyncTest

```zig
test "brawler sync test, 5000 frames, 4 players" {
    const gpa = std.testing.allocator;
    var io_state = std.testing.io;
    const io = &io_state.io;

    var state = BrawlerState.init();

    var sync_test = rollback.SyncTest.init(.{
        .io = io, .gpa = gpa,
        .callbacks = brawlerCallbacks(),
        .ctx = @ptrCast(&state),
        .num_players = 4,
        .check_distance = 1,
        .seed = 0xbrawler42,
    });
    defer sync_test.deinit();

    for (0..5000) |_| {
        try sync_test.advanceFrame();
    }
}
```

5000 frames is ~83 seconds of game time. Plenty to catch most determinism bugs.

If this passes, you're ready to try a real network test with two processes.

## See also

- [data-structures.md](data-structures.md) — The structs used above
- [determinism.md](determinism.md) — Why every choice above was made
- [integration.md](integration.md) — How to wire these into a real game loop
- [testing.md](testing.md) — More test patterns
