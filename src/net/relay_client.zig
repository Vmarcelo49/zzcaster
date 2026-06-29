// src/net/relay_client.zig
// ============================================================================
// NAT traversal client — TCP signaling + UDP hole-punch state machine.
//
// Drives the full relay-assisted hole-punch flow:
//   1. TCP connect to relay
//   2. Send initial message (HostRegister for host, ClientJoin for client)
//   3. Receive MatchInfo (matchId)
//   4. Open UDP socket, send UdpData to relay every 50ms
//   5. Receive TunInfo (peer's public UDP endpoint)
//   6. Send NullMsg hole-punch probes to peer every 50ms (same UDP socket)
//   7. First UDP packet from peer → SUCCESS, hand off peer_addr to ENet
//
// Step-based, non-blocking, main-thread — same pattern as NetplaySession.
// No background threads, no mutexes. The caller drives step() once per frame.
// ============================================================================

const std = @import("std");
const protocol = @import("relay_protocol.zig");
const relay_config = @import("relay_config.zig");

// ============================================================================
// ws2_32 bindings — shared module (src/net/ws2_32.zig).
// ============================================================================

const ws2_32 = @import("ws2_32.zig");

// ============================================================================
// Constants
// ============================================================================

/// Wall-clock timeouts (milliseconds) for each phase.
const tcp_connect_timeout_ms: i64 = 5_000;
const hosted_timeout_ms: i64 = 5_000;
const match_info_timeout_ms: i64 = 60_000; // relay TTL
const tun_info_timeout_ms: i64 = 10_000;
const hole_punch_timeout_ms: i64 = 10_000;

/// Retry backoff (milliseconds) for the relay handshake. After a transient
/// failure, the client waits before re-attempting the TCP connect + handshake.
/// The delay grows exponentially and is capped so it doesn't get excessive:
///   attempt 1 → 1s, 2 → 2s, 3 → 4s, 4+ → 5s (capped).
///
/// Retries continue indefinitely until the user cancels — this makes the
/// relay connection self-healing for transient outages (relay restart, DNS
/// hiccup, momentary packet loss) without forcing an app restart.
const retry_initial_delay_ms: i64 = 1_000;
const retry_max_delay_ms: i64 = 5_000;

/// How often to send UdpData to the relay (milliseconds).
/// Keeps the NAT mapping fresh on the same socket used to talk to the peer.
const udp_data_interval_ms: i64 = 50;

/// How often to send NullMsg hole-punch probes to the peer (milliseconds).
const null_msg_interval_ms: i64 = 50;

/// TCP read buffer size — relay messages are small (max ~32 bytes).
const tcp_buf_size: usize = 256;

/// UDP read buffer size — UdpData is 5 bytes, NullMsg is 1 byte, STUN reply is 8.
const udp_buf_size: usize = 64;

/// Invalid socket fd sentinel.
const INVALID_SOCKET: c_int = -1;

// ============================================================================
// Types
// ============================================================================

/// Structured error — distinguishes failure modes so the UI can show
/// helpful suggestions (e.g., "try direct IP" vs "port-forward needed").
pub const RelayError = enum {
    tcp_connect_failed, // relay unreachable (connection refused or timeout)
    tcp_timeout, // relay didn't respond to our initial message in time
    relay_error, // relay sent an Error message
    relay_disconnected, // TCP closed by relay before match completed
    match_info_timeout, // waited too long for MatchInfo (relay TTL expired?)
    tun_info_timeout, // relay didn't forward TunInfo in time
    hole_punch_failed, // couldn't reach peer via UDP (symmetric NAT?)
    invalid_room_code, // (client) bad room code format
    socket_error, // ws2_32 call failed unexpectedly

    pub fn label(self: RelayError) []const u8 {
        return switch (self) {
            .tcp_connect_failed => "Could not connect to relay server",
            .tcp_timeout => "Relay server did not respond",
            .relay_error => "Relay server rejected the request",
            .relay_disconnected => "Relay server disconnected",
            .match_info_timeout => "Timed out waiting for a match",
            .tun_info_timeout => "Timed out waiting for peer endpoint",
            .hole_punch_failed => "Could not reach peer (NAT too restrictive)",
            .invalid_room_code => "Invalid room code (must be 4 letters)",
            .socket_error => "Network socket error",
        };
    }

    /// Suggested next step for the user — shown in the UI on failure.
    pub fn suggestion(self: RelayError) []const u8 {
        return switch (self) {
            .tcp_connect_failed, .tcp_timeout => "Try direct IP mode, or check if the relay server is online.",
            .relay_error, .relay_disconnected => "Try a different relay server, or use direct IP mode.",
            .match_info_timeout => "No opponent connected in time. Try again or use direct IP.",
            .tun_info_timeout => "Peer may have disconnected. Try again.",
            .hole_punch_failed => "Your NAT type may be too restrictive. Try port-forwarding port 46318, or use a VPN.",
            .invalid_room_code => "Room codes must be exactly 4 letters (A-Z, 2-9, no I/O/0/1).",
            .socket_error => "Restart the application. If the problem persists, report this bug.",
        };
    }
};

/// Result of a successful relay handshake — the peer's public UDP endpoint
/// and the local UDP port that was used for hole-punching.
///
/// The caller should:
///   1. Call relay_client.deinit() to tear down the relay sockets
///   2. Create an ENet host bound to local_udp_port (with SO_REUSEADDR)
///   3. Call enet_host_connect(peer_ip, peer_port) — NAT mapping is open,
///      ENet's connect will succeed
pub const RelayResult = struct {
    peer_ip: [4]u8,
    peer_port: u16,
    local_udp_port: u16,
};

/// Which role this client plays.
pub const ClientRole = enum { host, client };

/// Configuration for initializing a RelayClient.
pub const RelayClientInit = struct {
    /// Which relay server to use (host + port).
    relay: relay_config.RelayEntry,
    /// Host or client role.
    role: ClientRole,
    /// Local UDP port to bind for hole-punching.
    /// Host: the port to host on (e.g., 46318).
    /// Client: 0 = let OS pick any available port.
    local_port: u16,
    /// For client: the 4-letter room code.
    /// Ignored for host role (host generates room code internally).
    peer_identifier: []const u8 = "",
};

/// Internal state machine states.
pub const RelayState = enum {
    idle,
    tcp_connecting, // TCP connect() in progress (non-blocking)
    waiting_for_hosted, // (host) waiting for Hosted reply
    waiting_for_match_info, // waiting for MatchInfo from relay
    waiting_for_tun_info, // got MatchInfo, sending UdpData, waiting for TunInfo
    hole_punching, // got TunInfo, sending NullMsg to peer, waiting for first packet
    connected, // SUCCESS — peer_addr is valid, caller can hand off to ENet
    failed, // terminal error occurred — check error field
    retrying, // transient error occurred — waiting for backoff, then restart handshake
};

/// The result of a step() call — either in progress, success, or failure.
pub const StepResult = union(enum) {
    in_progress: void,
    success: RelayResult,
    failed: RelayError,
};

// ============================================================================
// RelayClient — the state machine
// ============================================================================

pub const RelayClient = struct {
    // --- Configuration (set at init, never changed) ---
    relay: relay_config.RelayEntry,
    role: ClientRole,
    local_port: u16,

    // For host: the generated room code.
    // For client: a copy of the provided room code.
    room_code: [4]u8 = [_]u8{0} ** 4,
    room_code_set: bool = false,

    // --- Sockets ---
    tcp_sock: c_int = INVALID_SOCKET,
    udp_sock: c_int = INVALID_SOCKET,

    // --- TCP read buffer ---
    // TCP doesn't preserve message boundaries — we buffer incoming data
    // and parse complete messages from it.
    tcp_read_buf: [tcp_buf_size]u8 = undefined,
    tcp_read_pos: usize = 0, // bytes currently in the buffer

    // --- UDP state ---
    local_udp_port: u16 = 0,
    relay_udp_addr: ws2_32.sockaddr_in = .{},

    // --- Match state ---
    match_id: u32 = 0,
    peer_addr: ?ws2_32.sockaddr_in = null,

    // --- Timers (wall-clock milliseconds) ---
    phase_start_ms: i64 = 0,
    last_udp_data_ms: i64 = 0,
    last_null_msg_ms: i64 = 0,

    // --- Result ---
    state: RelayState = .idle,
    error_val: ?RelayError = null,

    // --- Retry state ---
    // When the handshake fails with a retriable error, the client enters the
    // `.retrying` state and waits `next_retry_ms - now` before re-attempting.
    // `retry_count` is the number of retries scheduled so far (0 = first
    // attempt in flight). The room code is NOT regenerated across retries so
    // the host's shared code stays stable.
    retry_count: u32 = 0,
    next_retry_ms: i64 = 0,

    // --- Current wall-clock time (set at the top of step()) ---
    // Cached so fail() can compute the retry deadline without every helper
    // having to thread `now_ms` through its signature. Only valid for the
    // duration of a single step() call.
    current_ms: i64 = 0,

    // ========================================================================
    // Init / deinit
    // ========================================================================

    pub fn init(io: std.Io, cfg: RelayClientInit) RelayClient {
        var rc: RelayClient = .{
            .relay = cfg.relay,
            .role = cfg.role,
            .local_port = cfg.local_port,
        };

        // For client, validate and store the room code.
        if (cfg.role == .client) {
            if (cfg.peer_identifier.len != protocol.ROOM_CODE_LEN or
                !protocol.isValidRoomCode(cfg.peer_identifier))
            {
                rc.state = .failed;
                rc.error_val = .invalid_room_code;
                return rc;
            }
            @memcpy(&rc.room_code, cfg.peer_identifier);
            rc.room_code_set = true;
        }

        // For host, generate a room code.
        if (cfg.role == .host) {
            const seed: u64 = @intCast(std.Io.Clock.now(.real, io).toMilliseconds());
            var prng = std.Random.DefaultPrng.init(seed);
            rc.room_code = protocol.generateRoomCode(prng.random());
            rc.room_code_set = true;
        }

        // Start the first handshake attempt. On failure, this sets the
        // terminal `.failed` state with the appropriate error (the first
        // attempt is never retried indirectly — a caller-visible failure
        // here means the relay address itself is bad, e.g. unresolvable).
        rc.restartHandshake(io);
        return rc;
    }

    /// (Re)start the relay handshake: resolve the relay host, create a fresh
    /// non-blocking TCP socket, and kick off a non-blocking connect().
    ///
    /// Called once from `init()` and again from `stepRetrying()` after a
    /// transient failure. The room code is NOT regenerated here — it stays
    /// stable across retries so a host's shared code remains valid.
    ///
    /// On failure this transitions to the terminal `.failed` state with
    /// `tcp_connect_failed` (host unresolvable) or `socket_error` (socket
    /// creation failed). These are not scheduled for retry here because
    /// they occur before any state machine runs; the next reachable failure
    /// points (stepTcpConnecting timeout, relay disconnect, etc.) ARE
    /// retriable via `fail()`.
    fn restartHandshake(self: *RelayClient, io: std.Io) void {
        // Reset per-attempt mutable state so a retry starts clean.
        self.tcp_read_pos = 0;
        self.udp_sock = INVALID_SOCKET;
        self.tcp_sock = INVALID_SOCKET;
        self.local_udp_port = 0;
        self.match_id = 0;
        self.peer_addr = null;
        self.last_udp_data_ms = 0;
        self.last_null_msg_ms = 0;
        self.error_val = null;

        // Stamp the wall clock so fail() (if reached below) schedules a
        // retry against a real deadline. step() also sets this, but
        // restartHandshake runs from init() where step() hasn't run yet.
        self.current_ms = std.Io.Clock.now(.real, io).toMilliseconds();

        // Re-resolve the relay address each attempt — DNS results may change
        // between retries (e.g., the relay's IP rotates after a restart).
        const relay_ip = resolveHost(self.relay.host);
        if (relay_ip == 0) {
            // Unresolvable host is treated as retriable: DNS may recover
            // while the user waits. Retries until cancel.
            self.fail(.tcp_connect_failed);
            return;
        }
        self.relay_udp_addr = makeSockaddr(relay_ip, self.relay.port);

        // Create non-blocking TCP socket and connect.
        const tcp_fd = ws2_32.socket(ws2_32.AF_INET, ws2_32.SOCK_STREAM, 0);
        if (tcp_fd < 0) {
            self.fail(.socket_error);
            return;
        }
        setNonBlocking(tcp_fd, true);

        const tcp_dest = makeSockaddr(relay_ip, self.relay.port);
        const connect_ret = ws2_32.connect(tcp_fd, &tcp_dest, @sizeOf(ws2_32.sockaddr_in));
        if (connect_ret != 0) {
            const err = ws2_32.WSAGetLastError();
            if (err != ws2_32.WSAEWOULDBLOCK and err != ws2_32.WSAEINPROGRESS) {
                _ = ws2_32.closesocket(tcp_fd);
                self.fail(.tcp_connect_failed);
                return;
            }
            // WSAEWOULDBLOCK is expected for non-blocking connect — we'll
            // poll for writability in stepTcpConnecting().
        }

        self.tcp_sock = tcp_fd;
        self.state = .tcp_connecting;
        self.phase_start_ms = self.current_ms;
    }

    pub fn deinit(self: *RelayClient) void {
        if (self.tcp_sock != INVALID_SOCKET) {
            _ = ws2_32.closesocket(self.tcp_sock);
            self.tcp_sock = INVALID_SOCKET;
        }
        if (self.udp_sock != INVALID_SOCKET) {
            _ = ws2_32.closesocket(self.udp_sock);
            self.udp_sock = INVALID_SOCKET;
        }
    }

    // ========================================================================
    // Public API — step() drives the state machine
    // ========================================================================

    /// Advance the state machine by one non-blocking iteration.
    /// Call this once per UI frame. Returns null while in progress,
    /// or a StepResult when the handshake completes (success or failure).
    pub fn step(self: *RelayClient, io: std.Io) ?StepResult {
        if (self.state == .connected) {
            return .{ .success = self.buildResult() };
        }
        if (self.state == .failed) {
            return .{ .failed = self.error_val orelse .socket_error };
        }

        const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
        self.current_ms = now_ms;

        switch (self.state) {
            .idle => return null,
            .tcp_connecting => self.stepTcpConnecting(io, now_ms),
            .waiting_for_hosted => self.stepWaitingForHosted(io, now_ms),
            .waiting_for_match_info => self.stepWaitingForMatchInfo(io, now_ms),
            .waiting_for_tun_info => self.stepWaitingForTunInfo(io, now_ms),
            .hole_punching => self.stepHolePunching(io, now_ms),
            .retrying => self.stepRetrying(io, now_ms),
            .connected, .failed => return null,
        }

        // Check if the state transitioned to terminal during this step.
        if (self.state == .connected) {
            return .{ .success = self.buildResult() };
        }
        if (self.state == .failed) {
            return .{ .failed = self.error_val orelse .socket_error };
        }
        return null;
    }

    /// For host: returns the generated room code.
    /// For client: returns the provided room code.
    pub fn getRoomCode(self: *const RelayClient) ?[4]u8 {
        if (!self.room_code_set) return null;
        return self.room_code;
    }

    pub fn getState(self: *const RelayClient) RelayState {
        return self.state;
    }

    pub fn getError(self: *const RelayClient) ?RelayError {
        return self.error_val;
    }

    /// Number of retries scheduled so far (0 = the first attempt is in
    /// flight). Exposed so the UI can show "Retrying (attempt N)...".
    pub fn getRetryCount(self: *const RelayClient) u32 {
        return self.retry_count;
    }

    // ========================================================================
    // State handlers
    // ========================================================================

    fn stepTcpConnecting(self: *RelayClient, io: std.Io, now_ms: i64) void {
        _ = io;
        // Check for timeout
        if (now_ms - self.phase_start_ms > tcp_connect_timeout_ms) {
            self.fail(.tcp_connect_failed);
            return;
        }

        // Poll the TCP socket for writability (connect completed) or
        // exception (connect failed).
        var write_set: ws2_32.fd_set = .{};
        var except_set: ws2_32.fd_set = .{};
        ws2_32.FD_SET(self.tcp_sock, &write_set);
        ws2_32.FD_SET(self.tcp_sock, &except_set);

        var tv: ws2_32.timeval = .{ .tv_sec = 0, .tv_usec = 0 };
        const ret = ws2_32.select(0, null, &write_set, &except_set, &tv);
        if (ret <= 0) return; // not ready yet

        // Check if connect failed (exception set)
        if (except_set.fd_count > 0) {
            self.fail(.tcp_connect_failed);
            return;
        }

        // Connect succeeded — check SO_ERROR to be sure
        var so_err: c_int = 0;
        var so_err_len: c_int = @sizeOf(c_int);
        _ = ws2_32.getsockopt(self.tcp_sock, ws2_32.SOL_SOCKET, ws2_32.SO_ERROR, @ptrCast(&so_err), &so_err_len);
        if (so_err != 0) {
            self.fail(.tcp_connect_failed);
            return;
        }

        // Connect succeeded — send the initial message
        self.sendInitialMessage(now_ms);
    }

    fn stepWaitingForHosted(self: *RelayClient, io: std.Io, now_ms: i64) void {
        _ = io;
        if (now_ms - self.phase_start_ms > hosted_timeout_ms) {
            self.fail(.tcp_timeout);
            return;
        }

        // Try to read a Hosted message
        if (!self.tryReadTCP()) return;
        const msg = self.tryParseServerMsg() orelse return;

        switch (msg) {
            .hosted => |h| {
                // Server confirmed our room code (or assigned one if we sent empty)
                @memcpy(&self.room_code, h.code[0..4]);
                self.room_code_set = true;
                self.state = .waiting_for_match_info;
                self.phase_start_ms = now_ms;
            },
            .err => |e| {
                _ = e;
                self.fail(.relay_error);
            },
            else => {
                // Unexpected message — protocol error
                self.fail(.relay_error);
            },
        }
    }

    fn stepWaitingForMatchInfo(self: *RelayClient, io: std.Io, now_ms: i64) void {
        _ = io;
        if (now_ms - self.phase_start_ms > match_info_timeout_ms) {
            self.fail(.match_info_timeout);
            return;
        }

        // Try to read MatchInfo
        if (!self.tryReadTCP()) return;
        const msg = self.tryParseServerMsg() orelse return;

        switch (msg) {
            .match_info => |m| {
                self.match_id = m.match_id;
                // Open UDP socket and start sending UdpData
                if (!self.openUdpSocket()) {
                    self.fail(.socket_error);
                    return;
                }
                self.state = .waiting_for_tun_info;
                self.phase_start_ms = now_ms;
                self.last_udp_data_ms = 0; // force immediate first send
            },
            .err => |e| {
                _ = e;
                // Relay sent an Error message. Report it.
                self.fail(.relay_error);
            },
            else => {
                self.fail(.relay_error);
            },
        }
    }

    fn stepWaitingForTunInfo(self: *RelayClient, io: std.Io, now_ms: i64) void {
        _ = io;
        if (now_ms - self.phase_start_ms > tun_info_timeout_ms) {
            self.fail(.tun_info_timeout);
            return;
        }

        // Send UdpData to relay every 50ms (keeps NAT mapping fresh)
        if (now_ms - self.last_udp_data_ms >= udp_data_interval_ms) {
            self.sendUdpData(now_ms);
        }

        // Try to read TunInfo from TCP
        if (self.tryReadTCP()) {
            if (self.tryParseServerMsg()) |msg| {
                switch (msg) {
                    .tun_info => |t| {
                        // Parse peer address from "ip:port" string
                        if (parseIpPort(t.addr)) |peer| {
                            self.peer_addr = makeSockaddr(peer.ip, peer.port);
                            self.state = .hole_punching;
                            self.phase_start_ms = now_ms;
                            self.last_null_msg_ms = 0; // force immediate first send
                        } else {
                            self.fail(.relay_error);
                        }
                    },
                    .err => {
                        self.fail(.relay_error);
                    },
                    else => {
                        self.fail(.relay_error);
                    },
                }
            }
        }
    }

    fn stepHolePunching(self: *RelayClient, io: std.Io, now_ms: i64) void {
        _ = io;
        if (now_ms - self.phase_start_ms > hole_punch_timeout_ms) {
            self.fail(.hole_punch_failed);
            return;
        }

        // Keep sending UdpData to relay (NAT keep-alive)
        if (now_ms - self.last_udp_data_ms >= udp_data_interval_ms) {
            self.sendUdpData(now_ms);
        }

        // Send NullMsg hole-punch probes to peer every 50ms
        if (now_ms - self.last_null_msg_ms >= null_msg_interval_ms) {
            self.sendNullMsg(now_ms);
        }

        // Poll UDP socket for incoming packets. Drain ALL pending packets
        // in this frame rather than just one — this avoids delaying
        // hole-punch detection by one frame when multiple probes arrive
        // simultaneously (common on high-latency links where the peer's
        // 50ms probes bunch up).
        while (true) {
            var from: ws2_32.sockaddr_in = undefined;
            var from_len: c_int = @sizeOf(ws2_32.sockaddr_in);
            var buf: [udp_buf_size]u8 = undefined;
            const recv_len = ws2_32.recvfrom(self.udp_sock, &buf, buf.len, 0, &from, &from_len);
            if (recv_len > 0) {
                // Check if this packet is from the peer (not from the relay)
                if (self.peer_addr) |peer| {
                    if (from.addr == peer.addr and from.port == peer.port) {
                        // Hole-punch succeeded!
                        self.state = .connected;
                        return;
                    }
                }
                // Packet from unknown source — ignore and keep draining.
                continue;
            }
            // recv_len <= 0 — check for errors
            if (recv_len < 0) {
                const err = ws2_32.WSAGetLastError();
                if (err != ws2_32.WSAEWOULDBLOCK) {
                    // Real socket error — fail fast instead of waiting
                    // for the 10s hole-punch timeout.
                    self.fail(.socket_error);
                    return;
                }
                // WSAEWOULDBLOCK — no more data, break the drain loop.
            }
            break;
        }
    }

    // ========================================================================
    // Internal helpers — socket operations
    // ========================================================================

    fn sendInitialMessage(self: *RelayClient, now_ms: i64) void {
        var buf: [64]u8 = undefined;
        var msg: []u8 = undefined;

        switch (self.role) {
            .host => {
                // HostRegister: 'U' + u16 port + u8 code_len + code
                msg = protocol.encodeHostRegister(
                    &buf,
                    protocol.TYPE_UDP,
                    self.local_port,
                    &self.room_code,
                );
            },
            .client => {
                // ClientJoin: 'U' + u8 code_len + code
                msg = protocol.encodeClientJoin(
                    &buf,
                    protocol.TYPE_UDP,
                    &self.room_code,
                );
            },
        }

        const sent = ws2_32.send(self.tcp_sock, msg.ptr, @intCast(msg.len), 0);
        if (sent != msg.len) {
            self.fail(.socket_error);
            return;
        }

        // Transition to next state based on role
        switch (self.role) {
            .host => self.state = .waiting_for_hosted,
            .client => self.state = .waiting_for_match_info,
        }
        self.phase_start_ms = now_ms;
    }

    fn openUdpSocket(self: *RelayClient) bool {
        const fd = ws2_32.socket(ws2_32.AF_INET, ws2_32.SOCK_DGRAM, 0);
        if (fd < 0) return false;

        // Set SO_REUSEADDR so ENet can rebind to the same port later
        // (Option A handoff — re-bind to same port after hole-punch).
        var reuse: c_int = 1;
        _ = ws2_32.setsockopt(fd, ws2_32.SOL_SOCKET, ws2_32.SO_REUSEADDR, @ptrCast(&reuse), @sizeOf(c_int));

        // Bind to local port
        var local_addr = makeSockaddr(0, self.local_port);
        if (ws2_32.bind(fd, &local_addr, @sizeOf(ws2_32.sockaddr_in)) != 0) {
            _ = ws2_32.closesocket(fd);
            return false;
        }

        // Set non-blocking
        setNonBlocking(fd, true);

        // Get the actual bound port (in case local_port was 0)
        var bound_addr: ws2_32.sockaddr_in = undefined;
        var bound_len: c_int = @sizeOf(ws2_32.sockaddr_in);
        if (ws2_32.getsockname(fd, &bound_addr, &bound_len) != 0) {
            _ = ws2_32.closesocket(fd);
            return false;
        }
        self.local_udp_port = std.mem.bigToNative(u16, bound_addr.port);

        self.udp_sock = fd;
        return true;
    }

    fn sendUdpData(self: *RelayClient, now_ms: i64) void {
        var buf: [5]u8 = undefined;
        const data = protocol.encodeUdpData(&buf, self.role == .client, self.match_id);
        _ = ws2_32.sendto(
            self.udp_sock,
            data.ptr,
            @intCast(data.len),
            0,
            &self.relay_udp_addr,
            @sizeOf(ws2_32.sockaddr_in),
        );
        self.last_udp_data_ms = now_ms;
    }

    fn sendNullMsg(self: *RelayClient, now_ms: i64) void {
        if (self.peer_addr == null) return;
        const null_msg = [_]u8{0};
        _ = ws2_32.sendto(
            self.udp_sock,
            &null_msg,
            null_msg.len,
            0,
            &self.peer_addr.?,
            @sizeOf(ws2_32.sockaddr_in),
        );
        self.last_null_msg_ms = now_ms;
    }

    // ========================================================================
    // Internal helpers — TCP read buffer + message parsing
    // ========================================================================

    /// Try to read more data from the TCP socket into the buffer.
    /// Returns true if new data was received (or connection is still open),
    /// false on EOF or would-block.
    fn tryReadTCP(self: *RelayClient) bool {
        if (self.tcp_read_pos >= self.tcp_read_buf.len) {
            // Buffer full — shouldn't happen with our small messages.
            // Shift the buffer to make room.
            self.shiftTcpBuffer();
        }

        const space = self.tcp_read_buf.len - self.tcp_read_pos;
        const recv_len = ws2_32.recv(
            self.tcp_sock,
            self.tcp_read_buf[self.tcp_read_pos..].ptr,
            @intCast(space),
            0,
        );

        if (recv_len > 0) {
            self.tcp_read_pos += @intCast(recv_len);
            return true;
        }

        if (recv_len == 0) {
            // Connection closed by relay
            self.fail(.relay_disconnected);
            return false;
        }

        // recv_len < 0 — check if it's WSAEWOULDBLOCK (non-blocking, no data)
        const err = ws2_32.WSAGetLastError();
        if (err == ws2_32.WSAEWOULDBLOCK) {
            return true; // no data yet, but connection is still open
        }

        // Actual error
        self.fail(.socket_error);
        return false;
    }

    /// Try to parse a complete server message from the TCP read buffer.
    /// If successful, consumes the message from the buffer and returns it.
    /// Returns null if the buffer doesn't contain a complete message yet.
    fn tryParseServerMsg(self: *RelayClient) ?protocol.ServerMsg {
        if (self.tcp_read_pos == 0) return null;

        const data = self.tcp_read_buf[0..self.tcp_read_pos];
        const msg = protocol.decodeServerMsg(data);

        // Check if the message was actually parsed (not .unknown)
        if (msg == .unknown) return null;

        // Calculate how many bytes the message consumed
        const consumed: usize = switch (msg) {
            .match_info => 9 + 4, // "MatchInfo" + u32
            .hosted => 6 + 4, // "Hosted" + 4-byte code
            .tun_info => |t| 7 + 4 + t.addr.len + 1, // "TunInfo" + u32 + addr + null
            // Error has no length prefix, so we consume up to MAX_ERROR_LEN.
            // The server closes the TCP connection after sending Error, so
            // in practice there won't be a subsequent message — but capping
            // at MAX_ERROR_LEN is defensive and follows good TCP framing.
            .err => @min(data.len, protocol.MAX_ERROR_LEN),
            .unknown => return null,
        };

        // Shift the buffer to remove the consumed message
        if (consumed <= self.tcp_read_pos) {
            const remaining = self.tcp_read_pos - consumed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, self.tcp_read_buf[0..remaining], self.tcp_read_buf[consumed..self.tcp_read_pos]);
            }
            self.tcp_read_pos = remaining;
        }

        return msg;
    }

    fn shiftTcpBuffer(self: *RelayClient) void {
        // This shouldn't happen with our small messages, but if it does,
        // just clear the buffer and start fresh. Better to lose a partial
        // message than to block forever.
        self.tcp_read_pos = 0;
    }

    // ========================================================================
    // Internal helpers — utilities
    // ========================================================================

    /// Record a failure. If the error is retriable, tears down the current
    /// sockets and schedules a retry (`.retrying` state with backoff) instead
    /// of going terminal — the handshake restarts from stepRetrying() once
    /// the backoff window elapses. Non-retriable errors (e.g. invalid room
    /// code) transition straight to `.failed`.
    fn fail(self: *RelayClient, err: RelayError) void {
        self.error_val = err;
        if (!isRetriable(err)) {
            self.state = .failed;
            return;
        }
        // Retriable: close any open sockets so the next attempt can rebind,
        // then schedule a backoff-waited retry. The room code is preserved.
        self.deinit();
        self.retry_count += 1;
        self.next_retry_ms = self.current_ms + retryDelayMs(self.retry_count);
        self.state = .retrying;
    }

    /// Wait out the backoff window, then restart the handshake. Returns
    /// without doing anything while the backoff hasn't elapsed so the UI
    /// can keep rendering the "Retrying..." status each frame.
    fn stepRetrying(self: *RelayClient, io: std.Io, now_ms: i64) void {
        if (now_ms < self.next_retry_ms) return;
        self.restartHandshake(io);
    }

    fn buildResult(self: *const RelayClient) RelayResult {
        const peer = self.peer_addr.?;
        // Extract IP bytes from the sockaddr_in's addr field (network byte order)
        const peer_ip_nbo = peer.addr;
        return .{
            .peer_ip = .{
                @intCast((peer_ip_nbo >> 0) & 0xFF),
                @intCast((peer_ip_nbo >> 8) & 0xFF),
                @intCast((peer_ip_nbo >> 16) & 0xFF),
                @intCast((peer_ip_nbo >> 24) & 0xFF),
            },
            .peer_port = std.mem.bigToNative(u16, peer.port),
            .local_udp_port = self.local_udp_port,
        };
    }
};

// ============================================================================
// Free functions — socket utilities
// ============================================================================

fn setNonBlocking(fd: c_int, enable: bool) void {
    var mode: u32 = if (enable) 1 else 0;
    _ = ws2_32.ioctlsocket(fd, ws2_32.FIONBIO, &mode);
}

/// True if a relay error is worth retrying. Transient/network errors
/// (relay unreachable, timeouts, disconnects, hole-punch failures) are
/// retriable — they may resolve on their own (relay restart, peer joins
/// late, NAT mapping refreshes). The only terminal error is
/// `invalid_room_code`, which can never succeed without the user retyping
/// the code.
///
/// Note: `.relay_error` (server-sent Error, e.g. room-not-found on join or
/// room-taken on host) is treated as retriable — with a stable room code,
/// room-taken clears once the server's TTL expires, and room-not-found
/// resolves once the host registers. This matches "retry until cancel".
pub fn isRetriable(err: RelayError) bool {
    return switch (err) {
        .invalid_room_code => false,
        else => true,
    };
}

/// Backoff delay (milliseconds) for the Nth retry attempt. Grows
/// exponentially from `retry_initial_delay_ms` and caps at
/// `retry_max_delay_ms`:
///   attempt 1 → 1000, 2 → 2000, 3 → 4000, 4+ → 5000 (capped).
pub fn retryDelayMs(attempt: u32) i64 {
    // Shift the attempt index by the initial delay; cap at the max.
    // attempt=1 → 1000<<0 = 1000, attempt=2 → 1000<<1 = 2000, etc.
    const shift: u6 = if (attempt >= 30) 30 else @intCast(attempt - 1);
    const raw: i64 = retry_initial_delay_ms << shift;
    return @min(raw, retry_max_delay_ms);
}

fn makeSockaddr(ip_nbo: u32, port_host: u16) ws2_32.sockaddr_in {
    return .{
        .family = ws2_32.AF_INET,
        .port = std.mem.nativeToBig(u16, port_host),
        .addr = ip_nbo,
    };
}

fn resolveHost(host: []const u8) u32 {
    var host_buf: [256:0]u8 = undefined;
    if (host.len >= host_buf.len) return 0;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;

    // Try dotted-decimal first (fast path, no DNS)
    const addr = ws2_32.inet_addr(&host_buf);
    if (addr != 0 and addr != std.math.maxInt(u32)) {
        return addr;
    }

    // Fall back to DNS lookup
    const he = ws2_32.gethostbyname(&host_buf) orelse return 0;
    const addr_list = he.h_addr_list orelse return 0;
    const first_addr_ptr = addr_list[0] orelse return 0;
    const a: [*]u8 = first_addr_ptr;
    // gethostbyname returns addresses in network byte order (big-endian),
    // same as inet_addr. Copy the raw bytes into a u32 so the result
    // matches inet_addr's return value on any platform endianness.
    // (The previous std.mem.readInt(..., .little) was correct only on
    // little-endian targets like x86-windows-gnu.)
    var result: u32 = undefined;
    @memcpy(std.mem.asBytes(&result), a[0..4]);
    return result;
}

const IpPort = struct { ip: u32, port: u16 };

/// Parse "ip:port" string into network-byte-order IP + host-byte-order port.
fn parseIpPort(s: []const u8) ?IpPort {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return null;
    const ip_str = s[0..colon];
    const port_str = s[colon + 1 ..];

    var ip_buf: [64:0]u8 = undefined;
    if (ip_str.len >= ip_buf.len) return null;
    @memcpy(ip_buf[0..ip_str.len], ip_str);
    ip_buf[ip_str.len] = 0;

    const ip_nbo = ws2_32.inet_addr(&ip_buf);
    if (ip_nbo == 0 or ip_nbo == std.math.maxInt(u32)) return null;

    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    return .{ .ip = ip_nbo, .port = port };
}

// ============================================================================
// WSAStartup / cleanup — re-exported from the shared ws2_32 module.
// ============================================================================
//
// main.zig calls relay_client_mod.initWinsock() at startup and pairs it
// with deinitWinsock() at shutdown. The implementation lives in
// ws2_32.zig so it can be shared with nat_probe.zig (which previously
// had an identical copy).

pub const initWinsock = ws2_32.initWinsock;
pub const deinitWinsock = ws2_32.deinitWinsock;

