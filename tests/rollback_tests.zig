// Top-level test aggregator. The per-module tests live next to their source
// files. To make `zig build test` discover AND run them, we import each module
// here with `_ = @import(...)` — this pulls the file's `test` blocks into the
// test binary's root.

const std = @import("std");

// Importing each source file directly causes its `test` blocks to be
// included in the test binary. The `cc_rollback` namespace import alone
// only checks declarations exist; it does NOT run the module's tests.
comptime {
    _ = @import("cc_rollback").constants;
    _ = @import("cc_rollback").IndexedFrame;
    _ = @import("cc_rollback").NetplayState;
    _ = @import("cc_rollback").InputsContainer;
    _ = @import("cc_rollback").mem_dump;
    _ = @import("cc_rollback").rollback_manager;
    _ = @import("cc_rollback").NetplayManager;
    _ = @import("cc_rollback").FrameStep;
    _ = @import("cc_rollback").GameState;
    _ = @import("cc_rollback").SavedFpu;
}

test "library exposes all modules" {
    const cc = @import("cc_rollback");
    try std.testing.expect(@hasDecl(cc, "RollbackManager"));
    try std.testing.expect(@hasDecl(cc, "NetplayManager"));
    try std.testing.expect(@hasDecl(cc, "FrameStep"));
    try std.testing.expect(@hasDecl(cc, "InputsContainer"));
    try std.testing.expect(@hasDecl(cc, "MemDumpList"));
    try std.testing.expect(@hasDecl(cc, "IndexedFrame"));
    try std.testing.expect(@hasDecl(cc, "NetplayState"));
    try std.testing.expect(@hasDecl(cc, "constants"));
}
