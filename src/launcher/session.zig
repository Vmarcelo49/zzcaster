const std = @import("std");
const logging = @import("common").logging;
const net = @import("net").enet_transport;
const ip_discovery = @import("net").ip_discovery;
const net_util = @import("net_util.zig");
const relay_client_mod = @import("net").relay_client;
const relay_config = @import("net").relay_config;
const relay_protocol = @import("net").relay_protocol;
const builtin = @import("builtin");

pub const NetplayConfig = struct {
    is_host: bool = false,
    is_training: bool = false,
    is_spectator: bool = false,
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
    spectator_listen_port: u16 = 0,
    local_name: [32]u8 = [_]u8{0} ** 32,
    remote_name: [32]u8 = [_]u8{0} ** 32,
    // Connection type ("Wired", "Wireless", "Unknown") — exchanged during
    // the handshake and displayed on the confirmation screen.
    local_connection_type: [16]u8 = [_]u8{0} ** 16,
    remote_connection_type: [16]u8 = [_]u8{0} ** 16,
    // Relay handoff: the local UDP port that was used for NAT-traversal
    // hole-punching. Set by stepRelay()/stepParallelRelay() when the
    // relay handshake succeeds. The DLL uses this to bind its ENet host
    // to the SAME port, preserving the NAT mapping opened during
    // hole-punching. 0 = direct connection (no relay, bind to any port
    // or to peer_port).
    local_udp_port: u16 = 0,
};

pub const SessionState = enum {
    idle,
    listening,
    connecting,
    handshaking,
    ping_exchanging,
    waiting_confirmation,
    launching,
    completed,
    failed,
    cancelled,

    // Relay-assisted connection states (Slice 4). The relay path is a
    // sibling to the direct-IP path — after relay handoff succeeds, the
    // session transitions to .connecting and the existing ENet handshake
    // flow takes over.
    relay_connecting, // relay handshake in progress (host or client)
};

pub const PingStats = struct {
    avg_ms: f64 = 0,
    min_ms: f64 = 0,
    max_ms: f64 = 0,
    count: u32 = 0,
    packet_loss: u8 = 0,
};

const Msg = enum(u8) {
    version = 1,
    config = 2,
    confirm = 3,
    ping = 4,
    name = 6,
};

/// NetplaySession runs entirely on the main thread. The UI calls step() once
/// per frame; step() does one non-blocking ENet poll (timeout=0) and advances
/// the internal handshake state machine by one iteration. This avoids all
/// cross-thread std.Io issues — no background thread, no thread-local state,
/// no races.
///
/// All timeouts are anchored to wall-clock milliseconds via
/// `std.Io.Clock.now(.real, io)`. The previous implementation counted
/// `phase_attempts` per `step()` call and assumed 60 fps — which broke on
/// high-refresh-rate monitors (144 Hz / 240 Hz) where the UI loop runs at
/// the monitor's refresh rate, not at 60 Hz. With wall-clock deadlines the
/// session is correct regardless of the caller's frame rate, which matters
/// because the GUI loop (`src/launcher/ui.zig`) is VSync-bound and the CLI
/// loop (`src/launcher/game_launcher.zig`) sleeps ~16 ms between steps.
pub const NetplaySession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log: *logging.Logger,
    transport: net.EnetTransport,
    state: SessionState = .idle,
    config: NetplayConfig = .{},
    stats: PingStats = .{},
    local_version: []const u8 = "4.0-zig",

    peer_address_buf: [80]u8 = [_]u8{0} ** 80,
    peer_address_len: usize = 0,

    public_ip_buf: [64]u8 = [_]u8{0} ** 64,
    public_ip_len: usize = 0,
    local_ip_buf: [64]u8 = [_]u8{0} ** 64,
    local_ip_len: usize = 0,

    cancel_requested: bool = false,
    host_confirmed: bool = false,

    error_buf: [128]u8 = [_]u8{0} ** 128,
    error_len: usize = 0,

    // --- Status message for UI display (Slice 5 redesign) ---
    //
    // Human-readable status string that describes what the session is
    // currently doing. Updated by stepRelay(), stepListening(), etc.
    // The UI reads this via getStatusMsg() and displays it prominently
    // so the user always knows what's happening.
    status_buf: [128]u8 = [_]u8{0} ** 128,
    status_len: usize = 0,

    // --- Internal sub-state for the step-based handshake state machine ---
    //
    // `phase_deadline_ms` is the wall-clock millisecond timestamp at which
    // the current phase should time out. It is set when entering a phase
    // (via `setPhaseTimeout`) and checked at the top of each `stepXxx()`.
    // 0 means "no deadline / not timing out" (used briefly between phases).
    //
    // `phase_start_ms` is the wall-clock ms when the current phase started;
    // used by `remainingSeconds()` to render a countdown for the UI.
    phase_deadline_ms: i64 = 0,
    phase_start_ms: i64 = 0,
    ping_index: u32 = 0,
    ping_start_ms: i64 = 0,
    handshake_subphase: u8 = 0, // 0=version, 1=names, 2=pings, 3=config
    // Wall-clock ms of the last ENet heartbeat ping sent. Reset to 0 on
    // init. Polled by maybeHeartbeat() in step().
    last_heartbeat_ms: i64 = 0,

    // --- Relay state (Slice 4) ---
    //
    // When non-null, the session is in relay mode (as opposed to direct-IP
    // mode). The relay_client drives the TCP+UDP hole-punch state machine.
    // relay_list owns the host strings that relay_client.relay.host points
    // into — must stay alive for the lifetime of relay_client.
    relay_client: ?relay_client_mod.RelayClient = null,
    relay_list: ?relay_config.RelayList = null,

    // Wall-clock timeouts (milliseconds) for each handshake phase. Tuned
    // to match the original 60-fps frame counts: 300 frames = 5 s,
    // 1800 frames = 30 s, 216000 frames = 1 hour, 50 frames = ~833 ms.
    const listen_timeout_ms: i64 = 60 * 60 * 1000; // 1 hour
    const connect_timeout_ms: i64 = 30 * 1000; // 30 s
    const version_timeout_ms: i64 = 5 * 1000; // 5 s
    const name_timeout_ms: i64 = 5 * 1000; // 5 s (best-effort)
    const host_wait_confirm_timeout_ms: i64 = 30 * 1000; // 30 s
    const ping_per_attempt_timeout_ms: i64 = 833; // ~50 frames @ 60fps
    // ENet heartbeat interval. During phases where no handshake traffic
    // flows (e.g., the host's "Start Match" confirmation screen), send an
    // ENet ping every 2 s to reset the peer's timeout timer. Well within
    // the 30 s minimum timeout set in enet_transport.zig.
    const heartbeat_interval_ms: i64 = 2 * 1000; // 2 s

    pub fn init(allocator: std.mem.Allocator, io: std.Io, log: *logging.Logger) NetplaySession {
        return .{
            .allocator = allocator,
            .io = io,
            .log = log,
            .transport = net.EnetTransport.init(),
        };
    }

    pub fn deinit(self: *NetplaySession) void {
        // Tear down relay state first — relay_client's sockets must be
        // closed before transport.deinit() to avoid port conflicts.
        if (self.relay_client) |*rc| {
            rc.deinit();
            self.relay_client = null;
        }
        if (self.relay_list) |*rl| {
            rl.deinit(self.allocator);
            self.relay_list = null;
        }
        self.transport.deinit();
    }

    pub fn cancel(self: *NetplaySession) void {
        self.cancel_requested = true;
    }

    pub fn peerAddress(self: *const NetplaySession) []const u8 {
        return self.peer_address_buf[0..self.peer_address_len];
    }

    pub fn publicIp(self: *const NetplaySession) ?[]const u8 {
        if (self.public_ip_len == 0) return null;
        return self.public_ip_buf[0..self.public_ip_len];
    }

    pub fn localIp(self: *const NetplaySession) ?[]const u8 {
        if (self.local_ip_len == 0) return null;
        return self.local_ip_buf[0..self.local_ip_len];
    }

    pub fn lookupHostAddresses(self: *NetplaySession) void {
        if (ip_discovery.getPublicIp(&self.public_ip_buf)) |ip| {
            self.public_ip_len = ip.len;
        }
        if (ip_discovery.getLocalIp(&self.local_ip_buf)) |ip| {
            self.local_ip_len = ip.len;
        }
    }

    pub fn setLocalName(self: *NetplaySession, name: []const u8) void {
        const copy_len = @min(name.len, self.config.local_name.len - 1);
        @memcpy(self.config.local_name[0..copy_len], name[0..copy_len]);
        self.config.local_name[copy_len] = 0;
    }

    /// Detect the local connection type (WiFi/Ethernet) and store it.
    /// Called by the launcher before the handshake starts.
    pub fn detectConnectionType(self: *NetplaySession) void {
        const ct = net_util.getConnectionType();
        const copy_len = @min(ct.len, self.config.local_connection_type.len - 1);
        @memcpy(self.config.local_connection_type[0..copy_len], ct[0..copy_len]);
        self.config.local_connection_type[copy_len] = 0;
    }

    pub fn localConnectionType(self: *const NetplaySession) []const u8 {
        return std.mem.sliceTo(&self.config.local_connection_type, 0);
    }

    pub fn remoteConnectionType(self: *const NetplaySession) []const u8 {
        return std.mem.sliceTo(&self.config.remote_connection_type, 0);
    }

    pub fn localName(self: *const NetplaySession) []const u8 {
        return std.mem.sliceTo(&self.config.local_name, 0);
    }

    pub fn remoteName(self: *const NetplaySession) []const u8 {
        return std.mem.sliceTo(&self.config.remote_name, 0);
    }

    pub fn errorMessage(self: *const NetplaySession) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    /// Returns the current status message for UI display.
    /// This is a human-readable string like "Connecting to relay server..."
    /// or "Listening on port 46318 (direct mode)..." that tells the user
    /// exactly what's happening. Never null — returns "Idle." if no status.
    pub fn getStatusMsg(self: *const NetplaySession) []const u8 {
        if (self.status_len == 0) return "Idle.";
        return self.status_buf[0..self.status_len];
    }

    /// Returns the remaining whole seconds for the current phase's timeout,
    /// or null if the current state has no active deadline. Used by the UI
    /// to render a countdown. Wall-clock based, so the countdown runs at
    /// real-time speed regardless of the UI's frame rate.
    pub fn remainingSeconds(self: *const NetplaySession) ?u32 {
        if (self.phase_deadline_ms == 0) return null;
        const now = std.Io.Clock.now(.real, self.io).toMilliseconds();
        const remaining_ms: i64 = self.phase_deadline_ms - now;
        if (remaining_ms <= 0) return 0;
        return @intCast(@divTrunc(remaining_ms, 1000));
    }

    /// Set the deadline for the current phase to `now + duration_ms` and
    /// record the phase start time (for the countdown). Pass 0 to clear.
    fn setPhaseTimeout(self: *NetplaySession, duration_ms: i64) void {
        if (duration_ms == 0) {
            self.phase_deadline_ms = 0;
            self.phase_start_ms = 0;
            return;
        }
        const now = std.Io.Clock.now(.real, self.io).toMilliseconds();
        self.phase_start_ms = now;
        self.phase_deadline_ms = now + duration_ms;
    }

    /// True if the current phase's wall-clock deadline has passed.
    fn phaseTimedOut(self: *const NetplaySession) bool {
        if (self.phase_deadline_ms == 0) return false;
        const now = std.Io.Clock.now(.real, self.io).toMilliseconds();
        return now >= self.phase_deadline_ms;
    }

    fn setError(self: *NetplaySession, msg: []const u8) void {
        const n = @min(msg.len, self.error_buf.len - 1);
        @memcpy(self.error_buf[0..n], msg[0..n]);
        self.error_buf[n] = 0;
        self.error_len = n;
    }

    /// Set the status message shown to the user on the waiting screen.
    /// Called by stepRelay(), stepListening(), stepConnecting(), etc.
    /// to keep the user informed about what's happening.
    fn setStatus(self: *NetplaySession, msg: []const u8) void {
        const n = @min(msg.len, self.status_buf.len - 1);
        @memcpy(self.status_buf[0..n], msg[0..n]);
        self.status_buf[n] = 0;
        self.status_len = n;
    }

    pub fn startHost(self: *NetplaySession, port: u16, training: bool) !void {
        self.config.is_host = true;
        self.config.is_training = training;
        self.config.is_netplay = true;
        self.config.host_player = 1;
        self.config.local_player = 1;
        self.config.remote_player = 2;
        self.config.peer_port = port;
        self.state = .listening;
        self.setPhaseTimeout(listen_timeout_ms);
        try self.transport.listen(port, self.log);
        self.setStatus("Listening for direct connection...");
        self.log.info("Waiting for opponent to connect on port {d}...", .{port});
    }

    pub fn startJoin(self: *NetplaySession, host_str: []const u8, port: u16, training: bool) !void {
        self.config.is_host = false;
        self.config.is_training = training;
        self.config.is_netplay = true;
        self.config.host_player = 1;
        self.config.local_player = 2;
        self.config.remote_player = 1;
        self.config.peer_port = port;
        const addr_copy_len = @min(host_str.len, self.config.peer_addr.len);
        @memcpy(self.config.peer_addr[0..addr_copy_len], host_str[0..addr_copy_len]);
        self.state = .connecting;
        self.setPhaseTimeout(connect_timeout_ms);
        try self.transport.connect(host_str, port, self.log);
        self.setStatus("Connecting directly to peer...");
    }

    // ========================================================================
    // Smart host — direct listener + relay in parallel (Slice 4 fix)
    // ========================================================================
    //
    // The smart host flow opens a direct ENet listener on `port` AND starts a
    // relay client (for NAT traversal) in parallel. Whichever peer arrives
    // first wins:
    //
    //   - If a direct peer connects (localhost/LAN), the relay client is
    //     canceled and the existing ENet handshake flow takes over.
    //   - If the relay handshake completes first (peer behind NAT), the
    //     direct listener is torn down and re-created bound to the relay's
    //     local_udp_port — preserving the NAT mapping opened during
    //     hole-punching. The peer's ENet CONNECT then arrives at the new
    //     listener.
    //
    // The relay client uses local_port=0 (random) so its UDP socket does
    // NOT conflict with the direct ENet listener (which is bound to `port`).
    // This is safe because the zzcaster relay matches peers by room code,
    // not by IP:port — so the relay doesn't care which local port the
    // host's UDP socket is bound to.
    //
    // If the relay list is empty or the relay client fails to start, the
    // session falls back to direct-only mode (still in .listening state).
    //
    // This fixes the regression where the smart host flow forced ALL host
    // sessions through the relay path — breaking localhost/LAN connections
    // where the relay is unreachable or unnecessary.

    pub fn startSmartHost(
        self: *NetplaySession,
        relay_source: []const u8,
        port: u16,
        training: bool,
    ) !void {
        // Set up config (same as direct host).
        self.config.is_host = true;
        self.config.is_training = training;
        self.config.is_netplay = true;
        self.config.host_player = 1;
        self.config.local_player = 1;
        self.config.remote_player = 2;
        self.config.peer_port = port;

        // Start the direct ENet listener FIRST. This ensures localhost and
        // LAN peers can connect immediately, without waiting for the relay
        // handshake to complete (or fail). This is the critical fix for the
        // localhost/LAN regression.
        try self.transport.listen(port, self.log);

        // Try to start the relay client in parallel. The relay client uses
        // local_port=0 (random) so it doesn't conflict with the direct
        // listener on `port`. If the relay list is empty or the client
        // fails to start, we continue with direct-only mode.
        self.relay_list = relay_config.parseList(self.allocator, relay_source) catch {
            self.log.warn("Failed to parse relay list — continuing with direct only", .{});
            self.state = .listening;
            self.setPhaseTimeout(listen_timeout_ms);
            self.setStatus("Listening for direct connection...");
            return;
        };

        if (self.relay_list.?.count() == 0) {
            self.log.info("No relay servers configured — continuing with direct only", .{});
            self.relay_list.?.deinit(self.allocator);
            self.relay_list = null;
            self.state = .listening;
            self.setPhaseTimeout(listen_timeout_ms);
            self.setStatus("Listening for direct connection...");
            return;
        }

        const entry = self.relay_list.?.get(0).?;

        // Initialize the relay client with local_port=0 (random) to avoid
        // port conflict with the direct ENet listener.
        self.relay_client = relay_client_mod.RelayClient.init(self.io, .{
            .relay = entry,
            .role = .host,
            .local_port = 0,
        });

        // Check for immediate failure (e.g., invalid relay address).
        if (self.relay_client.?.getState() == .failed) {
            const err = self.relay_client.?.getError() orelse .socket_error;
            self.log.warn("Relay client failed to start: {s} — continuing with direct only", .{err.label()});
            self.relay_client.?.deinit();
            self.relay_client = null;
            if (self.relay_list) |*rl| {
                rl.deinit(self.allocator);
            }
            self.relay_list = null;
            self.state = .listening;
            self.setPhaseTimeout(listen_timeout_ms);
            self.setStatus("Listening for direct connection...");
            return;
        }

        self.state = .listening;
        self.setPhaseTimeout(listen_timeout_ms);
        self.setStatus("Listening for direct connection...");
        self.log.info("Smart host started on port {d} (direct + relay)", .{port});
    }

    // ========================================================================
    // Relay-assisted connection (Slice 4)
    // ========================================================================
    //
    // These methods start a relay-assisted connection. The relay handles
    // NAT traversal (hole-punching) so the host doesn't need to port-forward.
    //
    // After the relay handshake completes (peer's UDP endpoint discovered),
    // the session transitions to .connecting and the existing ENet handshake
    // flow takes over — the relay is no longer involved.
    //
    // `relay_source` is the text contents of relay_list.txt or the
    // relayServers= config field. The session parses it, picks the first
    // entry, and owns the parsed list for the session's lifetime.
    //
    // For host: generates a 4-letter room code internally.
    //   Call getRoomCode() after startRelayHost to display it to the user.
    //
    // For client: `peer_identifier` is the 4-letter room code.

    pub fn startRelayHost(
        self: *NetplaySession,
        relay_source: []const u8,
        port: u16,
        training: bool,
    ) !void {
        // Parse relay list
        self.relay_list = relay_config.parseList(self.allocator, relay_source) catch {
            self.setError("Failed to parse relay server list");
            self.state = .failed;
            return;
        };

        if (self.relay_list.?.count() == 0) {
            self.setError("No relay servers configured");
            self.state = .failed;
            return;
        }

        const entry = self.relay_list.?.get(0).?;

        // Initialize relay client as host
        self.relay_client = relay_client_mod.RelayClient.init(self.io, .{
            .relay = entry,
            .role = .host,
            .local_port = port,
        });

        // Check for immediate failure (e.g., TCP connect failed)
        if (self.relay_client.?.getState() == .failed) {
            const err = self.relay_client.?.getError() orelse .socket_error;
            self.setError(err.label());
            self.state = .failed;
            return;
        }

        // Set up config (same as direct host, but no ENet listen yet)
        self.config.is_host = true;
        self.config.is_training = training;
        self.config.is_netplay = true;
        self.config.host_player = 1;
        self.config.local_player = 1;
        self.config.remote_player = 2;
        self.config.peer_port = port;

        self.state = .relay_connecting;
        self.setPhaseTimeout(0); // RelayClient manages its own timeouts
        self.setStatus("Connecting to relay server...");
        self.log.info("Relay host started", .{});
    }

    pub fn startRelayJoin(
        self: *NetplaySession,
        relay_source: []const u8,
        peer_identifier: []const u8,
        training: bool,
    ) !void {
        // Parse relay list
        self.relay_list = relay_config.parseList(self.allocator, relay_source) catch {
            self.setError("Failed to parse relay server list");
            self.state = .failed;
            return;
        };

        if (self.relay_list.?.count() == 0) {
            self.setError("No relay servers configured");
            self.state = .failed;
            return;
        }

        const entry = self.relay_list.?.get(0).?;

        // Initialize relay client as client
        self.relay_client = relay_client_mod.RelayClient.init(self.io, .{
            .relay = entry,
            .role = .client,
            .local_port = 0, // client uses any available port
            .peer_identifier = peer_identifier,
        });

        // Check for immediate failure (e.g., invalid room code, TCP connect failed)
        if (self.relay_client.?.getState() == .failed) {
            const err = self.relay_client.?.getError() orelse .socket_error;
            self.setError(err.label());
            self.state = .failed;
            return;
        }

        // Set up config (same as direct join, but no ENet connect yet)
        self.config.is_host = false;
        self.config.is_training = training;
        self.config.is_netplay = true;
        self.config.host_player = 1;
        self.config.local_player = 2;
        self.config.remote_player = 1;

        self.state = .relay_connecting;
        self.setPhaseTimeout(0); // RelayClient manages its own timeouts
        self.setStatus("Connecting to relay server...");
        self.log.info("Relay join started", .{});
    }

    /// For relay host: returns the generated 4-letter room code.
    /// For all other cases: returns null.
    pub fn getRoomCode(self: *const NetplaySession) ?[4]u8 {
        if (self.relay_client) |rc| return rc.getRoomCode();
        return null;
    }

    /// Returns true if the session is using relay-assisted connection.
    pub fn isRelayMode(self: *const NetplaySession) bool {
        return self.relay_client != null;
    }

    pub fn step(self: *NetplaySession) void {
        if (self.cancel_requested) {
            if (self.state != .launching and self.state != .failed and self.state != .cancelled) {
                self.state = .cancelled;
            }
            return;
        }

        // Heartbeat: send an ENet ping every 2 s to keep the peer alive
        // during phases where no other traffic flows (e.g., while the
        // host is on the "Start Match" confirmation screen). Without this,
        // ENet's peer timeout can fire and the peer disconnects — manifesting
        // as "Peer disconnected waiting for confirm" on the host side.
        self.maybeHeartbeat();

        switch (self.state) {
            .idle, .launching, .completed, .failed, .cancelled => return,

            .waiting_confirmation => {
                if (self.transport.poll(0)) |event| {
                    if (event == .disconnected) {
                        self.setError("Peer disconnected while waiting for host to confirm");
                        self.state = .failed;
                    }
                }
                return;
            },

            .listening => self.stepListening(),
            .connecting => self.stepConnecting(),
            .handshaking => self.stepHandshaking(),
            .ping_exchanging => self.stepPingExchanging(),
            .relay_connecting => self.stepRelay(),
        }
    }

    /// Send an ENet ping every `heartbeat_interval_ms` to keep the peer
    /// alive during phases where no other traffic flows. This is critical
    /// for the GUI flow where the host may spend many seconds on the
    /// "Start Match" confirmation screen — without heartbeats, ENet's
    /// peer timeout fires and the client disconnects.
    fn maybeHeartbeat(self: *NetplaySession) void {
        if (self.transport.peer == null or !self.transport.connected) return;
        const now = std.Io.Clock.now(.real, self.io).toMilliseconds();
        if (now - self.last_heartbeat_ms >= heartbeat_interval_ms) {
            self.transport.ping();
            self.last_heartbeat_ms = now;
        }
    }

    fn stepListening(self: *NetplaySession) void {
        if (self.phaseTimedOut()) {
            self.setError("Connection timed out (no opponent connected in 1 hour)");
            self.state = .failed;
            return;
        }

        // Step the parallel relay client if present (smart host mode).
        // stepParallelRelay may change state (e.g., to .failed if the relay
        // listener can't be rebound). If state changed, bail out this frame.
        if (self.relay_client != null) {
            self.stepParallelRelay();
            if (self.state != .listening) return;
        }

        if (self.transport.poll(0)) |event| {
            if (event == .connected) {
                self.log.info("Opponent connected!", .{});
                // A direct peer connected. Cancel the relay client if it's
                // still running — we're committing to the direct connection.
                if (self.relay_client) |*rc| {
                    rc.deinit();
                    self.relay_client = null;
                }
                if (self.relay_list) |*rl| {
                    rl.deinit(self.allocator);
                    self.relay_list = null;
                }
                self.recordPeerAddress();
                self.state = .handshaking;
                self.startVersionExchange();
            }
        }
    }

    /// Drive the parallel relay client (used in .listening state for smart
    /// host mode). If the relay handshake succeeds, tears down the direct
    /// ENet listener and re-creates it bound to the relay's local_udp_port
    /// (preserving the NAT mapping). If the relay fails, just deinit's the
    /// relay client and continues with direct-only mode.
    fn stepParallelRelay(self: *NetplaySession) void {
        const rc = &self.relay_client.?;

        // While the relay is retrying (backoff wait between attempts),
        // keep the host screen informative: the direct listener is still
        // open and the room code is still valid, but the relay path is
        // re-attempting. Without this, the host would see a stale
        // "Listening for direct connection..." with no hint that the relay
        // is recovering.
        if (rc.getState() == .retrying) {
            var buf: [112]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Listening for direct connection... (retrying relay, attempt {d})", .{rc.getRetryCount()}) catch "Listening for direct connection... (retrying relay)";
            self.setStatus(msg);
        }

        const result = rc.step(self.io);

        if (result == null) return; // still in progress

        switch (result.?) {
            .in_progress => return,
            .success => |r| {
                self.log.info("Relay handshake succeeded — peer={d}.{d}.{d}.{d}:{d}, local_udp_port={d}", .{
                    r.peer_ip[0], r.peer_ip[1], r.peer_ip[2], r.peer_ip[3],
                    r.peer_port, r.local_udp_port,
                });

                // CRITICAL: Write the relay result back into self.config so
                // launchGameAfterHandshake() snapshots the correct
                // local_udp_port for the DLL via IPC. The host DLL needs
                // this to bind its ENet host to the hole-punch port.
                // (See stepRelay's success handler for the full rationale.)
                self.config.local_udp_port = r.local_udp_port;
                self.config.peer_port = r.local_udp_port;

                // Tear down the relay sockets FIRST (frees local_udp_port).
                rc.deinit();
                self.relay_client = null;

                // Tear down the direct ENet listener so we can rebind to
                // local_udp_port (the port used for hole-punching). This
                // preserves the NAT mapping that was opened during
                // hole-punching — the peer's ENet CONNECT will arrive at
                // local_udp_port and reach our new listener.
                self.transport.deinit();

                // Re-create the transport as a listener on local_udp_port.
                self.transport.listen(r.local_udp_port, self.log) catch |err| {
                    var err_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&err_buf, "ENet listen after relay failed: {s}", .{@errorName(err)}) catch "ENet listen after relay failed";
                    self.setError(msg);
                    self.state = .failed;
                    return;
                };

                // Free the relay list — no longer needed.
                if (self.relay_list) |*rl| {
                    rl.deinit(self.allocator);
                    self.relay_list = null;
                }

                self.setStatus("Connected via relay! Waiting for ENet connect...");
                // Stay in .listening state — wait for the peer's ENet CONNECT.
                // The existing stepListening flow will detect the connection
                // and transition to .handshaking.
            },
            .failed => |err| {
                // Relay failed — continue with direct-only mode. Don't fail
                // the session: the direct listener is still open, and a
                // direct peer may still connect.
                self.log.warn("Relay failed: {s} — continuing with direct only", .{err.label()});
                rc.deinit();
                self.relay_client = null;
                if (self.relay_list) |*rl| {
                    rl.deinit(self.allocator);
                    self.relay_list = null;
                }
                self.setStatus("Listening for direct connection...");
                // Stay in .listening state — continue with direct.
            },
        }
    }

    fn stepConnecting(self: *NetplaySession) void {
        if (self.phaseTimedOut()) {
            self.setError("Failed to connect to host (30s timeout)");
            self.state = .failed;
            return;
        }

        if (self.transport.poll(0)) |event| {
            if (event == .connected) {
                self.log.info("Connected to host!", .{});
                self.recordPeerAddress();
                self.state = .handshaking;
                self.startVersionExchange();
            }
        }
    }

    // ========================================================================
    // Relay step handler (Slice 4)
    // ========================================================================

    /// Drives the relay handshake state machine. This is used by the CLIENT
    /// side (startRelayJoin) — the HOST side uses startSmartHost which drives
    /// the relay client from stepListening/stepParallelRelay.
    ///
    /// When the relay handshake completes successfully (peer's UDP endpoint
    /// discovered), tears down the relay sockets and transitions to .connecting
    /// via ENet's connectBound() — preserving the NAT mapping opened during
    /// hole-punch.
    ///
    /// NOTE: This handler is also reached if startRelayHost is called directly
    /// (i.e., without the parallel direct listener). In that case, on relay
    /// success the host LISTENs (not connects) on local_udp_port — the peer's
    /// ENet CONNECT then arrives at this listener. On relay failure, the host
    /// falls back to direct listen on peer_port.
    fn stepRelay(self: *NetplaySession) void {
        if (self.relay_client == null) {
            self.setError("Relay client not initialized");
            self.state = .failed;
            return;
        }

        const rc = &self.relay_client.?;

        // Update status message based on relay client's internal state
        switch (rc.getState()) {
            .tcp_connecting => self.setStatus("Connecting to relay server..."),
            .waiting_for_hosted => self.setStatus("Registering with relay..."),
            .waiting_for_match_info => {
                if (self.config.is_host) {
                    self.setStatus("Waiting for opponent to join...");
                } else {
                    self.setStatus("Joining host via relay...");
                }
            },
            .waiting_for_tun_info => self.setStatus("Negotiating connection..."),
            .hole_punching => self.setStatus("Hole-punching through NAT..."),
            .retrying => {
                // Relay handshake failed but will be retried (backoff).
                // Surface the attempt number so the user sees progress
                // rather than a stuck "Connecting..." message.
                var buf: [96]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Retrying relay connection (attempt {d})...", .{rc.getRetryCount()}) catch "Retrying relay connection...";
                self.setStatus(msg);
            },
            else => {},
        }

        const result = rc.step(self.io);

        if (result == null) return; // still in progress

        switch (result.?) {
            .in_progress => return,
            .success => |r| {
                self.log.info("Relay handshake succeeded — peer={d}.{d}.{d}.{d}:{d}, local_udp_port={d}", .{
                    r.peer_ip[0], r.peer_ip[1], r.peer_ip[2], r.peer_ip[3],
                    r.peer_port, r.local_udp_port,
                });
                self.setStatus("Connected! Starting ENet handshake...");

                // Format peer IP as string for ENet (needed for client-side
                // connectBound; harmless on host side).
                var peer_ip_str: [32]u8 = undefined;
                const peer_ip_z = std.fmt.bufPrintZ(&peer_ip_str, "{d}.{d}.{d}.{d}", .{
                    r.peer_ip[0], r.peer_ip[1], r.peer_ip[2], r.peer_ip[3],
                }) catch {
                    self.setError("Failed to format peer IP");
                    self.state = .failed;
                    return;
                };

                // CRITICAL: Write the relay result back into self.config so
                // launchGameAfterHandshake() snapshots the correct peer
                // endpoint and local_udp_port for the DLL via IPC.
                //
                // Without this, the DLL receives peer_port=0 and an empty
                // peer_addr (the values from startRelayJoin, which never
                // set them), and ENet connects to peer_ip:0 → instant
                // failure. This was the root cause of "all remote
                // connections fail with a black screen + crash".
                //
                // Host: peer_port is set to local_udp_port so the DLL's
                //   enet_host_create binds to the same port the relay's
                //   hole-punch used (preserves the NAT mapping). The host
                //   doesn't need a peer_addr (it listens, not connects).
                // Client: peer_addr is set to the relay-discovered peer IP,
                //   peer_port to the relay-discovered peer port, and
                //   local_udp_port is preserved so the DLL can bind its
                //   ENet host to the hole-punch port (connectBound).
                self.config.local_udp_port = r.local_udp_port;
                if (self.config.is_host) {
                    self.config.peer_port = r.local_udp_port;
                } else {
                    // Copy the peer IP string into config.peer_addr (the
                    // non-null-terminated version for the DLL).
                    const ip_len = @min(peer_ip_z.len, self.config.peer_addr.len - 1);
                    @memcpy(self.config.peer_addr[0..ip_len], peer_ip_z[0..ip_len]);
                    self.config.peer_addr[ip_len] = 0;
                    self.config.peer_port = r.peer_port;
                }

                // Tear down relay sockets BEFORE creating ENet host.
                // ENet creates its own UDP socket and binds it to
                // local_udp_port. With SO_REUSEADDR (which both the relay
                // client and ENet set), the rebind succeeds immediately.
                rc.deinit();
                self.relay_client = null;

                // Also free the relay list — no longer needed.
                if (self.relay_list) |*rl| {
                    rl.deinit(self.allocator);
                    self.relay_list = null;
                }

                if (self.config.is_host) {
                    // HOST: listen on local_udp_port for the peer's ENet
                    // CONNECT. The peer (client) will connectBound to us.
                    // This is the symmetric counterpart to the client's
                    // connectBound — without it, BOTH sides would try to
                    // connect and neither would listen, so ENet could never
                    // establish a connection (the original regression).
                    self.transport.listen(r.local_udp_port, self.log) catch |err| {
                        var err_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&err_buf, "ENet listen failed: {s}", .{@errorName(err)}) catch "ENet listen failed";
                        self.setError(msg);
                        self.state = .failed;
                        return;
                    };
                    self.state = .listening;
                    self.setPhaseTimeout(listen_timeout_ms);
                    self.setStatus("Connected via relay! Waiting for ENet connect...");
                } else {
                    // CLIENT: connect to peer via ENet, bound to the same
                    // local port that was used for hole-punching (preserves
                    // NAT mapping).
                    self.transport.connectBound(
                        peer_ip_z,
                        r.peer_port,
                        r.local_udp_port,
                        self.log,
                    ) catch |err| {
                        var err_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&err_buf, "ENet connect failed: {s}", .{@errorName(err)}) catch "ENet connect failed";
                        self.setError(msg);
                        self.state = .failed;
                        return;
                    };
                    self.state = .connecting;
                    self.setPhaseTimeout(connect_timeout_ms);
                }
            },
            .failed => |err| {
                if (self.config.is_host) {
                    // HOST: fall back to direct listen on peer_port. The
                    // comment in startSmartHostSession claimed this fallback
                    // existed, but the original code just set state to .failed
                    // — breaking localhost/LAN connections when the relay was
                    // unreachable. Now we actually fall back.
                    self.log.warn("Relay failed: {s} — falling back to direct listen", .{err.label()});
                    rc.deinit();
                    self.relay_client = null;
                    if (self.relay_list) |*rl| {
                        rl.deinit(self.allocator);
                        self.relay_list = null;
                    }
                    self.transport.listen(self.config.peer_port, self.log) catch |listen_err| {
                        var err_buf: [128]u8 = undefined;
                        const msg = std.fmt.bufPrint(&err_buf, "Direct listen fallback failed: {s}", .{@errorName(listen_err)}) catch "Direct listen fallback failed";
                        self.setError(msg);
                        self.state = .failed;
                        return;
                    };
                    self.state = .listening;
                    self.setPhaseTimeout(listen_timeout_ms);
                    self.setStatus("Listening for direct connection... (relay failed)");
                } else {
                    // CLIENT: report failure with the structured error's
                    // label + suggestion for a helpful message.
                    var err_buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&err_buf, "{s}. {s}", .{
                        err.label(),
                        err.suggestion(),
                    }) catch err.label();
                    self.setError(msg);
                    self.setStatus("Connection failed.");
                    self.state = .failed;
                }
            },
        }
    }

    fn startVersionExchange(self: *NetplaySession) void {
        self.handshake_subphase = 0;
        // Send our version: [1=version][len byte][version bytes]
        var ver_buf: [128]u8 = undefined;
        ver_buf[0] = @intFromEnum(Msg.version);
        const ver_len = @min(self.local_version.len, 126);
        ver_buf[1] = @intCast(ver_len);
        @memcpy(ver_buf[2 .. 2 + ver_len], self.local_version[0..ver_len]);
        _ = self.transport.sendReliable(ver_buf[0 .. 2 + ver_len]);
        self.log.info("Sent version: {s}", .{self.local_version});
        self.setPhaseTimeout(version_timeout_ms);
    }

    fn stepHandshaking(self: *NetplaySession) void {
        switch (self.handshake_subphase) {
            0 => self.stepExchangeVersion(),
            1 => self.stepExchangeNames(),

            3 => self.stepExchangeConfig(),
            else => self.state = .failed,
        }
    }

    fn stepExchangeVersion(self: *NetplaySession) void {
        if (self.phaseTimedOut()) {
            self.setError("Version exchange timed out");
            self.state = .failed;
            return;
        }

        if (self.transport.poll(0)) |event| {
            if (event == .message_received) {
                const msg = self.transport.getLastMessage();
                if (msg.len >= 2 and msg[0] == @intFromEnum(Msg.version)) {
                    const peer_ver_len: usize = @min(msg[1], msg.len - 2);
                    const peer_ver = msg[2 .. 2 + peer_ver_len];
                    self.log.info("Peer version: {s}", .{peer_ver});
                    if (!std.mem.eql(u8, peer_ver, self.local_version)) {
                        const err_msg = std.fmt.bufPrint(&self.error_buf, "Version mismatch: local={s} remote={s}", .{ self.local_version, peer_ver }) catch "Version mismatch";
                        self.error_len = err_msg.len;
                        self.state = .failed;
                        return;
                    }
                    // Move to name exchange.
                    self.handshake_subphase = 1;
                    self.startNameExchange();
                }
            }
            if (event == .disconnected) {
                self.setError("Peer disconnected during handshake");
                self.state = .failed;
            }
        }
    }

    fn startNameExchange(self: *NetplaySession) void {
        const local = self.localName();
        const conn_type = self.localConnectionType();
        // Format: [6=name][name_len][name_bytes][conn_type_len][conn_type_bytes]
        var buf: [66]u8 = undefined;
        buf[0] = @intFromEnum(Msg.name);
        const name_len = @min(local.len, 31);
        buf[1] = @intCast(name_len);
        @memcpy(buf[2 .. 2 + name_len], local[0..name_len]);
        const ct_len = @min(conn_type.len, 15);
        buf[2 + name_len] = @intCast(ct_len);
        @memcpy(buf[3 + name_len .. 3 + name_len + ct_len], conn_type[0..ct_len]);
        _ = self.transport.sendReliable(buf[0 .. 3 + name_len + ct_len]);
        self.log.info("Sent display name: '{s}' (conn: {s})", .{ local, conn_type });
        self.setPhaseTimeout(name_timeout_ms);
    }

    fn stepExchangeNames(self: *NetplaySession) void {
        // Name exchange is best-effort — on timeout we continue with an
        // empty remote name rather than failing the handshake.
        if (self.phaseTimedOut()) {
            self.log.warn("Name exchange timed out — continuing with empty remote name", .{});
            self.handshake_subphase = 2;
            self.startPingExchange();
            return;
        }

        if (self.transport.poll(0)) |event| {
            if (event == .message_received) {
                const msg = self.transport.getLastMessage();
                if (msg.len >= 2 and msg[0] == @intFromEnum(Msg.name)) {
                    const peer_name_len: usize = @min(msg[1], msg.len - 2);
                    const peer_name = msg[2 .. 2 + peer_name_len];
                    const copy_len = @min(peer_name.len, self.config.remote_name.len - 1);
                    @memcpy(self.config.remote_name[0..copy_len], peer_name[0..copy_len]);
                    self.config.remote_name[copy_len] = 0;

                    // Parse connection type if present (appended after name).
                    if (msg.len >= 3 + peer_name_len) {
                        const ct_len: usize = @min(msg[2 + peer_name_len], msg.len - 3 - peer_name_len);
                        const ct = msg[3 + peer_name_len .. 3 + peer_name_len + ct_len];
                        const ct_copy = @min(ct.len, self.config.remote_connection_type.len - 1);
                        @memcpy(self.config.remote_connection_type[0..ct_copy], ct[0..ct_copy]);
                        self.config.remote_connection_type[ct_copy] = 0;
                    }

                    self.log.info("Peer display name: '{s}' (conn: {s})", .{ self.remoteName(), self.remoteConnectionType() });
                    self.handshake_subphase = 2;
                    self.startPingExchange();
                }
            }
            if (event == .disconnected) {
                self.setError("Peer disconnected during name exchange");
                self.state = .failed;
            }
        }
    }

    fn startPingExchange(self: *NetplaySession) void {
        self.state = .ping_exchanging;
        self.ping_index = 0;
        self.sendOnePing();
    }

    fn sendOnePing(self: *NetplaySession) void {
        self.ping_start_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
        var ping_msg: [9]u8 = undefined;
        ping_msg[0] = @intFromEnum(Msg.ping);
        std.mem.writeInt(u64, ping_msg[1..9], @intCast(self.ping_start_ms), .little);
        _ = self.transport.sendReliable(&ping_msg);
        // `ping_start_ms` doubles as the per-ping deadline anchor.
        // stepPingExchanging checks (now - ping_start_ms) >= 833ms.
    }

    fn stepPingExchanging(self: *NetplaySession) void {
        // Each ping waits up to ~833 ms for a pong. Wall-clock based so
        // the per-ping timeout is correct regardless of UI frame rate.
        const now = std.Io.Clock.now(.real, self.io).toMilliseconds();
        if (now - self.ping_start_ms >= ping_per_attempt_timeout_ms) {
            // Timeout on this ping — move to next.
            self.ping_index += 1;
            if (self.ping_index >= 5) {
                self.finishPingExchange();
                return;
            }
            self.sendOnePing();
            return;
        }

        if (self.transport.poll(0)) |event| {
            if (event == .message_received) {
                const msg = self.transport.getLastMessage();
                if (msg.len >= 9 and msg[0] == @intFromEnum(Msg.ping)) {
                    const rtt = std.Io.Clock.now(.real, self.io).toMilliseconds() - self.ping_start_ms;
                    self.stats.count += 1;
                    const c = @as(f64, @floatFromInt(self.stats.count));
                    const r = @as(f64, @floatFromInt(rtt));
                    self.stats.avg_ms = (self.stats.avg_ms * (c - 1) + r) / c;
                    if (self.stats.min_ms == 0 or r < self.stats.min_ms) self.stats.min_ms = r;
                    if (r > self.stats.max_ms) self.stats.max_ms = r;

                    self.ping_index += 1;
                    if (self.ping_index >= 5) {
                        self.finishPingExchange();
                        return;
                    }
                    self.sendOnePing();
                } else if (msg.len >= 1 and msg[0] == @intFromEnum(Msg.ping)) {
                    // Echo stray pings from peer.
                    _ = self.transport.sendReliable(msg);
                }
            }
            if (event == .disconnected) {
                self.setError("Peer disconnected during ping exchange");
                self.state = .failed;
            }
        }
    }

    fn finishPingExchange(self: *NetplaySession) void {
        const stats = self.transport.getStats();
        self.stats.packet_loss = @intCast(stats.packet_loss_pct);
        self.log.info("Ping: avg={d:.0}ms min={d:.0}ms max={d:.0}ms loss={d}%", .{
            self.stats.avg_ms, self.stats.min_ms, self.stats.max_ms, self.stats.packet_loss,
        });

        // HOST computes the delay from ping RTT. The host's delay is
        // authoritative — it's sent to the client in the config message
        // (sendConfigMessage), and the client adopts it (stepExchangeConfig).
        //
        // The CLIENT does NOT compute its own delay. It waits for the host's
        // config and uses whatever delay the host sends. This guarantees both
        // peers use the same delay value — a mismatch causes immediate desync.
        //
        // Previously, both peers computed their own delay from their own RTT
        // measurement. If the measurements differed (asymmetric routing,
        // jitter), the peers ended up with different delay values → desync.
        // Now only the host computes; the client adopts.
        if (self.config.is_host) {
            const avg_rtt = if (self.stats.avg_ms > 0) self.stats.avg_ms else 50;
            const computed: u8 = @intFromFloat(@ceil(avg_rtt / (1000.0 / 60.0)));
            self.config.delay = @min(computed, 8);
            self.log.info("Auto delay (host): {d}", .{self.config.delay});
        } else {
            self.log.info("Client: waiting for host's delay (not computing own)", .{});
        }

        // After ping exchange:
        // - Host: go to waiting_confirmation. Config is sent later when
        //   the host clicks "Start Match" (hostConfirm), so the host can
        //   override the delay on the confirmation screen.
        // - Client: wait for the host's config message (subphase 3).
        if (self.config.is_host) {
            self.state = .waiting_confirmation;
            // No active deadline while we wait for the user to click Start.
            self.setPhaseTimeout(0);
            self.log.info("Handshake complete — waiting for host to confirm start", .{});
            self.notifyHostConfirmation();
        } else {
            self.handshake_subphase = 3;
            // Client waits for host's config — no explicit timeout (the
            // transport-level heartbeat will catch a stale peer).
            self.setPhaseTimeout(0);
            self.state = .handshaking;
        }
    }

    fn sendConfigMessage(self: *NetplaySession) void {
        var cfg_buf: [8]u8 = undefined;
        cfg_buf[0] = @intFromEnum(Msg.config);
        cfg_buf[1] = self.config.delay;
        cfg_buf[2] = self.config.rollback;
        cfg_buf[3] = self.config.win_count;
        cfg_buf[4] = self.config.host_player;
        _ = self.transport.sendReliable(cfg_buf[0..5]);
        self.log.info("Sent config: delay={d} rollback={d} winCount={d} hostPlayer={d}", .{
            self.config.delay, self.config.rollback, self.config.win_count, self.config.host_player,
        });
    }

    fn stepExchangeConfig(self: *NetplaySession) void {
        // Host waits up to 30 s for the client's confirm. Client has no
        // explicit timeout — the transport heartbeat catches a stale host.
        if (self.config.is_host and self.phaseTimedOut()) {
            self.setError("Client never confirmed config (30s timeout)");
            self.state = .failed;
            return;
        }

        if (self.transport.poll(0)) |event| {
            if (event == .message_received) {
                const msg = self.transport.getLastMessage();
                if (self.config.is_host) {
                    if (msg.len >= 1 and msg[0] == @intFromEnum(Msg.confirm)) {
                        self.log.info("Client confirmed config", .{});
                        self.state = .launching;
                        self.log.info("Handshake complete — ready to launch", .{});
                    }
                } else {
                    // Client waits for config, then sends confirm.
                    if (msg.len >= 5 and msg[0] == @intFromEnum(Msg.config)) {
                        self.config.delay = msg[1];
                        self.config.rollback = msg[2];
                        self.config.win_count = msg[3];
                        self.config.host_player = msg[4];
                        self.log.info("Received config: delay={d} rollback={d} winCount={d} hostPlayer={d}", .{
                            self.config.delay, self.config.rollback, self.config.win_count, self.config.host_player,
                        });
                        const confirm = [_]u8{@intFromEnum(Msg.confirm)};
                        _ = self.transport.sendReliable(&confirm);
                        self.log.info("Sent confirm", .{});
                        self.state = .launching;
                        self.log.info("Handshake complete — ready to launch", .{});
                    }
                }
            }
            if (event == .disconnected) {
                if (self.config.is_host) {
                    self.setError("Peer disconnected waiting for confirm");
                } else {
                    self.setError("Host disconnected during config exchange");
                }
                self.state = .failed;
            }
        }
    }

    fn recordPeerAddress(self: *NetplaySession) void {
        const is_host = self.config.is_host;
        const label = if (is_host) "connected-client" else "host";
        const printed = std.fmt.bufPrint(
            &self.peer_address_buf,
            "{s}",
            .{label},
        ) catch return;
        self.peer_address_len = printed.len;
    }

    /// Host-only: called by the UI once the user clicks "Start match".
    /// Sends the config (with the final delay value, which the host may
    /// have overridden) and transitions to a sub-phase that waits for
    /// the client's confirm. The step() function handles the confirm.
    pub fn hostConfirm(self: *NetplaySession) void {
        if (self.state != .waiting_confirmation) return;
        self.host_confirmed = true;
        // Send config with the (possibly overridden) delay.
        self.sendConfigMessage();
        // Move to config-exchange sub-phase to wait for client confirm.
        self.handshake_subphase = 3;
        self.setPhaseTimeout(host_wait_confirm_timeout_ms);
        self.state = .handshaking;
        self.log.info("Host confirmed — sent config, waiting for client confirm (delay={d})", .{self.config.delay});
    }

    fn notifyHostConfirmation(self: *NetplaySession) void {
        if (builtin.os.tag != .windows) return;

        const hwnd = win32.getWindowHandle();
        if (hwnd) |h| {
            _ = win32.FlashWindow(h, 1);
        }
        _ = win32.MessageBeep(0);
        self.log.info("Handshake complete: played notification sound and requested attention on launcher window", .{});
    }
};

const win32 = struct {
    const HWND = ?*anyopaque;
    const BOOL = i32;
    const LPARAM = usize;
    const WPARAM = usize;
    const UINT = u32;

    extern "user32" fn FlashWindow(hWnd: HWND, bInvert: BOOL) callconv(.winapi) BOOL;
    extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
    extern "user32" fn GetActiveWindow() callconv(.winapi) HWND;
    extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*u32) callconv(.winapi) u32;
    extern "user32" fn EnumWindows(lpEnumFunc: *const fn (HWND, LPARAM) callconv(.winapi) BOOL, lParam: LPARAM) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

    const EnumState = struct {
        pid: u32,
        hwnd: HWND,
    };

    fn getWindowHandle() HWND {
        if (builtin.os.tag != .windows) return null;
        
        if (GetActiveWindow()) |hwnd| {
            return hwnd;
        }

        const target_pid = GetCurrentProcessId();
        var state = EnumState{
            .pid = target_pid,
            .hwnd = null,
        };

        const Helper = struct {
            fn enumProc(hwnd: HWND, lParam: LPARAM) callconv(.winapi) BOOL {
                var s: *EnumState = @ptrFromInt(lParam);
                var process_id: u32 = 0;
                _ = GetWindowThreadProcessId(hwnd, &process_id);
                if (process_id == s.pid) {
                    s.hwnd = hwnd;
                    return 0; // stop
                }
                return 1; // continue
            }
        };

        _ = EnumWindows(Helper.enumProc, @intFromPtr(&state));
        return state.hwnd;
    }
};
