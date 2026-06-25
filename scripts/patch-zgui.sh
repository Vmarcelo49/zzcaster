#!/usr/bin/env bash
# ============================================================================
# patch-zgui.sh — strip duplicate declarations from zgui's bundled
# imgui_impl_sdl2.cpp that cause C++ compile errors with the pinned
# zgui commit (bfbebed372723d1f585f86fc0a550232b3427f4d).
#
# Bug:
#   imgui_impl_sdl2.cpp lines 167-168 (after the "FIX(zig-gamedev):" comment)
#   redeclare:
#     enum ImGui_ImplSDL2_GamepadMode { ... };
#     IMGUI_IMPL_API void ImGui_ImplSDL2_SetGamepadMode(... = nullptr, ... = -1);
#   Both are already declared in imgui_impl_sdl2.h (lines 51-52), which the
#   .cpp file #includes at line 112. C++ forbids both redefining an enum and
#   re-specifying default arguments on a function redeclaration — producing
#   3 compile errors that block the build.
#
#   The upstream zgui comment "we aren't importing imgui_impl_sdl2.h" is
#   incorrect — the .cpp DOES include the .h. This patch removes the
#   duplicate declarations.
#
# Idempotent: if the file is already patched (or never had the bug), this
# script does nothing and exits 0.
#
# Invoked from build.zig as a system command step that the imgui artifact
# depends on, so the patch runs before the .cpp is compiled.
# ============================================================================

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZGUI_PKG_DIR="$PROJECT_DIR/zig-pkg"

shopt -s nullglob
zgui_dirs=( "$ZGUI_PKG_DIR"/zgui-* )
shopt -u nullglob

if [[ ${#zgui_dirs[@]} -eq 0 ]]; then
    echo "[patch-zgui] no zgui-* directory in $ZGUI_PKG_DIR — nothing to patch"
    exit 0
fi

patched=0
for zgui_dir in "${zgui_dirs[@]}"; do
    cpp_file="$zgui_dir/libs/imgui/backends/imgui_impl_sdl2.cpp"
    [[ -f "$cpp_file" ]] || continue

    # Check if the bug is present (the enum redefinition line exists).
    # If not, the file is already patched (or never had the bug) — skip.
    if ! grep -q '^enum ImGui_ImplSDL2_GamepadMode {' "$cpp_file"; then
        continue
    fi

    # Remove the offending lines (idempotent — sed only deletes matches):
    #   1. The redefined enum:
    #        enum ImGui_ImplSDL2_GamepadMode { ImGui_ImplSDL2_GamepadMode_AutoFirst, ... };
    #   2. The redeclared function with default arguments:
    #        IMGUI_IMPL_API void  ImGui_ImplSDL2_SetGamepadMode(... = nullptr, ... = -1);
    sed -i \
        -e '/^enum ImGui_ImplSDL2_GamepadMode {/d' \
        -e '/^IMGUI_IMPL_API void *ImGui_ImplSDL2_SetGamepadMode.*= nullptr.*= -1);/d' \
        "$cpp_file"

    echo "[patch-zgui] patched $cpp_file"
    patched=1
done

if [[ $patched -eq 0 ]]; then
    echo "[patch-zgui] no patching needed (all files already clean)"
fi
