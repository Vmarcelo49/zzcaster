# Project Structure Reorganization Plan

**Date:** 2026-06-22
**Status:** Planning

---

## Current State

All 22 source files live in a flat `src/` directory. The largest files are:

| File | Lines | Responsibility |
|---|---|---|
| `ui.zig` | 1814 | ImGui UI + netplay session management + game launch + CLI netplay |
| `netplay_manager.zig` | 1692 | Netplay state machine + rollback + RNG sync + desync detection + spectator |
| `dllmain.zig` | 1270 | DLL entry + ASM hacks + SFX hooks + frame loop + input + config IPC |
| `session.zig` | 644 | Handshake state machine + protocol |
| `controller_mapper.zig` | 462 | Input bindings + save/load + input reading |
| `launcher.zig` | 360 | Process creation + DLL injection |
| `spectator_manager.zig` | 326 | Spectator chain forwarding |
| `rollback.zig` | 317 | InputBuffer + StatePool |
| `net.zig` | 281 | ENet transport + IP discovery |
| `gamepad.zig` | 268 | SDL gamepad/keyboard reader |
| `rollback_regions.zig` | 211 | Memory region list for state save/restore |
| `sfx_dedup.zig` | 187 | SFX dedup during rollback |
| `ipc.zig` | 163 | Named pipe IPC (launcher ↔ DLL) |
| `config.zig` | 149 | Config file parser |
| `keyboard.zig` | 114 | Win32 keyboard reader |
| `main.zig` | 113 | Entry point + CLI parsing |
| `net_util.zig` | 111 | Adapter type detection |
| `cimgui_shim.h` | 103 | ImGui C declarations |
| `logging.zig` | 62 | File logger |
| `imgui_backend_wrap.cpp` | 43 | ImGui SDL2/OpenGL3 backend wrappers |
| `hook_exports.c` | 5 | DLL export glue |

**Problem:** Files mix multiple concerns. `ui.zig` handles UI rendering, session lifecycle, game launching, and CLI netplay. `dllmain.zig` handles DLL entry, ASM patching, SFX hooks, the frame loop, input reading, and IPC config parsing. Finding code requires scrolling through 1800-line files.

---

## Proposed Structure

```
src/
├── main.zig                      # Entry point + CLI parsing (113 lines, unchanged)
├── build.zig                     # Build config (updated import paths)
│
├── common/                       # Shared utilities used by both launcher + DLL
│   ├── logging.zig               # File logger (62 lines, unchanged)
│   ├── config.zig                # Config file parser (149 lines, unchanged)
│   └── ipc.zig                   # Named pipe IPC (163 lines, unchanged)
│
├── launcher/                     # Everything in zzcaster.exe (the launcher)
│   ├── ui.zig                    # ImGui main loop + window (trimmed ~400 lines)
│   ├── ui_pages.zig              # Netplay/Offline/Config/Controllers pages (~500 lines)
│   ├── ui_controller_mapper.zig  # Controller mapper grid + list view (~400 lines)
│   ├── ui_waiting_for_peer.zig   # Waiting-for-peer screen + handshake display (~300 lines)
│   ├── session.zig               # NetplaySession handshake state machine (644 lines, unchanged)
│   ├── launcher.zig              # Process creation + DLL injection (360 lines, unchanged)
│   ├── game_launcher.zig         # launchGameImpl + launchGameAfterHandshake + launchNetplayImpl (~200 lines)
│   ├── cli_netplay.zig           # runCliNetplay + runCliOffline (~150 lines)
│   └── net_util.zig              # Adapter type detection (111 lines, unchanged)
│
├── dll/                          # Everything in hook.dll (injected into MBAA.exe)
│   ├── dllmain.zig               # DLL entry + lazyInit + frameStep dispatch (~300 lines)
│   ├── asm_hacks.zig             # hookMainLoop + hijackControls + SFX ASM patches (~300 lines)
│   ├── frame_step.zig            # frameStep logic: input reading + lockstep + rollback check (~400 lines)
│   ├── config_ipc.zig            # IPC pipe connect + waitForConfig + config parsing (~100 lines)
│   ├── input.zig                 # SDL init + controller mapping + keyboard reader integration (~200 lines)
│   ├── netplay_manager.zig       # NetplayManager: state machine + transitions (~800 lines)
│   ├── netplay_sync.zig          # isRemoteInputReady + getNetplayInput + heartbeat + catch-up (~400 lines)
│   ├── rollback.zig              # InputBuffer + StatePool (317 lines, unchanged)
│   ├── rollback_regions.zig      # Memory region list (211 lines, unchanged)
│   ├── sfx_dedup.zig             # SFX dedup (187 lines, unchanged)
│   ├── spectator_manager.zig     # Spectator chain (326 lines, unchanged)
│   ├── gamepad.zig               # SDL gamepad reader (268 lines, unchanged)
│   ├── keyboard.zig              # Win32 keyboard reader (114 lines, unchanged)
│   ├── controller_mapper.zig     # Input bindings + save/load (462 lines, unchanged)
│   └── hook_exports.c            # DLL export glue (5 lines, unchanged)
│
├── net/                          # Network transport (shared by launcher + DLL)
│   ├── enet_transport.zig        # EnetTransport wrapper (from net.zig, ~150 lines)
│   └── ip_discovery.zig          # getPublicIp + getLocalIp (from net.zig, ~130 lines)
│
└── cimgui_shim.h                 # ImGui C declarations (103 lines, unchanged)
└── imgui_backend_wrap.cpp        # ImGui backend wrappers (43 lines, unchanged)
```

---

## File Split Details

### ui.zig → 5 files (1814 → 5 files, ~200-400 lines each)

**`launcher/ui.zig`** (~400 lines) — Core ImGui setup:
- `pub fn run()` — SDL window creation, GL context, ImGui init, main loop
- `pub fn runCli()` — CLI dispatch
- ImGui style, window flags, layout constants
- State enums (`UiState`, `MenuPage`)

**`launcher/ui_pages.zig`** (~500 lines) — Page rendering:
- Netplay page (Host/Join/Spectate buttons + IP:Port inputs)
- Offline page (Training/Versus buttons)
- Game Config page (win count, rollback, display name)
- Controllers page header + device list + save button

**`launcher/ui_controller_mapper.zig`** (~400 lines) — Controller mapper UI:
- `drawPlayerPanel()` — grid view
- `drawListPanel()` — list view
- `bindButton()`, `applyBinding()`, `setClipboardZ()`
- Device name list builder

**`launcher/ui_waiting_for_peer.zig`** (~300 lines) — Connection screen:
- `drawWaitingForPeer()` — all states (listening, connecting, handshaking, waiting_confirmation, launching, failed, cancelled)
- Timer countdown display
- Delay override UI
- Connection type display
- `cleanupSession()`

**`launcher/game_launcher.zig`** (~200 lines) — Game launch functions:
- `launchGameImpl()` — offline game launch
- `launchGameAfterHandshake()` — post-handshake launch
- `launchNetplayImpl()` — spectate launch
- `cleanupGame()`
- `sendConfigToDll()` — IPC config send helper

### dllmain.zig → 4 files (1270 → 4 files, ~300-400 lines each)

**`dll/dllmain.zig`** (~300 lines) — DLL entry + init:
- `DllMain()` — PROCESS_ATTACH / DETACH
- `lazyInit()` — logger, IPC, ASM hooks, config wait
- `initThread()` — worker thread entry
- `initSdlOnMainThread()` — SDL + controller init
- `openMappedJoystick()` — joystick open helper
- Module-level state variables

**`dll/asm_hacks.zig`** (~300 lines) — ASM patching:
- `applyPreLoadHacks()` — hookMainLoop + hijackControls + SFX
- `applyHookMainLoop()` — main loop hook installation
- `applyHijackControls()` — input hijack NOPs
- `applySfxAsmHacks()` — SFX dedup ASM patches
- `writeBytes()`, `rel32()` — memory write helpers

**`dll/frame_step.zig`** (~400 lines) — Per-frame logic:
- `frameStep()` — main per-frame callback
- Offline input reading + writeInput
- Netplay input reading + lockstep wait
- Rollback check + rerun completion
- State save + spectator broadcast
- `writeInput()` — game memory input write
- `fillBothInputsCallback()`

**`dll/config_ipc.zig`** (~100 lines) — Config IPC:
- `connectPipe()` — named pipe connect
- `waitForConfig()` — config message receive + parse
- `resolvePipeName()` — pipe name resolution

**`dll/input.zig`** (~200 lines) — Input initialization:
- `applyPostLoadHacks()` — game mode patches + force goto
- `initSdlOnMainThread()` — SDL + controller + mapping init
- `openMappedJoystick()` — joystick open helper
- Diagnostic logging (InputDiag, InputFrame)

### netplay_manager.zig → 2 files (1692 → 2 files, ~800 + 400 lines)

**`dll/netplay_manager.zig`** (~800 lines) — Core netplay state:
- `NetplayManager` struct + init/deinit/configure
- ENet connection management (initEnet, waitForEnetConnect, pollEnet, pollAndDispatch)
- State transitions (onGameModeChanged, onStateTransition, isValidNext)
- Input management (setLocalInput, getLocalInput, setRemoteInputs, getRemoteInput, sendLocalInputs)
- RNG sync (syncRngState, applyRemoteRng)
- Rollback (checkRollback, isRerunning, checkRerunComplete)
- Spectator support (drainSpectatorEvents, writeGameInputs, fillBothInputsForBroadcast)
- writeGameInput (game memory write)

**`dll/netplay_sync.zig`** (~400 lines) — Sync + health checks:
- `isRemoteInputReady()` — lockstep gate
- `getNetplayInput()` — per-state input filtering + catch-up mash
- `shouldCatchUp()` — remote-ahead detection
- `checkHeartbeat()` — 20s heartbeat timeout
- Constants: `heartbeat_timeout_ms`, `input_wait_timeout_ms`, `sync_send_period`
- Desync detection (SyncHash send/compare — if present)

### net.zig → 2 files (281 → 2 files, ~150 + 130 lines)

**`net/enet_transport.zig`** (~150 lines):
- `EnetTransport` struct — listen, connect, sendReliable, sendUnreliable, poll, deinit
- TransportEvent enum
- TransportStats struct

**`net/ip_discovery.zig`** (~130 lines):
- `getPublicIp()` — HTTP GET to checkip services
- `getLocalIp()` — gethostname + getaddrinfo
- Win32 externs for wininet

---

## Migration Strategy

### Phase 1: Create directory structure (no code changes)
1. Create `src/common/`, `src/launcher/`, `src/dll/`, `src/net/` directories
2. Move unchanged files to their new locations
3. Update `build.zig` root_source_file paths
4. Update all `@import` paths
5. Verify build

### Phase 2: Split large files (one at a time)
6. Split `ui.zig` → 5 files (highest impact, do first)
7. Split `dllmain.zig` → 4 files
8. Split `netplay_manager.zig` → 2 files
9. Split `net.zig` → 2 files
10. Verify build after each split

### Phase 3: Clean up
11. Remove any dead code found during the split
12. Update import comments
13. Update `build.zig` if needed

### Import path convention

Zig uses relative paths for `@import`. After the restructure:

```zig
// In src/launcher/ui.zig:
const config = @import("../common/config.zig");
const session = @import("session.zig");
const ui_pages = @import("ui_pages.zig");

// In src/dll/dllmain.zig:
const logging = @import("../common/logging.zig");
const netman = @import("netplay_manager.zig");
const asm_hacks = @import("asm_hacks.zig");
```

### build.zig changes

The build has two targets:
- **zzcaster.exe** root: `src/main.zig` (unchanged)
- **hook.dll** root: `src/dll/dllmain.zig` (moved from `src/dllmain.zig`)

The `root_source_file` paths in `build.zig` need updating:
```zig
// Before:
.root_source_file = b.path("src/main.zig"),      // exe
.root_source_file = b.path("src/dllmain.zig"),    // dll

// After:
.root_source_file = b.path("src/main.zig"),              // exe
.root_source_file = b.path("src/dll/dllmain.zig"),       // dll
```

---

## Files NOT Being Split

These files are already appropriately sized and cohesive:
- `logging.zig` (62 lines) — single responsibility
- `config.zig` (149 lines) — single responsibility
- `ipc.zig` (163 lines) — single responsibility
- `sfx_dedup.zig` (187 lines) — single responsibility
- `rollback_regions.zig` (211 lines) — data table
- `gamepad.zig` (268 lines) — single responsibility
- `launcher.zig` (360 lines) — single responsibility
- `spectator_manager.zig` (326 lines) — single responsibility
- `rollback.zig` (317 lines) — single responsibility
- `session.zig` (644 lines) — already refactored to step-based state machine
- `controller_mapper.zig` (462 lines) — single responsibility
- `keyboard.zig` (114 lines) — single responsibility
- `net_util.zig` (111 lines) — single responsibility
- `main.zig` (113 lines) — entry point
- `cimgui_shim.h` (103 lines) — C declarations
- `imgui_backend_wrap.cpp` (43 lines) — C++ wrappers
- `hook_exports.c` (5 lines) — trivial

---

## Risk Assessment

| Risk | Mitigation |
|---|---|
| Import path errors | Update all imports atomically per file move; build after each move |
| Circular imports | Zig doesn't allow circular imports — if found, extract shared types to `common/` |
| Build system breakage | Update `build.zig` root_source_file + include paths; test after each phase |
| Git history disruption | Use `git mv` for moves to preserve history; split files with clear commit messages |
| Merge conflicts with open PRs | Do this when no other PRs are in flight; rebase open branches after |

## Effort Estimate

- Phase 1 (directory creation + file moves): 2-3 hours
- Phase 2 (file splits): 4-6 hours (mostly mechanical, but needs careful import tracking)
- Phase 3 (cleanup): 1 hour
- **Total: 7-10 hours**

The restructure is mechanical but tedious. Each step should be verified with a build. The risk of introducing bugs is low since no logic changes are made — only file organization and import path updates.
