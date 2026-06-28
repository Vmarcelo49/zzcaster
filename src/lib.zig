// Public API for the cc_rollback library — a focused Zig 0.16 port of
// CCCaster's rollback subsystem (targets/DllRollbackManager, the
// rollback-relevant parts of targets/DllNetplayManager, lib/MemDump,
// netplay/InputsContainer, and the frameStep rollback trigger in
// targets/DllMain.cpp).
//
// This port is written from CCCaster source only; it does NOT derive from
// any other implementation. The goal is byte-faithful behavior: the same
// region-table binary format, the same save/load memory layout, the same
// `_lastChangedFrame` semantics, and the same frameStep decision tree.

pub const constants = @import("constants.zig");
pub const IndexedFrame = @import("indexed_frame.zig").IndexedFrame;
pub const NetplayState = @import("netplay_state.zig").NetplayState;
pub const InputsContainer = @import("inputs_container.zig").InputsContainer;
pub const mem_dump = @import("mem_dump.zig");
pub const MemDump = mem_dump.MemDump;
pub const MemDumpPtr = mem_dump.MemDumpPtr;
pub const MemDumpList = mem_dump.MemDumpList;
pub const rollback_manager = @import("rollback_manager.zig");
pub const RollbackManager = rollback_manager.RollbackManager;
pub const GameState = rollback_manager.GameState;
pub const SavedFpu = rollback_manager.SavedFpu;
pub const NetManSnapshot = rollback_manager.NetManSnapshot;
pub const RepRound = rollback_manager.RepRound;
pub const NetplayManager = @import("netplay_manager.zig").NetplayManager;
pub const FrameStep = @import("frame_step.zig").FrameStep;

test {
    @import("std").testing.refAllDecls(@This());
}
