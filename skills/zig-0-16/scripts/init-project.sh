#!/usr/bin/env bash
# Scaffold a Zig 0.16 project skeleton.
#
# Usage:
#   bash scripts/init-project.sh <project-name> [target-dir]
#
# Creates:
#   <target-dir>/<project-name>/
#     ├── build.zig
#     ├── build.zig.zon
#     └── src/
#         └── main.zig
#
# The skeleton uses the new 0.16 main signature: pub fn main(init: std.process.Init) !void.
# It includes an ArenaAllocator, an Io.Group, and a smoke test.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <project-name> [target-dir]" >&2
    exit 1
fi

PROJECT_NAME="$1"
TARGET_DIR="${2:-.}"

# Convert hyphens to underscores for the Zig name identifier
ZIG_NAME=$(echo "$PROJECT_NAME" | tr '-' '_')
FINGERPRINT=$(bash "$(dirname "$0")/gen-fingerprint.sh")

PROJECT_PATH="${TARGET_DIR%/}/${PROJECT_NAME}"

if [ -e "$PROJECT_PATH" ]; then
    echo "error: $PROJECT_PATH already exists" >&2
    exit 1
fi

mkdir -p "$PROJECT_PATH/src"

cat > "$PROJECT_PATH/build.zig.zon" <<EOF
.{
    .name = .${ZIG_NAME},
    .fingerprint = ${FINGERPRINT},
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .paths = .{
        "src",
        "build.zig",
        "build.zig.zon",
    },
}
EOF

cat > "$PROJECT_PATH/build.zig" <<'EOF'
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
EOF

cat > "$PROJECT_PATH/src/main.zig" <<'EOF'
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena: std.heap.ArenaAllocator = .empty;
    arena.initContext(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var group = io.createGroup(gpa);
    defer group.cancelAndWait(io);

    try io.out().print("Hello from {s}!\n", .{@tagName(.app_name)});

    _ = a;
}

test "smoke" {
    var io_state = std.testing.io;
    const io = &io_state.io;

    try io.out().print("test ran\n", .{});
    try io_state.flush();
    try std.testing.expectEqualStrings("test ran\n", io_state.stdout_written);
}
EOF

# Mark .gitignore
cat > "$PROJECT_PATH/.gitignore" <<'EOF'
.zig-cache/
.zig-out/
zig-pkg/
EOF

echo "Created Zig 0.16 project at: $PROJECT_PATH"
echo ""
echo "Next steps:"
echo "  cd $PROJECT_PATH"
echo "  zig build run"
