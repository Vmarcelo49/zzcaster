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

/// Detect whether the active network connection is WiFi or Ethernet.
/// Returns "Wired", "Wireless", or "Unknown".
pub fn getConnectionType() []const u8 {
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
