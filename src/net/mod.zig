// Net module — network transport shared by launcher and DLL.
pub const enet_transport = @import("enet_transport.zig");
pub const ip_discovery = @import("ip_discovery.zig");

// Re-export the ENet cimport so all files see the same type definitions.
pub const enet = enet_transport.enet;
