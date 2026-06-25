const std = @import("std");

// Windows IP Helper API for adapter enumeration.
const win32 = struct {
    extern "iphlpapi" fn GetAdaptersAddresses(
        Family: u32,
        Flags: u32,
        Reserved: ?*anyopaque,
        AdapterAddresses: ?*IP_ADAPTER_ADDRESSES,
        SizePointer: *u32,
    ) callconv(.winapi) u32;

    extern "kernel32" fn GetProcessHeap() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn HeapAlloc(hHeap: ?*anyopaque, dwFlags: u32, dwBytes: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn HeapFree(hHeap: ?*anyopaque, dwFlags: u32, lpMem: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetModuleHandleA(lpModuleName: ?[*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: ?*const anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?*anyopaque,
    ) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn ReadFile(
        hFile: ?*anyopaque,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: u32,
        lpNumberOfBytesRead: ?*u32,
        lpOverlapped: ?*anyopaque,
    ) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;

    const GENERIC_READ: u32 = 0x80000000;
    const FILE_SHARE_READ: u32 = 1;
    const OPEN_EXISTING: u32 = 3;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;

    const AF_INET: u32 = 2;
    const AF_UNSPEC: u32 = 0;
    const GAA_FLAG_SKIP_ANYCAST: u32 = 0x0002;
    const GAA_FLAG_SKIP_MULTICAST: u32 = 0x0004;
    const GAA_FLAG_SKIP_DNS_SERVER: u32 = 0x0008;

    const IF_TYPE_ETHERNET_CSMACD: u32 = 6;
    const IF_TYPE_SOFTWARE_LOOPBACK: u32 = 24;
    const IF_TYPE_IEEE80211: u32 = 71;

    const IP_ADAPTER_ADDRESSES = extern struct {
        Alignment: u64,
        Next: ?*IP_ADAPTER_ADDRESSES,
        AdapterName: ?[*:0]u8,
        FriendlyName: ?[*:0]u16,
        Description: ?[*:0]u16,
        AddressLength: u32,
        Address: [8]u8,
        Index: u32,
        Type: u32,
        TunnelType: u32,
        MediaType: u32,
        PhysicalAddressLength: u32,
        PhysicalAddress: [8]u8,
        ConnectionType: u32,
        // ... many more fields we don't need; we only read up to Type.
        // The struct is much larger but GetAdaptersAddresses fills it all
        // in one allocation, so we just need the first fields.
    };

    const ERROR_SUCCESS: u32 = 0;
    const ERROR_BUFFER_OVERFLOW: u32 = 111;
};

fn isValidHandle(handle: ?*anyopaque) bool {
    if (handle == null) return false;
    if (handle == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) return false;
    return true;
}

fn isWine() bool {
    const ntdll = win32.GetModuleHandleA("ntdll.dll") orelse return false;
    return win32.GetProcAddress(ntdll, "wine_get_version") != null;
}

fn getLinuxConnectionType() ?[]const u8 {
    const handle = win32.CreateFileA(
        "Z:\\proc\\net\\route",
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (!isValidHandle(handle)) return null;
    defer _ = win32.CloseHandle(handle);

    var buf: [2048]u8 = undefined;
    var bytes_read: u32 = 0;
    if (win32.ReadFile(handle, &buf, buf.len, &bytes_read, null) == 0) return null;

    const content = buf[0..bytes_read];
    var lines = std.mem.splitScalar(u8, content, '\n');

    // Skip header line
    _ = lines.next() orelse return null;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        var it = std.mem.tokenizeAny(u8, trimmed, " \t");
        const iface = it.next() orelse continue;
        const dest = it.next() orelse continue;

        if (std.mem.eql(u8, dest, "00000000")) {
            var sys_path_buf: [256]u8 = undefined;
            const sys_path = std.fmt.bufPrintZ(&sys_path_buf, "Z:\\sys\\class\\net\\{s}\\wireless", .{iface}) catch return null;

            const attrs = win32.GetFileAttributesA(sys_path.ptr);
            if (attrs != win32.INVALID_FILE_ATTRIBUTES) {
                return "Wireless";
            }
            return "Wired";
        }
    }
    return null;
}

/// Detect whether the active network connection is WiFi or Ethernet.
/// Returns "Wired", "Wireless", or "Unknown".
pub fn getConnectionType() []const u8 {
    if (isWine()) {
        if (getLinuxConnectionType()) |conn_type| {
            return conn_type;
        }
    }

    var buf_size: u32 = 0;

    // First call to get required buffer size.
    const flags = win32.GAA_FLAG_SKIP_ANYCAST | win32.GAA_FLAG_SKIP_MULTICAST | win32.GAA_FLAG_SKIP_DNS_SERVER;
    _ = win32.GetAdaptersAddresses(win32.AF_UNSPEC, flags, null, null, &buf_size);
    if (buf_size == 0) return "Unknown";

    // Allocate buffer from process heap.
    const heap = win32.GetProcessHeap() orelse return "Unknown";
    const buf = win32.HeapAlloc(heap, 0, buf_size) orelse return "Unknown";
    defer _ = win32.HeapFree(heap, 0, buf);

    // Second call to get the actual adapter list.
    const adapters_ptr: ?*win32.IP_ADAPTER_ADDRESSES = @ptrCast(@alignCast(buf));
    const ret = win32.GetAdaptersAddresses(win32.AF_UNSPEC, flags, null, adapters_ptr, &buf_size);
    if (ret != win32.ERROR_SUCCESS) return "Unknown";

    var has_wifi = false;
    var has_ethernet = false;

    var adapter = adapters_ptr;
    while (adapter) |a| {
        // Skip loopback adapters.
        if (a.Type == win32.IF_TYPE_SOFTWARE_LOOPBACK) {
            adapter = a.Next;
            continue;
        }

        if (a.Type == win32.IF_TYPE_IEEE80211) {
            has_wifi = true;
        } else if (a.Type == win32.IF_TYPE_ETHERNET_CSMACD) {
            has_ethernet = true;
        }

        adapter = a.Next;
    }

    if (has_wifi) return "Wireless";
    if (has_ethernet) return "Wired";
    return "Unknown";
}
