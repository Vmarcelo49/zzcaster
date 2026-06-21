const std = @import("std");
const logging = @import("logging.zig");
const net = @import("net.zig");

pub const SessionState = enum {
    idle,
    listening,
    connecting,
    handshaking,
    ping_exchanging,
    waiting_confirmation,
    launching,
    in_game,
    completed,
    failed,
};

pub const PingStats = struct {
    avg_ms: f64 = 0,
    min_ms: f64 = 0,
    max_ms: f64 = 0,
    count: u32 = 0,
    packet_loss: u8 = 0,
};

pub const NetplayConfig = struct {
    is_host: bool = false,
    is_training: bool = false,
    delay: u8 = 0,
    rollback: u8 = 0,
    win_count: u8 = 2,
    host_player: u8 = 1,
    local_name: []const u8 = "Player",
    remote_name: []const u8 = "Opponent",
};

pub const NetplaySession = struct {
    allocator: std.mem.Allocator,
    // Zig 0.16: std.time.milliTimestamp() is gone — store the Io handle
    // here so we can call Io.Clock.now(self.io, .real).toMilliseconds().
    io: std.Io,
    log: *logging.Logger,
    transport: net.EnetTransport,
    state: SessionState = .idle,
    config: NetplayConfig = .{},
    stats: PingStats = .{},
    local_version: []const u8 = "4.0-zig",

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

    pub fn host(self: *NetplaySession, port: u16, training: bool) !void {
        self.config.is_host = true;
        self.config.is_training = training;
        self.state = .listening;
        try self.transport.listen(port, self.log);

        // Wait for client to connect (blocking with timeout)
        self.log.info("Waiting for opponent to connect on port {d}...", .{port});
        var attempts: u32 = 0;
        while (attempts < 600) : (attempts += 1) { // 60s timeout
            if (self.transport.poll(100)) |event| {
                if (event == .connected) {
                    self.log.info("Opponent connected!", .{});
                    try self.doHandshake();
                    return;
                }
            }
        }
        self.log.err("Connection timed out", .{});
        self.state = .failed;
        return error.Timeout;
    }

    pub fn join(self: *NetplaySession, host_str: []const u8, port: u16, training: bool) !void {
        self.config.is_host = false;
        self.config.is_training = training;
        self.state = .connecting;
        try self.transport.connect(host_str, port, self.log);

        // Wait for connect event
        var attempts: u32 = 0;
        while (attempts < 100) : (attempts += 1) { // 10s timeout
            if (self.transport.poll(100)) |event| {
                if (event == .connected) {
                    self.log.info("Connected to host!", .{});
                    try self.doHandshake();
                    return;
                }
            }
        }
        self.log.err("Connection timed out", .{});
        self.state = .failed;
        return error.Timeout;
    }

    fn doHandshake(self: *NetplaySession) !void {
        self.state = .handshaking;

        // Simple handshake: exchange version strings
        // Message format: [1 byte type] [payload]
        // Type 1 = Version, Type 2 = Config, Type 3 = Confirm, Type 4 = Ping, Type 5 = Inputs

        // Send our version
        var ver_buf: [128]u8 = undefined;
        ver_buf[0] = 1; // Version message
        const ver_len = @min(self.local_version.len, 127);
        @memcpy(ver_buf[1 .. 1 + ver_len], self.local_version[0..ver_len]);
        _ = self.transport.sendReliable(ver_buf[0 .. 1 + ver_len]);
        self.log.info("Sent version: {s}", .{self.local_version});

        // Wait for peer's version
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 1 and msg[0] == 1) {
                        const peer_ver = msg[1..];
                        self.log.info("Peer version: {s}", .{peer_ver});
                        break;
                    }
                }
                if (event == .disconnected) {
                    self.state = .failed;
                    return error.Disconnected;
                }
            }
        }

        // Exchange ping stats
        self.state = .ping_exchanging;
        try self.exchangePings();

        // Host sends config, client confirms
        if (self.config.is_host) {
            try self.sendConfig();
        } else {
            try self.waitForConfig();
        }

        self.state = .launching;
    }

    fn exchangePings(self: *NetplaySession) !void {
        // Send 5 ping packets, measure RTT
        const num_pings: u32 = 5;
        var i: u32 = 0;
        while (i < num_pings) : (i += 1) {
            const start = std.Io.Clock.now(.real, self.io).toMilliseconds();
            var ping_msg: [9]u8 = undefined;
            ping_msg[0] = 4; // Ping message
            std.mem.writeInt(u64, ping_msg[1..9], @intCast(start), .little);
            _ = self.transport.sendReliable(&ping_msg);

            // Wait for pong
            var waited: u32 = 0;
            while (waited < 50) : (waited += 1) {
                if (self.transport.poll(10)) |event| {
                    if (event == .message_received) {
                        const msg = self.transport.getLastMessage();
                        if (msg.len >= 1 and msg[0] == 4 and msg.len >= 9) {
                            const rtt = std.Io.Clock.now(.real, self.io).toMilliseconds() - start;
                            self.stats.count += 1;
                            self.stats.avg_ms = (self.stats.avg_ms * @as(f64, @floatFromInt(self.stats.count - 1)) + @as(f64, @floatFromInt(rtt))) / @as(f64, @floatFromInt(self.stats.count));
                            if (self.stats.min_ms == 0 or @as(f64, @floatFromInt(rtt)) < self.stats.min_ms) self.stats.min_ms = @floatFromInt(rtt);
                            if (@as(f64, @floatFromInt(rtt)) > self.stats.max_ms) self.stats.max_ms = @floatFromInt(rtt);
                            break;
                        }
                        // If it's a ping from peer, reply with pong (same message back)
                        if (msg.len >= 1 and msg[0] == 4) {
                            _ = self.transport.sendReliable(msg);
                        }
                    }
                    if (event == .disconnected) return error.Disconnected;
                }
            }
        }

        // Also respond to any pings the peer sent
        var extra: u32 = 0;
        while (extra < 10) : (extra += 1) {
            if (self.transport.poll(10)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 1 and msg[0] == 4) {
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

        // Auto-compute delay from RTT
        const avg_rtt = if (self.stats.avg_ms > 0) self.stats.avg_ms else 50;
        self.config.delay = @intFromFloat(@ceil(avg_rtt / (1000.0 / 60.0)));
        self.log.info("Auto delay: {d}", .{self.config.delay});
    }

    fn sendConfig(self: *NetplaySession) !void {
        // Host sends config to client
        var cfg_buf: [32]u8 = undefined;
        cfg_buf[0] = 2; // Config message
        cfg_buf[1] = self.config.delay;
        cfg_buf[2] = self.config.rollback;
        cfg_buf[3] = self.config.win_count;
        cfg_buf[4] = self.config.host_player;
        _ = self.transport.sendReliable(cfg_buf[0..5]);
        self.log.info("Sent config: delay={d} rollback={d} winCount={d}", .{
            self.config.delay, self.config.rollback, self.config.win_count,
        });

        // Wait for confirm
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 1 and msg[0] == 3) { // Confirm
                        self.log.info("Client confirmed", .{});
                        return;
                    }
                }
                if (event == .disconnected) return error.Disconnected;
            }
        }
        return error.NoConfirm;
    }

    fn waitForConfig(self: *NetplaySession) !void {
        var attempts: u32 = 0;
        while (attempts < 50) : (attempts += 1) {
            if (self.transport.poll(100)) |event| {
                if (event == .message_received) {
                    const msg = self.transport.getLastMessage();
                    if (msg.len >= 1 and msg[0] == 2 and msg.len >= 5) { // Config
                        self.config.delay = msg[1];
                        self.config.rollback = msg[2];
                        self.config.win_count = msg[3];
                        self.config.host_player = msg[4];
                        self.log.info("Received config: delay={d} rollback={d} winCount={d}", .{
                            self.config.delay, self.config.rollback, self.config.win_count,
                        });

                        // Send confirm
                        const confirm = [_]u8{3};
                        _ = self.transport.sendReliable(&confirm);
                        self.log.info("Sent confirm", .{});
                        return;
                    }
                }
                if (event == .disconnected) return error.Disconnected;
            }
        }
        return error.NoConfig;
    }

    pub fn pollTransport(self: *NetplaySession) ?[]const u8 {
        if (self.transport.poll(0)) |event| {
            switch (event) {
                .message_received => return self.transport.getLastMessage(),
                .disconnected => {
                    self.state = .failed;
                    self.log.warn("Peer disconnected", .{});
                },
                else => {},
            }
        }
        return null;
    }

    pub fn sendInputs(self: *NetplaySession, inputs: []const u8) void {
        // Type 5 = Inputs (unreliable for speed)
        var buf: [65]u8 = undefined;
        buf[0] = 5;
        const len = @min(inputs.len, 64);
        @memcpy(buf[1 .. 1 + len], inputs[0..len]);
        _ = self.transport.sendUnreliable(buf[0 .. 1 + len]);
    }
};
