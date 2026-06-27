# ZZCaster

A Zig port of [CCCaster](https://github.com/Rhekar/CCCaster), the netplay
launcher and DLL injector for **MELTY BLOOD Actress Again Current Code**
(MBAACC).

Why the name? First Z from Zig the programming language, second from Z.ai which this project used(almost by its entirety).


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

This is how CCCaster works too.

## Build

### Prerequisites

| Component | How to install |
|-----------|---------------|
| **Zig 0.16** | https://ziglang.org/download/ → extract → add to PATH or your package manager |

All C/C++ dependencies (ENet, Dear ImGui, SDL2 MinGW) are
auto-downloaded by `scripts/fetch-deps.sh`.

### Quick start

```bash
./scripts/fetch-deps.sh
zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast
```

Output appears in `zig-out/bin/`:
- `zzcaster.exe` — the launcher (32-bit)
- `hook.dll` — the injected DLL (32-bit, matches MBAA.exe)

Both binaries are 32-bit (x86-windows-gnu). MBAA.exe is a 32-bit binary,
so `hook.dll` MUST be 32-bit to be loadable. `zzcaster.exe` is also built
32-bit so the launcher and DLL share types and ABI for IPC. The build
will refuse to produce a non-x86 Windows target (see `build.zig`).

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
- **Controllers** — Per-player controller mapper: bind any button/direction
  via click-to-bind, set SOCD mode and analog deadzone, and toggle the
  optional Air Dash Macro (see below). Saved to `mapping.ini` and loaded by
  `hook.dll` on game start.



## New Features

#### Air Dash Macro

An optional input macro, enabled per-player in the **Controllers** tab
(off by default). When enabled, pressing `9AB` (up-forward + A+B) or `7AB`
(up-back + A+B) will perform a forward or backwards jump then an air dash.

#### Wi-fi Indicator

When you play online, you can see if your opponent is using wifi or wired.


## Netcode Improvements over CCCaster

ZZCaster's rollback netcode is ported from CCCaster and preserves its
core algorithm (input delay, indexed-frame coordinates, RNG sync,
SyncHash desync detection, TransitionIndex handshake). The following
changes add robustness on top of that foundation. They are informed by
the [ggpo-x](https://github.com/thomashenry79/ggpo-x) fork of GGPO but
do not replace the rollback algorithm itself.

CCCaster already measures ping at connect time (10 pings during the
handshake, used to compute input delay) and detects desyncs via a
periodic SyncHash exchange every 300 frames. What's new here:

- **Per-frame desync detection.** A lightweight 16-bit checksum is now
  piggybacked on every input packet, for a frame old enough to be
  confirmed. Desyncs are caught within roughly half a second instead of
  up to 5 seconds. The original periodic SyncHash is retained as a
  secondary check with richer field-level diagnostics.

- **Continuous RTT measurement during gameplay.** CCCaster only measures
  ping at connect time. ZZCaster now reads ENet's built-in round-trip
  time every frame and maintains a smoothed EMA (10-second window). This
  does not replace the connect-time ping used for input delay; it
  provides ongoing connection-quality data.

- **Cooperative time-sync.** When the local peer is running ahead of the
  remote, the game sleeps a few milliseconds per frame to let the remote
  catch up. This is the same idea as GGPO's frame advantage adjustment,
  adapted to MBAACC's game-driven frame loop. The sleep is capped at 4ms
  per frame to avoid stutter. This is the most experimental change and
  its effect on game feel has not been extensively playtested yet.

- **Larger rollback history.** The state pool grew from 60 frames
  (1 second, matching CCCaster's release build) to 90 frames (1.5
  seconds). This gives more headroom on high-latency or jittery
  connections where the 1-second window could be exhausted.

- **Bounded input history.** Confirmed inputs are now discarded once the
  remote has processed them, keeping memory usage stable over long rounds.

- **Network error surfacing.** Consecutive send failures are now tracked
  and logged before the heartbeat timeout fires, giving earlier warning
  of degraded connections.

- **Stale-input rollback fix.** A bug where late input packets from a
  previous round could silently disable rollback detection for the
  current round has been fixed. This was likely a contributor to the
  desync reports that motivated this work.

The wire protocol includes a version field so mismatched clients reject
each other cleanly at connection time rather than producing corrupted
inputs.


## Dependencies

| Library | Version | License | Purpose |
|---------|---------|---------|---------|
| [ENet](https://github.com/lsalzman/enet) | 1.3.18 | MIT | Reliable UDP transport |
| [Dear ImGui](https://github.com/ocornut/imgui) | 1.92.8 | MIT | UI rendering |
| [SDL2](https://github.com/libsdl-org/SDL) | 2.32.10 | zlib | Window, input, gamepad |


## Cross-compilation

ZZCaster cross-compiles from Linux to Windows. Both `hook.dll` and
`zzcaster.exe` are 32-bit (`-Dtarget=x86-windows-gnu`). MBAA.exe is a
32-bit binary so `hook.dll` MUST be 32-bit; the launcher is also 32-bit
so the two artifacts share types and ABI for the IPC config struct.
The build script rejects any non-x86 Windows target with a clear error.

## Credits

ZZCaster is a from-scratch rewrite of the CCCaster fork of **Rhekar**.
The original project is a C++ Win32 application that has
served the MBAACC community for years. This Zig port aims to modernize the
codebase while preserving the same netcode algorithm and game compatibility.

**Original project:** https://github.com/Rhekar/CCCaster

Key components ported from the original:
- Game memory addresses and ASM hacks (from `legacy_unused/targets/DllAsmHacks.cpp`)
- Rollback state pool and SFX dedup (from `DllRollbackManager.cpp`)
- Netplay state machine and input synchronization (from `DllNetplayManager.cpp`)
- Spectator chain forwarding (from `SpectatorManager.cpp`)
- Rollback memory regions (from `Generator.cpp`)

## License

ZZCaster is released under the same license as the original CCCaster.
