const std = @import("std");
const logging = @import("logging.zig");
const net = @import("net.zig");

// Use the shared ENet cimport from net.zig (see comment there).
const enet = net.enet;

// ============================================================================
// SpectatorManager — spectator chain forwarding (host-side).
//
// In the GGPO model, spectators are "just more players" — they're peers
// who don't contribute inputs of their own but receive both players'
// inputs every frame and re-simulate the match.
//
// In our DLL-resident ENet topology:
//   * The host's hook.dll owns the ENet host (already created for the
//     main peer in NetplayManager.initEnet).
//   * Spectators connect to the same ENet host but on a separate channel
//     (channel 2) so we can demux them from the main peer.
//   * When a new peer connects, the host either:
//       - Accepts it as a spectator (if spectator_count < MAX_ROOT_SPECTATORS
//         on a relay host, or < MAX_SPECTATORS on a chain spectator).
//       - Sends a REDIRECT:<addr>:<port> reliable message and disconnects,
//         so the would-be spectator reconnects to an existing spectator
//         (this is the chain forwarding from legacy SpectatorManager).
//
// PER-FRAME FLOW (host side, called from NetplayManager.frameStep)
//   spec_mgr.frameStepSpectators(indexed_frame, both_inputs_buf):
//     1. For each connected spectator, advance its `pos` to the next batch.
//     2. Send a BothInputs packet covering [pos..pos+NUM_INPUTS) frames.
//     3. Optionally send RNG state / state transitions (reliable).
// ============================================================================

pub const max_spectators: usize = 15;
pub const max_root_spectators: usize = 1;
pub const num_inputs_per_packet: u32 = 30;
pub const pending_timeout_ms: u64 = 20000;

pub const SpectatorState = enum {
    pending,    // TCP-accepted but no first message yet
    active,     // receiving inputs
    redirecting, // sent REDIRECT, awaiting disconnect
};

pub const Spectator = struct {
    peer: ?*enet.ENetPeer = null,
    state: SpectatorState = .pending,
    accepted_at_ms: i64 = 0,

    // The next indexed frame to send to this spectator. Starts at the
    // match start; advances by NUM_INPUTS each broadcast.
    pos_frame: u32 = 0,
    pos_index: u32 = 0,

    // One-time flags per round
    sent_rng_state: bool = false,
    sent_initial_state: bool = false,

    // Spectator's external address (for redirect advertisement)
    redirect_addr: [64]u8 = [_]u8{0} ** 64,
    redirect_port: u16 = 0,
};

pub const SpectatorManager = struct {
    allocator: std.mem.Allocator,
    // Zig 0.16: std.crypto.random.intRangeLessThan is gone — we keep our
    // own PRNG (Xoshiro256) seeded once from io.random() and reuse it.
    prng: std.Random.Xoshiro256,
    log: *logging.Logger,
    spectators: std.ArrayList(Spectator),
    enet_host: ?*enet.ENetHost = null, // borrowed from NetplayManager

    // Round-robin broadcast position (legacy iterates spectators in order).
    broadcast_pos: usize = 0,

    // The minimum spectator pos.index — used to know how long to preserve
    // input history before garbage collecting.
    current_min_index: u32 = std.math.maxInt(u32),
    preserve_start_index: u32 = std.math.maxInt(u32),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, log: *logging.Logger) SpectatorManager {
        var seed_buf: [8]u8 = undefined;
        io.random(&seed_buf);
        var prng: std.Random.Xoshiro256 = undefined;
        prng.seed(@bitCast(seed_buf));
        return .{
            .allocator = allocator,
            .prng = prng,
            .log = log,
            .spectators = .empty,
        };
    }

    pub fn deinit(self: *SpectatorManager) void {
        // Disconnect all spectators cleanly.
        for (self.spectators.items) |*s| {
            if (s.peer != null) {
                enet.enet_peer_disconnect(s.peer.?, 0);
            }
        }
        if (self.enet_host != null) enet.enet_host_flush(self.enet_host);
        self.spectators.deinit(self.allocator);
    }

    pub fn setEnetHost(self: *SpectatorManager, host: ?*enet.ENetHost) void {
        self.enet_host = host;
    }

    pub fn numSpectators(self: *const SpectatorManager) usize {
        var n: usize = 0;
        for (self.spectators.items) |s| {
            if (s.state == .active) n += 1;
        }
        return n;
    }

    /// Called when ENet delivers a CONNECT event for a NEW peer that is NOT
    /// the main game peer. The host decides whether to accept (as spectator)
    /// or redirect (chain-forwarding).
    pub fn onNewPeer(self: *SpectatorManager, peer: ?*enet.ENetPeer, now_ms: i64) void {
        // If we're at capacity, redirect to a random existing spectator.
        if (self.spectators.items.len >= max_spectators) {
            self.sendRedirectAndDisconnect(peer);
            return;
        }

        // If we're a root host (not a chain spectator), only allow 1 direct
        // spectator — anyone else gets redirected.
        if (self.spectators.items.len >= max_root_spectators) {
            self.sendRedirectAndDisconnect(peer);
            return;
        }

        self.spectators.append(self.allocator, .{
            .peer = peer,
            .state = .pending,
            .accepted_at_ms = now_ms,
        }) catch {
            self.log.err("SpectatorManager: failed to allocate spectator slot", .{});
            return;
        };

        const addr = if (peer) |p| p.address else std.mem.zeroes(enet.ENetAddress);
        self.log.info("Spectator connected from {d}.{d}.{d}.{d}:{d} (pending)", .{
            (addr.host >> 0) & 0xFF,
            (addr.host >> 8) & 0xFF,
            (addr.host >> 16) & 0xFF,
            (addr.host >> 24) & 0xFF,
            addr.port,
        });
    }

    fn sendRedirectAndDisconnect(self: *SpectatorManager, peer: ?*enet.ENetPeer) void {
        if (peer == null) return;

        // Pick a random active spectator's address.
        var redirect_buf: [80]u8 = undefined;
        redirect_buf[0] = 0xFE; // REDIRECT message type
        redirect_buf[1] = 0x01;

        // If we have at least one spectator, advertise its address; else
        // just disconnect (the client will retry or give up).
        if (self.spectators.items.len > 0) {
            const idx = self.prng.random().intRangeLessThan(usize, 0, self.spectators.items.len);
            const s = self.spectators.items[idx];
            const addr_len = std.mem.indexOfScalar(u8, &s.redirect_addr, 0) orelse s.redirect_addr.len;
            const total_len = 2 + addr_len + 1 + 2;
            if (total_len <= redirect_buf.len) {
                @memcpy(redirect_buf[2 .. 2 + addr_len], s.redirect_addr[0..addr_len]);
                redirect_buf[2 + addr_len] = 0; // null-terminator
                std.mem.writeInt(u16, redirect_buf[3 + addr_len .. 5 + addr_len][0..2], s.redirect_port, .little);
                const packet = enet.enet_packet_create(&redirect_buf, 5 + addr_len, enet.ENET_PACKET_FLAG_RELIABLE);
                if (packet != null) {
                    _ = enet.enet_peer_send(peer, 0, packet);
                    enet.enet_host_flush(self.enet_host);
                }
            }
        }

        enet.enet_peer_disconnect_later(peer.?, 0);
        enet.enet_host_flush(self.enet_host);
        self.log.info("Spectator redirected (capacity reached)", .{});
    }

    /// Called when a spectator disconnects (or times out).
    pub fn onPeerDisconnect(self: *SpectatorManager, peer: ?*enet.ENetPeer) void {
        if (peer == null) return;
        var i: usize = 0;
        while (i < self.spectators.items.len) {
            if (self.spectators.items[i].peer == peer) {
                _ = self.spectators.swapRemove(i);
                self.log.info("Spectator removed ({d} remaining)", .{self.spectators.items.len});
                return;
            }
            i += 1;
        }
    }

    /// Promote a pending spectator to active after they've sent their first
    /// message (HELLO).
    pub fn activateSpectator(self: *SpectatorManager, peer: ?*enet.ENetPeer, start_index: u32) void {
        for (self.spectators.items) |*s| {
            if (s.peer == peer) {
                s.state = .active;
                s.pos_index = start_index;
                s.pos_frame = num_inputs_per_packet - 1; // legacy default
                if (start_index < self.preserve_start_index) {
                    self.preserve_start_index = start_index;
                }
                self.log.info("Spectator activated (start_index={d})", .{start_index});
                return;
            }
        }
    }

    /// Check pending spectators for timeout — call once per second or so.
    pub fn checkPendingTimeouts(self: *SpectatorManager, now_ms: i64) void {
        var i: usize = 0;
        while (i < self.spectators.items.len) {
            const s = self.spectators.items[i];
            if (s.state == .pending and now_ms - s.accepted_at_ms > pending_timeout_ms) {
                self.log.warn("Spectator pending timeout — disconnecting", .{});
                if (s.peer != null) enet.enet_peer_disconnect(s.peer.?, 0);
                _ = self.spectators.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Per-frame: advance each spectator's pos and send a batch of inputs.
    ///
    /// `both_inputs_buf` is a function that fills a buffer with NUM_INPUTS
    /// frames of (P1 input, P2 input) starting at a given (index, frame).
    /// Returns the actual length written, or 0 if inputs aren't ready yet.
    pub fn frameStepSpectators(
        self: *SpectatorManager,
        current_index: u32,
        current_frame: u32,
        world_timer: u32,
        fill_inputs: *const fn (index: u32, frame: u32, out: []u8) usize,
    ) void {
        _ = current_index;
        _ = current_frame;

        if (self.spectators.items.len == 0) {
            self.preserve_start_index = std.math.maxInt(u32);
            self.current_min_index = std.math.maxInt(u32);
            return;
        }

        // Legacy broadcast pacing: number of broadcasts per frame scales with
        // spectator count so that each spectator gets a batch roughly every
        // NUM_INPUTS frames.
        const n_spec: u32 = @intCast(self.spectators.items.len);
        const multiplier: u32 = 1 + (n_spec * 2) / (num_inputs_per_packet + 1);
        const interval: u32 = (multiplier * num_inputs_per_packet / 2) / n_spec;
        if (interval == 0 or world_timer % interval != 0) return;

        var batch: u32 = 0;
        while (batch < multiplier) : (batch += 1) {
            // Wrap around the spectator list.
            if (self.broadcast_pos >= self.spectators.items.len) {
                self.broadcast_pos = 0;
                self.preserve_start_index = self.current_min_index;
                self.current_min_index = std.math.maxInt(u32);
            }

            const s = &self.spectators.items[self.broadcast_pos];
            if (s.state != .active) {
                self.broadcast_pos += 1;
                continue;
            }

            // Build the inputs packet. [1 type=0x20][4 frame][4 index][p1p2 × N]
            var input_buf: [1 + 4 + 4 + num_inputs_per_packet * 4]u8 = undefined;
            const written = fill_inputs(s.pos_index, s.pos_frame, &input_buf);
            if (written > 0) {
                const packet = enet.enet_packet_create(&input_buf, written, 0); // unreliable for speed
                if (packet != null and s.peer != null) {
                    _ = enet.enet_peer_send(s.peer, 2, packet); // channel 2 = spectator
                }
            }

            // Advance pos by NUM_INPUTS.
            s.pos_frame +%= num_inputs_per_packet;

            // Update min index for preserveStartIndex.
            if (s.pos_index < self.current_min_index) {
                self.current_min_index = s.pos_index;
            }

            self.broadcast_pos += 1;
        }

        enet.enet_host_flush(self.enet_host);
    }

    /// Broadcast a reliable message to all spectators (e.g. RNG state,
    /// state transition, initial game state).
    pub fn broadcastReliable(self: *SpectatorManager, channel: u8, data: []const u8) void {
        for (self.spectators.items) |s| {
            if (s.state != .active or s.peer == null) continue;
            const packet = enet.enet_packet_create(data.ptr, data.len, enet.ENET_PACKET_FLAG_RELIABLE);
            if (packet != null) {
                _ = enet.enet_peer_send(s.peer, channel, packet);
            }
        }
        enet.enet_host_flush(self.enet_host);
    }

    /// Send the initial game state (mode, training flag, start pos) to a
    /// specific newly-activated spectator.
    pub fn sendInitialState(self: *SpectatorManager, peer: ?*enet.ENetPeer, state_byte: u8, is_training: bool, start_index: u32, start_frame: u32) void {
        if (peer == null) return;
        var buf: [10]u8 = undefined;
        buf[0] = 0x10; // INITIAL_GAME_STATE
        buf[1] = state_byte;
        buf[2] = if (is_training) 1 else 0;
        std.mem.writeInt(u32, buf[3..7], start_index, .little);
        std.mem.writeInt(u32, buf[7..11], start_frame, .little);
        const packet = enet.enet_packet_create(&buf, buf.len, enet.ENET_PACKET_FLAG_RELIABLE);
        if (packet != null) _ = enet.enet_peer_send(peer, 0, packet);
        enet.enet_host_flush(self.enet_host);
    }
};
