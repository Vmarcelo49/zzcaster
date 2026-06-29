// Net module — network transport shared by launcher and DLL.
pub const ws2_32 = @import("ws2_32.zig");
pub const enet_transport = @import("enet_transport.zig");
pub const ip_discovery = @import("ip_discovery.zig");
pub const relay_protocol = @import("relay_protocol.zig");
pub const relay_config = @import("relay_config.zig");
pub const relay_client = @import("relay_client.zig");
pub const nat_probe = @import("nat_probe.zig");
pub const connection_detector = @import("connection_detector.zig");

// Re-export the ENet cimport so all files see the same type definitions.
pub const enet = enet_transport.enet;
