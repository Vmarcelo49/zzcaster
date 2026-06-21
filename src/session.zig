const std = @import("std");
const logging = @import("logging.zig");
const net = @import("net.zig");

// Re-use NetplayManager.NetplayConfig so the launcher and the DLL see the same
// struct layout (avoids drift when new fields are added). We don't import the
// whole netplay_manager module (it pulls in game memory addresses etc.) — we
// just re-declare a struct here that mirrors it byte-for-byte for the fields
// the DLL's IPC config parser reads.
//
// Fields kept in sync with src/netplay_manager.zig:NetplayConfig.
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
    // Player display names exchanged during the handshake. Null-terminated
    // fixed-size buffers (31 chars + null) so they don't need allocation and
    // can be read directly by the UI thread. The game itself does NOT receive
    // these — MBAA reads its own name from System/NetConnect.dat. These are
    // launcher-side display only (connection screen + logs).
    local_name: [32]u8 = [_]u8{0} ** 32,
    remote_name: [32]u8 = [_]u8{0} ** 32,
};

pub const SessionState = enum {
    idle,
    listening,
    connecting,
    handshaking,
    ping_exchanging,
    waiting_confirmation, // host: handshake done, waiting for user to click "Start"
    launching, // user confirmed (or auto-confirmed) — about to open the game
    completed,
    failed,
    cancelled,
};

pub const PingStats = struct {
    avg_ms: f64 = 0,
    min_ms: f64 = 0,
    max_ms: f64 = 0,
    count: u32 = 0,
    packet_loss: u8 = 0,
};

/// Handshake protocol message tags (1-byte prefix). Matches the legacy
/// CCCaster Protocol.cpp byte layout where applicable; we keep it minimal but
/// compatible with the existing EnetTransport message framing.
const Msg = enum(u8) {
    version = 1,
    config = 2,
    confirm = 3,
    ping = 4,
    name = 6, // player display name exchange
};

pub const NetplaySession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    log: *logging.Logger,
    transport: net.EnetTransport,
    state: SessionState = .idle,
    config: NetplayConfig = .{},
    stats: PingStats = .{},
    local_version: []const u8 = "4.0-zig",

    // Address of the remote peer as actually connected (host:port string for
    // display; populated once the CONNECT event fires).
    peer_address_buf: [80]u8 = [_]u8{0} ** 80,
    peer_address_len: usize = 0,

    // Host-screen display IPs — looked up by the launcher when the user clicks
    // "Host Game", stored here so drawWaitingForPeer can read them without
    // extra plumbing.
    public_ip_buf: [64]u8 = [_]u8{0} ** 64,
    public_ip_len: usize = 0,
    local_ip_buf: [64]u8 = [_]u8{0} ** 64,
    local_ip_len: usize = 0,

    // Cancellation flag — set by cancel(), polled by the host/join loops.
    // Atomic-free volatile read/write is fine here: there's exactly one writer
    // (the UI thread) and one reader (the session thread), and a missed wake
    // just means one more 100ms poll iteration.
    cancel_requested: bool = false,

    // Host-only: set true when the UI tells us to proceed after
    // waiting_confirmation. hostConfirm() sends the final ConfirmConfig and
    // moves state to launching.
    host_confirmed: bool = false,

    // Error message buffer for failed states (displayed by the UI).
    error_buf: [128]u8 = [_]u8{0} ** 128,
    error_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, log: *logging.Logger) NetplaySession {
        return .{
            .allocator = allocator,
            .io = io,
            .log = log,
            .transport = net.EnetTransport.init(),
        };
    }

    pub fn deinit(self: *NetplaySession) void {
        self.transport.deinit();
    }

    /// User-facing: abort the in-progress host()/join(). Safe to call from
    /// the UI thread while the session thread is blocked inside host()/join().
    pub fn cancel(self: *NetplaySession) void {
        self.cancel_requested = true;
        // Tear down the socket so any blocked poll() returns immediately.
        self.transport.deinit();
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

    /// Look up public + local IPs and stash them in the session buffers.
    /// Called by the launcher when the user clicks "Host Game".
    pub fn lookupHostAddresses(self: *NetplaySession) void {
        if (net.getPublicIp(&self.public_ip_buf)) |ip| {
            self.public_ip_len = ip.len;
        }
        if (net.getLocalIp(&self.local_ip_buf)) |ip| {
            self.local_ip_len = ip.len;
        }
    }

    /// Set the local display name (truncated to 31 chars + null). Called by
    /// the launcher before host()/join() so the handshake can exchange it.
    pub fn setLocalName(self: *NetplaySession, name: []const u8) void {
        const copy_len = @min(name.len, self.config.local_name.len - 1);
        @memcpy(self.config.local_name[0..copy_len], name[0..copy_len]);
        self.config.local_name[copy_len] = 0;
    }

    /// Null-terminated local name slice (empty if unset).
    pub fn localName(self: *const NetplaySession) []const u8 {
        return std.mem.sliceTo(&self.config.local_name, 0);
    }

    /// Null-terminated remote name slice (empty until the handshake exchanges it).
    pub fn remoteName(self: *const NetplaySession) []const u8 {
        return std.mem.sliceTo(&self.config.remote_name, 0);
    }

    pub fn errorMessage(self: *const NetplaySession) []const u8 {
        return self.error_buf[0..self.error_len];
    }

    fn setError(self: *NetplaySession, msg: []const u8) void {
        const n = @min(msg.len, self.error_buf.len - 1);
        @memcpy(self.error_buf[0..n], msg[0..n]);
        self.error_buf[n] = 0;
        self.error_len = n;
    }

    /// Host entry point: listen on `port`, run the full handshake, then block
    /// in waiting_confirmation until hostConfirm() is called (or the session
    /// is cancelled / peer disconnects).
    pub fn host(self: *NetplaySession, port: u16, training: bool) !void {
        self.config.is_host = true;
        self.config.is_training = training;
        self.config.is_netplay = true;
        self.config.host_player = 1;
        self.config.local_player = 1;
        self.config.remote_player = 2;
        self.config.peer_port = port;
        self.state = .listening;
        try self.transport.listen(port, self.log);

        // Wait for the client's CONNECT (60s timeout, cancellable).
        self.log.info("Waiting for opponent to connect on port {d}...", .{port});
        var attempts: u32 = 0;
        while (attempts < 600 and !self.cancel_requested) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .connected) {
                    self.log.info("Opponent connected!", .{});
                    self.recordPeerAddress();
                    try self.doHandshake();
                    return;
                }
            }
        }
        if (self.cancel_requested) {
            self.state = .cancelled;
            return error.Cancelled;
        }
        self.setError("Connection timed out (no opponent connected in 60s)");
        self.state = .failed;
        return error.Timeout;
    }

    /// Client entry point: connect to host_str:port, run the handshake, and
    /// transition straight to launching (the client auto-confirms — only the
    /// host gatekeeps via waiting_confirmation).
    pub fn join(self: *NetplaySession, host_str: []const u8, port: u16, training: bool) !void {
        self.config.is_host = false;
        self.config.is_training = training;
        self.config.is_netplay = true;
        self.config.host_player = 1; // host is always player 1
        self.config.local_player = 2; // we are player 2
        self.config.remote_player = 1;
        self.config.peer_port = port;
        // Stash the peer address for the DLL (which will reconnect to it).
        const addr_copy_len = @min(host_str.len, self.config.peer_addr.len);
        @memcpy(self.config.peer_addr[0..addr_copy_len], host_str[0..addr_copy_len]);

        self.state = .connecting;
        try self.transport.connect(host_str, port, self.log);

        // Wait for CONNECT event (10s timeout, cancellable).
        var attempts: u32 = 0;
        while (attempts < 100 and !self.cancel_requested) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .connected) {
                    self.log.info("Connected to host!", .{});
                    self.recordPeerAddress();
                    try self.doHandshake();
                    return;
                }
            }
        }
        if (self.cancel_requested) {
            self.state = .cancelled;
            return error.Cancelled;
        }
        self.setError("Failed to connect to host (10s timeout)");
        self.state = .failed;
        return error.Timeout;
    }

    fn recordPeerAddress(self: *NetplaySession) void {
        // For display purposes only.
        const is_host = self.config.is_host;
        const label = if (is_host) "connected-client" else "host";
        const printed = std.fmt.bufPrint(
            &self.peer_address_buf,
            "{s}",
            .{label},
        ) catch return;
        self.peer_address_len = printed.len;
    }

    fn doHandshake(self: *NetplaySession) !void {
        self.state = .handshaking;

        // 1. Exchange version strings (strict — bail on mismatch).
        try self.exchangeVersion();
        if (self.cancel_requested) {
            self.state = .cancelled;
            return error.Cancelled;
        }

        // 2. Exchange display names (for the connection screen + logs).
        try self.exchangeNames();
        if (self.cancel_requested) {
            self.state = .cancelled;
            return error.Cancelled;
        }

        // 3. Exchange ping stats (drives auto input-delay).
        self.state = .ping_exchanging;
        try self.exchangePings();
        if (self.cancel_requested) {
            self.state = .cancelled;
            return error.Cancelled;
        }

        // 4. Host sends config (with auto delay), client confirms.
        if (self.config.is_host) {
            try self.sendConfig();
            // Host now waits for the user to confirm before launching.
            // The UI thread will call hostConfirm() when the user clicks "Start".
            self.state = .waiting_confirmation;
            self.log.info("Handshake complete — waiting for host to confirm start", .{});
        } else {
            try self.waitForConfig();
            // Client is ready to launch.
            self.state = .launching;
            self.log.info("Handshake complete — ready to launch", .{});
        }
    }

    fn exchangeVersion(self: *NetplaySession) !void {
        // Send our version: [1=version][len byte][version bytes]
        var ver_buf: [128]u8 = undefined;
        ver_buf[0] = @intFromEnum(Msg.version);
        const ver_len = @min(self.local_version.len, 126);
        ver_buf[1] = @intCast(ver_len);
        @memcpy(ver_buf[2 .. 2 + ver_len], self.local_version[0..ver_len]);
        _ = self.transport.sendReliable(ver_buf[0 .. 2 + ver_len]);
        self.log.info("Sent version: {s}", .{self.local_version});

        // Wait for peer's version.
        var attempts: u32 = 0;
        while (attempts < 50 and !self.cancel_requested) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 2 and msg[0] == @intFromEnum(Msg.version)) {
                        const peer_ver_len: usize = @min(msg[1], msg.len - 2);
                        const peer_ver = msg[2 .. 2 + peer_ver_len];
                        self.log.info("Peer version: {s}", .{peer_ver});
                        // Strict version check.
                        if (!std.mem.eql(u8, peer_ver, self.local_version)) {
                            const err_msg = std.fmt.bufPrint(&self.error_buf, "Version mismatch: local={s} remote={s}", .{ self.local_version, peer_ver }) catch "Version mismatch";
                            self.error_len = err_msg.len;
                            self.state = .failed;
                            return error.VersionMismatch;
                        }
                        return;
                    }
                }
                if (event == .disconnected) {
                    self.setError("Peer disconnected during handshake");
                    self.state = .failed;
                    return error.Disconnected;
                }
            }
        }
        self.setError("Version exchange timed out");
        self.state = .failed;
        return error.Timeout;
    }

    fn exchangeNames(self: *NetplaySession) !void {
        // Send our name: [6=name][len byte][name bytes]
        const local = self.localName();
        var name_buf: [34]u8 = undefined;
        name_buf[0] = @intFromEnum(Msg.name);
        const name_len = @min(local.len, 31);
        name_buf[1] = @intCast(name_len);
        @memcpy(name_buf[2 .. 2 + name_len], local[0..name_len]);
        _ = self.transport.sendReliable(name_buf[0 .. 2 + name_len]);
        self.log.info("Sent display name: '{s}'", .{local});

        // Wait for peer's name.
        var attempts: u32 = 0;
        while (attempts < 50 and !self.cancel_requested) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 2 and msg[0] == @intFromEnum(Msg.name)) {
                        const peer_name_len: usize = @min(msg[1], msg.len - 2);
                        const peer_name = msg[2 .. 2 + peer_name_len];
                        const copy_len = @min(peer_name.len, self.config.remote_name.len - 1);
                        @memcpy(self.config.remote_name[0..copy_len], peer_name[0..copy_len]);
                        self.config.remote_name[copy_len] = 0;
                        self.log.info("Peer display name: '{s}'", .{self.remoteName()});
                        return;
                    }
                    // Ignore other message types here — they'll be handled in
                    // their own exchange phase.
                }
                if (event == .disconnected) {
                    self.setError("Peer disconnected during name exchange");
                    self.state = .failed;
                    return error.Disconnected;
                }
            }
        }
        // Name exchange is best-effort: if the peer didn't send one, leave
        // remote_name empty and continue (we still know they connected).
        self.log.warn("Name exchange timed out — continuing with empty remote name", .{});
    }

    fn exchangePings(self: *NetplaySession) !void {
        // Send N ping packets and measure RTT.
        const num_pings: u32 = 5;
        var i: u32 = 0;
        while (i < num_pings and !self.cancel_requested) : (i += 1) {
            const start = std.Io.Clock.now(.real, self.io).toMilliseconds();
            var ping_msg: [9]u8 = undefined;
            ping_msg[0] = @intFromEnum(Msg.ping);
            std.mem.writeInt(u64, ping_msg[1..9], @intCast(start), .little);
            _ = self.transport.sendReliable(&ping_msg);

            // Wait for pong (echo of the same packet).
            var waited: u32 = 0;
            while (waited < 50 and !self.cancel_requested) : (waited += 1) {
                if (self.transport.poll(10)) |event| {
                    if (event == .message_received) {
                        const msg = self.transport.getLastMessage();
                        if (msg.len >= 9 and msg[0] == @intFromEnum(Msg.ping)) {
                            const rtt = std.Io.Clock.now(.real, self.io).toMilliseconds() - start;
                            self.stats.count += 1;
                            const c = @as(f64, @floatFromInt(self.stats.count));
                            const r = @as(f64, @floatFromInt(rtt));
                            self.stats.avg_ms = (self.stats.avg_ms * (c - 1) + r) / c;
                            if (self.stats.min_ms == 0 or r < self.stats.min_ms) self.stats.min_ms = r;
                            if (r > self.stats.max_ms) self.stats.max_ms = r;
                            break;
                        }
                        // Echo any stray ping the peer sent.
                        if (msg.len >= 1 and msg[0] == @intFromEnum(Msg.ping)) {
                            _ = self.transport.sendReliable(msg);
                        }
                    }
                    if (event == .disconnected) {
                        self.setError("Peer disconnected during ping exchange");
                        self.state = .failed;
                        return error.Disconnected;
                    }
                }
            }
        }

        // Echo any trailing pings the peer has queued.
        var extra: u32 = 0;
        while (extra < 10) : (extra += 1) {
            if (self.transport.poll(10)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 1 and msg[0] == @intFromEnum(Msg.ping)) {
                        _ = self.transport.sendReliable(msg);
                    }
                } else break;
            } else break;
        }

        const stats = self.transport.getStats();
        self.stats.packet_loss = @intCast(stats.packet_loss_pct);
        self.log.info("Ping: avg={d:.0}ms min={d:.0}ms max={d:.0}ms loss={d}%", .{
            self.stats.avg_ms, self.stats.min_ms, self.stats.max_ms, self.stats.packet_loss,
        });

        // Auto-compute input delay from RTT (one frame per ~16.67ms of RTT,
        // clamped to [0, max_real_delay]). Matches legacy computeDelay().
        const avg_rtt = if (self.stats.avg_ms > 0) self.stats.avg_ms else 50;
        const computed: u8 = @intFromFloat(@ceil(avg_rtt / (1000.0 / 60.0)));
        self.config.delay = @min(computed, 8); // sane cap; the DLL clamps further
        self.log.info("Auto delay: {d}", .{self.config.delay});
    }

    fn sendConfig(self: *NetplaySession) !void {
        // Host → client: [2=config][delay][rollback][win_count][host_player]
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

        // Wait for the client's ConfirmConfig.
        var attempts: u32 = 0;
        while (attempts < 50 and !self.cancel_requested) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 1 and msg[0] == @intFromEnum(Msg.confirm)) {
                        self.log.info("Client confirmed config", .{});
                        return;
                    }
                }
                if (event == .disconnected) {
                    self.setError("Peer disconnected waiting for confirm");
                    self.state = .failed;
                    return error.Disconnected;
                }
            }
        }
        self.setError("Client never confirmed config (5s timeout)");
        self.state = .failed;
        return error.NoConfirm;
    }

    fn waitForConfig(self: *NetplaySession) !void {
        var attempts: u32 = 0;
        while (attempts < 50 and !self.cancel_requested) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 5 and msg[0] == @intFromEnum(Msg.config)) {
                        self.config.delay = msg[1];
                        self.config.rollback = msg[2];
                        self.config.win_count = msg[3];
                        self.config.host_player = msg[4];
                        self.log.info("Received config: delay={d} rollback={d} winCount={d} hostPlayer={d}", .{
                            self.config.delay, self.config.rollback, self.config.win_count, self.config.host_player,
                        });

                        // Echo confirm back to host.
                        const confirm = [_]u8{@intFromEnum(Msg.confirm)};
                        _ = self.transport.sendReliable(&confirm);
                        self.log.info("Sent confirm", .{});
                        return;
                    }
                }
                if (event == .disconnected) {
                    self.setError("Host disconnected during config exchange");
                    self.state = .failed;
                    return error.Disconnected;
                }
            }
        }
        self.setError("Never received config from host (5s timeout)");
        self.state = .failed;
        return error.NoConfig;
    }

    /// Host-only: called by the UI thread once the user clicks "Start match".
    /// Closes the handshake socket and moves to launching state. The caller
    /// (UI) then opens the game.
    pub fn hostConfirm(self: *NetplaySession) void {
        if (self.state != .waiting_confirmation) return;
        self.host_confirmed = true;
        self.state = .launching;
        // Note: we do NOT close the transport here. The UI's
        // launchGameAfterHandshake() calls session.deinit() (which closes the
        // socket) right before CreateProcess, matching MainApp.cpp:1271-1274.
        self.log.info("Host confirmed — ready to launch", .{});
    }
};
