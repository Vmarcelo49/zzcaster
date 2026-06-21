# ZZCaster

A Zig port of [CCCaster](https://github.com/Rhekar/CCCaster), the netplay
launcher and DLL injector for **MELTY BLOOD Actress Again Current Code**
(MBAACC).

## Credits

ZZCaster is a from-scratch rewrite of the original CCCaster by **Rhekar**
and contributors. The original project is a C++ Win32 application that has
served the MBAACC community for years. This Zig port aims to modernize the
codebase while preserving the same netcode algorithm and game compatibility.

**Original project:** https://github.com/Rhekar/CCCaster

Key components ported from the original:
- Game memory addresses and ASM hacks (from `legacy_unused/targets/DllAsmHacks.cpp`)
- Rollback state pool and SFX dedup (from `DllRollbackManager.cpp`)
- Netplay state machine and input synchronization (from `DllNetplayManager.cpp`)
- Spectator chain forwarding (from `SpectatorManager.cpp`)
- Rollback memory regions (from `Generator.cpp`)

## What ZZCaster Does

ZZCaster consists of two binaries:

1. **`zzcaster.exe`** — The launcher. Provides an ImGui-based UI for selecting
   game modes (Training, Versus, Netplay Host/Join, Spectate), configuring
   settings, and mapping controllers. Creates the MBAA.exe process in suspended
   state, injects `hook.dll` via `CreateRemoteThread(LoadLibraryA)`, then
   resumes the main thread.

2. **`hook.dll`** — The injected DLL. Runs inside MBAA.exe's process space.
   Patches the game's main loop to call a per-frame callback (`frameStep`),
   which handles input reading, network communication (ENet), rollback state
   management, and SFX deduplication.

## Build

### Prerequisites

| Component | How to install |
|-----------|---------------|
| **Zig 0.16** | https://ziglang.org/download/ → extract → add to PATH or your package manager |

All C/C++ dependencies (ENet, Dear ImGui, cimgui, SDL2 MinGW) are
auto-downloaded by `scripts/fetch-deps.sh`.

### Quick start

```bash
./scripts/fetch-deps.sh
zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast
```

Output appears in `zig-out/bin/`:
- `zzcaster.exe` — the launcher (64-bit)
- `hook.dll` — the injected DLL (32-bit, matches MBAA.exe)

### Deploy to game directory

```bash
./scripts/build-and-deploy.sh --game-dir="/path/to/MBAACC"
```

This copies `zzcaster.exe` to the MBAACC root and `hook.dll` + `SDL2.dll`
to `MBAACC/zzcaster/`.

## Usage

### Interactive (ImGui UI)

```bash
zzcaster.exe
```

A window opens with a sidebar menu:
- **Netplay / Spectate** — Enter IP:port, then click Host, Join, or Spectate
- **Offline** — Training Mode or Versus Mode
- **Game Config** — Set win count and rollback frames (text input + Apply)
- **Controllers** — Lists detected gamepads (full mapper planned)

### CLI (non-interactive)

```bash
zzcaster.exe --mode=training
zzcaster.exe --mode=versus
zzcaster.exe --mode=host --port=46318
zzcaster.exe --mode=join --peer=1.2.3.4:46318
zzcaster.exe --mode=spectate --peer=1.2.3.4:46318
```

## Architecture

```
zzcaster.exe (launcher, 64-bit)
  ├── Creates MBAA.exe suspended
  ├── Injects hook.dll via CreateRemoteThread
  ├── Sends config via named pipe IPC
  └── Monitors process exit

hook.dll (injected, 32-bit)
  ├── DllMain: applies ASM hacks, connects IPC, inits SDL2
  ├── frameStep (called every game frame via patched main loop):
  │   ├── Reads local input (gamepad/keyboard)
  │   ├── Sends inputs to peer via ENet (UDP)
  │   ├── Receives remote inputs via ENet
  │   ├── Lockstep wait (blocks until remote input ready)
  │   ├── Rollback check (if remote input differs from prediction):
  │   │   ├── Load saved game state from StatePool
  │   │   ├── Set CC_SKIP_FRAMES=1 (skip rendering during re-run)
  │   │   └── Re-run frames with corrected inputs
  │   ├── Save current state to StatePool
  │   └── Write both players' inputs to game memory
  └── StatePool: saves/restores ~750KB of game memory per frame
      (player structs, effects, camera, RNG, timers)
```

### Netcode

The netcode uses a lockstep + rollback algorithm (same approach as the
original CCCaster, conceptually similar to GGPO but adapted for a
closed-source binary-patched game):

1. **Lockstep** — Each frame, both clients exchange inputs. The game frame
   cannot advance until the remote player's input for the current frame
   is received (with configurable input delay to hide latency).

2. **Prediction** — If the remote input hasn't arrived yet, the last known
   input is used as a prediction. The game advances with the predicted input.

3. **Rollback** — When the real remote input arrives and differs from the
   prediction, the game state is rewound to the mispredicted frame, the
   corrected inputs are applied, and the game re-runs forward to the current
   frame (skipping rendering during the re-run).

4. **State save/restore** — The StatePool snapshots ~370 memory regions
   (player positions, health, velocities, effects, camera, RNG, timers)
   every frame. On rollback, the closest saved state is restored via memcpy.

### Network protocol (ENet)

| Channel | Type | Purpose |
|---------|------|---------|
| 0 | Reliable | RNG state sync, TransitionIndex (round change) |
| 1 | Unreliable | Player inputs (30 frames per packet) |
| 2 | Unreliable | Spectator BothInputs broadcast |

Message types (1-byte tag prefix):
- `0x01` — Player inputs: `[start_frame][index][N×2 inputs]`
- `0x02` — RNG state: `[index][rng0][rng1][rng2][rng3(220 bytes)]`
- `0x03` — TransitionIndex: `[index]` (sent on every round/state change)
- `0x20` — BothInputs (spectator): `[frame][index][N×4 (P1+P2 inputs)]`

## Dependencies

| Library | Version | License | Purpose |
|---------|---------|---------|---------|
| [ENet](https://github.com/lsalzman/enet) | 1.3.18 | MIT | Reliable UDP transport |
| [Dear ImGui](https://github.com/ocornut/imgui) | 1.92.8 | MIT | UI rendering |
| [cimgui](https://github.com/cimgui/cimgui) | master | MIT | C API wrapper for ImGui |
| [SDL2](https://github.com/libsdl-org/SDL) | 2.32.10 | zlib | Window, input, gamepad |

## Project layout

```
src/
├── main.zig              # Entry point + CLI parsing
├── ui.zig                # ImGui UI (SDL2 window + render loop)
├── cimgui_shim.h         # Minimal C declarations for ImGui functions
├── imgui_backend_wrap.cpp # C-linkage wrappers for ImGui SDL2/OpenGL3 backends
├── config.zig            # INI config parser
├── logging.zig           # File logger
├── ipc.zig               # Named-pipe IPC (launcher ↔ hook.dll)
├── launcher.zig          # CreateProcess + DLL injection (Win32)
├── net.zig               # ENet transport wrapper
├── session.zig           # Netplay session FSM (version handshake, pings)
├── gamepad.zig           # SDL2 gamepad/keyboard reader
├── keyboard.zig          # Win32 GetKeyState (in-game keyboard)
├── rollback.zig          # InputBuffer + StatePool (with FPU env save)
├── rollback_regions.zig  # Memory regions to save/restore (ported from Generator.cpp)
├── dllmain.zig           # hook.dll entry: DllMain + frame loop + ASM hacks
├── netplay_manager.zig   # Per-frame netplay state machine
├── sfx_dedup.zig         # SFX dedup (rollback re-run audio cancellation)
├── spectator_manager.zig # Spectator chain forwarding
└── hook_exports.c        # C glue for DLL exports
```

## Cross-compilation

ZZCaster cross-compiles from Linux to Windows. The `hook.dll` is 32-bit
(MBAA.exe is a 32-bit binary); `zzcaster.exe` is also built as 32-bit for
simplicity (both use the same `-Dtarget=x86-windows-gnu`).

## License

ZZCaster is released under the same license as the original CCCaster.
