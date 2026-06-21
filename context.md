# ZZCaster — Project Context Document

> **Purpose:** This document provides full context for an LLM taking over the
> ZZCaster project. It covers the project's history, architecture, current
> state, known issues, and next steps. Read this entirely before making changes.

---

## 1. Project Overview

### What is ZZCaster?

ZZCaster is a **Zig 0.16+ rewrite** of [CCCaster](https://github.com/Rhekar/CCCaster),
the netplay launcher and DLL injector for **MELTY BLOOD Actress Again Current Code**
(MBAACC). The original CCCaster is a C++ Win32 application by **Rhekar** that has
served the MBAACC community for years. ZZCaster modernizes the codebase while
preserving the same netcode algorithm and game compatibility.

### Two Binaries

| Binary | Architecture | Purpose |
|--------|-------------|---------|
| `zzcaster.exe` | 32-bit (x86-windows-gnu) | Launcher with ImGui UI. Creates MBAA.exe, injects hook.dll, sends config via named pipe IPC. |
| `hook.dll` | 32-bit (matches MBAA.exe) | Injected DLL. Patches game's main loop, handles input, network, rollback. |

Both are built with a single `zig build` command targeting `x86-windows-gnu`.

### Key Credits

- **Original CCCaster**: Rhekar (https://github.com/Rhekar/CCCaster)
- **ZZCaster rewrite**: Built iteratively across multiple LLM sessions
---
## 2. Build System

### Prerequisites

- **Zig 0.16+** (the project was migrated from 0.15; the entire I/O subsystem
  was rewritten — see `docs/zig-0.16-migration-plan.md`)
- Linux or Windows host (cross-compilation from Linux to Windows is supported)

### Dependencies (all auto-downloaded)

| Library | Version | Source | Purpose |
|---------|---------|--------|---------|
| ENet | 1.3.18 | lsalzman/enet | Reliable UDP netplay transport |
| Dear ImGui | 1.92.8 | ocornut/imgui | UI rendering |
| cimgui | master | cimgui/cimgui | C API wrapper for ImGui (so Zig can call ImGui via @cImport) |
| SDL2 | 2.32.10 (MinGW) | libsdl-org/SDL | Window, input, gamepad, OpenGL context |

### Build Commands

```bash
./scripts/fetch-deps.sh                              # Download all deps into libs/
zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast
```

Output: `zig-out/bin/zzcaster.exe` + `zig-out/bin/hook.dll`

### Deploy Script

```bash
./scripts/build-and-deploy.sh --game-dir="/path/to/MBAACC"
```

Copies `zzcaster.exe` to the MBAACC root and `hook.dll` + `SDL2.dll` to
`MBAACC/zzcaster/`.

### Build Script Zig Detection

`build-and-deploy.sh` prefers `~/.local/zig/0.16.0/zig` (local install),
falls back to system `zig` on PATH (must be 0.16.x), or accepts a `ZIG=`
environment variable override.

---

## 3. Architecture

### 3.1 Launcher (zzcaster.exe)

**Entry point:** `src/main.zig`
- `main()` receives `std.process.Init.Minimal` (Zig 0.16 signature)
- Uses `std.heap.DebugAllocator(.{})` (Zig 0.16; replaces `GeneralPurposeAllocator`)
- Creates `std.Io.Threaded` backend (single-threaded) — all file/stdout I/O
  requires an explicit `Io` handle threaded through function parameters
- Parses CLI args (`--mode=training|versus|host|join|spectate`, `--port=`, `--peer=`)
- Generates a unique IPC pipe name based on the launcher PID (`zzcaster_<pid>_pipe`)
- Sets `CCCASTER_PIPE` environment variable so the injected DLL knows which pipe to connect to
- Calls `ui.run()` for interactive mode or `ui.runCli()` for CLI mode

**UI:** `src/ui.zig`
- SDL2 window (1024×768, non-resizable) with OpenGL 3.0 context
- ImGui rendered via cimgui (C API wrapper — Zig can't @cImport C++ headers directly)
- **cimgui_shim.h** — Minimal C header declaring only the ImGui functions we use
  (cimgui.h contains C++ template typedefs that Zig's @cImport can't parse)
- **imgui_backend_wrap.cpp** — C-linkage wrappers for ImGui SDL2/OpenGL3 backend
  functions (the backends are C++ with name mangling; our shim declares them as
  `extern "C"`, so we need wrapper functions with matching C linkage)

**UI Layout:**
- Left sidebar (140px): Netplay/Spectate, Offline, Game Config, Controllers, Quit
- Right content area: changes based on sidebar selection

**Pages:**
1. **Netplay/Spectate** — IP:port text input, port text input, Host/Join/Spectate buttons
2. **Offline** — Training Mode, Versus Mode buttons
3. **Game Config** — Win count + rollback frames text inputs with Apply buttons
4. **Controllers** — Full controller mapper (see section 5)

**UI State Machine:**
- `idle` — sidebar + content area
- `in_game` — shows game PID, monitors exit, Force Kill button
- `error_state` — shows error message + OK button

**IPC:** `src/ipc.zig`
- Named pipe server (`\\.\pipe\zzcaster_<pid>_pipe`)
- Overlapped I/O for non-blocking connect
- Length-prefix framing: 4-byte LE length + payload
- The IPC server is stored in the UI state and properly closed on game exit
  (via `cleanupGame()`) so the pipe handle is released for reuse

**Game launching:** `src/launcher.zig`
- `CreateProcessA` with `CREATE_SUSPENDED` flag
- Reads PE header from the remote process to find the entry point (does NOT
  patch with `EB FE` infinite loop — the main thread stays suspended naturally)
- `VirtualAllocEx` + `WriteProcessMemory` to write the DLL path into the remote process
- `CreateRemoteThread(LoadLibraryA)` to inject hook.dll while main thread is suspended
- `WaitForSingleObject` on the remote thread (5s timeout)
- `ResumeThread` on the main thread
- Also patches config dialog skip bytes at `0x04A1D42` and `0x04A1D4A`

**Config:** `src/config.zig`
- INI file parser (`zzcaster/config.ini`)
- Settings: versus_win_count, default_rollback, max_real_delay, high_cpu_priority,
  stage_animations_off, auto_replay_save, auto_check_updates, log_to_stdout
- Uses `std.Io` for all file operations

### 3.2 Injected DLL (hook.dll)

**Entry point:** `src/dllmain.zig`

**DllMain flow:**
1. `DLL_PROCESS_ATTACH`:
   - Create `std.Io.Threaded.init_single_threaded` (no worker threads — runs inside game process)
   - Create logger (writes to `zzcaster/dll_<pid>.log`)
   - `SetThreadExecutionState` (prevent sleep)
   - `connectPipe()` — connect to the launcher's named pipe (resolves pipe name
    from `CCCASTER_PIPE` env var, falls back to default `\\.\pipe\zzcaster_pipe`)
   - `applyPreLoadHacks()` — ASM patches (main loop hook, hijack controls, SFX dedup)
   - Set `frame_callback = frameStep`
   - `waitForConfig()` — non-blocking peek at the pipe; if config is available, read it
   - If config received: `applyPostLoadHacks()` (SDL2 init, keyboard init, ENet init)
2. `DLL_PROCESS_DETACH`:
   - Cleanup (deinit NetplayManager, close IPC pipe, SDL_Quit)
   - `ExitProcess(0)`

**DllMain return type:** `std.os.windows.BOOL` (Zig 0.16 — was `i32` before)

**Critical: Non-blocking DllMain**
Under Wine, blocking in DllMain (e.g., `waitForEnetConnect`) stalls the game's
main thread. The DLL must return from DllMain promptly. ENet connection
waiting is done lazily in `frameStep()` via `pollAndDispatch(50)` with a
1200-attempt cap (~60s timeout).

**frameStep() flow (called every game frame via patched main loop):**
1. Lazy config check (if config wasn't received in DllMain)
2. Read `world_timer` — if unchanged, return (not a new frame)
3. Detect game mode changes → `onGameModeChanged()`
4. Clear inputs to 0
5. If pre-game: skip rendering, mash confirm button, return
6. If spectator: poll for BothInputs, write both inputs, return
7. If normal netplay:
   a. Lazy ENet connect (if not yet connected)
   b. Host: drain spectator events
   c. Read local input (gamepad/keyboard)
   d. `updateFrame()` — compute current frame from world_timer
   e. `setLocalInput(input)` — store with delay
   f. `sendLocalInputs()` — send to peer via ENet
   g. `syncRngState()` — host sends RNG once per round
   h. `pollAndDispatch(3)` — receive remote messages
   i. Check for disconnect (uses `was_connected` flag to distinguish
      "never connected" from "disconnected during play")
   j. **Lockstep wait** — if remote input not ready, poll + resend every 100ms
      with periodic warnings (infinite timeout, NOT the old 300ms force-exit)
      Uses `std.Io.Clock.now(.real, io).toMilliseconds()` for timestamps
   k. `checkRollback()` — if remote input differs from prediction, load saved state
   l. `checkRerunComplete()` — if mid-rollback, advance to fast_fwd_stop_frame
   m. `saveState()` — snapshot game memory to StatePool
   n. `writeGameInputs()` — write both players' inputs to game memory
   o. Host: broadcast BothInputs to spectators via callback
8. Else (offline): read local input, write to P1

### 3.3 ASM Hacks

Applied in `applyPreLoadHacks()`:

1. **hookMainLoop** — Patches the game's main loop to call our
   `zzcasterFrameCallback` every frame. Three patch sites:
   - `0x40D032`: `E8 <rel32> E9 <rel32>` (call callback + jmp to hook_call2)
   - `0x40D411`: `6A 01 6A 00 6A 00 E9 <rel32>` (push args + jmp to loop_start+6)
   - `0x40D330`: `E9 <rel32> 90` (jmp to hook_call1 + nop)

2. **hijackControls** — NOPs out 9 sites where the game writes to the input
   buffer, so only our DLL controls the inputs. Also zeros 20 bytes at `0x54D2C0`
   (keyboard scan code config in MBAA.exe).

3. **multipleMelty** — Changes a byte at `0x40D25A` to `0xEB` (jmp) to allow
   multiple instances of the game.

4. **SFX dedup ASM hooks** — Two patch sequences that intercept the game's SFX
   play path:
   - `filterRepeatedSfx` (6 patches at 0x4DD836–0x4DE210): checks sfxMuteArray
     and sfxFilterArray before playing a sound. Includes a final loop-back patch
     at 0x4DE210 that pushes eax and jumps back to 0x4DD836.
   - `muteSpecificSfx` (6 patches at 0x40EEA1–0x40F3D5): overrides volume to
     DX_MUTED_VOLUME when a sound is marked for muting. Includes a loop-back
     patch at 0x40F3D5 that jumps back to 0x40EEA1.

### 3.4 Post-load Hacks

Applied in `applyPostLoadHacks()`:

1. **forceGotoTraining/Versus** — Writes `EB 22` or `EB 3F` at `0x42B475`
2. **damage_level = 2, timer_speed = 2, win_count_vs = 2**
3. **SDL2 init** (GAMECONTROLLER + JOYSTICK)
4. **Keyboard init** (reads scan codes from MBAA.exe at offset 0x14D2C0)
5. **ENet init** (but does NOT block waiting for connect — that's lazy in frameStep)
6. **Load controller mapping** from `zzcaster/mapping.ini` if it exists
7. If no custom mapping: falls back to `defaultXboxMapping()`, opens joystick 0

---

## 4. Netcode

### 4.1 Overview

The netcode uses a **lockstep + rollback** algorithm — conceptually similar to
GGPO but adapted for a closed-source binary-patched game. The key constraint:
we can't call `advanceFrame()` ourselves; the game's own main loop drives
simulation. We intercept it and feed inputs.

### 4.2 State Transition Index

The core of the sync algorithm. Each round/state transition gets a unique
`index` value. The `indexed_frame` struct has `{ frame: u32, index: u32 }`:

- `index` increments on every transition to CharaSelect/Loading/InGame
- `frame` resets to 0 on each transition (computed from `world_timer - start_world_time`)
- This ensures inputs from different rounds don't collide in the InputBuffer

**TransitionIndex exchange:** On every state transition, both peers send a
reliable `[0x03][4-byte index]` message. The receiver calls `setRemoteIndex()`
so `isRemoteInputReady()` knows whether to wait (remote behind) or predict
(remote ahead).

### 4.3 Input Format

MBAA uses a 16-bit combined input: `direction (4 bits) | buttons (12 bits)`

- Direction: numpad notation (1-9, 0=neutral, 5=also neutral)
- Buttons: A=0x10, B=0x20, C=0x08, D=0x04, E=0x80, AB=0x40, Start=0x01,
  Confirm=0x0400, Cancel=0x0800, FN1=0x100, FN2=0x200

**Writing to game memory:** The DLL writes two `u16` values at offsets
`[0x76E6AC] + 0x18` (P1 direction) and `[0x76E6AC] + 0x24` (P1 buttons),
and similar for P2 at `+0x2C` and `+0x38`. **Must write u16, not u8** —
writing u8 leaves the high byte untouched, causing wrong button bits.

**64-bit alignment workaround:** The game memory address `0x76E6AC` is 4-byte
aligned but `*usize` needs 8-byte alignment on 64-bit targets. The code reads
through a `[*]u8` pointer and `@bitCast`s the result to `usize`.

### 4.4 Network Protocol (ENet)

| Channel | Type | Purpose |
|---------|------|---------|
| 0 | Reliable | RNG state sync, TransitionIndex |
| 1 | Unreliable | Player inputs (30 frames per packet, 1-byte type tag 0x01) |
| 2 | Unreliable | Spectator BothInputs broadcast |

Message types (1-byte tag prefix):
- `0x01` — Player inputs: `[start_frame][index][N×2 inputs]`
- `0x02` — RNG state: `[index][rng0][rng1][rng2][rng3(220 bytes)]`
- `0x03` — TransitionIndex: `[index]`
- `0x20` — BothInputs (spectator): `[frame][index][N×4 (P1:u16,P2:u16)]`
- `0xFE` — Spectator redirect (chain forwarding)

**ENet topology:**
- Host: creates ENet host on `peer_port` with capacity for 1 main peer + 15 spectators
- Spectator client: connects with `connect_data=0x5FEC` sentinel so host distinguishes them
- Regular client (P2): same as spectator but sends inputs on channel 1

### 4.5 InputBuffer (`src/rollback.zig`)

- Stores inputs in `AutoHashMap(u64, u16)` keyed by `(index << 32) | frame`
- **Prediction**: `get()` returns the last known input for the exact index,
  falling back to previous indices (walks backwards), returns 0 if nothing found
- `setRemote()` — bulk set with change detection: updates `last_changed_frame`
  when an input differs from the existing value (rollback trigger)
- Per-index metadata via `end_frames` and `last_inputs` hashmaps
- `getEndFrame(index)` — highest frame number for a given index
- `getEndIndex()` — highest index with any data

### 4.6 StatePool (`src/rollback.zig`)

- Saves/restores game memory regions per frame
- 60-state pool (covers ~1 second of rollback at 60fps)
- Memory regions are defined in `src/rollback_regions.zig` (ported from
  legacy `Generator.cpp`):
  - Misc globals (timers, RNG, camera, effects, HUD)
  - 4× player structs (P1, P2, Puppet1, Puppet2) at 0x555130 + offset
  - Effects array (1000 elements × 0x33C bytes, saved as one contiguous block)
- FPU environment save/restore via `fnstenv`/`fldenv` (x86 only, guarded by
  `builtin.cpu.arch == .x86`)
- `loadStateForFrame(target_frame, target_index)` — finds the saved state
  closest to the target frame and restores all memory regions
- Also supports loading regions from `res/rollback.bin` (binary format)
- Uses `std.ArrayList` with `.empty` init + explicit allocator in `deinit`/`append`

### 4.7 SFX Dedup (`src/sfx_dedup.zig`)

During rollback re-runs, the game re-executes logic that may play sound effects.
Without dedup, sounds replay incorrectly.

**Three arrays** (1500 bytes each, at game address 0x76E008 for the trigger array):
- `sfx_filter_array` — 0=not played, 1+=played N times, 0x80=played-then-rolled-back
- `sfx_mute_array` — 1=next playback should be muted
- Game's SFX trigger array at 0x76E008

**Flow:**
1. `snapshotToHistory(frame)` — snapshot sfx_filter into history ring (called after saveState)
2. `applyRollbackFilter(loaded, current)` — OR together snapshots between loaded and current frame, mark with 0x80
3. During re-run: `saveRerunSounds(frame)` — record which sounds actually re-fired
4. `finishedRerun()` — for sounds that were queued but didn't re-fire, play them muted

**SfxDedup struct:**
- Stores `io: std.Io` (not currently used but follows the pattern)
- History ring buffer of `[1500]u8` slots, indexed by `frame % 60`
- `in_rerun` flag gates `saveRerunSounds`

### 4.8 Spectator System (`src/spectator_manager.zig`)

- Host's hook.dll owns an ENet host with capacity for 1 main peer + 15 spectators
- Spectators connect with `connect_data=0x5FEC` sentinel so the host distinguishes them
- Channel 2 is used for spectator control messages and BothInputs broadcasts
- Chain forwarding: when at capacity, host sends REDIRECT message (type `0xFE`),
  spectator reconnects to the redirected address
- Broadcast pacing: legacy formula `multiplier = 1 + (n_spec*2)/(NUM_INPUTS+1)`
- `SpectatorManager.init()` takes an `io: std.Io` parameter to seed its PRNG
  (`std.Random.Xoshiro256`) via `io.random()`
- Pending spectators time out after 20 seconds
- Spectators must send a HELLO (type 0x01) with a `start_index` to become active

### 4.9 NetplayManager (`src/netplay_manager.zig`)

The per-frame state machine. Key functions:
- `init(allocator, io, log)` — takes explicit `io: std.Io` for clock operations
- `onGameModeChanged(mode)` — handles state transitions, calls `onStateTransition()`
- `onStateTransition(old, new)` — increments index, resets frame, sends TransitionIndex
- `isRemoteInputReady()` — returns true for non-gameplay states, handles prediction,
  checks `remote_index` vs our index
- `checkRollback()` — detects mispredictions via `last_changed_frame`, calls `loadStateForFrame()`
- `checkRerunComplete()` — advances through re-run, calls `finishedRerun()`
- `pollAndDispatch(timeout)` — polls ENet and dispatches messages via `handleMessage()`
- `handleMessage(msg)` — routes by type tag: 0x01=inputs, 0x02=RNG, 0x03=TransitionIndex, 0x20=BothInputs
- `drainSpectatorEvents()` — host-only: accept/deny spectator connections, route messages
- `fillBothInputsForBroadcast(index, frame, out)` — host: build BothInputs packet for spectators
- `applyBothInputsPacket(data)` — spectator client: parse BothInputs from host
- `writeGameInputs()` — writes both players' inputs (uses `writeGameInput()` in same file)

**Disconnect detection:** Uses `was_connected` flag. Set to `true` once any
successful ENet connection occurs. `frameStep` checks `was_connected and !enet_connected`
to detect mid-game disconnects.

**Lazy ENet connect:** `connect_attempts` counter incremented each frame in
`frameStep()` with `pollAndDispatch(50)`. After 1200 attempts (~60s), sets
`connect_attempts_exhausted = true` and gives up.

### 4.10 Session (`src/session.zig`)

A higher-level netplay session FSM (version handshake, ping exchange, config
negotiation). Currently **not wired into the main game flow** — the DLL uses
`NetplayManager` directly. `Session` may be used in a future lobby/lobby system.

Stores `io: std.Io` for timestamp operations. Uses `std.Io.Clock.now(.real, io)`.

---

## 5. Controller Mapper

### 5.1 Overview

A PCSX2-style click-to-bind controller mapper. Located in:
- `src/controller_mapper.zig` — Data model + input polling + save/load
- `src/ui.zig` (Controllers page) — UI with two player panels
- `src/gamepad.zig` — GamepadReader updated to use custom mappings

### 5.2 Data Model

```zig
InputType = enum { none, sdl_button, sdl_axis_pos, sdl_axis_neg, sdl_hat, keyboard_key }

InputBinding = struct {
    type: InputType,
    index: u16,  // For sdl_hat: (direction << 8) | hat_index
}

ControllerMapping = struct {
    a, b, c, d, e, ab, start, fn1, fn2: InputBinding,  // Buttons
    up, down, left, right: InputBinding,                  // Directions
    stick_x_axis, stick_y_axis: u8,                       // Analog stick axes
    deadzone: u32,
    socd_mode: u8,  // 0=default, 1=L+R negate, 2=U+D negate, 3=both
    device_index: c_int,  // -1 = keyboard
}
```

### 5.3 Click-to-Bind Flow

1. User clicks a button cell (e.g. `[A: Btn 0]`)
2. Cell shows "Press..." and sets `bind_target`
3. `pollForBindInput()` scans all SDL inputs:
   - Buttons first (highest priority)
   - Axes (skips triggers at rest = -32768, threshold 20000)
   - Hats (D-pad directions)
   - Keyboard VK codes (if device = keyboard)
4. First detected input → binding stored, cell returns to normal
5. 15-frame cooldown (~250ms at 60fps) to prevent click re-binding

### 5.4 Default Xbox Mapping

```
A → X (btn 2)     B → Y (btn 3)     C → B (btn 1)     D → A (btn 0)
E → LB (btn 4)    A+B → RB (btn 5)  Start → Start (btn 7)
FN1 → Select/Back (btn 6)            FN2 → R-Stick press (btn 9)
Directions → D-pad hat 0
```

### 5.5 File Format (`zzcaster/mapping.ini`)

```ini
[Player1]
device=0
a=btn:2
b=btn:3
c=btn:1
d=btn:0
e=btn:4
ab=btn:5
start=btn:7
fn1=btn:6
fn2=btn:9
up=hat:0:8
down=hat:0:2
left=hat:0:4
right=hat:0:6
stick_x=0
stick_y=1
deadzone=8000
socd=1

[Player2]
...
```

Binding serialization: `none`, `btn:N`, `axp:N` (axis positive), `axn:N` (axis negative),
`hat:hat_idx:direction`, `key:vk_code`

The `saveMapping` and `loadMapping` functions handle both Player1 and Player2
sections in a single file.

### 5.6 SOCD Modes

- **Default** (0) — Last input wins (no negation)
- **L+R negate** (1) — Left+Right simultaneously = neutral (default for fighting games)
- **U+D negate** (2) — Up+Down simultaneously = neutral
- **Both negate** (3) — Both L+R and U+D negate

### 5.7 Integration with hook.dll

On startup, `dllmain.zig`'s `applyPostLoadHacks()`:
1. Calls `mapper.loadMapping("zzcaster/mapping.ini", io, log)` — loads both P1 and P2
2. Uses P1 mapping: `loaded_mapping = mappings.p1`
3. If found: opens the specified SDL joystick, sets `custom_mapping` on GamepadReader
4. If not found: falls back to `defaultXboxMapping()`, opens joystick 0
5. If joystick open fails: tries index 0 as fallback (avoids silent input loss)

`GamepadReader.readInput()` checks `custom_mapping` first, falling back to the
hardcoded `GamepadMapping` if not set.

**`readInputMapped()`** in `controller_mapper.zig`:
- Reads all bindings using `isBindingActive()`
- Handles analog stick directions + SOCD resolution
- Returns the MBAA combined input u16

### 5.8 UI Layout

Each player panel has:
- **Device combo box** — "Keyboard" + all detected SDL joysticks
- **Top row**: FN1, Start, FN2 (indented to center)
- **Left child** (220×140): Directions in a + layout (Up/Left/Right/Down)
- **Right child** (310×140): Buttons in 2×3 grid (A/B/C, D/E/A+B)
- **SOCD** radio buttons (4 options inline)
- **Deadzone** slider + **Default Bindings** + **Clear** buttons inline
- **Save Mapping** button at the bottom (saves both P1 and P2 to `zzcaster/mapping.ini`)

ImGui ID conflicts are avoided by wrapping each player's widgets in
`igPushID_Str`/`igPopID` with the player name as the ID.

---

## 6. Project File Layout

```
src/
├── main.zig                # Entry point + CLI parsing (Zig 0.16 Init.Minimal)
├── ui.zig                  # ImGui UI (SDL2 window + render loop + all pages)
├── cimgui_shim.h           # Minimal C declarations for ImGui functions
├── imgui_backend_wrap.cpp  # C-linkage wrappers for ImGui SDL2/OpenGL3 backends
├── config.zig              # INI config parser (uses std.Io)
├── logging.zig             # File logger (uses std.Io)
├── ipc.zig                 # Named-pipe IPC (launcher ↔ hook.dll)
├── launcher.zig            # CreateProcess + DLL injection (Win32)
├── net.zig                 # ENet transport wrapper + shared cimport
├── session.zig             # Netplay session FSM (version handshake, pings)
├── gamepad.zig             # SDL2 gamepad/keyboard reader
├── keyboard.zig            # Win32 GetKeyState (in-game keyboard, uses std.Io)
├── rollback.zig            # InputBuffer + StatePool (with FPU env save)
├── rollback_regions.zig    # ~370 memory regions to save/restore (from Generator.cpp)
├── controller_mapper.zig   # InputBinding + ControllerMapping + click-to-bind + save/load
├── dllmain.zig             # hook.dll entry: DllMain + frame loop + ASM hacks
├── netplay_manager.zig     # Per-frame netplay state machine
├── sfx_dedup.zig           # SFX dedup (rollback re-run audio cancellation)
├── spectator_manager.zig   # Spectator chain forwarding
└── hook_exports.c          # C glue (currently empty)

scripts/
├── fetch-deps.sh           # Downloads ENet, ImGui, cimgui, SDL2 MinGW
├── build-and-deploy.sh     # Builds + copies to game directory (prefers Zig 0.16)
├── deploy-pixeldrain.sh    # Uploads to pixeldrain.com, prints URL
└── README.md               # Script documentation

docs/
├── imgui-remake-plan.md     # Plan for ImGui UI implementation
├── netcode-test-plan.md     # Plan for netcode testing
└── zig-0.16-migration-plan.md  # Detailed 0.15→0.16 migration analysis

build.zig                   # Single build file for both binaries
```

---

## 7. Key Technical Decisions

### Why cimgui + shim instead of Zig-ImGui bindings?

Zig-ImGui (SpexGuy/Zig-ImGui) is pinned to old Zig versions (0.9 era) and old
ImGui (1.88). It uses deprecated build APIs (`std.build.Pkg`, `LibExeObjStep`).
Porting it to modern Zig would require rewriting the build integration.

Instead, we use **cimgui** (a C API generator for ImGui) directly:
1. Compile `cimgui.cpp` + ImGui C++ files via `addCSourceFiles`
2. `@cImport` a **shim header** (`cimgui_shim.h`) that declares only the
   functions we need — cimgui.h itself contains C++ template typedefs that
   Zig's C parser can't handle
3. Write the UI entirely in Zig, calling ImGui functions via the shim

### Why not GGPO?

GGPO's core assumption is that **you control the simulation loop** (via
`advanceFrame()` callbacks). MBAA.exe is a closed-source binary — we can't
add callbacks to it. We can only intercept its main loop via ASM patches.

The legacy CCCaster's approach (which we ported) is a hand-rolled rollback
that lets the game drive its own frames, intercepting via a patched main
loop. The algorithm is the same as GGPO (save state, detect misprediction,
load state, re-run) but the simulation driver is different.

### Why u16 writes for game inputs?

The legacy C++ DLL writes `*(uint16_t*)` at both direction and buttons
offsets. Writing u8 leaves the high byte of each u16 slot at whatever the
game last stored there, which flips unrelated button bits. For example,
`button_confirm = 0x0400` becomes `0x?40` (where `?` is stale), making the
game think "AB pressed" (bit 6 = 0x40) instead of "Confirm pressed"
(bit 10 = 0x400).

### Why non-blocking DllMain?

Under Wine, blocking in DllMain (specifically in the LoadLibraryA remote
thread) appears to stall the game's main thread. The DLL must return from
DllMain promptly. ENet connection waiting is deferred to `frameStep()`.

### Why separate @cImport for SDL2 in different files?

Zig creates separate opaque types for each `@cImport` invocation, even
if they import the same header. This means `?*c.SDL_Joystick` from
`gamepad.zig`'s `@cImport` is incompatible with `?*c.SDL_Joystick` from
`dllmain.zig`'s `@cImport`. The solution: use `?*anyopaque` for cross-module
SDL pointer types and cast at the call site.

**Exception:** `net.zig` exports a single shared `pub const enet = @cImport({...})`
that all other files import via `@import("net.zig").enet`. This ensures
ENet types are consistent across modules.

### Why std.Io.Threaded.init_single_threaded in the DLL?

The DLL runs inside the game's process and threads. Using the threaded I/O
backend would spawn worker threads that could interfere with the game's
threading model. The single-threaded variant performs all I/O on the
calling thread with no concurrency.

### Why the _X86_ c_macros workaround?

Zig 0.16's MinGW headers (e.g., `malloc.h`) gate `_ALLOCA_S_MARKER_SIZE`
behind `defined(_X86_) && !defined(__x86_64)`. Zig's clang front-end
doesn't pre-define `_X86_` on i686-windows-gnu targets during `@cImport`
parsing. The build.zig adds `-D_X86_=1` to each module's `c_macros`
when targeting x86. This also fixes `winnt.h`'s `PCONTEXT` type.

---

## 8. Current State & Known Issues

### Working

- ✅ ImGui UI with sidebar layout (1024×768, non-resizable)
- ✅ Game launching (CreateProcess + DLL injection + IPC config)
- ✅ Controller mapper with click-to-bind, default Xbox mapping, save/load (both P1+P2)
- ✅ IPC pipe cleanup on game exit (supports relaunching)
- ✅ ASM hacks (main loop hook, hijack controls, SFX dedup, forceGoto, config dialog skip)
- ✅ ENet transport (listen/connect/send/poll)
- ✅ Input buffer with prediction + change detection
- ✅ State transition index + TransitionIndex exchange
- ✅ Rollback state pool with memory regions
- ✅ SFX dedup (filter + mute arrays + history ring)
- ✅ Spectator chain forwarding (pending/active/redirect states)
- ✅ Cross-compilation from Linux to Windows
- ✅ Zig 0.16 migration complete (std.Io throughout)

### Known Issues / TODO

1. **Netcode not fully tested** — The rollback logic compiles and the state
   transitions + TransitionIndex exchange are implemented, but real-world
   testing over the internet hasn't been done. Localhost testing on Wine
   showed the game launches and reaches chara_select, but ENet connection
   between two Wine processes had issues.

2. **Player 2 controller mapping in DLL** — The UI has Player 2 panels and
   `mapping.ini` stores both P1 and P2 mappings. However, `dllmain.zig`'s
   `applyPostLoadHacks()` only loads and uses Player 1's mapping from the file.
   Player 2 mapping needs to be passed to the DLL for offline versus mode.
   In online mode, both sides use Player 1's mapping (the local player's).

3. **Pointer-following MemDumpPtr** — The legacy code follows pointers within
   saved memory to save/restore heap-allocated sub-structures (mainly for
   graphical effects). This is not ported. The flat regions cover ~95% of
   the state needed for correct rollback. Visual glitches in pointed-to
   effect sub-structures are possible but won't affect game logic.

4. **Replay table fixup** — The legacy code erases one frame of replay inputs
   per rolled-back frame to prevent the game's internal replay recorder from
   getting corrupted. Not ported. Only affects replay saving, not gameplay.

5. **CharaIntro → InGame transition** — The state machine has a `chara_intro`
   state that's set when entering InGame during netplay, but nothing ever
   moves it to `in_game`. This means `isInGame()` returns false during
   chara_intro, which may prevent rollback from triggering during the intro.

6. **hook.dll SDL2 conflicts** — The hook.dll and zzcaster.exe both init SDL2
   independently. If both are in the same process (they shouldn't be, but
   under Wine this can happen), SDL2 may conflict.

7. **Session module unused** — `src/session.zig` implements a higher-level
   netplay session FSM (handshake, ping exchange, config negotiation) but
   is not currently wired into the main game flow. The DLL uses
   `NetplayManager` directly with hardcoded config from IPC.

---

## 9. Legacy Code Reference

The original C++ codebase is at `/home/marcelo/Projetos/CCCaster/`.
Key reference files:

| Legacy file | Ported to | What it contains |
|-------------|-----------|------------------|
| `targets/DllMain.cpp` | `src/dllmain.zig` | Frame loop, ASM hooks, state transitions |
| `targets/DllNetplayManager.cpp` | `src/netplay_manager.zig` | Input sync, rollback trigger, state machine |
| `targets/DllRollbackManager.cpp` | `src/rollback.zig` + `sfx_dedup.zig` | State pool, SFX dedup |
| `targets/DllAsmHacks.cpp` | `src/dllmain.zig` (applySfxAsmHacks) | SFX ASM patch byte sequences |
| `targets/DllSpectatorManager.cpp` | `src/spectator_manager.zig` | Spectator chain forwarding |
| `netplay/InputsContainer.hpp` | `src/rollback.zig` (InputBuffer) | Input storage with prediction |
| `netplay/Constants.hpp` | Various | Game memory addresses, button constants |
| `Generator.cpp` | `src/rollback_regions.zig` | Memory regions to save/restore |
| `lib/Controller.hpp` | `src/controller_mapper.zig` | Controller mapping model (legacy used a different format) |

---

## 10. How to Deploy

```bash
./scripts/fetch-deps.sh                              # First time only
./scripts/build-and-deploy.sh --game-dir="/path/to/MBAACC"
```

Or manual:
```bash
zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast
# Copy zig-out/bin/zzcaster.exe to MBAACC root
# Copy zig-out/bin/hook.dll to MBAACC/zzcaster/
# Copy libs/sdl2-mingw/i686-w64-mingw32/bin/SDL2.dll to MBAACC/zzcaster/
```

---

## 11. Zig 0.16 Quirks (Important for LLM)

These are Zig 0.16-specific patterns used throughout the codebase:

1. **`std.Io` — the I/O subsystem rewrite** — Every file/stdout operation
   requires an explicit `Io` handle. Created via:
   ```zig
   var io_backend: std.Io.Threaded = .init_single_threaded;
   const io = io_backend.io();
   ```
   For the DLL, `init_single_threaded` avoids spawning worker threads.

2. **`std.fs.cwd()` → `std.Io.Dir.cwd()`** — All directory/file methods
   take `io` as first arg:
   ```zig
   std.Io.Dir.cwd().openFile(io, path, .{}) catch ...
   std.Io.Dir.cwd().createFile(io, path, .{}) catch ...
   std.Io.Dir.cwd().access(io, path, .{}) catch ...
   std.Io.Dir.cwd().createDirPath(io, dir_path) catch ...
   ```

3. **File write** — `file.writeStreamingAll(io, data)` instead of `writeAll(data)`

4. **File read** — Use `file.reader(io, &buf)` then `reader.interface.readSliceShort(&buf)`
   or `file.readPositionalAll(io, buf, offset)`

5. **File writer** — `var writer = file.writer(io, &buf);` then `writer.interface.print(...)`
   or `writer.interface.flush()`

6. **Stdout** — `std.Io.File.stdout().writeStreamingAll(io, "msg\n")` or build a writer:
   ```zig
   var stdout_buf: [256]u8 = undefined;
   var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
   stdout.interface.print("msg\n", .{}) catch {};
   stdout.interface.flush() catch {};
   ```

7. **Sleep** — `std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {}`
   (replaces `std.Thread.sleep`)

8. **Timestamps** — `std.Io.Clock.now(.real, io).toMilliseconds()`
   (replaces `std.time.milliTimestamp()`)

9. **Random** — `io.random(&seed_buf)` to fill a seed, then `std.Random.Xoshiro256`
   (replaces `std.crypto.random.intRangeLessThan`)

10. **`main()` signature** — `pub fn main(init: std.process.Init.Minimal) !void`
    (was `pub fn main() !void`). Use `init.args` and iterate via `Args.Iterator`.

11. **Allocator** — `std.heap.DebugAllocator(.{})` replaces `GeneralPurposeAllocator`

12. **`ArrayList(T)`** — Default is unmanaged; use `.empty` to init, pass allocator
    to `append`, `deinit`, `swapRemove`, etc. This pattern is unchanged from 0.15
    and already correct in the codebase.

13. **`callconv(.c)` / `callconv(.winapi)`** — Lowercase enum tags. Unchanged from 0.15.

14. **`@cImport` creates incompatible types per invocation** — Use `?*anyopaque`
    for cross-module pointer types (except `net.zig` which exports a shared ENet
    cimport).

15. **Build runner `Io`** — Available as `b.graph.io` in `build.zig`. Used for
    detecting the vendored SDL2 MinGW directory.

16. **`c_macros` on modules** — Used to pass `-D_X86_=1` for i686-windows-gnu
    targets. Affects both C compilation and @cImport parsing.

17. **`error` is a reserved keyword** — Can't use as an enum tag name. Unchanged.

18. **Inline asm** — Named operands with `%[name]` syntax. Guard x86-only asm with
    `builtin.cpu.arch == .x86`. Unchanged.

---

## 12. Session History Summary

This project was built across multiple LLM sessions:

1. **Initial analysis** — Studied the legacy CCCaster codebase, documented
   architecture, produced 5 design docs
2. **C++ rewrite** — First attempt in C++ with CMake (abandoned in favor of Zig)
3. **Zig port** — Rewrote everything in Zig, set up build system, cross-compilation
4. **Spectator mode + SFX dedup** — Ported from legacy, added to Zig code
5. **Build fixes** — Multiple rounds of fixing Zig API changes
6. **Netcode analysis** — Identified 7 critical issues in the netcode
7. **Phase 1 (delay-based)** — Fixed InputBuffer, state transitions, TransitionIndex,
   isRemoteInputReady, wait loop, u16 writes
8. **Phase 2 (rollback)** — Ported memory regions from Generator.cpp, wired
   checkRollback to call loadStateForFrame
9. **Launch fix** — Fixed non-blocking DllMain (Wine stall issue)
10. **Input write fix** — Changed u8 back to u16 (was the cause of "Start not firing")
11. **ImGui UI** — Replaced TUI with SDL2+ImGui+cimgui, cimgui_shim.h approach
12. **Project rename** — CCCaster → ZZCaster
13. **IPC cleanup** — Fixed pipe handle leak preventing game relaunch
14. **Controller mapper** — Full PCSX2-style click-to-bind with save/load
15. **UI fixes** — Window size 1024×768, ID conflict fixes, button sizing,
    trigger detection fix, default Xbox bindings
16. **Zig 0.16 migration** — Rewrote entire I/O subsystem to use `std.Io`,
    updated `main()` signature, allocator, timestamps, sleep, file operations.
    All source files updated. Build.zig uses `b.graph.io` + `c_macros` workaround.

---

## 13. Next Steps (Suggested)

1. **Test netcode on real Windows** — The rollback logic compiles but hasn't
   been tested with two real game instances. Need to verify state transitions,
   TransitionIndex exchange, and rollback trigger work correctly.

2. **Pass Player 2 mapping to DLL** — For offline versus mode, the DLL needs
   to know Player 2's controller mapping. Currently only Player 1 is loaded.

3. **Fix CharaIntro → InGame transition** — The state machine gets stuck in
   `chara_intro` and never transitions to `in_game` during netplay.

4. **Port replay table fixup** — Needed for correct replay saving after rollbacks.

5. **Port pointer-following MemDumpPtr** — Would fix visual glitches in
   effect sub-structures during rollback.

6. **Keyboard mapping in controller mapper** — Currently the keyboard option
   exists in the device dropdown, but keyboard bindings use Win32 VK codes
   which need testing.

7. **Adaptive delay** — Auto-compute input delay from ENet RTT + jitter
   (the legacy code has this; our version uses fixed delay from config).

8. **Wire session.zig into the flow** — The session FSM (handshake, pings,
   config negotiation) exists but is unused. Could be used for a future
   lobby system or to replace the simple IPC-based config exchange.
