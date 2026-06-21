# Data structures for rollback netcode

This file is the implementation reference: the full Zig 0.16 code for the five core
structs of a rollback system. Lift these into your codebase, fill in the game-specific
bits (serialization, input format), and you have a working rollback layer.

## Table of contents

1. [`GameInput`](#gameinput)
2. [`InputQueue`](#inputqueue)
3. [`StateStore`](#statestore)
4. [`Session`](#session)
5. [`TimeSync`](#timesync)
6. [`UdpTransport`](#udptransport)
7. [`SessionCallbacks`](#sessioncallbacks)
8. [Putting it together](#putting-it-together)

## `GameInput`

A `GameInput` is the per-player, per-frame input value. It's a fixed-size byte array —
fixed because we need to packetize it and compare it byte-for-byte.

```zig
pub const MAX_INPUT_BYTES: u8 = 9;   // 72 bits — enough for a fightstick + extras

pub const GameInput = struct {
    frame: i32 = -1,
    bits: [MAX_INPUT_BYTES]u8 = [_]u8{0} ** MAX_INPUT_BYTES,

    pub fn eql(a: GameInput, b: GameInput) bool {
        return std.mem.eql(u8, &a.bits, &b.bits);
    }

    pub fn isPressed(self: GameInput, button: u8) bool {
        const byte_idx = button / 8;
        const bit_idx: u3 = @intCast(button % 8);
        return (self.bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
    }

    pub fn setPressed(self: *GameInput, button: u8) void {
        const byte_idx = button / 8;
        const bit_idx: u3 = @intCast(button % 8);
        self.bits[byte_idx] |= (@as(u8, 1) << bit_idx);
    }

    pub fn clearPressed(self: *GameInput, button: u8) void {
        const byte_idx = button / 8;
        const bit_idx: u3 = @intCast(button % 8);
        self.bits[byte_idx] &= ~(@as(u8, 1) << bit_idx);
    }
};
```

For most games, 9 bytes is overkill — a fighting game needs ~16 buttons (2 bytes), an NES
game needs 8 buttons (1 byte). The size is fixed at compile time so the wire format is
stable.

## `InputQueue`

Each player has one. Tracks confirmed + predicted inputs and the first incorrect frame.

```zig
pub const INPUT_QUEUE_LENGTH: u16 = 128;

pub const InputQueue = struct {
    io: std.Io,
    head: i32 = 0,                       // next frame to be added
    tail: i32 = 0,                       // oldest frame still in queue
    length: u16 = 0,
    first_incorrect_frame: i32 = -1,     // -1 = no known incorrect prediction
    last_added_frame: i32 = -1,
    prediction: ?GameInput = null,
    inputs: [INPUT_QUEUE_LENGTH]GameInput = [_]GameInput{.{}} ** INPUT_QUEUE_LENGTH,
    frame_delay: u8 = 0,

    pub fn init(io: std.Io) InputQueue {
        return .{ .io = io };
    }

    pub fn addInput(self: *InputQueue, input: GameInput) !void {
        const new_frame = self.head;

        // If we had a prediction for this frame, check correctness.
        if (self.prediction) |pred| {
            if (pred.eql(input)) {
                // Prediction was correct.
                if (self.first_incorrect_frame == new_frame) {
                    self.first_incorrect_frame = -1;
                }
            } else {
                // Prediction was wrong.
                if (self.first_incorrect_frame < 0 or new_frame < self.first_incorrect_frame) {
                    self.first_incorrect_frame = new_frame;
                }
            }
            self.prediction = null;
        }

        // Append at head.
        const idx = self.frameIndex(new_frame);
        self.inputs[idx] = input;
        self.inputs[idx].frame = new_frame;
        self.head = new_frame + 1;
        self.last_added_frame = new_frame;

        if (self.length < INPUT_QUEUE_LENGTH) {
            self.length += 1;
        } else {
            self.tail += 1;
        }
    }

    pub fn getInput(self: *InputQueue, frame: i32) !GameInput {
        if (frame >= self.head) {
            // Future frame — predict.
            if (self.prediction == null) {
                const last_idx = self.frameIndex(self.last_added_frame);
                self.prediction = self.inputs[last_idx];
                self.prediction.?.frame = frame;
                if (self.first_incorrect_frame < 0) {
                    self.first_incorrect_frame = self.last_added_frame + 1;
                }
            }
            return self.prediction.?;
        }
        if (frame < self.tail) return error.InputNotInQueue;
        return self.inputs[self.frameIndex(frame)];
    }

    pub fn firstIncorrectFrame(self: *const InputQueue) ?i32 {
        if (self.first_incorrect_frame < 0) return null;
        return self.first_incorrect_frame;
    }

    pub fn setFrameDelay(self: *InputQueue, delay: u8) void {
        self.frame_delay = delay;
    }

    fn frameIndex(self: *const InputQueue, frame: i32) usize {
        const signed_idx: i64 = @as(i64, frame) % INPUT_QUEUE_LENGTH;
        const unsigned_idx: u64 = @bitCast(signed_idx);
        return @intCast(unsigned_idx % INPUT_QUEUE_LENGTH);
    }
};
```

### Frame delay semantics

`setFrameDelay(N)` means "the local player's input is buffered for N frames before being
applied to the sim." This shifts the entire queue forward by N frames:

- Player presses a button at wall-clock time T.
- The input is recorded for frame `current_frame + N`.
- The sim applies the input at frame `current_frame + N`.

The purpose: shrink the prediction window for remote peers. If you have 2 frames of local
delay, the remote peer only needs to predict 2 fewer frames ahead.

## `StateStore`

A ring of `MAX_PREDICTION_FRAMES + 2 = 10` saved states.

```zig
pub const MAX_PREDICTION_FRAMES: u8 = 8;
pub const STATE_RING_SIZE: u8 = MAX_PREDICTION_FRAMES + 2;

pub const StateStore = struct {
    gpa: std.mem.Allocator,
    slots: [STATE_RING_SIZE]Slot = [_]Slot{.{}} ** STATE_RING_SIZE,

    const Slot = struct {
        frame: i32 = -1,
        buffer: ?[]u8 = null,
        checksum: u64 = 0,
    };

    pub fn init(gpa: std.mem.Allocator) StateStore {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *StateStore) void {
        for (&self.slots) |*slot| {
            if (slot.buffer) |buf| {
                self.gpa.free(buf);
                slot.buffer = null;
            }
        }
    }

    pub fn save(self: *StateStore, io: std.Io, frame: i32, ctx: *anyopaque,
                save_fn: *const fn(std.Io, *anyopaque, *std.ArrayList(u8)) anyerror!void) !void {
        const idx = self.frameIndex(frame);
        var slot = &self.slots[idx];

        // Serialize into a temporary buffer first.
        var tmp: std.ArrayList(u8) = .empty;
        tmp.initContext(self.gpa);
        defer tmp.deinit(self.gpa);

        try save_fn(io, ctx, &tmp);

        // Reuse or allocate the slot's buffer.
        if (slot.buffer) |old| {
            if (old.len < tmp.items.len) {
                self.gpa.free(old);
                slot.buffer = try self.gpa.dupe(u8, tmp.items);
            } else {
                @memcpy(old[0..tmp.items.len], tmp.items);
                slot.buffer = old[0..tmp.items.len];
            }
        } else {
            slot.buffer = try self.gpa.dupe(u8, tmp.items);
        }

        slot.frame = frame;
        slot.checksum = std.hash.Wyhash.hash(0, slot.buffer.?);
    }

    pub fn load(self: *StateStore, io: std.Io, frame: i32, ctx: *anyopaque,
                load_fn: *const fn(std.Io, *anyopaque, []const u8) anyerror!void) !void {
        const idx = self.frameIndex(frame);
        const slot = &self.slots[idx];
        if (slot.frame != frame) return error.StateNotFound;
        try load_fn(io, ctx, slot.buffer.?);
    }

    pub fn getChecksum(self: *StateStore, frame: i32) ?u64 {
        const idx = self.frameIndex(frame);
        const slot = &self.slots[idx];
        if (slot.frame != frame) return null;
        return slot.checksum;
    }

    fn frameIndex(self: *const StateStore, frame: i32) usize {
        const signed_idx: i64 = @as(i64, frame) % STATE_RING_SIZE;
        const unsigned_idx: u64 = @bitCast(signed_idx);
        return @intCast(unsigned_idx % STATE_RING_SIZE);
    }
};
```

The save/load functions are passed as parameters (function pointers) because the StateStore
itself doesn't know your game's serialization format. Your game implements
`saveGameState(io, &state, &buf)` and `loadGameState(io, &state, buf)` and passes them in.

## `Session`

The main entry point. Owns `InputQueue`s for each player, a `StateStore`, the network
transport, and the time sync.

```zig
pub const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    callbacks: SessionCallbacks,
    ctx: *anyopaque,                     // user data passed to callbacks

    num_players: u8,
    local_player: u8,
    inputs: [MAX_PLAYERS]InputQueue,
    states: StateStore,
    network: UdpTransport,
    time_sync: TimeSync,

    frame: i32 = 0,
    rolling_back: bool = false,
    synchronizing: bool = true,
    next_recommended_sleep: i32 = 0,

    pub const Init = struct {
        io: std.Io,
        gpa: std.mem.Allocator,
        callbacks: SessionCallbacks,
        ctx: *anyopaque,
        num_players: u8,
        local_player: u8,
        local_port: u16,
        remote_addrs: []const std.net.Address,
    };

    pub fn init(opts: Init) !Session {
        var s: Session = .{
            .io = opts.io,
            .gpa = opts.gpa,
            .callbacks = opts.callbacks,
            .ctx = opts.ctx,
            .num_players = opts.num_players,
            .local_player = opts.local_player,
            .inputs = undefined,
            .states = StateStore.init(opts.gpa),
            .network = try UdpTransport.init(opts.io, opts.gpa, opts.local_port, opts.remote_addrs),
            .time_sync = TimeSync.init(opts.io),
        };
        for (&s.inputs) |*q| q.* = InputQueue.init(opts.io);
        return s;
    }

    pub fn deinit(self: *Session) void {
        self.states.deinit();
        self.network.deinit(self.io);
    }

    pub fn advanceFrame(self: *Session, local_input: GameInput) !void {
        if (self.synchronizing) return error.NotSynced;

        // Phase 1: add local input (with delay).
        const delayed_frame = self.frame + self.inputs[self.local_player].frame_delay;
        var input = local_input;
        input.frame = delayed_frame;
        try self.inputs[self.local_player].addInput(input);

        // Phase 2: send to remote peers.
        try self.network.sendInput(self.io, delayed_frame, input);

        // Phase 3: poll network.
        try self.network.pump(self.io, self);

        // Phase 4: predict missing inputs.
        const frame_inputs = try self.collectInputs(self.frame);

        // Phase 5: save state.
        try self.states.save(self.io, self.gpa, self.frame, self.ctx, self.callbacks.save_game_state);

        // Phase 6: advance sim.
        try self.callbacks.advance_frame(self.ctx, &frame_inputs);
        self.frame += 1;

        // Phase 7: check for rollbacks.
        if (try self.findIncorrectFrame()) |wrong_frame| {
            try self.rollbackTo(wrong_frame);
        }

        // Phase 8: time sync.
        try self.time_sync.advanceFrame(self.frame, self.localFrameAdvantage());
    }

    pub fn idle(self: *Session, ms: u32) !void {
        try self.network.pump(self.io, self);
        try self.checkDisconnects();
        if (self.synchronizing) {
            try self.pollSync();
        }
        if (ms > 0) self.io.sleep(.{ .ms = ms });
    }

    pub fn addLocalInput(self: *Session, frame: i32, input: GameInput) !void {
        if (self.synchronizing) return error.NotSynced;
        if (frame < self.frame) return error.InvalidFrame;
        if (frame > self.frame + MAX_PREDICTION_FRAMES) return error.PredictionThreshold;

        const delayed = frame + self.inputs[self.local_player].frame_delay;
        var copy = input;
        copy.frame = delayed;
        try self.inputs[self.local_player].addInput(copy);
    }

    pub fn setFrameDelay(self: *Session, player: u8, delay: u8) !void {
        if (player >= self.num_players) return error.InvalidPlayer;
        self.inputs[player].setFrameDelay(delay);
    }

    // ----- Internal helpers -----

    fn collectInputs(self: *Session, frame: i32) ![MAX_PLAYERS]GameInput {
        var out: [MAX_PLAYERS]GameInput = undefined;
        for (0..self.num_players) |p| {
            out[p] = try self.inputs[p].getInput(frame);
        }
        return out;
    }

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

    fn rollbackTo(self: *Session, target_frame: i32) !void {
        self.rolling_back = true;
        defer self.rolling_back = false;

        // Load state from one frame before the incorrect frame.
        const load_frame = target_frame - 1;
        try self.states.load(self.io, load_frame, self.ctx, self.callbacks.load_game_state);
        self.frame = load_frame;

        // Reset incorrect-frame markers — they'll be re-set if prediction is still wrong.
        for (self.inputs[0..self.num_players]) |*q| {
            q.first_incorrect_frame = -1;
            q.prediction = null;
        }

        // Replay forward to where we were.
        const replay_to = self.frame + MAX_PREDICTION_FRAMES;
        while (self.frame <= replay_to) {
            const inputs = try self.collectInputs(self.frame);
            try self.states.save(self.io, self.gpa, self.frame, self.ctx, self.callbacks.save_game_state);
            try self.callbacks.advance_frame(self.ctx, &inputs);
            self.frame += 1;

            // Stop if no more incorrect frames remain.
            if (try self.findIncorrectFrame() == null) break;
        }
    }

    fn localFrameAdvantage(self: *Session) i32 {
        // Local frame - remote confirmed frame
        var min_remote: i32 = std.math.maxInt(i32);
        for (0..self.num_players) |p| {
            if (p == self.local_player) continue;
            const confirmed = self.inputs[p].last_added_frame;
            if (confirmed < min_remote) min_remote = confirmed;
        }
        if (min_remote == std.math.maxInt(i32)) return 0;
        return self.frame - min_remote;
    }
};
```

This is the core. Real implementations add: sync handshake (initial frame-0 negotiation),
spectator mode, configurable prediction cap, and event emission. But the algorithm above
is what makes rollback work.

## `TimeSync`

Averages frame advantage over a 40-frame window and emits sleep recommendations.

```zig
pub const TimeSync = struct {
    io: std.Io,
    local_advantage_history: [FRAME_WINDOW_SIZE]i32 = [_]i32{0} ** FRAME_WINDOW_SIZE,
    remote_advantage_history: [FRAME_WINDOW_SIZE]i32 = [_]i32{0} ** FRAME_WINDOW_SIZE,
    next: u8 = 0,
    last_recommendation_ms: i64 = 0,

    pub fn init(io: std.Io) TimeSync {
        return .{ .io = io };
    }

    pub fn advanceFrame(self: *TimeSync, frame: i32, local_advantage: i32) void {
        self.local_advantage_history[self.next] = local_advantage;
        self.remote_advantage_history[self.next] = -local_advantage;
        self.next = (self.next + 1) % FRAME_WINDOW_SIZE;
        _ = frame;
    }

    pub fn recommendSleep(self: *TimeSync) i32 {
        const now_ms = self.io.clock.now().ms;
        if (now_ms - self.last_recommendation_ms < RECOMMENDATION_INTERVAL_MS) return 0;
        self.last_recommendation_ms = now_ms;

        const local_avg = average(&self.local_advantage_history);
        const remote_avg = average(&self.remote_advantage_history);

        // Only recommend sleep if local is meaningfully ahead of remote.
        if (local_avg <= remote_avg) return 0;
        const sleep_frames = std.math.clamp(local_avg - MIN_FRAME_ADVANTAGE, 0, MAX_FRAME_ADVANTAGE);
        return @intCast(sleep_frames);
    }
};

fn average(xs: []const i32) i32 {
    var sum: i64 = 0;
    for (xs) |x| sum += x;
    return @intCast(@divTrunc(sum, @as(i64, @intCast(xs.len))));
}
```

When `recommendSleep` returns N, the app should sleep N frames (e.g., call
`ggpo_idle(io, N * 16)` instead of `ggpo_idle(io, 0)`). The sleep is cooperative — it just
gives the remote peer time to catch up.

## `UdpTransport`

The wire layer. Sends and receives UDP packets; doesn't try to be reliable.

```zig
pub const UdpTransport = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    socket: std.Io.Net.Udp.Socket,
    peers: []std.net.Address,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, local_port: u16,
                remote_addrs: []const std.net.Address) !UdpTransport {
        var net: std.Io.Net = .empty;
        net.initContext(io);
        const socket = try net.udpListen(io, .{ .port = local_port });
        const peers = try gpa.dupe(std.net.Address, remote_addrs);
        return .{ .io = io, .gpa = gpa, .socket = socket, .peers = peers };
    }

    pub fn deinit(self: *UdpTransport, io: std.Io) void {
        self.socket.close(io);
        self.gpa.free(self.peers);
    }

    pub fn sendInput(self: *UdpTransport, io: std.Io, frame: i32, input: GameInput,
                     queue: *const InputQueue) !void {
        // Pack the input + recent history into a packet and broadcast to all peers.
        var pkt = InputPacket{
            .header = .{ .start_frame = frame, .ack_frame = queue.last_added_frame },
            .input = input.bits,
        };
        // The history lets peers recover if a previous packet was lost.
        for (0..PACKET_HISTORY_BITS) |i| {
            const hist_frame = frame - @as(i32, @intCast(i));
            if (hist_frame >= queue.tail) {
                pkt.history[i] = queue.inputs[queue.frameIndex(hist_frame)].bits;
            }
        }
        for (self.peers) |addr| {
            try self.socket.sendTo(io, addr, std.mem.asBytes(&pkt));
        }
    }

    pub fn pump(self: *UdpTransport, io: std.Io, session: *Session) !void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.socket.receiveNonblocking(io, &buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            try self.handlePacket(io, session, buf[0..n]);
        }
    }

    fn handlePacket(self: *UdpTransport, io: std.Io, session: *Session, data: []const u8) !void {
        if (data.len < @sizeOf(PacketHeader)) return error.PacketTooSmall;
        const header = std.mem.bytesAsValue(PacketHeader, data[0..@sizeOf(PacketHeader)]);
        switch (header.kind) {
            .input => try self.handleInputPacket(io, session, data),
            .input_ack => try self.handleInputAck(io, session, data),
            .sync_request => try self.handleSyncRequest(io, session, data),
            .sync_reply => try self.handleSyncReply(io, session, data),
            .quality_report => try self.handleQualityReport(io, session, data),
            .keep_alive => {}, // just refresh last_recv
        }
    }
};
```

See [network-protocol.md](network-protocol.md) for the full packet format and the
reliability-via-repetition strategy.

## `SessionCallbacks`

The game-facing interface. Your game implements these and passes them to `Session.init`.

```zig
pub const SessionCallbacks = struct {
    begin_game: *const fn(ctx: *anyopaque, info: BeginGameInfo) anyerror!void,
    advance_frame: *const fn(ctx: *anyopaque, inputs: []const GameInput) anyerror!void,
    save_game_state: *const fn(io: std.Io, ctx: *anyopaque, out: *std.ArrayList(u8)) anyerror!void,
    load_game_state: *const fn(io: std.Io, ctx: *anyopaque, buf: []const u8) anyerror!void,
    free_buffer: *const fn(ctx: *anyopaque, buf: []u8) void,
    log_game_state: *const fn(ctx: *anyopaque, label: []const u8, inputs: []const GameInput) void,
    on_event: *const fn(ctx: *anyopaque, event: Event) void,
};

pub const Event = union(enum) {
    connected: struct { player: u8 },
    synchronizing: struct { player: u8, count: u32, total: u32 },
    synchronized: struct { player: u8 },
    disconnected: struct { player: u8 },
    network_interrupted: struct { player: u8, disconnect_timeout_ms: u32 },
    network_resumed: struct { player: u8 },
    timesync: struct { frames_ahead: u32 },
};

pub const BeginGameInfo = struct {
    game_name: []const u8,
};
```

Note: the original C++ GGPO lacks the `ctx: *anyopaque` parameter on callbacks — it uses a
global game-state pointer instead. Most serious downstream users fork GGPO to add the
parameter. See [ggpo-ffi.md](ggpo-ffi.md#the-missing-user_data-parameter).

## Putting it together

A minimal game using the above:

```zig
const std = @import("std");
const rollback = @import("rollback");

const Game = struct {
    io: std.Io,
    state: GameState,        // your sim state
    session: rollback.Session,

    pub fn main(init: std.process.Init) !void {
        const io = init.io;
        const gpa = init.gpa;

        var game = Game{
            .io = io,
            .state = GameState.init(),
            .session = try rollback.Session.init(.{
                .io = io,
                .gpa = gpa,
                .callbacks = .{
                    .begin_game = beginGame,
                    .advance_frame = advanceFrame,
                    .save_game_state = saveGameState,
                    .load_game_state = loadGameState,
                    .free_buffer = freeBuffer,
                    .log_game_state = logGameState,
                    .on_event = onEvent,
                },
                .ctx = undefined,   // set below
                .num_players = 2,
                .local_player = 0,
                .local_port = 7000,
                .remote_addrs = &.{try std.net.Address.parseIp("127.0.0.1", 7001)},
            }),
        };
        game.session.ctx = @ptrCast(&game);
        defer game.session.deinit();

        // Wait for sync.
        while (game.session.synchronizing) {
            try game.session.idle(16);
        }

        // Main loop.
        var last: std.Io.Timestamp = io.clock.now();
        while (true) {
            const now = io.clock.now();
            const dt = now.since(last);
            last = now;
            if (dt.ms >= 16) {
                const input = readLocalInput(io);
                try game.session.advanceFrame(input);
            } else {
                try game.session.idle(0);
            }
        }
    }
};
```

For a complete worked example, see [examples.md](examples.md).

## See also

- [algorithm.md](algorithm.md) — Why these structs are shaped this way
- [network-protocol.md](network-protocol.md) — Wire format
- [integration.md](integration.md) — Wiring into a real game loop
