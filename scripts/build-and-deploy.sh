#!/usr/bin/env bash
# ============================================================================
# build-and-deploy.sh — build zig-zzcaster for Windows and copy the
# resulting zzcaster.exe + hook.dll into the MBAACC game's zzcaster/
# folder, overwriting any previous build.
#
# Usage:
#   ./scripts/build-and-deploy.sh                    # default target + game dir
#   ./scripts/build-and-deploy.sh --target=x86_64-windows-gnu
#   ./scripts/build-and-deploy.sh --game-dir="/path/to/MBAACC/zzcaster"
#   ./scripts/build-and-deploy.sh --optimize=Debug
#
# Defaults match the project's recommended setup (cross-compile to 32-bit
# Windows from Linux, deploy into the Community Edition install).
# ============================================================================

set -euo pipefail

# ---- Resolve paths ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---- Defaults ----
TARGET="x86-windows-gnu"
OPTIMIZE="ReleaseFast"
# The launcher (zzcaster.exe) must live in the MBAACC root so it can find
# MBAA.exe (./MBAA.exe) and zzcaster/hook.dll + zzcaster/config.ini. So
# --game-dir is the MBAACC root; zzcaster.exe and hook.dll are written
# there, and SDL2.dll is dropped in zzcaster/ next to hook.dll.
DEFAULT_GAME_DIR="/home/marcelo/Downloads/Community_Edition_3-1-004/MBAACC - Community Edition/MBAACC"
GAME_DIR="$DEFAULT_GAME_DIR"

# ---- Parse args ----
for arg in "$@"; do
    case "$arg" in
        --target=*)   TARGET="${arg#*=}" ;;
        --optimize=*) OPTIMIZE="${arg#*=}" ;;
        --game-dir=*) GAME_DIR="${arg#*=}" ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "build-and-deploy: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ---- Helpers ----
log()  { printf "\033[1;34m[build-deploy]\033[0m %s\n" "$*"; }
ok()   { printf "\033[1;32m  ✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m  ⚠\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m  ✗\033[0m %s\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---- 1. Build ----
log "Building zig-zzcaster (target=$TARGET optimize=$OPTIMIZE)"

# Prefer Zig 0.16 from ~/.local/zig — this project was migrated to
# Zig 0.16's std.Io-based I/O subsystem (see docs/zig-0.16-migration-plan.md).
# Fall back to PATH if 0.16 isn't installed locally.
LOCAL_ZIG="$HOME/.local/zig/0.16.0/zig"
if [[ -x "$LOCAL_ZIG" ]]; then
    ZIG="$LOCAL_ZIG"
elif [[ -n "${ZIG:-}" ]] && [[ -x "$ZIG" ]]; then
    : # user-supplied ZIG= takes precedence
elif have zig; then
    ZIG_VER="$(zig version 2>/dev/null || true)"
    case "$ZIG_VER" in
        0.16.*) ZIG="$(command -v zig)" ;;
        *) die "system zig is $ZIG_VER but this project requires 0.16.x
Install Zig 0.16.0 to ~/.local/zig/0.16.0/ or set ZIG=/path/to/zig16" ;;
    esac
else
    die "zig not on PATH and ~/.local/zig/0.16.0/zig missing
Install Zig 0.16.0 from https://ziglang.org/download/"
fi

(
    cd "$PROJECT_DIR"
    "$ZIG" build "-Dtarget=$TARGET" "-Doptimize=$OPTIMIZE"
)
ok "zig build complete (used $("$ZIG" version) at ${ZIG%/*})"

BIN_DIR="$PROJECT_DIR/zig-out/bin"
[[ -f "$BIN_DIR/zzcaster.exe" ]] || die "missing $BIN_DIR/zzcaster.exe"
[[ -f "$BIN_DIR/hook.dll" ]]     || die "missing $BIN_DIR/hook.dll"

# ---- 2. Deploy ----
if [[ ! -d "$GAME_DIR" ]]; then
    die "game directory does not exist: $GAME_DIR
Pass --game-dir=/path/to/MBAACC/zzcaster to override."
fi

log "Deploying into: $GAME_DIR"
cp -f "$BIN_DIR/zzcaster.exe" "$GAME_DIR/zzcaster.exe"
ok "copied zzcaster.exe (→ $GAME_DIR/)"

# The injected hook.dll must live in zzcaster/ subdir — the DLL load
# path passed to CreateRemoteThread is `.\zzcaster\hook.dll`.
mkdir -p "$GAME_DIR/zzcaster"
cp -f "$BIN_DIR/hook.dll" "$GAME_DIR/zzcaster/hook.dll"
ok "copied hook.dll (→ $GAME_DIR/zzcaster/)"

# Also drop the vendored SDL2.dll alongside hook.dll so the DLL can
# load it at runtime (hook.dll links SDL2.dll). The MinGW zip ships
# both i686 and x86_64 DLLs; pick the one matching the build target.
SDL_DLL_SRC=""
if [[ -d "$PROJECT_DIR/libs/sdl2-mingw" ]]; then
    case "$TARGET" in
        x86_64*)        sdl_arch="x86_64-w64-mingw32" ;;
        *)              sdl_arch="i686-w64-mingw32"   ;;
    esac
    SDL_DLL_SRC="$PROJECT_DIR/libs/sdl2-mingw/$sdl_arch/bin/SDL2.dll"
    if [[ -f "$SDL_DLL_SRC" ]]; then
        cp -f "$SDL_DLL_SRC" "$GAME_DIR/zzcaster/SDL2.dll"
        ok "copied SDL2.dll ($sdl_arch, → $GAME_DIR/zzcaster/)"
    else
        warn "SDL2.dll not found in libs/sdl2-mingw/$sdl_arch/bin/ — skipping"
        SDL_DLL_SRC=""
    fi
else
    warn "libs/sdl2-mingw/ not present — SDL2.dll not copied (game may need it at runtime)"
fi

# ---- 2.5. Package release zip ----
RELEASE_DIR="$PROJECT_DIR/release"
mkdir -p "$RELEASE_DIR"
ZIP_PATH="$RELEASE_DIR/zzcaster.zip"

log "Packaging release zip: $ZIP_PATH"

# Stage files into a temp dir that mirrors the in-game layout, then zip
# from there so the archive's internal paths match exactly:
#   zzcaster.exe
#   zzcaster/hook.dll
#   zzcaster/SDL2.dll   (if available)
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT

cp -f "$BIN_DIR/zzcaster.exe" "$STAGE_DIR/zzcaster.exe"
mkdir -p "$STAGE_DIR/zzcaster"
cp -f "$BIN_DIR/hook.dll" "$STAGE_DIR/zzcaster/hook.dll"
if [[ -n "$SDL_DLL_SRC" ]]; then
    cp -f "$SDL_DLL_SRC" "$STAGE_DIR/zzcaster/SDL2.dll"
fi

(
    cd "$STAGE_DIR"
    have zip || die "zip not found on PATH — install it to create the release archive"
    zip -r "$ZIP_PATH" .
)
ok "created $ZIP_PATH"

# ---- 3. Summary ----
echo
log "Deploy summary"
printf "  target:    %s\n" "$TARGET"
printf "  optimize:  %s\n" "$OPTIMIZE"
printf "  game dir:  %s\n" "$GAME_DIR"
printf "  release:   %s\n" "$ZIP_PATH"
printf "  files:\n"
for f in zzcaster.exe hook.dll SDL2.dll; do
    # hook.dll + SDL2.dll live in zzcaster/ subdir; zzcaster.exe in the root.
    p="$GAME_DIR/$(if [[ $f == zzcaster.exe ]]; then echo ""; else echo "zzcaster/"; fi)$f"
    if [[ -f "$p" ]]; then
        printf "    %-32s %8d bytes  %s\n" "$p" "$(stat -c%s "$p")" "$(date -u -d "@$(stat -c%Y "$p")" '+%Y-%m-%d %H:%M:%S UTC')"
    fi
done
echo
ok "done"