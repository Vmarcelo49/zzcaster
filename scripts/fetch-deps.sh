#!/usr/bin/env bash
# ============================================================================
# fetch-deps.sh — fetch & vendor the C dependencies for the Zig port of
# CCCaster, so that `zig build -Dtarget=x86-windows-gnu` works.
#
# What this script does:
#   1. Downloads ENet (pure C, ~2000 lines) into libs/enet/
#   2. Downloads Dear ImGui into libs/imgui/
#   3. Verifies the downloads via SHA-256
#   4. Checks that SDL2 dev headers are discoverable (msys2 / vcpkg / system)
#   5. Checks that Zig 0.16+ is on PATH
#
# What this script does NOT do (manual steps):
#   - Install Zig itself (see README.md → Manual Setup)
#   - Install SDL2 dev package (instructions below + README.md)
#   - Install a MinGW toolchain (only needed if linking against system libs
#     that don't ship with the Zig toolchain)
#
# Usage:
#   ./scripts/fetch-deps.sh          # fetch everything
#   ./scripts/fetch-deps.sh --check  # just check, don't download
#   ./scripts/fetch-deps.sh --clean  # remove libs/ directory
# ============================================================================

set -euo pipefail

# Resolve script & project paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIBS_DIR="$PROJECT_DIR/libs"
mkdir -p "$LIBS_DIR"

# ---- Versions (pinned for reproducibility) ----
ENET_VERSION="1.3.18"
ENET_TARBALL_URL="https://github.com/lsalzman/enet/archive/refs/tags/v${ENET_VERSION}.tar.gz"
ENET_TARBALL_SHA256="28603c895f9ed24a846478180ee72c7376b39b4bb1287b73877e5eae7d96b0dd"

IMGUI_VERSION="1.92.8"
IMGUI_TARBALL_URL="https://github.com/ocornut/imgui/archive/refs/tags/v${IMGUI_VERSION}.tar.gz"
IMGUI_TARBALL_SHA256="fecb33d33930e12ff53a34064e9d3a06c8f7c3e04408f14cd36c80e3faac863b"

CIMGUI_VERSION="master"
CIMGUI_H_URL="https://raw.githubusercontent.com/cimgui/cimgui/${CIMGUI_VERSION}/cimgui.h"
CIMGUI_CPP_URL="https://raw.githubusercontent.com/cimgui/cimgui/${CIMGUI_VERSION}/cimgui.cpp"

SDL2_VERSION="2.32.10"
SDL2_TARBALL_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-devel-${SDL2_VERSION}-mingw.zip"
SDL2_TARBALL_SHA256="f15cff5fca62ec9381a016ef1d42a95c638cd72d2f226ba5781c76fe43dbd1ac"
SDL2_EXTRACT_DIR="SDL2-${SDL2_VERSION}"

# ---- Helpers ----
log()    { printf "\033[1;34m[fetch-deps]\033[0m %s\n" "$*"; }
ok()     { printf "\033[1;32m  ✓\033[0m %s\n" "$*"; }
warn()   { printf "\033[1;33m  ⚠\033[0m %s\n" "$*"; }
die()    { printf "\033[1;31m  ✗\033[0m %s\n" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

sha256_file() {
    local file="$1"
    if have sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif have shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        die "Neither sha256sum nor shasum found — cannot verify checksums"
    fi
}

download() {
    local url="$1" dest="$2" expected_sha="$3"
    if [[ -f "$dest" ]]; then
        log "Already downloaded: $(basename "$dest")"
    else
        log "Downloading $(basename "$dest") from $url"
        if have curl; then
            curl -sSL --fail -o "$dest" "$url" || die "curl failed for $url"
        elif have wget; then
            wget -q -O "$dest" "$url" || die "wget failed for $url"
        else
            die "Neither curl nor wget found — install one to continue"
        fi
    fi

    local actual_sha
    actual_sha="$(sha256_file "$dest")"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        die "SHA-256 mismatch for $dest
expected: $expected_sha
actual:   $actual_sha"
    fi
    ok "Checksum verified"
}

extract() {
    local tarball="$1" dest_dir="$2"
    if [[ -d "$dest_dir" ]]; then
        log "Already extracted: $(basename "$dest_dir")"
        return
    fi
    log "Extracting $(basename "$tarball")"
    mkdir -p "$dest_dir.tmp"
    tar -xzf "$tarball" -C "$dest_dir.tmp" --strip-components=1
    mv "$dest_dir.tmp" "$dest_dir"
    ok "Extracted to $dest_dir"
}

# Like extract() but for .zip archives (no strip-components).
extract_zip() {
    local zipball="$1" dest_dir="$2" strip_components="${3:-0}"
    if [[ -d "$dest_dir" ]]; then
        log "Already extracted: $(basename "$dest_dir")"
        return
    fi
    log "Extracting $(basename "$zipball")"
    mkdir -p "$dest_dir.tmp"
    if [[ "$strip_components" -gt 0 ]]; then
        # unzip doesn't support --strip-components; use Python for that.
        python3 -c "
import sys, zipfile, os, shutil
zf = zipfile.ZipFile(sys.argv[1])
strip = int(sys.argv[3])
dest = sys.argv[2]
for name in zf.namelist():
    parts = name.split('/')
    if len(parts) <= strip:
        continue
    rel = '/'.join(parts[strip:])
    if not rel:
        continue
    target = os.path.join(dest, rel)
    if name.endswith('/'):
        os.makedirs(target, exist_ok=True)
    else:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, 'wb') as f:
            f.write(zf.read(name))
" "$zipball" "$dest_dir.tmp" "$strip_components"
    else
        unzip -q "$zipball" -d "$dest_dir.tmp"
    fi
    mv "$dest_dir.tmp" "$dest_dir"
    ok "Extracted to $dest_dir"
}

# ---- Mode flags ----
CHECK_ONLY=0
CLEAN=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --clean) CLEAN=1 ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            warn "Unknown argument: $arg"
            ;;
    esac
done

if [[ $CLEAN -eq 1 ]]; then
    log "Cleaning libs/ directory"
    rm -rf "$LIBS_DIR"
    ok "libs/ removed"
    exit 0
fi

# ---- 1. Zig version check ----
log "Checking Zig installation"
if ! have zig; then
    die "zig is not on PATH.
Install Zig 0.16+ from https://ziglang.org/download/ and add it to PATH.
See README.md → Manual Setup for details."
fi

ZIG_VERSION_OUTPUT="$(zig version 2>&1 || true)"
ZIG_MAJOR_MINOR="$(echo "$ZIG_VERSION_OUTPUT" | awk -F. '{print $1"."$2}')"
ZIG_MAJOR="$(echo "$ZIG_VERSION_OUTPUT" | awk -F. '{print $1}')"
ZIG_MINOR="$(echo "$ZIG_VERSION_OUTPUT" | awk -F. '{print $2}')"

if [[ -z "$ZIG_VERSION_OUTPUT" ]]; then
    die "zig version returned empty — is your install complete?"
fi

# Zig 0.16+ is required (std.Io I/O subsystem rewrite — see
# docs/zig-0.16-migration-plan.md). 0.15 and earlier are not supported.
if [[ "$ZIG_MAJOR" -lt 0 ]] || [[ "$ZIG_MAJOR" -eq 0 && "$ZIG_MINOR" -lt 16 ]]; then
    die "Zig 0.16+ required (detected: $ZIG_VERSION_OUTPUT).
This codebase was migrated to Zig 0.16's std.Io-based I/O subsystem.
Download 0.16.0 or later from https://ziglang.org/download/"
fi
ok "Zig $ZIG_VERSION_OUTPUT detected"

# ---- 2. ENet ----
log "Fetching ENet v${ENET_VERSION}"
ENET_TARBALL="$LIBS_DIR/enet-v${ENET_VERSION}.tar.gz"
if [[ $CHECK_ONLY -eq 0 ]]; then
    download "$ENET_TARBALL_URL" "$ENET_TARBALL" "$ENET_TARBALL_SHA256"
    extract "$ENET_TARBALL" "$LIBS_DIR/enet"

    # Sanity check: build.zig expects these specific files
    for f in callbacks.c compress.c host.c list.c packet.c peer.c protocol.c unix.c win32.c; do
        [[ -f "$LIBS_DIR/enet/$f" ]] || die "Missing $f in libs/enet/ — archive layout may have changed"
    done
    [[ -f "$LIBS_DIR/enet/include/enet/enet.h" ]] || die "Missing include/enet/enet.h"
    ok "ENet layout matches build.zig expectations"
else
    [[ -d "$LIBS_DIR/enet" ]] && ok "ENet present" || warn "ENet not present (run without --check to fetch)"
fi

# ---- 3. Dear ImGui ----
log "Fetching Dear ImGui v${IMGUI_VERSION}"
IMGUI_TARBALL="$LIBS_DIR/imgui-v${IMGUI_VERSION}.tar.gz"
if [[ $CHECK_ONLY -eq 0 ]]; then
    download "$IMGUI_TARBALL_URL" "$IMGUI_TARBALL" "$IMGUI_TARBALL_SHA256"
    extract "$IMGUI_TARBALL" "$LIBS_DIR/imgui"

    # Sanity check: build.zig expects these specific files
    for f in imgui.cpp imgui_draw.cpp imgui_tables.cpp imgui_widgets.cpp imgui_demo.cpp; do
        [[ -f "$LIBS_DIR/imgui/$f" ]] || die "Missing $f in libs/imgui/ — archive layout may have changed"
    done
    for f in imgui_impl_sdl2.cpp imgui_impl_opengl3.cpp; do
        [[ -f "$LIBS_DIR/imgui/backends/$f" ]] || die "Missing backends/$f"
    done
    ok "ImGui layout matches build.zig expectations"
else
    [[ -d "$LIBS_DIR/imgui" ]] && ok "ImGui present" || warn "ImGui not present (run without --check to fetch)"
fi

# ---- 3b. cimgui (C API wrapper for Zig @cImport) ----
log "Fetching cimgui (${CIMGUI_VERSION})"
if [[ $CHECK_ONLY -eq 0 ]]; then
    mkdir -p "$LIBS_DIR/cimgui"
    if have curl; then
        curl -sSL --fail -o "$LIBS_DIR/cimgui/cimgui.h" "$CIMGUI_H_URL" || die "curl failed for cimgui.h"
        curl -sSL --fail -o "$LIBS_DIR/cimgui/cimgui.cpp" "$CIMGUI_CPP_URL" || die "curl failed for cimgui.cpp"
    elif have wget; then
        wget -q -O "$LIBS_DIR/cimgui/cimgui.h" "$CIMGUI_H_URL" || die "wget failed for cimgui.h"
        wget -q -O "$LIBS_DIR/cimgui/cimgui.cpp" "$CIMGUI_CPP_URL" || die "wget failed for cimgui.cpp"
    else
        die "Neither curl nor wget found"
    fi
    [[ -f "$LIBS_DIR/cimgui/cimgui.h" ]] || die "Missing cimgui.h"
    [[ -f "$LIBS_DIR/cimgui/cimgui.cpp" ]] || die "Missing cimgui.cpp"

    # cimgui.cpp uses #include "./imgui/imgui.h" (relative to its own
    # directory). Create a symlink so libs/cimgui/imgui points to libs/imgui.
    # This can't go in the zip (symlinks don't survive), so fetch-deps.sh
    # must create it after extraction.
    if [[ ! -e "$LIBS_DIR/cimgui/imgui" ]]; then
        ln -sf ../imgui "$LIBS_DIR/cimgui/imgui"
    fi
    [[ -e "$LIBS_DIR/cimgui/imgui/imgui.h" ]] || die "cimgui→imgui symlink broken"

    ok "cimgui downloaded"
else
    [[ -f "$LIBS_DIR/cimgui/cimgui.h" ]] && ok "cimgui present" || warn "cimgui not present (run without --check to fetch)"
fi

# ---- 4. SDL2 MinGW (for Windows cross-compile) ----
log "Fetching SDL2 v${SDL2_VERSION} (MinGW cross-compile build)"
SDL2_TARBALL="$LIBS_DIR/sdl2-v${SDL2_VERSION}-mingw.zip"
if [[ $CHECK_ONLY -eq 0 ]]; then
    download "$SDL2_TARBALL_URL" "$SDL2_TARBALL" "$SDL2_TARBALL_SHA256"
    extract_zip "$SDL2_TARBALL" "$LIBS_DIR/sdl2-mingw" 1

    # Sanity check: build.zig expects these specific files
    for arch in i686-w64-mingw32 x86_64-w64-mingw32; do
        local_dir="$LIBS_DIR/sdl2-mingw/$arch"
        [[ -f "$local_dir/include/SDL2/SDL.h" ]] \
            || die "Missing $arch/include/SDL2/SDL.h"
        [[ -f "$local_dir/lib/libSDL2.dll.a" ]] \
            || die "Missing $arch/lib/libSDL2.dll.a"
        [[ -f "$local_dir/bin/SDL2.dll" ]] \
            || die "Missing $arch/bin/SDL2.dll"
    done
    ok "SDL2 MinGW layout matches build.zig expectations (both i686 + x86_64)"
else
    [[ -d "$LIBS_DIR/sdl2-mingw" ]] && ok "SDL2 MinGW present" \
        || warn "SDL2 MinGW not present (run without --check to fetch)"
fi

# Also probe for system SDL2 (used if user builds for the host target only).
SDL2_SYSTEM_FOUND=0
if have pkg-config; then
    if pkg-config --exists sdl2 2>/dev/null; then
        SDL2_VERSION_PKG="$(pkg-config --modversion sdl2)"
        ok "System SDL2 $SDL2_VERSION_PKG also available via pkg-config (for host-only builds)"
        SDL2_SYSTEM_FOUND=1
    fi
fi
if [[ $SDL2_SYSTEM_FOUND -eq 0 ]]; then
    ok "No system SDL2 pkg-config entry (that's OK — MinGW copy will be used for cross-compile)"
fi

# ---- 5. Final summary ----
log "Summary"
if [[ $CHECK_ONLY -eq 0 ]]; then
    ok "Dependencies fetched into libs/"
else
    ok "Dependency check complete"
fi
echo
printf "  zig:                %s\n" "$ZIG_VERSION_OUTPUT"
printf "  libs/enet:          %s\n" "$([ -d "$LIBS_DIR/enet" ] && echo "present (v$ENET_VERSION)" || echo "MISSING")"
printf "  libs/imgui:         %s\n" "$([ -d "$LIBS_DIR/imgui" ] && echo "present (v$IMGUI_VERSION)" || echo "MISSING")"
printf "  libs/sdl2-mingw:    %s\n" "$([ -d "$LIBS_DIR/sdl2-mingw" ] && echo "present (v$SDL2_VERSION)" || echo "MISSING")"
printf "  system SDL2 (opt):  %s\n" "$([ $SDL2_SYSTEM_FOUND -eq 1 ] && echo "found (for native builds only)" || echo "not found (OK)")"
echo
log "Next step: zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast"
