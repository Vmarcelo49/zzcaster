const std = @import("std");
const logging = @import("logging.zig");
const rollback = @import("rollback.zig");
const sfx_dedup = @import("sfx_dedup.zig");
const spectator_manager_mod = @import("spectator_manager.zig");
const net = @import("net.zig");
const rollback_regions = @import("rollback_regions.zig");

// Use the shared ENet cimport from net.zig so all files see the same
// `cimport.struct__ENetPeer` / `cimport.struct__ENetHost` types.
const enet = net.enet;

// Game memory addresses
const game_mode_addr: *u32 = @ptrFromInt(0x54EEE8);
const world_timer_addr: *u32 = @ptrFromInt(0x55D1D4);
const skip_frames_addr: *u32 = @ptrFromInt(0x55D25C);
const alive_flag_addr: *u8 = @ptrFromInt(0x76E650);
const damage_level_addr: *u32 = @ptrFromInt(0x553FCC);
const timer_speed_addr: *u32 = @ptrFromInt(0x553FD0);
const win_count_vs_addr: *u32 = @ptrFromInt(0x553FDC);
const ptr_to_write_input_addr: [*]u8 = @ptrFromInt(0x76E6AC);
const p1_offset_direction: u32 = 0x18;
const p1_offset_buttons: u32 = 0x24;
const p2_offset_direction: u32 = 0x2C;
const p2_offset_buttons: u32 = 0x38;

// RNG state addresses
const rng_state0_addr: *u32 = @ptrFromInt(0x563778);
const rng_state1_addr: *u32 = @ptrFromInt(0x56377C);
const rng_state2_addr: *u32 = @ptrFromInt(0x564068);
const rng_state3_addr: [*]u8 = @ptrFromInt(0x564070);
const rng_state3_size: u32 = 220;

// Game modes
const mode_startup: u32 = 65535;
const mode_opening: u32 = 3;
const mode_title: u32 = 2;
const mode_main: u32 = 25;
const mode_chara_select: u32 = 20;
const mode_loading: u32 = 8;
const mode_in_game: u32 = 1;

// Buttons
pub const button_confirm: u16 = 0x0400;
pub const button_a: u16 = 0x0010;
pub const button_b: u16 = 0x0020;
pub const button_c: u16 = 0x0008;
pub const button_d: u16 = 0x0004;
pub const button_e: u16 = 0x0080;
pub const button_start: u16 = 0x0001;

// ASM addresses
const loop_start_addr: u32 = 0x40D330;
const hook_call1_addr: u32 = 0x40D032;
const hook_call2_addr: u32 = 0x40D411;
const multiple_melty_addr: *u8 = @ptrFromInt(0x40D25A);
const force_goto_addr: *u8 = @ptrFromInt(0x42B475);
const keyboard_config_offset: u32 = 0x14D2C0;

const num_inputs: u32 = 30;
const max_rollback: u8 = 15;

// Health-check timeouts (ported from CCCaster's GoBackN keepalive + input-wait)
const heartbeat_timeout_ms: i64 = 20000; // 20s — no packet → peer is dead
const input_wait_timeout_ms: i64 = 10000; // 10s — no remote input → timed out

pub const NetplayState = enum {
    pre_initial,
    initial,
    chara_select,
    loading,
    chara_intro,
    skippable,
    in_game,
    retry_menu,
};

pub const NetplayConfig = struct {
    is_host: bool = false,
    is_training: bool = false,
    is_spectator: bool = false, // spectator client mode (no local input → host)
    delay: u8 = 0,
    rollback: u8 = 0,
    rollback_delay: u8 = 0,
    win_count: u8 = 2,
    host_player: u8 = 1,
    local_player: u8 = 1,
    remote_player: u8 = 2,
    peer_addr: [64]u8 = [_]u8{0} ** 64,
    peer_port: u16 = 0,
    is_netplay: bool = false,
    spectator_listen_port: u16 = 0, // host: port to also-listen on for spectators (== peer_port)
};

pub const NetplayManager = struct {
    allocator: std.mem.Allocator,
    // Zig 0.16: std.time.milliTimestamp() is gone — Io.Clock.now(io, …)
    // requires an Io handle. Stored once in init() and reused everywhere
    // we need a millisecond timestamp.
    io: std.Io,
    log: *logging.Logger,
    config: NetplayConfig = .{},
    state: NetplayState = .pre_initial,

    // ENet
    enet_host: ?*enet.ENetHost = null,
    enet_peer: ?*enet.ENetPeer = null,
    enet_connected: bool = false,

    // Input buffers (local + remote, per round)
    local_inputs: rollback.InputBuffer,
    remote_inputs: rollback.InputBuffer,

    // Frame tracking
    indexed_frame: struct { frame: u32 = 0, index: u32 = 0 } = .{},
    start_world_time: u32 = 0,

    // Rollback
    state_pool: rollback.StatePool,
    rollback_timer: u8 = 0,
    min_rollback_spacing: u8 = 2,
    fast_fwd_stop_frame: u32 = 0,

    // SFX dedup (drives the sfx_filter_array / sfx_mute_array + history ring)
    sfx_dedup: ?sfx_dedup.SfxDedup = null,

    // Spectator chain (host-side: forwards both players' inputs to spectators)
    spectators: ?spectator_manager_mod.SpectatorManager = null,

    // RNG sync
    should_sync_rng: bool = true,
    rng_synced: bool = false,

    // Input resend
    resend_timer_active: bool = false,
    wait_ticks: u32 = 0,

    // Lazy ENet connect: instead of blocking in DllMain, poll in frameStep.
    connect_attempts: u32 = 0,
    connect_attempts_exhausted: bool = false,
    // Set to true once we ever successfully connected — used to distinguish
    // "never connected" from "was connected then disconnected".
    was_connected: bool = false,

    // Stage-0 netcode diagnostics (see docs/netcode-test-plan.md Stage 0.3).
    // Track which non-CONNECT event types were observed during the lazy
    // connect-poll loop so the 60s-cap log can distinguish a silent timeout
    // (no peer ever responded) from an explicit REFUSE/disconnect. Pure
    // additive counters — they never change connect outcome.
    diag_connect_disconnects: u32 = 0,
    diag_connect_receives: u32 = 0,

    // State transition tracking (ported from legacy _startIndex / _indexedFrame)
    // remote_index = the transition index the remote peer is currently on,
    // learned from TransitionIndex messages. Used by isRemoteInputReady to
    // decide whether to wait (remote behind) or predict (remote ahead).
    remote_index: u32 = 0,

    // Heartbeat: timestamp (ms) of the last packet received from the peer.
    // Updated in pollEnet() whenever any packet arrives. Checked in
    // frameStep — if now - last_packet_ms > HEARTBEAT_TIMEOUT_MS (20s),
    // we force a disconnect. This catches dead peers that crash/kill
    // without sending an ENET_EVENT_TYPE_DISCONNECT (which is the only
    // other way to detect a dead connection).
    last_packet_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, log: *logging.Logger) !NetplayManager {
        return .{
            .allocator = allocator,
            .io = io,
            .log = log,
            .local_inputs = rollback.InputBuffer.init(allocator),
            .remote_inputs = rollback.InputBuffer.init(allocator),
            .state_pool = rollback.StatePool.init(allocator),
            .sfx_dedup = try sfx_dedup.SfxDedup.init(allocator),
            .spectators = spectator_manager_mod.SpectatorManager.init(allocator, io, log),
        };
    }

    pub fn deinit(self: *NetplayManager) void {
        self.local_inputs.deinit();
        self.remote_inputs.deinit();
        self.state_pool.deinit();
        if (self.sfx_dedup) |*sd| sd.deinit();
        if (self.spectators) |*sm| sm.deinit();
        if (self.enet_peer != null) {
            enet.enet_peer_disconnect(self.enet_peer, 0);
            enet.enet_host_flush(self.enet_host);
        }
        if (self.enet_host != null) {
            enet.enet_host_destroy(self.enet_host);
        }
        enet.enet_deinitialize();
    }

    pub fn configure(self: *NetplayManager, cfg: NetplayConfig) void {
        self.config = cfg;
        self.min_rollback_spacing = if (cfg.rollback > 0) @max(@min(cfg.rollback, 4), 2) else 2;
        self.rollback_timer = self.min_rollback_spacing;
        if (self.sfx_dedup) |*sd| sd.setLogger(self.log);
        self.log.info("NetplayManager: delay={d} rollback={d} host={} spectator={}", .{
            cfg.delay, cfg.rollback, cfg.is_host, cfg.is_spectator,
        });
    }

    // --- ENet connection (inside the DLL) ---
    //
    // Topology:
    //   * Host (non-spectator): creates an ENet host bound to peer_port,
    //     allowing up to (1 + MAX_SPECTATORS) peers (1 main player + 15
    //     spectators). The main peer is on channel 0/1; spectators share
    //     channel 2.
    //   * Spectator client: creates a 1-peer ENet host and connects to the
    //     host's peer_port. It only listens for BothInputs / state-transition
    //     messages — never sends any.
    //   * Regular client (player 2): same as spectator client, but also
    //     sends local inputs each frame on channel 1.
    pub fn initEnet(self: *NetplayManager) !void {
        if (enet.enet_initialize() != 0) {
            self.log.err("ENet init failed", .{});
            return error.EnetInitFailed;
        }

        if (self.config.is_host) {
            var addr: enet.ENetAddress = undefined;
            addr.host = enet.ENET_HOST_ANY;
            addr.port = self.config.peer_port;
            // 1 main peer + 15 spectators = 16 total peers; 3 channels (0=reliable, 1=inputs, 2=spectator).
            self.enet_host = enet.enet_host_create(&addr, 16, 3, 0, 0);
            // Stage-0 diag: log the host_create return so we can tell bind
            // success from bind failure in the DLL log.
            self.log.info("DIAG: host_create returned {x} on port {d}", .{
                @intFromPtr(self.enet_host), self.config.peer_port,
            });
            if (self.enet_host == null) {
                self.log.err("ENet host_create failed on port {d}", .{self.config.peer_port});
                return error.HostCreateFailed;
            }
            // Hook spectator manager to this host.
            if (self.spectators) |*sm| sm.setEnetHost(self.enet_host);
            self.log.info("ENet listening on port {d} (1 player + up to 15 spectators)", .{self.config.peer_port});
        } else {
            // Spectator OR player-2 client — both connect outbound.
            self.enet_host = enet.enet_host_create(null, 1, 3, 0, 0);
            // Stage-0 diag: log the client host_create return too.
            self.log.info("DIAG: client host_create returned {x}", .{@intFromPtr(self.enet_host)});
            if (self.enet_host == null) return error.HostCreateFailed;

            var addr: enet.ENetAddress = undefined;
            const addr_z = std.mem.sliceTo(&self.config.peer_addr, 0);
            var addr_buf: [64]u8 = undefined;
            const addr_z_copy = std.fmt.bufPrintZ(&addr_buf, "{s}", .{addr_z}) catch return error.AddrTooLong;
            if (enet.enet_address_set_host(&addr, addr_z_copy.ptr) != 0) {
                self.log.err("DIAG: enet_address_set_host failed for {s}", .{addr_z});
                return error.BadAddr;
            }
            addr.port = self.config.peer_port;

            // Stage-0 diag: log the resolved address (host is network byte
            // order) so we can confirm 127.0.0.1 actually resolved. Format
            // the 4 bytes as dotted-quad for readability.
            const h = std.mem.bigToNative(u32, addr.host);
            self.log.info("DIAG: resolved peer = {d}.{d}.{d}.{d}:{d}", .{
                (h >> 24) & 0xff, (h >> 16) & 0xff, (h >> 8) & 0xff, h & 0xff,
                addr.port,
            });

            // For spectators, use a non-zero connect data so the host can
            // immediately distinguish them from the main player peer.
            // 0x5FEC == "SPEC" sentinel (visual mnemonic).
            const connect_data: u32 = if (self.config.is_spectator) 0x5FEC else 0;
            self.enet_peer = enet.enet_host_connect(self.enet_host, &addr, 3, connect_data);
            // Stage-0 diag: log the host_connect return — a null here means
            // the connect call itself failed (not the same as a timeout).
            self.log.info("DIAG: host_connect returned {x} (spectator={})", .{
                @intFromPtr(self.enet_peer), self.config.is_spectator,
            });
            if (self.enet_peer == null) return error.ConnectFailed;
            self.log.info("ENet connecting to {s}:{d} (spectator={})", .{
                addr_z, self.config.peer_port, self.config.is_spectator,
            });
        }
    }

    pub fn waitForEnetConnect(self: *NetplayManager, timeout_ms: u32) !void {
        if (self.enet_host == null) return error.NoHost;
        var event: enet.ENetEvent = undefined;
        const deadline = timeout_ms / 100;
        var i: u32 = 0;
        while (i < deadline) : (i += 1) {
            if (enet.enet_host_service(self.enet_host, &event, 100) > 0) {
                if (event.type == enet.ENET_EVENT_TYPE_CONNECT) {
                    // Host: the FIRST connect event is the main peer (player 2).
                    // Subsequent connect events are spectators — handled by
                    // drainSpectatorEvents() below.
                    if (self.config.is_host and !self.enet_connected) {
                        self.enet_peer = event.peer;
                        self.enet_connected = true;
                        self.log.info("Main peer connected", .{});
                        return;
                    } else if (!self.config.is_host) {
                        self.enet_peer = event.peer;
                        self.enet_connected = true;
                        self.log.info("ENet peer connected!", .{});
                        return;
                    } else {
                        // Host: additional peer — treat as spectator.
                        if (self.spectators) |*sm| sm.onNewPeer(event.peer, std.Io.Clock.now(.real, self.io).toMilliseconds());
                    }
                }
            }
        }
        self.log.err("ENet connect timeout", .{});
        return error.Timeout;
    }

    /// After the main peer is connected, the host should call this each
    /// frame to accept/deny any incoming spectator connections.
    pub fn drainSpectatorEvents(self: *NetplayManager) void {
        if (self.enet_host == null) return;
        if (!self.config.is_host) return;
        if (self.spectators == null) return;

        var event: enet.ENetEvent = undefined;
        while (enet.enet_host_service(self.enet_host, &event, 0) > 0) {
            const peer_opt: ?*enet.ENetPeer = if (event.peer != null) event.peer else null;
            switch (event.type) {
                enet.ENET_EVENT_TYPE_CONNECT => {
                    // Distinguish main peer (already connected) from spectator
                    // by checking connect data (0x5FEC == "SPEC" sentinel).
                    if (peer_opt) |p| {
                        if (p.data != null) {
                            const cd: *u32 = @ptrCast(@alignCast(p.data.?));
                            if (cd.* == 0x5FEC) {
                                self.spectators.?.onNewPeer(peer_opt, std.Io.Clock.now(.real, self.io).toMilliseconds());
                                continue;
                            }
                        }
                    }
                    // Default: treat as spectator (no connect data set).
                    self.spectators.?.onNewPeer(peer_opt, std.Io.Clock.now(.real, self.io).toMilliseconds());
                },
                enet.ENET_EVENT_TYPE_DISCONNECT => {
                    self.spectators.?.onPeerDisconnect(peer_opt);
                },
                enet.ENET_EVENT_TYPE_RECEIVE => {
                    // Route by channel: 2 = spectator control messages.
                    // Non-channel-2 messages are regular gameplay packets
                    // (inputs, RNG, TransitionIndex) that arrived while the
                    // host was also draining spectator events — dispatch them
                    // via handleMessage so they're not lost.
                    if (event.packet != null) {
                        const pkt = event.packet;
                        const data_ptr = pkt.*.data;
                        const data_len = pkt.*.dataLength;
                        if (event.channelID == 2) {
                            self.handleSpectatorMessage(peer_opt, data_ptr[0..data_len]);
                        } else {
                            const copy_len = @min(data_len, recv_buf.len);
                            @memcpy(recv_buf[0..copy_len], data_ptr[0..copy_len]);
                            self.handleMessage(recv_buf[0..copy_len]);
                        }
                        enet.enet_packet_destroy(event.packet);
                    }
                },
                else => {},
            }
        }

        // Check pending timeouts.
        self.spectators.?.checkPendingTimeouts(std.Io.Clock.now(.real, self.io).toMilliseconds());
    }

    fn handleSpectatorMessage(self: *NetplayManager, peer: ?*enet.ENetPeer, data: []const u8) void {
        if (peer == null or data.len == 0) return;
        const msg_type = data[0];
        switch (msg_type) {
            0x01 => {
                // HELLO from spectator — promote to active.
                const start_index: u32 = if (data.len >= 5) std.mem.readInt(u32, data[1..5], .little) else 0;
                self.spectators.?.activateSpectator(peer, start_index);
            },
            else => {
                self.log.warn("Unknown spectator message type: 0x{x}", .{msg_type});
            },
        }
    }

    pub fn pollEnet(self: *NetplayManager, timeout_ms: u32) ?[]const u8 {
        if (self.enet_host == null) return null;
        var event: enet.ENetEvent = undefined;
        if (enet.enet_host_service(self.enet_host, &event, timeout_ms) <= 0) return null;

        const peer_opt: ?*enet.ENetPeer = if (event.peer != null) event.peer else null;

        switch (event.type) {
            enet.ENET_EVENT_TYPE_RECEIVE => {
                // Stage-0 diag: a packet during the connect phase is unusual
                // (we haven't agreed on a frame yet); count it so the 60s-cap
                // log can show "we got N mystery packets instead of a CONNECT".
                if (!self.enet_connected) self.diag_connect_receives += 1;
                // Heartbeat: record when we last heard from the peer.
                self.last_packet_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
                const pkt = event.packet;
                const data = pkt.*.data;
                const len = pkt.*.dataLength;
                const copy_len = @min(len, recv_buf.len);
                @memcpy(recv_buf[0..copy_len], data[0..copy_len]);
                enet.enet_packet_destroy(event.packet);
                return recv_buf[0..copy_len];
            },
            enet.ENET_EVENT_TYPE_DISCONNECT => {
                // Stage-0 diag: a disconnect during the connect phase means the
                // peer actively REFUSED us (or timed out at the ENet layer) —
                // distinct from a silent timeout where nothing ever answered.
                if (!self.enet_connected) {
                    self.diag_connect_disconnects += 1;
                    self.log.warn("DIAG: DISCONNECT during connect phase (peer refused/timed out) count={d}", .{
                        self.diag_connect_disconnects,
                    });
                }
                // Host: if this was a spectator, route to SpectatorManager.
                if (self.config.is_host and self.spectators != null) {
                    self.spectators.?.onPeerDisconnect(peer_opt);
                    if (peer_opt == self.enet_peer) {
                        self.enet_connected = false;
                        self.log.warn("Main peer disconnected", .{});
                    }
                    return null;
                }
                self.enet_connected = false;
                self.was_connected = true; // don't tear down on first poll
                self.log.warn("ENet peer disconnected", .{});
                return null;
            },
            enet.ENET_EVENT_TYPE_CONNECT => {
                // Mark the main peer connected. For host the first CONNECT
                // is the player-2 peer; subsequent ones are spectators.
                self.log.info("DIAG: ENET_EVENT_TYPE_CONNECT received host={} connected_before={}", .{
                    self.config.is_host,
                    self.enet_connected,
                });
                // Heartbeat: start the heartbeat clock from the CONNECT event.
                self.last_packet_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
                if (self.config.is_host and !self.enet_connected) {
                    self.enet_peer = event.peer;
                    self.enet_connected = true;
                    self.was_connected = true;
                    self.log.info("Main peer connected", .{});
                } else if (!self.config.is_host) {
                    self.enet_peer = event.peer;
                    self.enet_connected = true;
                    self.was_connected = true;
                    self.log.info("ENet peer connected!", .{});
                } else if (self.spectators != null) {
                    self.spectators.?.onNewPeer(peer_opt, std.Io.Clock.now(.real, self.io).toMilliseconds());
                }
                return null;
            },
            else => return null,
        }
    }

    /// Dispatch a received message to the appropriate handler based on the
    /// 1-byte type tag. Called by pollAndDispatch for each received packet.
    fn handleMessage(self: *NetplayManager, msg: []const u8) void {
        if (msg.len < 1) return;
        switch (msg[0]) {
            0x01 => { // Player inputs
                if (msg.len >= 8) self.setRemoteInputs(msg[1..]);
            },
            0x02 => { // RNG state
                self.applyRemoteRng(msg);
            },
            0x03 => { // TransitionIndex
                if (msg.len >= 5) {
                    const idx = std.mem.readInt(u32, msg[1..5], .little);
                    self.setRemoteIndex(idx);
                }
            },
            0x20 => { // BothInputs (spectator broadcast from host)
                if (self.config.is_spectator) {
                    self.applyBothInputsPacket(msg[1..]);
                }
            },
            else => {
                self.log.warn("Unknown message type: 0x{x}", .{msg[0]});
            },
        }
    }

    /// Poll ENet for events and dispatch any received messages. Call this
    /// once per frame to process incoming network traffic. The first poll
    /// uses the given timeout; subsequent polls use 0 to drain all pending.
    pub fn pollAndDispatch(self: *NetplayManager, timeout_ms: u32) void {
        if (self.pollEnet(timeout_ms)) |msg| {
            self.handleMessage(msg);
        }
        while (self.pollEnet(0)) |msg| {
            self.handleMessage(msg);
        }
    }

    var recv_buf: [4096]u8 = undefined;

    // ----- Spectator-mode (client side) -----
    //
    // A spectator-mode DLL doesn't read the local gamepad; instead, every
    // frame it receives a BothInputs message from the host containing both
    // players' inputs for an upcoming frame, then writes them to the game.
    //
    // The spectator never triggers rollback (no local input to predict),
    // so its frame loop is simpler than the player's.

    /// Spectator client: parse a BothInputs packet from the host.
    /// Format: [4 bytes start_frame][4 bytes start_index][N × 4 bytes (P1:u16,P2:u16)]
    pub fn applyBothInputsPacket(self: *NetplayManager, data: []const u8) void {
        if (data.len < 8) return;
        const start_frame = std.mem.readInt(u32, data[0..4], .little);
        const start_index = std.mem.readInt(u32, data[4..8], .little);
        const num = (data.len - 8) / 4;
        var i: u32 = 0;
        while (i < num) : (i += 1) {
            const p1 = std.mem.readInt(u16, data[8 + i * 4 .. 10 + i * 4][0..2], .little);
            const p2 = std.mem.readInt(u16, data[10 + i * 4 .. 12 + i * 4][0..2], .little);
            self.local_inputs.set(start_index, start_frame + i, p1);
            self.remote_inputs.set(start_index, start_frame + i, p2);
        }
    }

    /// Spectator: get both inputs for the current frame.
    pub fn getSpectatorInputs(self: *const NetplayManager) struct { p1: u16, p2: u16 } {
        return .{
            .p1 = self.local_inputs.get(self.indexed_frame.index, self.indexed_frame.frame),
            .p2 = self.remote_inputs.get(self.indexed_frame.index, self.indexed_frame.frame),
        };
    }

    pub fn sendInputs(self: *NetplayManager, inputs: []const u8) void {
        if (self.enet_peer == null or !self.enet_connected) return;
        // Prepend a 1-byte type tag (0x01) so the receiver can disambiguate
        // this from RNG-state packets (type 0x02) and TransitionIndex (0x03)
        // which share channel 1.
        var tagged: [1 + 128]u8 = .{0x01} ++ .{0} ** 128;
        const copy_len = @min(inputs.len, tagged.len - 1);
        @memcpy(tagged[1..][0..copy_len], inputs[0..copy_len]);
        const packet = enet.enet_packet_create(&tagged, 1 + copy_len, 0); // unreliable
        if (packet != null) {
            _ = enet.enet_peer_send(self.enet_peer, 1, packet);
            enet.enet_host_flush(self.enet_host);
        }
    }

    var dbg_send_inputs: u32 = 0;
    var dbg_send_reliable: u32 = 0;

    pub fn sendReliable(self: *NetplayManager, data: []const u8) void {
        if (self.enet_peer == null or !self.enet_connected) return;
        const packet = enet.enet_packet_create(data.ptr, data.len, enet.ENET_PACKET_FLAG_RELIABLE);
        if (packet != null) {
            _ = enet.enet_peer_send(self.enet_peer, 0, packet);
            enet.enet_host_flush(self.enet_host);
        }
    }

    // --- Frame stepping ---

    pub fn updateFrame(self: *NetplayManager) void {
        const world_timer = world_timer_addr.*;
        self.indexed_frame.frame = world_timer - self.start_world_time;
    }

    pub fn isPreGame(_: *const NetplayManager) bool {
        const mode = game_mode_addr.*;
        return mode == mode_startup or mode == mode_opening or
            mode == mode_title or mode == mode_main;
    }

    pub fn isInGame(self: *const NetplayManager) bool {
        return self.state == .in_game;
    }

    pub fn isInRollback(self: *const NetplayManager) bool {
        // Spectators never trigger rollback — they just replay both players'
        // inputs as delivered by the host.
        if (self.config.is_spectator) return false;
        return self.isInGame() and self.config.rollback > 0 and self.config.is_netplay;
    }

    // --- Input management ---

    /// Returns true if the remote peer's transition index is more than 1
    /// ahead of ours — meaning we're lagging behind and should auto-mash
    /// Confirm to catch up. Used by getNetplayInput() in Loading/CharaIntro/
    /// Skippable states to prevent one side from being stuck on a screen
    /// while the other has already advanced.
    pub fn shouldCatchUp(self: *const NetplayManager) bool {
        if (self.remote_inputs.getEndIndex() == 0) return false;
        const remote_end_index = self.remote_inputs.getEndIndex() - 1;
        return remote_end_index > self.indexed_frame.index + 1;
    }

    /// Get the input to send/write for the local player, with per-state
    /// filtering. This is the Zig equivalent of CCCaster's getInput(player)
    /// dispatch.
    ///
    /// - CharaSelect: real input, but B/Cancel masked (can't back out)
    /// - Loading/CharaIntro/Skippable: if remote is ahead, mash Confirm;
    ///   otherwise only Confirm/Cancel pass through (no cursor movement)
    /// - InGame/RetryMenu: real input (filtered later by game logic)
    /// - PreInitial/Initial: mash Confirm to auto-advance menus
    pub fn getNetplayInput(self: *NetplayManager, raw_input: u16) u16 {
        switch (self.state) {
            .pre_initial, .initial => {
                // Mash Confirm every other frame to auto-advance through
                // the title screen and menus.
                if (self.indexed_frame.frame % 2 == 0) {
                    return button_confirm << 4;
                }
                return 0;
            },
            .chara_select => {
                // Mask B/Cancel (0x0800 button bit, which is in the high
                // byte after << 4 = 0x0800 in the combined u16). This
                // prevents either player from backing out of chara-select
                // and desyncing the state machine.
                // combined = dir | (btns << 4), so Cancel bit = 0x0800 << 4? No.
                // button_cancel = 0x0800, and btns is shifted << 4 in the
                // combined u16, so Cancel occupies bits 15..12 area.
                // Actually: button_b = 0x0020, button_cancel = 0x0800.
                // Combined = dir | (btns << 4). So btns = (combined >> 4).
                // Cancel bit in btns = 0x0800, in combined = 0x0800 << 4? No.
                // Let me re-check: readInput returns dir | (btns << 4).
                // So if btns has bit 0x0800 set, combined has 0x0800 << 4?
                // No — btns is already the button field. combined = dir | (btns << 4).
                // So btns=0x0800 → combined bits = 0x0800 << 4 = 0x8000? That's wrong.
                //
                // Actually the button constants are: button_b = 0x0020.
                // readInputMapped returns dir | (btns << 4).
                // So button_b (0x0020) in the combined u16 is at bits 4+5=9?
                // 0x0020 << 4 = 0x0200. So B is bit 9 in the combined u16.
                // button_cancel = 0x0800. 0x0800 << 4 = 0x8000. Cancel is bit 15.
                //
                // To mask Cancel: clear bit 15 of the combined u16.
                // To mask B: clear bit 9 (0x0200) of the combined u16.
                return raw_input & ~@as(u16, 0x8000); // mask Cancel
            },
            .loading, .chara_intro, .skippable => {
                // If remote is ahead, mash Confirm to catch up.
                if (self.shouldCatchUp()) {
                    if (self.indexed_frame.frame % 2 == 0) {
                        return button_confirm << 4;
                    }
                    return 0;
                }
                // Otherwise, only allow Confirm/Cancel through — suppress
                // all direction and action buttons so the player can't
                // accidentally affect game state during loading/intro.
                // Confirm = 0x0400 in btns = 0x4000 in combined.
                // Cancel  = 0x0800 in btns = 0x8000 in combined.
                return raw_input & 0xC000; // keep only Confirm + Cancel bits
            },
            .in_game, .retry_menu => {
                // Real input — game logic handles filtering.
                return raw_input;
            },
        }
    }

    pub fn setLocalInput(self: *NetplayManager, input: u16) void {
        const frame = self.indexed_frame.frame + self.config.delay;
        self.local_inputs.set(self.indexed_frame.index, frame, input);
    }

    pub fn getLocalInput(self: *const NetplayManager) u16 {
        return self.local_inputs.get(self.indexed_frame.index, self.indexed_frame.frame);
    }

    pub fn setRemoteInputs(self: *NetplayManager, data: []const u8) void {
        // Parse input packet: [4 bytes start_frame][4 bytes index][N × 2 bytes inputs]
        if (data.len < 8) return;
        const start_frame = std.mem.readInt(u32, data[0..4], .little);
        const index = std.mem.readInt(u32, data[4..8], .little);
        const num = (data.len - 8) / 2;
        if (num == 0) return;

        // Only keep remote inputs at most 1 transition index old (legacy guard)
        if (index + 1 < self.indexed_frame.index) return;

        var inputs_buf: [num_inputs]u16 = undefined;
        const n = @min(num, inputs_buf.len);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            inputs_buf[i] = std.mem.readInt(u16, data[8 + i * 2 ..][0..2], .little);
        }

        // check_changes=true so last_changed_frame is updated on misprediction
        // (needed for rollback to trigger; harmless for delay-based since
        // checkRollback returns false when rollback=0).
        self.remote_inputs.setRemote(index, start_frame, inputs_buf[0..n], true);
    }

    pub fn getRemoteInput(self: *const NetplayManager) u16 {
        return self.remote_inputs.get(self.indexed_frame.index, self.indexed_frame.frame);
    }

    /// Check if the peer has been silent for too long. Returns true if the
    /// heartbeat has expired (no packet received in HEARTBEAT_TIMEOUT_MS).
    /// Called from frameStep to detect dead peers that crashed without
    /// sending a DISCONNECT event.
    pub fn checkHeartbeat(self: *const NetplayManager) bool {
        if (!self.enet_connected or self.last_packet_ms == 0) return false;
        const now = std.Io.Clock.now(.real, self.io).toMilliseconds();
        return (now - self.last_packet_ms) > heartbeat_timeout_ms;
    }

    pub fn isRemoteInputReady(self: *const NetplayManager) bool {
        // In CharaSelect and InGame, the frame loop MUST block until the
        // remote peer has caught up to our transition index AND has sent
        // input for the current frame. This is the lock-step gate that
        // keeps both sides synchronized — without it, one side can race
        // ahead (e.g. start the match while the other is still loading).
        //
        // Loading / CharaIntro / Skippable / RetryMenu do NOT block:
        // each side runs at its own pace, and the catch-up mash logic
        // in getNetplayInput() ensures the lagging side auto-skips.
        switch (self.state) {
            .pre_initial, .initial, .loading, .chara_intro, .skippable, .retry_menu => return true,
            .chara_select, .in_game => {},
        }

        // Offline / spectator: always ready
        if (!self.config.is_netplay or self.config.is_spectator) return true;

        const our_index = self.indexed_frame.index;

        // No remote inputs at all yet — wait
        if (self.remote_inputs.getEndIndex() == 0) return false;

        const remote_end_index = self.remote_inputs.getEndIndex() - 1;

        // Remote is behind us — wait for them to catch up to our index
        if (remote_end_index < our_index) return false;

        // Remote is ahead of us — use prediction, don't wait
        if (remote_end_index > our_index) return true;

        // Same index — check if we have the frame we need
        const needed = self.indexed_frame.frame + self.config.delay;
        const end_frame = self.remote_inputs.getEndFrame(our_index);
        return end_frame > needed;
    }

    // --- Send local inputs to peer ---

    pub fn sendLocalInputs(self: *NetplayManager) void {
        // Send the last num_inputs frames of local input, up to frame+delay.
        // Wire format (after sendInputs prepends 0x01 tag):
        //   [4 start_frame][4 index][N × 2 inputs]
        const last_frame = self.indexed_frame.frame + self.config.delay;
        const start_frame: u32 = if (last_frame + 1 < num_inputs)
            0
        else
            last_frame + 1 - num_inputs;

        var buf: [4 + 4 + num_inputs * 2]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], start_frame, .little);
        std.mem.writeInt(u32, buf[4..8], self.indexed_frame.index, .little);
        var i: u32 = 0;
        while (i < num_inputs) : (i += 1) {
            const input = self.local_inputs.get(self.indexed_frame.index, start_frame + i);
            std.mem.writeInt(u16, buf[8 + i * 2 ..][0..2], input, .little);
        }
        self.sendInputs(buf[0 .. 8 + num_inputs * 2]);
    }

    // --- RNG sync ---

    pub fn syncRngState(self: *NetplayManager) void {
        if (!self.should_sync_rng or self.rng_synced) return;
        if (!self.config.is_host) return;

        // Host sends RNG state to client. Format:
        //   [1 byte type=0x02][4 bytes index][4+4+4+220 bytes RNG state]
        const payload_len: usize = 1 + 4 + 4 + 4 + 4 + rng_state3_size;
        var rng_buf: [1 + 4 + 4 + 4 + 4 + rng_state3_size]u8 = undefined;
        rng_buf[0] = 0x02;
        std.mem.writeInt(u32, rng_buf[1..5], self.indexed_frame.index, .little);
        std.mem.writeInt(u32, rng_buf[5..9], rng_state0_addr.*, .little);
        std.mem.writeInt(u32, rng_buf[9..13], rng_state1_addr.*, .little);
        std.mem.writeInt(u32, rng_buf[13..17], rng_state2_addr.*, .little);
        @memcpy(rng_buf[17..][0..rng_state3_size], rng_state3_addr[0..rng_state3_size]);
        self.sendReliable(rng_buf[0..payload_len]);
        self.rng_synced = true;
        self.log.info("RNG state synced (index={d})", .{self.indexed_frame.index});
    }

    pub fn applyRemoteRng(self: *NetplayManager, data: []const u8) void {
        // Skip the 1-byte type tag added by syncRngState.
        // Format: [1 type=0x02][4 index][4 rng0][4 rng1][4 rng2][220 rng3]
        if (data.len < 1 + 16 + rng_state3_size) return;
        const body = data[1..];
        const rng_index = std.mem.readInt(u32, body[0..4], .little);

        // Only accept RNG for our current index or the one we're about to
        // enter. This prevents stale RNG from a previous round overwriting
        // the current round's state.
        if (rng_index != self.indexed_frame.index and rng_index != self.indexed_frame.index + 1) {
            self.log.warn("Ignoring RNG for index {d} (we're at {d})", .{ rng_index, self.indexed_frame.index });
            return;
        }

        rng_state0_addr.* = std.mem.readInt(u32, body[4..8], .little);
        rng_state1_addr.* = std.mem.readInt(u32, body[8..12], .little);
        rng_state2_addr.* = std.mem.readInt(u32, body[12..16], .little);
        @memcpy(rng_state3_addr[0..rng_state3_size], body[16..16 + rng_state3_size]);
        self.rng_synced = true;
        self.log.info("Applied remote RNG state (index={d})", .{rng_index});
    }

    // --- State transitions ---

    /// Validate that a state transition is allowed. CCCaster uses an explicit
    /// white-list; invalid transitions indicate a desync and should be logged.
    /// Returns true if the transition is valid, false otherwise.
    ///
    /// Valid transitions (from CCCaster's isValidNext):
    ///   pre_initial → initial
    ///   initial → chara_select (netplay) | in_game (training)
    ///   chara_select → loading
    ///   loading → chara_intro (versus) | in_game (training)
    ///   chara_intro → in_game
    ///   in_game → skippable
    ///   skippable → in_game (next round) | retry_menu
    ///   retry_menu → loading (rematch) | chara_select
    fn isValidNext(self: *const NetplayManager, new: NetplayState) bool {
        const old = self.state;
        const valid = switch (old) {
            .pre_initial => new == .initial,
            .initial => new == .chara_select or new == .in_game,
            .chara_select => new == .loading,
            .loading => new == .chara_intro or new == .in_game,
            .chara_intro => new == .in_game,
            .in_game => new == .skippable or new == .chara_select,
            .skippable => new == .in_game or new == .retry_menu,
            .retry_menu => new == .loading or new == .chara_select,
        };
        if (!valid) {
            self.log.err("Invalid state transition: {s} -> {s} (potential desync)", .{
                @tagName(old), @tagName(new),
            });
        }
        return valid;
    }

    pub fn onGameModeChanged(self: *NetplayManager, new_mode: u32) void {
        const old_state = self.state;
        var new_state: ?NetplayState = null;

        if (new_mode == mode_chara_select) {
            new_state = .chara_select;
        } else if (new_mode == mode_loading) {
            new_state = .loading;
        } else if (new_mode == mode_in_game) {
            if (self.config.is_training or !self.config.is_netplay or self.config.is_spectator) {
                new_state = .in_game;
            } else {
                new_state = .chara_intro;
            }
        }

        if (new_state) |ns| {
            // Validate the transition — log invalid ones but proceed anyway
            // (the game already wrote the new mode, we can't stop it).
            _ = self.isValidNext(ns);
            self.state = ns;
            self.onStateTransition(old_state, ns);
            if (new_mode == mode_in_game) self.onEnterInGame();
        }
        self.log.info("NetplayState -> {s} (game_mode={d})", .{ @tagName(self.state), new_mode });

        // Reset SFX dedup on each state transition (legacy clears per round).
        if (self.sfx_dedup) |*sd| sd.clearPerFrame();
    }

    /// Called on every state transition to a gameplay-relevant state
    /// (CharaSelect or higher). Increments the transition index, resets the
    /// frame counter, re-enables RNG sync, and sends a TransitionIndex
    /// message to the peer so they know which round we're on.
    ///
    /// This is the core of the legacy sync algorithm: each round gets a
    /// unique (index, frame) coordinate so inputs from different rounds
    /// don't collide in the InputBuffer.
    fn onStateTransition(self: *NetplayManager, old: NetplayState, new: NetplayState) void {
        // Only track transitions to CharaSelect or higher (skip startup/title)
        const new_val = @intFromEnum(new);
        const chara_select_val = @intFromEnum(NetplayState.chara_select);
        if (new_val < chara_select_val) return;

        // Increment transition index and reset frame counter.
        // This matches legacy: ++_indexedFrame.parts.index; _startWorldTime = world_timer; frame = 0;
        self.indexed_frame.index += 1;
        self.start_world_time = world_timer_addr.*;
        self.indexed_frame.frame = 0;

        // Reset RNG sync for the new round so the host re-sends RNG.
        if (new == .in_game or new == .chara_select) {
            self.rng_synced = false;
            self.should_sync_rng = true;
        }

        // Send TransitionIndex to peer so they know our current index.
        // The receiver calls setRemoteIndex() to extend their view of our
        // progress, which is used by isRemoteInputReady().
        if (self.enet_connected and !self.config.is_spectator and self.config.is_netplay) {
            var buf: [5]u8 = undefined;
            buf[0] = 0x03; // TransitionIndex
            std.mem.writeInt(u32, buf[1..5], self.indexed_frame.index, .little);
            self.sendReliable(&buf);
        }

        self.log.info("State transition: {s} -> {s}, index={d}", .{
            @tagName(old), @tagName(new), self.indexed_frame.index,
        });
    }

    /// Called when we receive a TransitionIndex message from the remote peer.
    /// Records their current transition index so isRemoteInputReady can
    /// decide whether to wait or predict.
    pub fn setRemoteIndex(self: *NetplayManager, remote_idx: u32) void {
        self.remote_index = remote_idx;
        self.log.info("Remote transition index: {d}", .{remote_idx});
    }

    fn onEnterInGame(self: *NetplayManager) void {
        // Allocate rollback states if rollback is enabled (and we're not a
        // spectator — spectators don't roll back, they just replay).
        if (self.config.rollback > 0 and self.config.is_netplay and !self.config.is_spectator) {
            // Load the memory region list (ported from Generator.cpp).
            // This tells the StatePool which game memory addresses to
            // snapshot on each saveState and restore on each loadState.
            for (rollback_regions.all_regions) |r| {
                self.state_pool.addRegion(r.addr, r.size) catch {};
            }
            self.log.info("Loaded {d} rollback memory regions ({d} bytes per state)",
                .{ rollback_regions.all_regions.len, self.state_pool.totalRegionSize() });

            self.state_pool.allocate(60, 0) catch {
                self.log.warn("StatePool allocate failed — rollback disabled", .{});
            };
        }
        self.rollback_timer = self.min_rollback_spacing;

        // Reset SFX dedup at round start.
        if (self.sfx_dedup) |*sd| sd.reset();
    }

    // --- Rollback ---

    pub fn checkRollback(self: *NetplayManager) bool {
        if (!self.isInRollback()) return false;
        if (self.rollback_timer < self.min_rollback_spacing) return false;

        const lcf = self.remote_inputs.last_changed_frame;
        if (lcf == null) return false;

        const lcf_frame = @as(u32, @intCast(lcf.? & 0xFFFFFFFF));
        const lcf_index = @as(u32, @intCast(lcf.? >> 32));
        if (lcf_index != self.indexed_frame.index) return false;
        if (lcf_frame >= self.indexed_frame.frame) return false;

        // Trigger rollback!
        const current_frame = self.indexed_frame.frame;
        self.fast_fwd_stop_frame = current_frame;
        self.log.info("ROLLBACK: frame {d} -> {d}", .{ current_frame, lcf_frame });

        // Apply SFX dedup filter: OR together snapshots between loaded and
        // current frame, then mark with 0x80 sentinel so the play-hook
        // knows to suppress them.
        if (self.sfx_dedup) |*sd| {
            sd.applyRollbackFilter(lcf_frame, current_frame);
        }

        // Load the saved state closest to lcf_frame. This restores game
        // memory (player positions, health, effects, camera, etc.) to the
        // saved state's frame. The game will then re-run from the loaded
        // frame to fast_fwd_stop_frame using the corrected remote inputs.
        if (self.state_pool.loadStateForFrame(lcf_frame, lcf_index)) |loaded_frame| {
            self.indexed_frame.frame = loaded_frame;
            self.log.info("ROLLBACK: loaded state for frame {d}, re-running to {d}", .{ loaded_frame, current_frame });
        } else {
            // No saved state found — just reset to lcf_frame. Game memory
            // stays at the current frame, which may cause minor desync but
            // is better than crashing. This should only happen if rollback
            // triggers before any saveState has been called.
            self.indexed_frame.frame = lcf_frame;
            self.log.warn("ROLLBACK: no saved state for frame {d}", .{lcf_frame});
        }

        self.remote_inputs.clearLastChanged();
        self.rollback_timer = 0;
        return true;
    }

    pub fn isRerunning(self: *const NetplayManager) bool {
        return self.fast_fwd_stop_frame != 0;
    }

    pub fn checkRerunComplete(self: *NetplayManager) bool {
        if (self.fast_fwd_stop_frame == 0) return false;

        // While re-running, snapshot SFX per-frame so finishedRerun knows
        // which sounds actually re-fired.
        if (self.sfx_dedup) |*sd| sd.saveRerunSounds(self.indexed_frame.frame);

        if (self.indexed_frame.frame >= self.fast_fwd_stop_frame) {
            self.fast_fwd_stop_frame = 0;
            skip_frames_addr.* = 0; // restore rendering
            // Re-run finished — cancel any SFX that was queued pre-rollback
            // but didn't actually re-fire during the re-run.
            if (self.sfx_dedup) |*sd| sd.finishedRerun();
            return true;
        }
        skip_frames_addr.* = 1; // keep skipping
        return false;
    }

    // --- Write game inputs ---

    pub fn writeGameInputs(self: *NetplayManager) void {
        if (self.config.is_spectator) {
            // Spectator: both inputs come from the host's BothInputs packet.
            const both = self.getSpectatorInputs();
            writeGameInput(1, both.p1);
            writeGameInput(2, both.p2);
        } else {
            const local = self.getLocalInput();
            const remote = self.getRemoteInput();
            writeGameInput(self.config.local_player, local);
            writeGameInput(self.config.remote_player, remote);
        }
    }

    /// Host: build a BothInputs packet for spectator broadcast. Returns
    /// the number of bytes written into `out`.
    /// Format: [1 type=0x20][4 start_frame][4 start_index][N × 4 (P1:u16, P2:u16)]
    pub fn fillBothInputsForBroadcast(self: *NetplayManager, index: u32, frame: u32, out: []u8) usize {
        if (out.len < 1 + 8 + num_inputs * 4) return 0;
        out[0] = 0x20;
        std.mem.writeInt(u32, out[1..5], frame, .little);
        std.mem.writeInt(u32, out[5..9], index, .little);
        var i: u32 = 0;
        while (i < num_inputs) : (i += 1) {
            const p1 = self.local_inputs.get(index, frame + i);
            const p2 = self.remote_inputs.get(index, frame + i);
            std.mem.writeInt(u16, out[9 + i * 4 .. 11 + i * 4][0..2], p1, .little);
            std.mem.writeInt(u16, out[11 + i * 4 .. 13 + i * 4][0..2], p2, .little);
        }
        return 1 + 8 + num_inputs * 4;
    }
};

fn writeGameInput(player: u8, input: u16) void {
    // See dllmain.zig writeInput — same alignment trick for 64-bit.
    const base_ptr = @as(usize, @bitCast(ptr_to_write_input_addr[0..@sizeOf(usize)].*));
    if (base_ptr == 0) return;
    const base: [*]u8 = @ptrFromInt(base_ptr);
    const dir_off: u32 = if (player == 1) p1_offset_direction else p2_offset_direction;
    const btn_off: u32 = if (player == 1) p1_offset_buttons else p2_offset_buttons;
    // COMBINE_INPUT(dir, btn) = dir | (btn << 4); write both halves as u16
    // to match the legacy C++ DLL (see DllProcessManager.cpp::writeGameInput).
    // Writing u8 leaves the high byte of each u16 slot untouched, which
    // flips unrelated button bits the game reads with `test $0x400,%eax`.
    const dir_ptr: *u16 = @ptrCast(@alignCast(base + dir_off));
    const btn_ptr: *u16 = @ptrCast(@alignCast(base + btn_off));
    dir_ptr.* = input & 0x0F;
    btn_ptr.* = (input >> 4) & 0x0FFF;
}
