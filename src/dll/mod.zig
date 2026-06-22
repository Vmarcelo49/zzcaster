// DLL module — everything in hook.dll (injected into MBAA.exe).
pub const dllmain = @import("dllmain.zig");
pub const asm_hacks = @import("asm_hacks.zig");
pub const frame_step = @import("frame_step.zig");
pub const netplay_manager = @import("netplay_manager.zig");
pub const rollback = @import("rollback.zig");
pub const rollback_regions = @import("rollback_regions.zig");
pub const sfx_dedup = @import("sfx_dedup.zig");
pub const spectator_manager = @import("spectator_manager.zig");
pub const gamepad = @import("gamepad.zig");
pub const keyboard = @import("keyboard.zig");
pub const controller_mapper = @import("controller_mapper.zig");
