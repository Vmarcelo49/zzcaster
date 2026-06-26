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
// ws2_32 bindings — TCP + UDP + select + non-blocking I/O
// ============================================================================

const ws2_32 = struct {
    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSAData) callconv(.winapi) c_int;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    extern "ws2_32" fn socket(af: c_int, sock_type: c_int, protocol: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn connect(s: c_int, name: ?*const sockaddr_in, namelen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn bind(s: c_int, name: ?*const sockaddr_in, namelen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn send(s: c_int, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recv(s: c_int, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn sendto(s: c_int, buf: [*]const u8, len: c_int, flags: c_int, to: ?*const sockaddr_in, tolen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn recvfrom(s: c_int, buf: [*]u8, len: c_int, flags: c_int, from: ?*sockaddr_in, fromlen: ?*c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn select(nfds: c_int, readfds: ?*fd_set, writefds: ?*fd_set, exceptfds: ?*fd_set, timeout: ?*const timeval) callconv(.winapi) c_int;
    extern "ws2_32" fn ioctlsocket(s: c_int, cmd: u32, argp: *u32) callconv(.winapi) c_int;
    extern "ws2_32" fn setsockopt(s: c_int, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockopt(s: c_int, level: c_int, optname: c_int, optval: [*]u8, optlen: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockname(s: c_int, name: ?*sockaddr_in, namelen: ?*c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn inet_addr(cp: ?[*:0]const u8) callconv(.winapi) u32;
    extern "ws2_32" fn gethostbyname(name: [*:0]const u8) callconv(.winapi) ?*hostent;
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;

    const WSAData = extern struct {
        wVersion: u16,
        wHighVersion: u16,
        szDescription: [257]u8,
        szSystemStatus: [129]u8,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?*u8,
    };

    const hostent = extern struct {
        h_name: ?[*:0]const u8,
        h_aliases: ?[*]?[*:0]const u8,
        h_addrtype: i16,
        h_length: i16,
        h_addr_list: ?[*]?[*]u8,
    };

    const AF_INET: c_int = 2;
    const SOCK_STREAM: c_int = 1;
    const SOCK_DGRAM: c_int = 2;
    const SOL_SOCKET: c_int = 0xFFFF;
    const SO_REUSEADDR: c_int = 0x0004;
    const SO_RCVTIMEO: c_int = 0x1006;
    const SO_ERROR: c_int = 0x1007;
    const FIONBIO: u32 = 0x8004667E;

    const WSAEWOULDBLOCK: c_int = 10035;
    const WSAEINPROGRESS: c_int = 10036;
    const WSAECONNREFUSED: c_int = 10061;

    const sockaddr_in = extern struct {
        family: u16 = AF_INET,
        port: u16 = 0, // network byte order
        addr: u32 = 0, // network byte order
        zero: [8]u8 = [_]u8{0} ** 8,
    };

    // fd_set for select() — Windows uses a different layout than POSIX.
    // Winsock: { u_int fd_count; SOCKET fd_array[FD_SETSIZE]; }
    // FD_SETSIZE is 64 by default.
    const FD_SETSIZE: c_int = 64;
    const fd_set = extern struct {
        fd_count: u32 = 0,
        fd_array: [FD_SETSIZE]c_int = [_]c_int{0} ** FD_SETSIZE,
    };

    const timeval = extern struct {
        tv_sec: c_long = 0,
        tv_usec: c_long = 0,
    };

    /// Zero-initialize an fd_set.
    fn FD_ZERO(set: *fd_set) void {
        set.fd_count = 0;
    }

    /// Add a socket to an fd_set.
    fn FD_SET(fd: c_int, set: *fd_set) void {
        if (set.fd_count < FD_SETSIZE) {
            var i: u32 = 0;
            while (i < set.fd_count) : (i += 1) {
                if (set.fd_array[i] == fd) return;
            }
            set.fd_array[set.fd_count] = fd;
            set.fd_count += 1;
        }
    }
};

// ============================================================================
// Constants
// ============================================================================

/// Wall-clock timeouts (milliseconds) for each phase.
const tcp_connect_timeout_ms: i64 = 5_000;
const hosted_timeout_ms: i64 = 5_000;
const match_info_timeout_ms: i64 = 60_000; // relay TTL
const tun_info_timeout_ms: i64 = 10_000;
const hole_punch_timeout_ms: i64 = 10_000;

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
    failed, // error occurred — check error field
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

        // Resolve relay address and start TCP connect.
        const relay_ip = resolveHost(cfg.relay.host);
        if (relay_ip == 0) {
            rc.state = .failed;
            rc.error_val = .tcp_connect_failed;
            return rc;
        }

        rc.relay_udp_addr = makeSockaddr(relay_ip, cfg.relay.port);

        // Create non-blocking TCP socket and connect.
        const tcp_fd = ws2_32.socket(ws2_32.AF_INET, ws2_32.SOCK_STREAM, 0);
        if (tcp_fd < 0) {
            rc.state = .failed;
            rc.error_val = .socket_error;
            return rc;
        }
        setNonBlocking(tcp_fd, true);

        const tcp_dest = makeSockaddr(relay_ip, cfg.relay.port);
        const connect_ret = ws2_32.connect(tcp_fd, &tcp_dest, @sizeOf(ws2_32.sockaddr_in));
        if (connect_ret != 0) {
            const err = ws2_32.WSAGetLastError();
            if (err != ws2_32.WSAEWOULDBLOCK and err != ws2_32.WSAEINPROGRESS) {
                _ = ws2_32.closesocket(tcp_fd);
                rc.state = .failed;
                rc.error_val = .tcp_connect_failed;
                return rc;
            }
            // WSAEWOULDBLOCK is expected for non-blocking connect — we'll
            // poll for writability in stepTcpConnecting().
        }

        rc.tcp_sock = tcp_fd;
        rc.state = .tcp_connecting;
        rc.phase_start_ms = std.Io.Clock.now(.real, io).toMilliseconds();
        return rc;
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

        switch (self.state) {
            .idle => return null,
            .tcp_connecting => self.stepTcpConnecting(io, now_ms),
            .waiting_for_hosted => self.stepWaitingForHosted(io, now_ms),
            .waiting_for_match_info => self.stepWaitingForMatchInfo(io, now_ms),
            .waiting_for_tun_info => self.stepWaitingForTunInfo(io, now_ms),
            .hole_punching => self.stepHolePunching(io, now_ms),
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

    fn fail(self: *RelayClient, err: RelayError) void {
        self.state = .failed;
        self.error_val = err;
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
// WSAStartup / cleanup — must be called once at app start
// ============================================================================

/// Initialize Winsock. Must be called once at app start before any
/// ws2_32 socket operations. Returns true on success.
pub fn initWinsock() bool {
    var wsa_data: ws2_32.WSAData = undefined;
    const version_req: u16 = 0x0202; // version 2.2
    if (ws2_32.WSAStartup(version_req, &wsa_data) != 0) return false;
    return true;
}

/// Cleanup Winsock. Must be called once at app shutdown.
pub fn deinitWinsock() void {
    _ = ws2_32.WSACleanup();
}
