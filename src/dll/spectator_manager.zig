const std = @import("std");
const logging = @import("common").logging;
const net = @import("net").enet_transport;

// Use the shared ENet cimport from enet_transport.zig
const enet = net.enet;

pub const max_spectators: usize = 15;
pub const max_root_spectators: usize = 1;
pub const num_inputs_per_packet: u32 = 30;
pub const pending_timeout_ms: u64 = 20000;

pub const SpectatorState = enum {
    pending, // ENet-connected but no first message yet
    active, // receiving inputs
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

        // Unconditionally cap direct spectators at max_root_spectators (1).
        // NOTE: diverges from CCCaster, which only applies this cap to root
        // hosts (ClientMode::Host/Client) and lets chain spectators
        // (Spectate) accept up to MAX_SPECTATORS (15). The clientMode check
        // is missing — see CCCaster DllMain.cpp:59 SHOULD_REDIRECT_SPECTATORS.
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

        // Pick a random spectator's address from the full list (any state).
        // NOTE: CCCaster uses round-robin via _spectatorMapPos, not random.
        var redirect_buf: [80]u8 = undefined;
        redirect_buf[0] = 0xFE; // ZZCaster-specific REDIRECT tag (0xFE); does NOT match CCCaster, which sends IpAddrPort (0x0B).
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
    /// message. NOTE: in CCCaster the first message is an IpAddrPort (0x0B)
    /// advertising the spectator's external port, and the start_index is taken
    /// from the host's getSpectateStartIndex() — not sent by the spectator.
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
    /// `fill_inputs` is a function that fills a buffer with NUM_INPUTS
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
        // NUM_INPUTS / 2 frames (≈15 for NUM_INPUTS=30).
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
            // (CCCaster MsgType::BothInputs = 0x02; Zig uses 0x20 — diverges.
            // CCCaster's wire format also prefixes a compressionLevel byte and
            // appends an MD5 hash, omitted here.)
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
    ///
    /// Packet layout: 1 type + 1 state + 1 training + 4 start_index + 4 start_frame = 11 bytes.
    pub fn sendInitialState(self: *SpectatorManager, peer: ?*enet.ENetPeer, state_byte: u8, is_training: bool, start_index: u32, start_frame: u32) void {
        if (peer == null) return;
        var buf: [11]u8 = undefined;
        buf[0] = 0x10; // INITIAL_GAME_STATE (CCCaster MsgType::InitialGameState = 0x0A; Zig uses 0x10 — diverges. CCCaster's InitialGameState also carries stage/chara/moon/color fields.)
        buf[1] = state_byte;
        buf[2] = if (is_training) 1 else 0;
        std.mem.writeInt(u32, buf[3..7], start_index, .little);
        std.mem.writeInt(u32, buf[7..11], start_frame, .little);
        const packet = enet.enet_packet_create(&buf, buf.len, enet.ENET_PACKET_FLAG_RELIABLE);
        if (packet != null) _ = enet.enet_peer_send(peer, 0, packet);
        enet.enet_host_flush(self.enet_host);
    }
};
