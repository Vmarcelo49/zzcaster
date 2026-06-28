const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- The rollback library module ---------------------------------------
    const cc_rollback = b.addModule("cc_rollback", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- Demo executable ---------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "cc_rollback_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("cc_rollback", cc_rollback);
    b.installArtifact(exe);

    // --- Unit tests --------------------------------------------------------
    // The test root IS lib.zig so all per-module `test` blocks are discovered
    // via `refAllDecls`. The test file imports the library as `cc_rollback`
    // for any cross-module assertions.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("cc_rollback", cc_rollback);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
