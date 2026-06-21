#!/usr/bin/env bash
# Best-effort mechanical migration of a 0.15 Zig codebase to 0.16.
#
# Usage:
#   bash scripts/migrate-015.sh <src-dir>
#
# This script does the mechanical substitutions that are safe to do blindly.
# It does NOT do:
#   - Threading `Io` through function signatures (needs human judgment)
#   - Replacing `@Type` with specialized builtins (case-by-case)
#   - Moving `@cImport` to `b.addTranslateC` (build system restructure)
#   - Updating `main` signature (must inspect main function)
#
# Always review the diff before committing.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "usage: $0 <src-dir>" >&2
    exit 1
fi

SRC_DIR="$1"

if [ ! -d "$SRC_DIR" ]; then
    echo "error: $SRC_DIR is not a directory" >&2
    exit 1
fi

# Use sed -i'' for BSD/macOS compatibility (works on GNU sed too)
SED_INPLACE=(-i '')

echo "Migrating $SRC_DIR from 0.15 to 0.16..."
echo ""

# 1. GeneralPurposeAllocator → DebugAllocator
find "$SRC_DIR" -name '*.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e 's/GeneralPurposeAllocator/DebugAllocator/g' {} \;

# 2. .init(allocator) → .empty + initContext(allocator)  — for the common containers.
#    This is a regex approximation; review the diff.
find "$SRC_DIR" -name '*.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e 's/std\.ArrayList(\([A-Za-z_][A-Za-z0-9_]*\))\.init(\([a-z_][a-z0-9_]*\))/std.ArrayList(\1): .empty; initContext(\2)/g' {} \;

# 3. AutoArrayHashMap / StringArrayHashMap / ArrayHashMap
find "$SRC_DIR" -name '*.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e 's/std\.AutoArrayHashMap/std.array_hash_map.Auto/g' \
    -e 's/std\.StringArrayHashMap/std.array_hash_map.String/g' \
    -e 's/std\.ArrayHashMap/std.array_hash_map.Custom/g' {} \;

# 4. BoundedArray → bounded_array.Bounded
find "$SRC_DIR" -name '*.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e 's/std\.BoundedArray/std.bounded_array.Bounded/g' {} \;

# 5. PriorityQueue.add/remove → push/pop
find "$SRC_DIR" -name '*.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e '/PriorityQueue/ s/\.add(/.push(/g' \
    -e '/PriorityQueue/ s/\.remove(/.pop(/g' {} \;

# 6. @setCold(true) → @branchHint(.cold)
find "$SRC_DIR" -name '*.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e 's/@setCold(true)/@branchHint(.cold)/g' \
    -e 's/@setCold(false)/@branchHint(.none)/g' {} \;

# 7. @intFromFloat → @trunc
find "$SRC_DIR" -name '*.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e 's/@intFromFloat/@trunc/g' {} \;

# 8. ThreadSafeAllocator removal — wraps the child allocator
find "$SRC_DIR" -name '*.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e 's/std\.heap\.ThreadSafeAllocator{ .child_allocator = \([a-z_][a-z0-9_]*\) }/\1/g' \
    -e 's/std\.heap\.ThreadSafeAllocator//g' {} \;

# 9. build.zig: root_source_file → root_module (in addExecutable / addLibrary / addTest)
find "$SRC_DIR" -name 'build.zig' -type f -exec sed "${SED_INPLACE[@]}" \
    -e 's/\.root_source_file = b\.path(\("[^"]*"\)),/\.root_module = b.createModule(.{ .root_source_file = b.path(\1), .target = target, .optimize = optimize }),/g' {} \;

# 10. build.zig.zon: name as string → enum-literal, add fingerprint if missing
for ZON in $(find "$SRC_DIR" -name 'build.zig.zon' -type f); do
    # Convert .name = "foo-bar" → .name = .foo_bar
    sed "${SED_INPLACE[@]}" -E 's/\.name = "([a-zA-Z0-9-]+)"/.name = .\1/g' "$ZON"
    sed "${SED_INPLACE[@]}" -E 's/\.name = \.([a-zA-Z0-9]+)-([a-zA-Z0-9-]+)/.name = .\1_\2/g' "$ZON"

    # Add fingerprint if missing
    if ! grep -q 'fingerprint' "$ZON"; then
        FP=$(bash "$(dirname "$0")/gen-fingerprint.sh")
        sed "${SED_INPLACE[@]}" -E "s/(\.name = \.[a-zA-Z0-9_]+,)/\1\n    .fingerprint = ${FP},/" "$ZON"
    fi
done

echo "Mechanical migration complete."
echo ""
echo "Manual steps remaining (the script cannot do these safely):"
echo "  1. Update main signature: pub fn main() !void → pub fn main(init: std.process.Init) !void"
echo "  2. Thread `io: std.Io` through every function that does I/O"
echo "  3. Replace std.fs.cwd() with std.Io.Dir.cwd(io)"
echo "  4. Replace std.io.getStdOut().writer() with init.io.out()"
echo "  5. Replace std.Thread.Pool + WaitGroup with Io.Group + io.async"
echo "  6. Replace std.Thread.Mutex with Io.Mutex (.lock(io) / .unlock(io))"
echo "  7. Replace @Type with specialized builtins (@Int, @Struct, @Union, etc.)"
echo "  8. Move @cImport blocks into c_imports.h + b.addTranslateC in build.zig"
echo "  9. Fix container init: .init(allocator) → .empty + initContext(allocator)"
echo "     (the script does this for ArrayList only — check HashMap, PriorityQueue, etc.)"
echo ""
echo "See references/migration-015-016.md in this skill for the full walkthrough."
