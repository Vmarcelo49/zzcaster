//! Single source of truth for Winsock (ws2_32) extern bindings, structs, and
//! constants.
//!
//! Why this exists: Zig has no `#include <winsock2.h>` equivalent. Every file
//! that needs ws2_32 must declare its externs, and prior to this module three
//! files (`relay_client.zig`, `nat_probe.zig`, `ip_discovery.zig`) each had
//! their own copy. The copies had already drifted:
//!   - `nat_probe.zig` had a `readInt(..., .little)` endianness bug in
//!     `resolveHost` that `relay_client.zig` had already fixed (commit f96c6e9)
//!   - `ip_discovery.zig` named the hostent struct `Hostent` (capital H)
//!     while the other two used `hostent`
//! Consolidating here prevents that class of drift going forward.
//!
//! Usage:
//!   const ws2_32 = @import("ws2_32.zig");
//!   ... ws2_32.socket(...), ws2_32.sockaddr_in, ws2_32.AF_INET, etc.
//!
//! The original per-file `ws2_32` structs named exactly the same identifier
//! (`ws2_32`), so callers only need to swap the local struct definition for
//! a one-line `@import` — call sites are unchanged.
//!
//! CCCaster has no equivalent: it just `#include <winsock2.h>` everywhere
//! and lets the system header define everything. The duplication issue is
//! zzcaster-specific (a side effect of the Zig port's lack of a system
//! header include).

const std = @import("std");

// ============================================================================
// Extern functions
// ============================================================================

pub extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSAData) callconv(.winapi) c_int;
pub extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;

pub extern "ws2_32" fn socket(af: c_int, sock_type: c_int, protocol: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn closesocket(s: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn bind(s: c_int, name: ?*const sockaddr_in, namelen: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn connect(s: c_int, name: ?*const sockaddr_in, namelen: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn send(s: c_int, buf: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn recv(s: c_int, buf: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn sendto(
    s: c_int,
    buf: [*]const u8,
    len: c_int,
    flags: c_int,
    to: ?*const sockaddr_in,
    tolen: c_int,
) callconv(.winapi) c_int;
pub extern "ws2_32" fn recvfrom(
    s: c_int,
    buf: [*]u8,
    len: c_int,
    flags: c_int,
    from: ?*sockaddr_in,
    fromlen: ?*c_int,
) callconv(.winapi) c_int;
pub extern "ws2_32" fn select(
    nfds: c_int,
    readfds: ?*fd_set,
    writefds: ?*fd_set,
    exceptfds: ?*fd_set,
    timeout: ?*const timeval,
) callconv(.winapi) c_int;
pub extern "ws2_32" fn ioctlsocket(s: c_int, cmd: u32, argp: *u32) callconv(.winapi) c_int;
pub extern "ws2_32" fn setsockopt(
    s: c_int,
    level: c_int,
    optname: c_int,
    optval: [*]const u8,
    optlen: c_int,
) callconv(.winapi) c_int;
pub extern "ws2_32" fn getsockopt(
    s: c_int,
    level: c_int,
    optname: c_int,
    optval: [*]u8,
    optlen: *c_int,
) callconv(.winapi) c_int;
pub extern "ws2_32" fn getsockname(s: c_int, name: ?*sockaddr_in, namelen: ?*c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn gethostname(name: [*]u8, namelen: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn inet_addr(cp: ?[*:0]const u8) callconv(.winapi) u32;
pub extern "ws2_32" fn gethostbyname(name: [*:0]const u8) callconv(.winapi) ?*hostent;

// ============================================================================
// Structs
// ============================================================================

pub const WSAData = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?*u8,
};

pub const hostent = extern struct {
    h_name: ?[*:0]const u8,
    h_aliases: ?[*]?[*:0]const u8,
    h_addrtype: i16,
    h_length: i16,
    h_addr_list: ?[*]?[*]u8,
};

pub const sockaddr_in = extern struct {
    family: u16 = AF_INET,
    port: u16 = 0, // network byte order
    addr: u32 = 0, // network byte order
    zero: [8]u8 = [_]u8{0} ** 8,
};

// fd_set for select() — Windows uses a different layout than POSIX.
// Winsock: { u_int fd_count; SOCKET fd_array[FD_SETSIZE]; }
// FD_SETSIZE is 64 by default.
pub const FD_SETSIZE: c_int = 64;

pub const fd_set = extern struct {
    fd_count: u32 = 0,
    fd_array: [FD_SETSIZE]c_int = [_]c_int{0} ** FD_SETSIZE,
};

pub const timeval = extern struct {
    tv_sec: c_long = 0,
    tv_usec: c_long = 0,
};

// ============================================================================
// Constants
// ============================================================================

pub const AF_INET: c_int = 2;
pub const SOCK_STREAM: c_int = 1;
pub const SOCK_DGRAM: c_int = 2;
pub const SOL_SOCKET: c_int = 0xFFFF;
pub const SO_REUSEADDR: c_int = 0x0004;
pub const SO_RCVTIMEO: c_int = 0x1006;
pub const SO_ERROR: c_int = 0x1007;
pub const FIONBIO: u32 = 0x8004667E;

pub const WSAEWOULDBLOCK: c_int = 10035;
pub const WSAEINPROGRESS: c_int = 10036;
pub const WSAECONNREFUSED: c_int = 10061;

// ============================================================================
// fd_set helpers (Windows semantics — FD_SET dedupes, FD_ZERO just zeroes)
// ============================================================================

/// Zero-initialize an fd_set.
pub fn FD_ZERO(set: *fd_set) void {
    set.fd_count = 0;
}

/// Add a socket to an fd_set (no-op if already present).
pub fn FD_SET(fd: c_int, set: *fd_set) void {
    if (set.fd_count < FD_SETSIZE) {
        var i: u32 = 0;
        while (i < set.fd_count) : (i += 1) {
            if (set.fd_array[i] == fd) return;
        }
        set.fd_array[set.fd_count] = fd;
        set.fd_count += 1;
    }
}

// ============================================================================
// Winsock init / cleanup
// ============================================================================
//
// Winsock requires WSAStartup before any socket call and WSACleanup at
// shutdown. The reference count is per-process — multiple WSAStartup calls
// are allowed but each must be matched by a WSACleanup.
//
// In zzcaster, only the launcher calls these (the injected DLL goes through
// ENet, which calls WSAStartup internally). The launcher calls initWinsock
// once at startup via main.zig.
//
// `pub const init` / `pub const deinit` aliases are provided so callers can
// use the conventional Zig pattern (ws2_32.init() / ws2_32.deinit()) in
// addition to the original initWinsock()/deinitWinsock() names that
// relay_client.zig and nat_probe.zig export as `pub fn`.

/// Initialize Winsock (request version 2.2). Returns true on success.
pub fn initWinsock() bool {
    var wsa_data: WSAData = undefined;
    // 0x0202 = MAKEWORD(2, 2) — request Winsock 2.2.
    const version_req: u16 = 0x0202;
    if (WSAStartup(version_req, &wsa_data) != 0) return false;
    return true;
}

/// Cleanup Winsock. Must be called once at app shutdown, paired with each
/// successful initWinsock() call.
pub fn deinitWinsock() void {
    _ = WSACleanup();
}

/// Conventional Zig alias for initWinsock.
pub const init = initWinsock;

/// Conventional Zig alias for deinitWinsock.
pub const deinit = deinitWinsock;
