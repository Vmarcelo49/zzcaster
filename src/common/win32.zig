/// Common Windows helpers shared by both the launcher (zzcaster.exe) and the
/// injected DLL (hook.dll).  All path-returning functions produce UTF-8 so the
/// rest of the Zig codebase never needs to deal with UTF-16.
const std = @import("std");

const kernel32 = struct {
    extern "kernel32" fn GetModuleFileNameW(
        hModule: ?*anyopaque,
        lpFilename: [*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;
};

/// Retrieve the full path of a loaded module as UTF-8.
///
/// `hModule` — module handle (`null` = current .exe; pass the DLL handle to
/// get the DLL path).
///
/// On success returns the UTF-8 slice within `utf8_buf`.
/// Returns `null` when the Win32 call fails or the buffer is too small.
pub fn getModuleFileNameUtf8(hModule: ?*anyopaque, utf8_buf: []u8) ?[]const u8 {
    var wide_buf: [512]u16 = undefined;
    const wide_len = kernel32.GetModuleFileNameW(hModule, &wide_buf, wide_buf.len);
    if (wide_len == 0 or wide_len >= wide_buf.len) return null;

    const utf8_len = std.unicode.utf16LeToUtf8(utf8_buf, wide_buf[0..wide_len]) catch return null;
    return utf8_buf[0..utf8_len];
}
