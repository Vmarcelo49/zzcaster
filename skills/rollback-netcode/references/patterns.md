# Production patterns for rollback netcode

This is the cookbook: production patterns that don't fit in the algorithm reference. Each
pattern is motivated by a real bug, performance issue, or operability concern seen in
shipped games.

## Table of contents

1. [State serialization strategies](#state-serialization-strategies)
2. [Save ring sizing](#save-ring-sizing)
3. [Input compression](#input-compression)
4. [Disconnect handling UX](#disconnect-handling-ux)
5. [Spectator mode](#spectator-mode)
6. [Reconnection](#reconnection)
7. [Matchmaking and peer discovery](#matchmaking-and-peer-discovery)
8. [Stats and telemetry](#stats-and-telemetry)
9. [Debug overlays](#debug-overlays)
10. [Backward compatibility](#backward-compatibility)

## State serialization strategies

The fastest serialization is "memcpy the whole struct." This works if:

1. Your state is one contiguous struct.
2. No pointers (use generational indices instead).
3. No padding (use `extern struct`).
4. No variable-length data.

```zig
const GameState = extern struct {
    frame: i32,
    entities: [MAX_ENTITIES]Entity,
    bullets: [MAX_BULLETS]Bullet,
    rng_state: [32]u8,    // raw PRNG state
};

fn serialize(state: *const GameState, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(std.mem.asBytes(state));
}

fn deserialize(state: *GameState, buf: []const u8) !void {
    @memcpy(std.mem.asBytes(state), buf);
}
```

For a 100-entity fighting game with 64 bytes per entity, the state is ~7 KB. Saving 10 of
them (the ring size) is 70 KB — fits in L2 cache, snapshots in microseconds.

### When memcpy doesn't work

If your state has:
- Pointers (you're using raw pointers instead of indices)
- Variable-length data (dynamic arrays)
- Computed fields that shouldn't be saved

...then you need a real serializer. The simplest pattern:

```zig
fn serialize(state: *const GameState, w: anytype) !void {
    try w.writeInt(i32, state.frame, .little);
    try w.writeInt(u32, state.entity_count, .little);
    for (state.entities[0..state.entity_count]) |e| {
        try serializeEntity(w, e);
    }
}

fn serializeEntity(w: anytype, e: Entity) !void {
    try w.writeInt(i32, e.x.v, .little);
    try w.writeInt(i32, e.y.v, .little);
    try w.writeInt(i32, e.vx.v, .little);
    try w.writeInt(i32, e.vy.v, .little);
    try w.writeInt(u8, @intFromEnum(e.state), .little);
    try w.writeInt(u8, e.health, .little);
    // etc.
}
```

Don't reach for a serialization library. Hand-roll it. You get:
- Determinism (no library quirks).
- Speed (no reflection overhead).
- Small code size.
- Clear documentation of what's saved.

### Avoiding drift between save and load

A common bug: add a field to `GameState`, update `serialize`, forget `deserialize`. Now
load reads garbage.

Mitigation: a single function that lists every field, used by both:

```zig
fn forEachField(state: anytype, comptime visitor: anytype) !void {
    try visitor.field("frame", &state.frame);
    try visitor.field("entity_count", &state.entity_count);
    for (state.entities[0..state.entity_count]) |*e| {
        try forEachEntityField(e, visitor);
    }
}

const Serializer = struct {
    w: *std.ArrayList(u8),

    pub fn field(self: Serializer, comptime name: []const u8, v: anytype) !void {
        _ = name;
        const T = @TypeOf(v.*);
        if (@typeInfo(T) == .int) {
            try self.w.appendSlice(std.mem.asBytes(&v.*));
        } else {
            @compileError("Unsupported field type: " ++ @typeName(T));
        }
    }
};

const Deserializer = struct {
    r: *[]const u8,

    pub fn field(self: Deserializer, comptime name: []const u8, v: anytype) !void {
        _ = name;
        const T = @TypeOf(v.*);
        if (@typeInfo(T) == .int) {
            @memcpy(std.mem.asBytes(&v.*), self.r[0..@sizeOf(T)]);
            self.r.* = self.r.*[@sizeOf(T)..];
        } else {
            @compileError("Unsupported field type: " ++ @typeName(T));
        }
    }
};

fn serialize(state: *const GameState, w: *std.ArrayList(u8)) !void {
    try forEachField(state, Serializer{ .w = w });
}

fn deserialize(state: *GameState, buf: *[]const u8) !void {
    try forEachField(state, Deserializer{ .r = buf });
}
```

The field list is defined once; save and load can't drift.

## Save ring sizing

The default `MAX_PREDICTION_FRAMES + 2 = 10` is right for most games. Increase it if:

- Your network has high jitter (>50ms) — peers may fall further behind.
- You allow large input delay (>5 frames) — the prediction window can grow.
- Your game has long replay chains (rare).

Decrease it if:

- Memory is tight (embedded target).
- Your state is very large (>1 MB) — 10 snapshots is 10 MB.

Don't go below 4 — that leaves no room for prediction, and any packet loss will trigger
`PREDICTION_THRESHOLD`.

### Pre-allocating the save buffers

```zig
const StateStore = struct {
    slots: [STATE_RING_SIZE]Slot,
    preallocated_buffer: []u8,    // single big buffer, sliced into slots

    pub fn init(gpa: std.mem.Allocator, max_state_size: usize) !StateStore {
        const total = STATE_RING_SIZE * max_state_size;
        const buf = try gpa.alloc(u8, total);

        var slots: [STATE_RING_SIZE]Slot = undefined;
        for (&slots, 0..) |*slot, i| {
            slot.* = .{
                .frame = -1,
                .buffer = buf[i * max_state_size .. (i + 1) * max_state_size],
                .checksum = 0,
            };
        }

        return .{ .slots = slots, .preallocated_buffer = buf };
    }

    pub fn deinit(self: *StateStore, gpa: std.mem.Allocator) void {
        gpa.free(self.preallocated_buffer);
    }
};
```

This avoids per-frame allocation entirely — the buffers are carved out of one big
allocation at startup. The slot's `buffer` field is a slice into this big buffer; the
save function writes into it directly.

## Input compression

For most games, inputs are small enough that compression isn't worth it. But for:

- Games with many players (4+) — each player's input is sent to every other.
- Games on metered connections (mobile data).
- Games with very high packet rates (120+ FPS).

...compression can cut bandwidth significantly.

### Bit-packing

A fighting game has ~16 buttons per player, packed into 2 bytes. Sending the full 2 bytes
every frame at 60 FPS is 120 bytes/sec per peer. Trivial.

A real-time strategy game has 64+ unit commands per frame, often with coordinates. 64
commands × 8 bytes each = 512 bytes per frame, 30 KB/sec. Worth compressing.

Strategy: bit-pack commands into a compact format:

```zig
const PackedCommand = packed struct {
    unit_id: u16,    // up to 65536 units
    command: u4,     // 16 possible commands
    target_x: u12,   // 0..4095
    target_y: u12,   // 0..4095
    // total: 44 bits = 5.5 bytes — fits in 6 bytes (with 4 bits padding)
};

fn packCommand(cmd: Command) [6]u8 {
    const packed_cmd: PackedCommand = .{
        .unit_id = cmd.unit_id,
        .command = @intFromEnum(cmd.kind),
        .target_x = @intCast(cmd.target.x),
        .target_y = @intCast(cmd.target.y),
    };
    return std.mem.toBytes(packed_cmd);
}
```

### Delta compression

If most frames have empty input (player is idle), send a 1-bit "no input" flag instead of
the full input:

```zig
fn sendInput(io: std.Io, frame: i32, input: GameInput, last_input: GameInput) !void {
    if (input.eql(last_input)) {
        // Send a 1-byte "same as last" packet.
        const pkt = SameInputPacket{ .header = ..., .frame = frame };
        try socket.sendTo(io, addr, std.mem.asBytes(&pkt));
    } else {
        // Send the full input.
        try sendFullInput(io, frame, input);
    }
}
```

For a fighting game where 80% of frames are "no input," this cuts bandwidth 5x.

## Disconnect handling UX

The default UX is bad: the game freezes for 5 seconds, then kicks the player. Better:

```zig
fn onEvent(ctx: *anyopaque, event: rollback.Event) void {
    const game: *Game = @ptrCast(@alignCast(ctx));
    switch (event) {
        .network_interrupted => |info| {
            // Show a "Player 2 disconnected..." banner immediately.
            game.ui.showBanner("Player 2 disconnected — waiting for reconnect...", .{
                .timeout_ms = info.disconnect_timeout_ms,
            });
            // Continue predicting. If they come back, no harm done.
        },
        .network_resumed => {
            game.ui.hideBanner();
        },
        .disconnected => |info| {
            game.ui.showModal("Player 2 has left the match. Return to menu?", .{
                .buttons = .{ .ok = "Return", .cancel = "Watch AI" },
            });
        },
        else => {},
    }
}
```

Key principles:
- **Show the interruption immediately.** Don't wait for the hard 5-second timeout.
- **Keep simulating during the interruption.** Predict the missing peer's input.
- **On reconnect, accept the rollback.** The state may snap, but the match continues.
- **On hard disconnect, ask the player.** Don't auto-quit — they may want to fight the AI.

## Spectator mode

Spectators receive all inputs and run the sim, but produce no inputs. Implementation:

```zig
pub const SpectatorSession = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    callbacks: SessionCallbacks,
    ctx: *anyopaque,
    inputs: [MAX_PLAYERS]InputQueue,
    states: StateStore,
    frame: i32 = 0,
    broadcaster_addr: std.net.Address,
    socket: std.Io.Net.Udp.Socket,

    pub fn advanceFrame(self: *SpectatorSession) !void {
        // Pump network — receive inputs from broadcaster.
        try self.pumpNetwork();

        // If we have all inputs for the current frame, advance.
        if (self.haveAllInputs(self.frame)) {
            const inputs = try self.collectInputs(self.frame);
            try self.states.save(self.io, self.gpa, self.frame, self.ctx, self.callbacks.save_game_state);
            try self.callbacks.advance_frame(self.ctx, &inputs);
            self.frame += 1;
        }

        // If we're falling behind, skip frames.
        if (self.frame_buffer.len > 30) {
            self.frame += 1;   // drop a frame to catch up
        }
    }
};
```

The broadcaster (one of the players, or a dedicated relay) sends every input packet to the
spectator in addition to the other player. Bandwidth: 2x the player bandwidth per
spectator. For 4-player matches with 32 spectators, that's 64x the player bandwidth —
usually too much. Use a relay server for large spectator counts.

### Spectator time sync

Spectators don't have frame advantage — they're receivers. Instead, they manage a
**frame queue**:

- If the queue is growing, the spectator is too slow. Skip frames.
- If the queue is emptying, the spectator is too fast. Sleep.

```zig
fn spectatorLoop(self: *SpectatorSession) !void {
    while (true) {
        try self.pumpNetwork();

        const queue_depth = self.pending_frames.len;
        if (queue_depth > 30) {
            // Drop 1 frame
            _ = self.pending_frames.orderedRemove(0);
        }

        if (self.pending_frames.len > 0) {
            const frame = self.pending_frames.orderedRemove(0);
            try self.advanceFrameWithInputs(frame);
        }

        if (queue_depth < 3) {
            self.io.sleep(.{ .ms = 8 });
        }
    }
}
```

## Reconnection

If a peer disconnects briefly (network hiccup), can they rejoin? GGPO's original answer
is "no — start a new session." Modern implementations support reconnection:

```zig
const ReconnectableSession = struct {
    session: Session,
    pending_inputs: std.ArrayList(TimestampedInput),  // inputs from remote while they were gone
    last_known_remote_frame: i32,

    fn onNetworkInterrupted(self: *ReconnectableSession) void {
        // Don't kill the session. Just stop expecting inputs.
        self.session.peers[1].expecting_inputs = false;
    }

    fn onNetworkResumed(self: *ReconnectableSession, remote_frame: i32) !void {
        // The remote peer is back. Their frame counter may have advanced
        // (if they kept simulating locally) or stayed (if they paused).
        // Negotiate the new starting frame.
        const new_frame = @max(self.session.frame, remote_frame);

        // Rewind if needed.
        if (new_frame < self.session.frame) {
            try self.session.states.load(self.session.io, new_frame, &self.session.game_state);
            self.session.frame = new_frame;
        }

        // Drain pending inputs.
        for (self.pending_inputs.items) |input| {
            try self.session.inputs[1].addInput(input);
        }
        self.pending_inputs.clearRetainingCapacity();
    }
};
```

Reconnection is hard. The remote peer's state may have diverged (they kept simulating
while disconnected). You have to either:
- Accept the divergence and let rollback fix it.
- Force a state sync (serialize the host's state, send to the rejoining peer, both
  resume from there).

For competitive games, the latter is safer. For casual games, the former is fine.

## Matchmaking and peer discovery

GGPO doesn't include matchmaking — you have to bring your own. Options:

1. **Direct connect.** Player A tells player B their IP, B connects. Works on LAN, painful
   on the public internet (NAT).
2. **Matchmaking server.** A central server pairs players and gives them each other's IPs.
   Players connect P2P; the server is only involved in pairing.
3. **Relay.** A central server forwards packets between players. Adds latency, works
   through any NAT.

For a small game, a simple matchmaking server is fine:

```zig
// Server: maintains a queue of waiting players, pairs them on connect.
// Client: connects to server, requests match, gets paired peer IP.

fn requestMatch(io: std.Io, gpa: std.mem.Allocator, server_addr: std.net.Address) !std.net.Address {
    var net: std.Io.Net = .empty;
    net.initContext(io);
    var conn = try net.tcpConnect(io, .{ .address = server_addr });
    defer conn.close(io);

    var w = conn.writer(io, &buf);
    try w.print("MATCH\n", .{});
    try w.flush();

    var r = conn.reader(io, &buf);
    const line = (try r.takeDelimiter('\n')).?;
    // line format: "MATCHED <ip>:<port>"
    var it = std.mem.splitScalar(u8, line, ' ');
    _ = it.next();   // "MATCHED"
    const addr_str = it.next() orelse return error.MalformedResponse;
    return try std.net.Address.parseIp(addr_str, 0);
}
```

For Fightcade-style matchmaking, you also need to handle: friend lists, lobbies, ranked
matching, region preference. That's a separate skill.

## Stats and telemetry

Track per-match stats so you can tune the algorithm:

```zig
const MatchStats = struct {
    frames_played: u32 = 0,
    rollbacks: u32 = 0,
    frames_rolled_back: u32 = 0,
    packets_sent: u32 = 0,
    packets_received: u32 = 0,
    packets_lost: u32 = 0,         // estimated from ack gaps
    ping_ms_avg: u32 = 0,
    ping_ms_p99: u32 = 0,
    input_delay_frames: u8 = 0,
    desyncs: u32 = 0,

    fn record(self: *MatchStats, session: *const Session) void {
        self.frames_played = session.frame;
        self.rollbacks = session.rollback_count;
        self.frames_rolled_back = session.frames_rolled_back;
        // ... etc
    }

    fn log(self: *const MatchStats, io: std.Io) void {
        io.out().print(
            "match: frames={d} rollbacks={d} rolled_back={d} loss={d:.2}% ping={d}ms\n",
            .{ self.frames_played, self.rollbacks, self.frames_rolled_back,
               @as(f32, @floatFromInt(self.packets_lost)) / @as(f32, @floatFromInt(self.packets_sent)) * 100.0,
               self.ping_ms_avg },
        ) catch {};
    }
};
```

Send these to your telemetry backend (anonymized). After 1000 matches you'll have enough
data to tune: are rollbacks too frequent? Is ping p99 too high? Should you bump input
delay?

## Debug overlays

For development, ship a debug overlay:

```zig
const DebugOverlay = struct {
    session: *const Session,
    visible: bool = false,

    fn draw(self: *DebugOverlay, ui: *Ui) void {
        if (!self.visible) return;

        ui.begin("Rollback Debug");
        defer ui.end();

        ui.text("Frame: {d}", .{self.session.frame});
        ui.text("Rollbacks: {d}", .{self.session.rollback_count});
        ui.text("Frames rolled back: {d}", .{self.session.frames_rolled_back});
        ui.text("Ping: {d}ms", .{self.session.network.ping_ms});

        for (self.session.inputs[0..self.session.num_players], 0..) |q, i| {
            ui.text("Player {d}:", .{i});
            ui.text("  last_added: {d}", .{q.last_added_frame});
            ui.text("  first_incorrect: {any}", .{q.first_incorrect_frame});
            ui.text("  prediction: {any}", .{q.prediction != null});
        }

        ui.separator();
        for (self.session.states.slots) |slot| {
            if (slot.frame >= 0) {
                ui.text("  slot: frame={d} checksum=0x{x}", .{slot.frame, slot.checksum});
            }
        }
        ui.end();
    }
};
```

Toggle with a hotkey. When players report "the game felt laggy," ask them to enable the
overlay and send a screenshot.

## Backward compatibility

If you ship versioned updates, you may need to support old versions in netplay. Strategies:

1. **Strict version matching.** Both peers must be on the same version. Simple but
   fragments the player base.
2. **Sim-only version matching.** Both peers must agree on the sim version, but the
   network protocol can be forward-compatible. Old clients can spectate new sims.
3. **Schema versioning.** Save states include a version number. New peers can load old
   save states; old peers reject new ones.

For most games, (1) is fine — players update quickly, and matching across versions is
rare. For long-lived games (fighting games that get balance patches), (3) is necessary.

```zig
const SAVE_STATE_VERSION: u32 = 3;

fn serialize(state: *const GameState, w: *std.ArrayList(u8)) !void {
    try w.appendSlice(std.mem.asBytes(&SAVE_STATE_VERSION));
    // ... write fields ...
}

fn deserialize(state: *GameState, buf: []const u8) !void {
    var cursor = buf;
    const version = std.mem.readInt(u32, cursor[0..4], .little);
    cursor = cursor[4..];

    switch (version) {
        1 => try deserializeV1(state, cursor),
        2 => try deserializeV2(state, cursor),
        3 => try deserializeV3(state, cursor),
        else => return error.UnsupportedSaveStateVersion,
    }
}
```

If you change the sim's behavior, the save state version must bump — otherwise old
recordings will desync when replayed on the new version.

## See also

- [data-structures.md](data-structures.md) — The structs these patterns layer on
- [integration.md](integration.md) — Fitting these into your game loop
- [testing.md](testing.md) — Testing all of this
