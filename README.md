# cc-rollback-zig

A from-scratch Zig 0.16 port of CCCaster's rollback subsystem.

This port is written directly from the CCCaster C++ source
(https://github.com/Rhekar/CCCaster). It does **not** derive from any other
implementation. The goal is byte-faithful behavior: the same region-table
binary format, the same save/load memory layout, the same `_lastChangedFrame`
semantics, and the same `frameStep` rollback decision tree.

## What's ported

| CCCaster source                          | Zig port                       |
|------------------------------------------|--------------------------------|
| `netplay/Constants.hpp` (rollback parts) | `src/constants.zig`            |
| `netplay/NetplayStates.hpp`              | `src/netplay_state.zig`        |
| `union IndexedFrame` (Constants.hpp)     | `src/indexed_frame.zig`        |
| `netplay/InputsContainer.hpp`            | `src/inputs_container.zig`     |
| `lib/MemDump.hpp` + `lib/MemDump.cpp`    | `src/mem_dump.zig`             |
| `targets/DllRollbackManager.{cpp,hpp}`   | `src/rollback_manager.zig`     |
| `targets/DllNetplayManager.{cpp,hpp}`    | `src/netplay_manager.zig` (rollback parts only) |
| `targets/DllMain.cpp` (frameStep)        | `src/frame_step.zig`           |

## What's NOT ported (intentionally)

- Chara-select menu navigation
- Retry-menu sync
- RNG sync (host→client handshake)
- Spectator manager
- Replay export
- Network transport (ENet / TCP / relay)
- GUI / launcher
- ASM hacks (stage-animation disable, intro-state hijack, SFX filter hooks)

These are orthogonal to the rollback subsystem and would obscure the core
logic. The host (the real hook.dll) is expected to wire `read_byte` /
`write_byte` / `read_world_timer` up to the live MBAACC address space.

## Build & test

Requires Zig 0.16.0.

```bash
zig build test --summary all    # run the 34 unit tests
zig build                       # build the demo binary
./zig-out/bin/cc_rollback_demo  # run a smoke-test rollback cycle
```

## Architecture

The port preserves CCCaster's layering exactly:

1. **`InputsContainer(T)`** — the input-history data structure backing
   `NetplayManager._inputs`. Maps `index → frame → input`, tracks
   `_lastChangedFrame` (the earliest frame whose input differed from the
   prediction — this is what triggers rollback).

2. **`MemDump` / `MemDumpPtr` / `MemDumpList`** — the memory region save/load
   mechanism. Each `MemDump` is a contiguous `[addr, addr+size)` range.
   `MemDumpPtr` follows a pointer stored inside a parent region to reach a
   child region (so the rollback snapshot can follow MBAACC's pointer-chased
   allocations like the effects array). The binary serialization format
   matches CCCaster's cereal archive byte-for-byte.

3. **`RollbackManager`** — the heart of the subsystem. Allocates a fixed-size
   memory pool, snapshots game memory + FSM state + FPU env + SFX history on
   `saveState`, restores them on `loadState` (with the RepRound input-history
   rewind and SFX dedup filter seeding).

4. **`NetplayManager`** — the rollback-relevant parts of the netplay FSM:
   `isInRollback`, `getDelay`, `setInput`, `setInputs` (with the
   `checkStartingFromIndex` flag that drives `_lastChangedFrame`),
   `isRemoteInputReady` (the lockstep gate), and `setState` (index increment +
   `startWorldTime` capture on transitions past CharaSelect).

5. **`FrameStep`** — the per-frame driver that decides WHEN to save a state,
   WHEN to fire a rollback, and WHEN to re-run. This is the decision tree
   from `DllMain.cpp`'s `frameStepNormal` / `frameStepRerun` / `frameStep`:
   - Save a state only in-game with rollback configured.
   - Clear `lastChangedFrame` only when the rollback timer is full.
   - Fire a rollback when `isInRollback() && rollbackTimer == minRollbackSpacing
     && getLastChangedFrame().value < getIndexedFrame().value`.
   - Re-run (no saving) until `getIndexedFrame() >= fastFwdStopFrame`.

## Host integration

The port is transport-agnostic. The host provides three callbacks:

- `read_byte(addr: usize) u8` — read a byte from a 32-bit MBAACC address.
- `write_byte(addr: usize, b: u8) void` — write a byte to a 32-bit MBAACC address.
- `read_world_timer() u32` — read `*CC_WORLD_TIMER_ADDR`.

On Windows (inside the injected hook.dll), these dereference the live MBAACC
addresses directly. In tests, they read from a mock buffer.

## Testing

34 unit tests cover:

- `InputsContainer`: set/assign/get semantics, `lastInputBefore` fallback,
  `setBatch` change detection with `checkStartingFromIndex`, `eraseIndexOlderThan`.
- `MemDumpList`: save/load round-trip, pointer-chain following, NULL-pointer
  zero-fill, binary serialize/deserialize.
- `RollbackManager`: saveState + loadState round-trip, FPU env defaults.
- `NetplayManager`: setInput delay selection (rollback vs chara_select),
  setInputs change recording, isRemoteInputReady lockstep gate, setState
  index increment.
- `FrameStep`: full rollback cycle (save → predict → mispredict → load → re-run),
  min_rollback_spacing clamping, shouldFireRollback timer + lcf guards.
