const std = @import("std");
const ws2_32 = @import("ws2_32.zig");

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
