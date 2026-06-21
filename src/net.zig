const std = @import("std");
const logging = @import("logging.zig");

// ENet via @cImport — this is the SINGLE cimport for the whole project.
// Other files (dll/netplay_manager.zig, dll/spectator_manager.zig) import
// `enet` from here via `@import("net.zig").enet` to share the same type
// definitions.
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
        // Both listen() and connect() call enet_initialize(); we match that
        // with a single deinit here. (If the host process already inited ENet
        // elsewhere — e.g. the DLL — that caller is responsible for its own
        // deinit.)
        if (self.is_host or !self.is_host) {
            enet.enet_deinitialize();
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

// ============================================================================
// IP address discovery — used by the launcher's "Host Game" screen so the
// host can show its public + local address for the peer to connect to.
// ============================================================================

const wininet = struct {
    extern "wininet" fn InternetOpenA(
        lpszAgent: ?[*:0]const u8,
        dwAccessType: u32,
        lpszProxy: ?[*:0]const u8,
        lpszProxyBypass: ?[*:0]const u8,
        dwFlags: u32,
    ) callconv(.winapi) ?*anyopaque;
    extern "wininet" fn InternetOpenUrlA(
        hInternet: ?*anyopaque,
        lpszUrl: ?[*:0]const u8,
        lpszHeaders: ?[*:0]const u8,
        dwHeadersLength: u32,
        dwFlags: u32,
        dwContext: usize,
    ) callconv(.winapi) ?*anyopaque;
    extern "wininet" fn InternetReadFile(
        hFile: ?*anyopaque,
        lpBuffer: [*]u8,
        dwNumberOfBytesToRead: u32,
        lpdwNumberOfBytesRead: *u32,
    ) callconv(.winapi) i32;
    extern "wininet" fn InternetCloseHandle(hInternet: ?*anyopaque) callconv(.winapi) i32;

    const OPEN_TYPE_PRECONFIG: u32 = 0;
    const FLAG_RELOAD: u32 = 0x80000000;
};

const ws2_32 = struct {
    extern "ws2_32" fn gethostname(name: [*]u8, namelen: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn gethostbyname(name: [*:0]const u8) callconv(.winapi) ?*Hostent;

    const Hostent = extern struct {
        h_name: ?[*:0]const u8,
        h_aliases: ?[*]?[*:0]const u8,
        h_addrtype: i16,
        h_length: i16,
        h_addr_list: ?[*]?[*]u8,
    };
};

/// Look up the machine's public IP via a small HTTP GET (api.ipify.org).
/// Returns a slice into the caller-provided buffer, or null on failure.
/// Non-blocking from the user's perspective: InternetOpenUrl honors the
/// system's HTTP connect timeout (~few seconds).
pub fn getPublicIp(buf: []u8) ?[]const u8 {
    const hInternet = wininet.InternetOpenA(
        "zzcaster",
        wininet.OPEN_TYPE_PRECONFIG,
        null,
        null,
        0,
    ) orelse return null;
    defer _ = wininet.InternetCloseHandle(hInternet);

    const url = "https://api.ipify.org";
    const hUrl = wininet.InternetOpenUrlA(hInternet, url, null, 0, wininet.FLAG_RELOAD, 0) orelse return null;
    defer _ = wininet.InternetCloseHandle(hUrl);

    var read: u32 = 0;
    const cap: u32 = @intCast(@min(buf.len, 64));
    if (wininet.InternetReadFile(hUrl, buf.ptr, cap, &read) == 0) return null;
    if (read == 0) return null;

    // Strip trailing whitespace/newlines.
    var end: usize = read;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r' or
        buf[end - 1] == ' ' or buf[end - 1] == '\t'))
    {
        end -= 1;
    }
    if (end == 0) return null;
    return buf[0..end];
}

/// Look up the machine's primary local IPv4 via gethostname + gethostbyname.
/// Returns a slice into the caller-provided buffer, or null on failure.
pub fn getLocalIp(buf: []u8) ?[]const u8 {
    var name_buf: [256]u8 = undefined;
    if (ws2_32.gethostname(&name_buf, name_buf.len) != 0) return null;
    // gethostname doesn't guarantee null-termination on every platform, but
    // on Windows it does. Find it just in case.
    var name_end: usize = 0;
    while (name_end < name_buf.len and name_buf[name_end] != 0) : (name_end += 1) {}
    name_buf[name_end] = 0;

    const he = ws2_32.gethostbyname(@ptrCast(&name_buf)) orelse return null;
    const addr_list = he.h_addr_list orelse return null;
    const first_addr_ptr = addr_list[0] orelse return null;
    // IPv4 address is 4 bytes in network byte order.
    const a: [*]u8 = first_addr_ptr;
    const ip_str = std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a[0], a[1], a[2], a[3] }) catch return null;
    return ip_str;
}
