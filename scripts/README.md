# scripts/

Helper scripts for the Zig port of CCCaster.

## fetch-deps.sh

Fetches and vendors the C/C++ dependencies that the Zig build pulls in via
`addCSourceFiles`. Run this once before your first `zig build`.

```bash
./scripts/fetch-deps.sh          # fetch everything (downloads + extracts)
./scripts/fetch-deps.sh --check  # don't download, just report state
./scripts/fetch-deps.sh --clean  # remove libs/ directory
```

What it does automatically:

1. **Verifies Zig 0.16+ is on PATH.** The build was migrated to Zig 0.16's
   `std.Io`-based I/O subsystem (see `docs/zig-0.16-migration-plan.md`).
   0.15 and earlier will not work.

2. **Downloads ENet 1.3.18** (pure C, ~2k lines, BSD-licensed) from
   https://github.com/lsalzman/enet → extracts to `libs/enet/`.
   SHA-256 verified against the pinned checksum.

3. **Downloads Dear ImGui 1.91.5** (MIT-licensed) from
   https://github.com/ocornut/imgui → extracts to `libs/imgui/`.
   SHA-256 verified against the pinned checksum.

4. **Probes for SDL2 dev package** via `pkg-config --exists sdl2`.
   If not found, prints platform-specific install instructions and
   exits 0 (warning only — you may have SDL2 installed some other way
   that pkg-config can't see).

What it does NOT do (you must do these manually):

### Install Zig 0.16+

Download from https://ziglang.org/download/ (0.16.0 or later) and put
`zig` on your PATH.

- **Linux:** extract the tarball anywhere, e.g. `/opt/zig-0.16.0/`, then
  `export PATH=/opt/zig-0.16.0:$PATH`. Add to `~/.bashrc` to persist.
- **Windows:** extract the zip and add the folder to your PATH env var.
  Use `zig.exe` instead of `zig`.
- **macOS:** download the `macos-x86_64` or `macos-aarch64` tarball and
  extract. (Cross-compiling to Windows from macOS is untested.)

### Install SDL2 dev package

`hook.dll` is a 32-bit DLL injected into MBAA.exe (32-bit).
`cccaster.exe` is a 64-bit launcher. **You need both 32-bit and 64-bit
SDL2 dev packages** to build the whole tree.

If you only want to build `cccaster.exe` (no `hook.dll`), 64-bit SDL2
is enough.

**MSYS2 (recommended on Windows):**
```bash
pacman -S \
    mingw32/mingw-w64-i686-SDL2 \
    mingw64/mingw-w64-x86_64-SDL2 \
    mingw32/mingw-w64-i686-pkg-config \
    mingw64/mingw-w64-x86_64-pkg-config
```

**Linux (cross-compiling to Windows):**
```bash
# Debian/Ubuntu — these only cover host builds, NOT cross-compile to Windows.
sudo apt install libsdl2-dev pkg-config

# For actual cross-compile to Windows you need mingw-w64 SDL2:
sudo apt install mingw-w64 libsdl2-dev:i386 pkg-config-mingw-w64-i686 \
                 pkg-config-mingw-w64-x86-64
# (i386 SDL2 dev requires multiarch: dpkg --add-architecture i386 &&
#  apt update before installing)
```

**Linux native build (for testing only — won't inject into MBAA.exe):**
```bash
sudo apt install libsdl2-dev
zig build -Doptimize=ReleaseFast   # native target
```

**macOS:** `brew install sdl2` (cross-compile to Windows is untested).

### (Optional) Install a MinGW toolchain

Only needed if you want to use `zig cc` to compile arbitrary MinGW C/C++
code that links against system libraries Zig's toolchain doesn't ship.
For this project, you can skip this — Zig's bundled LLVM/LD-LDD handles
everything `build.zig` asks for.

## Updating dependency versions

To upgrade ENet or ImGui to a newer version:

1. Update the version string + URL + SHA-256 in `scripts/fetch-deps.sh`
   (top of the file, after the `# ---- Versions ----` header).
2. Delete `libs/` and re-run `./scripts/fetch-deps.sh`.
3. If the new version changes the file layout (rare), update `build.zig`
   to match — both the file list passed to `addCSourceFiles` and the
   `addIncludePath` calls.

To get the SHA-256 for a new version:
```bash
curl -sL https://github.com/lsalzman/enet/archive/refs/tags/v1.3.19.tar.gz | sha256sum
```

## Build process overview

After `fetch-deps.sh` has run successfully:

```
zig-cccaster/
├── build.zig
├── scripts/
│   ├── fetch-deps.sh
│   └── README.md          ← this file
├── libs/                   ← created by fetch-deps.sh
│   ├── enet/               ← from lsalzman/enet
│   └── imgui/              ← from ocornut/imgui
└── src/
    ├── main.zig            ← cccaster.exe entry point
    ├── ui.zig              ← TUI menu
    ├── config.zig
    ├── logging.zig
    ├── ipc.zig             ← named-pipe IPC to hook.dll
    ├── launcher.zig        ← DLL injector
    ├── net.zig             ← ENet transport wrapper
    ├── session.zig         ← netplay session FSM
    ├── gamepad.zig         ← SDL2 gamepad
    ├── keyboard.zig        ← Win32 GetKeyState
    ├── rollback.zig        ← InputBuffer + StatePool
    └── dll/
        ├── dllmain.zig     ← hook.dll entry point
        ├── netplay_manager.zig
        ├── sfx_dedup.zig   ← SFX dedup module
        ├── spectator_manager.zig
        └── hook_exports.c
```

To build everything (cccaster.exe + hook.dll) for the 32-bit Windows
target:

```bash
zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast
```

To build only `cccaster.exe` for 64-bit Windows:

```bash
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
```

(You may need to comment out the `hook` target in `build.zig` if you
only have 64-bit SDL2 installed.)

Output goes to `zig-out/bin/` (`cccaster.exe`, `hook.dll`).
