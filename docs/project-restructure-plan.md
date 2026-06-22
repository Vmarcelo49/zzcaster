# Project Structure Reorganization — Complete

**Date:** 2026-06-22
**Status:** Implemented

---

## What was done

The flat `src/` directory was preserved (Zig 0.16 restricts `@import` to the module root directory, preventing subdirectory structures without complex `addModule` wiring). Instead, large files were split into smaller, focused files — all in `src/`.

### File splits completed

| Before | Lines | After | Lines |
|---|---|---|---|
| `ui.zig` | 1814 | `ui.zig` | 412 |
| | | `ui_pages.zig` | 294 |
| | | `ui_controller_mapper.zig` | 418 |
| | | `ui_waiting_for_peer.zig` | 326 |
| | | `game_launcher.zig` | 603 |
| `dllmain.zig` | 1270 | `dllmain.zig` | 745 |
| | | `asm_hacks.zig` | 310 |
| | | `frame_step.zig` | 337 |
| `net.zig` | 281 | `enet_transport.zig` | 181 |
| | | `ip_discovery.zig` | 101 |

### Files NOT split (already appropriately sized)

- `netplay_manager.zig` (1692 lines) — Zig doesn't allow splitting struct methods across files. The struct is cohesive.
- `session.zig` (645 lines) — already refactored to step-based state machine
- `controller_mapper.zig` (462 lines) — single responsibility
- All other files are <400 lines

### Final file inventory

```
src/
├── main.zig                     113  Entry point + CLI parsing
├── cimgui_shim.h                103  ImGui C declarations
├── imgui_backend_wrap.cpp        43  ImGui SDL2/OpenGL3 backend wrappers
├── hook_exports.c                 5  DLL export glue
│
├── logging.zig                   62  File logger
├── config.zig                   149  Config file parser
├── ipc.zig                      163  Named pipe IPC (launcher ↔ DLL)
│
├── ui.zig                       412  Main ImGui loop, run(), runCli(), state enums
├── ui_pages.zig                 294  Idle page rendering (netplay/offline/config/controllers)
├── ui_controller_mapper.zig     418  Controller mapper grid + list view
├── ui_waiting_for_peer.zig      326  Connection screen + handshake display
├── game_launcher.zig            603  Game launch functions + CLI helpers
├── session.zig                  645  NetplaySession handshake state machine
├── launcher.zig                 360  Process creation + DLL injection
├── net_util.zig                 111  Adapter type detection (WiFi/Ethernet)
│
├── dllmain.zig                  745  DLL entry, lazyInit, frameStep, IPC, SDL init
├── asm_hacks.zig                310  ASM patching: hookMainLoop, hijackControls, SFX
├── frame_step.zig               337  In-game frame logic: spectator/netplay/offline branches
├── netplay_manager.zig         1692  NetplayManager: state machine, rollback, RNG sync
├── rollback.zig                 317  InputBuffer + StatePool
├── rollback_regions.zig         211  Memory region list for state save/restore
├── sfx_dedup.zig                187  SFX dedup during rollback
├── spectator_manager.zig        326  Spectator chain forwarding
├── gamepad.zig                  268  SDL gamepad/keyboard reader
├── keyboard.zig                 114  Win32 keyboard reader
├── controller_mapper.zig        462  Input bindings + save/load
│
├── enet_transport.zig           181  EnetTransport wrapper
└── ip_discovery.zig             101  getPublicIp + getLocalIp
```

### Build verification

All builds pass: `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast` produces both `zzcaster.exe` and `hook.dll` with zero errors.
