const std = @import("std");
const logging = @import("common").logging;

// ENet via @cImport — this is the SINGLE cimport for the whole project.
// Other files (netplay_manager.zig, spectator_manager.zig) import
// `enet` from here via `@import("enet_transport.zig").enet` to share the
// same type definitions.
pub const enet = @cImport({
    @cInclude("enet/enet.h");
});

pub const TransportEvent = enum {
    connected,
    disconnected,
    timed_out,
    message_received,
    err_state,
};

pub const TransportStats = struct {
    rtt_ms: u32 = 0,
    jitter_ms: u32 = 0,
    packet_loss_pct: u32 = 0,
};

pub const EnetTransport = struct {
    host: ?*enet.ENetHost = null,
    peer: ?*enet.ENetPeer = null,
    is_host: bool = false,
    connected: bool = false,
    last_message: [4096]u8 = undefined,
    last_message_len: usize = 0,
    // True when THIS instance called `enet_initialize()` (i.e. we own the
    // global ENet state). Set by `listen()` and `connect()`, checked by
    // `deinit()` so we don't tear down ENet while another transport in the
    // same process is still using it.
    owns_enet_init: bool = false,

    pub fn init() EnetTransport {
        return EnetTransport{};
    }

    pub fn deinit(self: *EnetTransport) void {
        if (self.peer != null) {
            enet.enet_peer_disconnect(self.peer, 0);
            enet.enet_host_flush(self.host);
            self.peer = null;
        }
        if (self.host != null) {
            enet.enet_host_destroy(self.host);
            self.host = null;
        }
        self.connected = false;
        // Only deinitialize ENet if we were the side that initialized it.
        // The previous code had `if (self.is_host or !self.is_host)` which is
        // tautologically true — it always deinitialized ENet regardless of
        // ownership, which is dangerous when multiple transports share a
        // process (the DLL's NetplayManager and a spectator chain, for
        // example). Now we track ownership explicitly.
        if (self.owns_enet_init) {
            enet.enet_deinitialize();
            self.owns_enet_init = false;
        }
    }

    pub fn listen(self: *EnetTransport, port: u16, log: *logging.Logger) !void {
        // NOTE: do NOT `defer enet_deinitialize()` here — that would tear down
        // the library (and its internal state) immediately after we create the
        // host, making every subsequent enet_host_service call fail. ENet is
        // process-global; the launcher/DLL is expected to keep it alive for the
        // whole session. deinit() below calls enet_deinitialize() once the
        // transport is dropped.
        if (enet.enet_initialize() != 0) return error.EnetInitFailed;
        // If enet_initialize() succeeded we own the global state until deinit.
        // (If anything below fails, we still need to tear it down.)
        self.owns_enet_init = true;
        errdefer {
            enet.enet_deinitialize();
            self.owns_enet_init = false;
        }

        var addr: enet.ENetAddress = undefined;
        addr.host = enet.ENET_HOST_ANY;
        addr.port = port;

        self.host = enet.enet_host_create(&addr, 2, 2, 0, 0);
        if (self.host == null) {
            log.err("enet_host_create failed on port {d}", .{port});
            return error.HostCreateFailed;
        }
        self.is_host = true;
        log.info("ENet listening on port {d}", .{port});
    }

    pub fn connect(self: *EnetTransport, host_str: []const u8, port: u16, log: *logging.Logger) !void {
        if (enet.enet_initialize() != 0) return error.EnetInitFailed;
        self.owns_enet_init = true;
        errdefer {
            enet.enet_deinitialize();
            self.owns_enet_init = false;
        }

        self.host = enet.enet_host_create(null, 1, 2, 0, 0);
        if (self.host == null) {
            log.err("enet_host_create (client) failed", .{});
            return error.HostCreateFailed;
        }

        // Parse IP address
        var addr: enet.ENetAddress = undefined;
        var host_buf: [64]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&host_buf, "{s}", .{host_str}) catch return error.HostTooLong;
        if (enet.enet_address_set_host(&addr, host_z.ptr) != 0) {
            log.err("Failed to parse host: {s}", .{host_str});
            return error.InvalidHost;
        }
        addr.port = port;

        self.peer = enet.enet_host_connect(self.host, &addr, 2, 0);
        if (self.peer == null) {
            log.err("enet_host_connect failed", .{});
            return error.ConnectFailed;
        }
        self.is_host = false;
        log.info("ENet connecting to {s}:{d}", .{ host_str, port });
    }

    pub fn sendReliable(self: *EnetTransport, data: []const u8) bool {
        if (self.peer == null or !self.connected) return false;
        const packet = enet.enet_packet_create(data.ptr, data.len, enet.ENET_PACKET_FLAG_RELIABLE);
        if (packet == null) return false;
        if (enet.enet_peer_send(self.peer, 0, packet) < 0) {
            enet.enet_packet_destroy(packet);
            return false;
        }
        enet.enet_host_flush(self.host);
        return true;
    }

    pub fn sendUnreliable(self: *EnetTransport, data: []const u8) bool {
        if (self.peer == null or !self.connected) return false;
        const packet = enet.enet_packet_create(data.ptr, data.len, 0);
        if (packet == null) return false;
        if (enet.enet_peer_send(self.peer, 1, packet) < 0) {
            enet.enet_packet_destroy(packet);
            return false;
        }
        enet.enet_host_flush(self.host);
        return true;
    }

    pub fn poll(self: *EnetTransport, timeout_ms: u32) ?TransportEvent {
        if (self.host == null) return null;

        var event: enet.ENetEvent = undefined;
        const result = enet.enet_host_service(self.host, &event, timeout_ms);
        if (result <= 0) return null;

        switch (event.type) {
            enet.ENET_EVENT_TYPE_CONNECT => {
                self.peer = event.peer;
                self.connected = true;
                return .connected;
            },
            enet.ENET_EVENT_TYPE_RECEIVE => {
                // ENet's event.packet is a [*c]ENetPacket; deref before field
                // access (matches the pattern used in netplay_manager.zig).
                const pkt = event.packet;
                const data = pkt.*.data;
                const data_len = pkt.*.dataLength;
                const len = @min(data_len, self.last_message.len);
                @memcpy(self.last_message[0..len], data[0..len]);
                self.last_message_len = len;
                enet.enet_packet_destroy(event.packet);
                return .message_received;
            },
            enet.ENET_EVENT_TYPE_DISCONNECT => {
                self.connected = false;
                self.peer = null;
                return .disconnected;
            },
            else => return null,
        }
    }

    pub fn getLastMessage(self: *const EnetTransport) []const u8 {
        return self.last_message[0..self.last_message_len];
    }

    pub fn getStats(self: *const EnetTransport) TransportStats {
        if (self.peer == null) return .{};
        return .{
            .rtt_ms = self.peer.?.roundTripTime,
            .jitter_ms = self.peer.?.lastRoundTripTimeVariance,
            // ENet's packetLoss is a fixed-point percentage; divide by the
            // scale. Cast to u32 to avoid signed/unsigned division.
            .packet_loss_pct = @intCast(self.peer.?.packetLoss / @as(c_uint, @intCast(enet.ENET_PEER_PACKET_LOSS_SCALE))),
        };
    }
};
