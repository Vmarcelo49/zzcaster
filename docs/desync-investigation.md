# Desync Investigation & Fix Tracker

> **Purpose:** Root-cause analysis of netplay desyncs in ZZCaster, cross-referenced
> against the legacy CCCaster source at `/home/marcelo/Projetos/CCCaster/`.
> Each section documents a confirmed gap and tracks its fix status. Update this
> file as work progresses.

---

## Summary of findings

The desyncs are **not** caused by the transport layer (TCP vs UDP). ZZCaster
replaced the legacy `Socket`/`SmartSocket` abstraction with ENet, which is
itself a reliable-UDP protocol — functionally equivalent to the legacy UDP data
channel. The desyncs come from **state-machine and sync logic gaps** between
ZZCaster and the legacy code.

### Status

| # | Fix | Priority | Status |
|---|-----|----------|--------|
| 1 | SyncHash desync detection (diagnostic) | High | ✅ Done |
| 2 | CharaIntro → InGame transition via RoundStart/INTRO_DONE | High | ✅ Done |
| 3 | 150-frame chara-select confirm guard | High | ✅ Done |
| 4 | checkRoundOver (InGame→Skippable via no-input flags) | Medium | ✅ Done |
| 5 | Force CC_INTRO_STATE_ADDR=0 during rollback past frame 224 | Medium | ✅ Done |

All five fixes build clean (`zig build -Dtarget=x86-windows-gnu`). No real-
match testing has been done yet — see "Next steps" below.

---

## Background: the TCP/UDP question

**User hypothesis:** cccaster uses TCP through char-select, then switches to UDP
for the match.

**Reality (from legacy source):** The legacy code runs **two sockets in
parallel**, both via the `SmartSocket` wrapper (`lib/SmartSocket.cpp`):

- `serverCtrlSocket` — a **TCP** listening socket (`SmartSocket::listenTCP`).
  Used only for connection setup / IP exchange / relay redirect.
- `serverDataSocket` / `dataSocket` — a **UDP** socket
  (`SmartSocket::listenUDP` / `connectUDP`). **This carries ALL gameplay
  traffic** — inputs, RNG, TransitionIndex, SyncHash, BothInputs.

```cpp
// targets/DllMain.cpp:1826-1841
if ( clientMode.isHost() ) {
    serverCtrlSocket = SmartSocket::listenTCP(this, address.port);
    serverDataSocket = SmartSocket::listenUDP(this, address.port);
} else if ( clientMode.isClient() ) {
    serverCtrlSocket = SmartSocket::listenTCP(this, 0);
    dataSocket       = SmartSocket::connectUDP(this, address, clientMode.isUdpTunnel());
}
```

**There is no switch back to TCP after the match.** The TCP control socket
stays open in the background; all gameplay data is always UDP. The "TCP at
start, UDP in match" perception comes from TCP handling the visible handshake
phase.

**Implication for ZZCaster:** The ENet replacement is transport-fine. The
desyncs are in the protocol/state layer on top of it. The one thing ENet does
NOT provide that the legacy had is the **relay-server UDP-tunnel fallback**
(`SmartSocket` queries a VPS to punch NAT) — but that affects *connectivity*,
not *desync*. If both peers can connect at all, ENet is sufficient.

---

## Background: the two sync barriers ("sync, then sync again, then play")

The legacy game flow has **two distinct sync barriers** before gameplay:

### Barrier A — CharaSelect (with the "moon selector desync" guard)

Legacy masks Confirm/A for the first 150 frames of chara-select, because the
moon (Crescent/Full/Half) selector hasn't settled identically on both sides:

```cpp
// targets/DllNetplayManager.cpp:138-141
// Prevent hitting Confirm until 150f after beginning of CharaSelect,
// this is to workaround the moon selector desync
if ( config.mode.isOnline() && getFrame() < 150 )
    input &= ~ COMBINE_INPUT(0, CC_BUTTON_A | CC_BUTTON_CONFIRM);
```

### Barrier B — CharaIntro → InGame (the intro sync)

The `CharaIntro → InGame` transition in the legacy is driven by **two
independent game-memory signals**, NOT the `game_mode` change:

1. **`RoundStart` variable watch** (`targets/DllMain.cpp:1266-1269`): the game
   raises a "round start" signal when players can actually move — this is what
   flips state to `InGame`, not the earlier `game_mode` change.

2. **`gameStateChanged(CC_GAME_STATE_INTRO_DONE)`** (`targets/DllMain.cpp:1177-1185`):
   a separate game-state variable (`0x74d598`) hits the value `99`
   (`CC_GAME_STATE_INTRO_DONE`), which **enables RNG sync**
   (`shouldSyncRngState = true`). Both peers then seed the round's RNG
   identically just before gameplay.

The skippable intro/cutscene is **not freely skippable** in netplay — the
legacy only allows Confirm/Cancel through, and if the remote peer is ahead, it
auto-mashes Confirm to catch up (`getSkippableInput`).

---

## Gap 1 — SyncHash desync detection (ABSENT in ZZCaster) — HIGH

### Legacy behavior

`Messages.hpp:311-415` and `targets/DllMain.cpp:775-831`:

- Every 5 seconds (`frame % (5*60) == 0`) and at frame 149 of each 150-cycle,
  each side snapshots a hash of: timers, camera, and per-character
  `{seq, seqState, health, redHealth, meter, heat, guardBar, guardQuality, x, y,
  chara, moon}`.
- They exchange these hashes and compare.
- **On mismatch → `delayedStop("Desync!")` — hard stop.** The original does
  not try to recover; it aborts the match.
- The per-field dump tells you *what* diverged (health? position? the seq
  counter?), pinpointing the root cause.

### ZZCaster state

**Completely absent.** No SyncHash message type, no hash exchange, no
comparison. When a desync happens, the game keeps running with divergent state
— players see different positions/health — and there is no alarm. This is why
the desyncs feel mysterious.

### Why fix this first

It's additive (won't change behavior, just aborts + logs on divergence) and
the per-field dump will confirm whether the other gaps below are the actual
cause in real matches. Highest diagnostic value.

### Status

✅ Done. Implemented in `src/netplay_manager.zig`:
- `SyncHash` struct with `capture()` (MD5 of RNG state + per-field snapshot,
  matching the legacy `DllHacks.cpp` constructor), `serialize`/`deserialize`
  (136-byte body), and `matches()` (legacy `operator==` including the
  seq==0 seqState exception).
- Message type `0x04` for SyncHash; dispatched in `handleMessage`.
- `maybeSendSyncHash()` sends on the legacy cadence (every 300f + frame 149),
  excluding Loading/CharaIntro/Skippable/RetryMenu and active re-runs.
- `checkSyncHashDesync()` pairs local/remote entries by indexed_frame and
  compares; on mismatch sets `desync_detected` and logs the divergent field.
- `frameStep` calls both after `pollAndDispatch`; on `desync_detected` it
  force-exits the match (matches legacy `delayedStop("Desync!")`).

Wire format: `[1 type=0x04][136 SyncHash body]` (reliable channel 0).

---

## Gap 2 — CharaIntro → InGame transition (BROKEN in ZZCaster) — HIGH

### Legacy behavior

`CharaIntro → InGame` is driven by the `RoundStart` variable watch
(`DllMain.cpp:1266`), not the `game_mode` change. Separately, the
intro-done game state (`0x74d598 == 99`) enables RNG sync.

### ZZCaster state

`onGameModeChanged` (`netplay_manager.zig:856`) flips straight to
`chara_intro` on the mode change and **never advances to `in_game`** because
it only watches `game_mode_addr`, not the `RoundStart`/intro-done signals.

Consequences:
- `isInGame()` returns false during the intro → `isInRollback()` returns
  false → **rollback is silently disabled for the first ~224 frames of every
  round** (`CC_PRE_GAME_INTRO_FRAMES`).
- `isRemoteInputReady()` doesn't gate on the intro → peers can drift.
- RNG sync timing is wrong (re-enabled on chara_select/in_game transitions,
  never on the intro-done edge).

This is issue #5 in `context.md`.

### Status

✅ Done. Implemented in `src/netplay_manager.zig` + `src/dllmain.zig`:
- `checkIntroDone()` watches `CC_INTRO_STATE_ADDR` (`0x55D20B`) each frame;
  when it drops to 0 (in-game, players can move), advances
  `chara_intro → in_game` via the proper state-machine path (increments
  transition index, sends TransitionIndex).
- RNG sync is enabled on the rising edge of `CC_GAME_STATE_ADDR` (`0x74D598`)
  hitting `99` (`CC_GAME_STATE_INTRO_DONE`), via the `intro_rng_enabled`
  one-shot latch (re-armed on loading/chara_select transitions).
- `frameStep` calls `checkIntroDone()` every frame after the game-mode-change
  check.

---

## Gap 3 — 150-frame chara-select confirm guard (ABSENT in ZZCaster) — HIGH

### Legacy behavior

`targets/DllNetplayManager.cpp:138-141` — masks Confirm/A for the first 150
frames of chara-select to avoid the moon-selector desync.

### ZZCaster state

`getNetplayInput` in `netplay_manager.zig:622` only masks Cancel. The 150f
guard is missing. A player confirming within the first 2.5s of char-select
can lock the two clients into different moon styles and desync at round start.

### Status

✅ Done. Implemented in `src/netplay_manager.zig`:
- The `.chara_select` branch of `getNetplayInput` now masks A (`0x0100` in
  the combined u16) and Confirm (`0x4000`) for the first 150 frames when
  `is_netplay`. Also masks Cancel (`0x8000`) unconditionally, matching the
  legacy's "can't back out of chara-select" rule.
- Rewrote the tangled bit-layout comment to clearly document the
  `dir | (btns << 4)` encoding.

---

## Gap 4 — checkRoundOver (ABSENT in ZZCaster) — MEDIUM

### Legacy behavior

`targets/DllMain.cpp:1200-1245`: the `InGame → Skippable` transition is driven
by the `no_input_flag` for each player (KO / time over), NOT by `game_mode`.
With rollback, it waits `rollback + ROLLBACK_ROUND_OVER_DELAY` frames before
committing the transition.

### ZZCaster state

Only watches `game_mode_addr`. The InGame→Skippable edge can drift between
peers if the round-end signals don't align with the mode change on both
sides.

### Status

✅ Done. Implemented in `src/netplay_manager.zig` + `src/dllmain.zig`:
- `checkRoundOver()` reads both players' `no_input_flag`, accounting for the
  puppet wrinkle (when `puppet_state != 0`, the flag lives on P3/P4). Ported
  from `DllMain.cpp:1200-1245`.
- Rollback path uses the `round_over_timer` sentinel (`-1` armed, `0` fire,
  `>0` countdown) with `rollback + 5` frame delay; non-rollback path fires
  immediately (skipping training mode).
- `tickRoundOverTimer()` decrements the countdown once per in-game frame
  (matches the legacy decrement in `frameStepNormal`).
- `frameStep` calls both every frame after `checkIntroDone`.

---

## Gap 5 — Force CC_INTRO_STATE_ADDR=0 during rollback — MEDIUM

### Legacy behavior

`targets/DllMain.cpp:975-976`:
```cpp
if ( netMan.isInRollback() && netMan.getFrame() > CC_PRE_GAME_INTRO_FRAMES && *CC_INTRO_STATE_ADDR )
    *CC_INTRO_STATE_ADDR = 0;
```

During a rollback re-run that goes past frame 224, the intro state is forced
to 0 so the re-run doesn't re-trigger intro logic.

### ZZCaster state

Not implemented. Rollback re-runs past the intro window may behave
incorrectly.

### Status

✅ Done. Implemented in `src/netplay_manager.zig` + `src/dllmain.zig`:
- `clearIntroStateDuringRollback()` mirrors `DllMain.cpp:975-976`: when
  `isInRollback()` and `indexed_frame.frame > 224` and the intro flag is
  non-zero, write 0.
- `frameStep` calls it every frame after `checkRoundOver`.

---

## Reference: key game-memory addresses

| Address | Size | Name | Notes |
|---------|------|------|-------|
| `0x54EEE8` | u32 | `CC_GAME_MODE_ADDR` | Current game mode |
| `0x74d598` | u32 | `CC_GAME_STATE_ADDR` | Intermediate game state (`99`=intro done) |
| `0x55D20B` | u8 | `CC_INTRO_STATE_ADDR` | 2=chara intro, 1=pre-game, 0=in-game |
| `0x5552A7` | u8 | `CC_P1_NO_INPUT_FLAG_ADDR` | KO/time-over flag |
| `0x555D53` | u8 | `CC_P2_NO_INPUT_FLAG_ADDR` | `0x5552A7 + 0xAFC` |
| `0x5552A8` | u8 | `CC_P1_PUPPET_STATE_ADDR` | 0=main, 1=puppet |
| `0x555D54` | u8 | `CC_P2_PUPPET_STATE_ADDR` | |
| `0x562A3C` | u32 | `CC_ROUND_TIMER_ADDR` | Counts down from 4752 |
| `0x562A40` | u32 | `CC_REAL_TIMER_ADDR` | Counts up from 0 |
| `0x564B14` | i32 | `CC_CAMERA_X_ADDR` | |
| `0x564B18` | i32 | `CC_CAMERA_Y_ADDR` | |
| `0x555140` | u32 | `CC_P1_SEQUENCE_ADDR` | Animation sequence |
| `0x555144` | u32 | `CC_P1_SEQ_STATE_ADDR` | |
| `0x5551EC` | u32 | `CC_P1_HEALTH_ADDR` | |
| `0x5551F0` | u32 | `CC_P1_RED_HEALTH_ADDR` | |
| `0x5551F4` | f32 | `CC_P1_GUARD_BAR_ADDR` | |
| `0x555208` | f32 | `CC_P1_GUARD_QUALITY_ADDR` | |
| `0x555210` | u32 | `CC_P1_METER_ADDR` | |
| `0x555214` | u32 | `CC_P1_HEAT_ADDR` | |
| `0x555238` | i32 | `CC_P1_X_POSITION_ADDR` | |
| `0x55523C` | i32 | `CC_P1_Y_POSITION_ADDR` | |

P2 structs are at `P1_addr + 0xAFC` (`CC_PLR_STRUCT_SIZE`).

Constants: `CC_PRE_GAME_INTRO_FRAMES = 224`, `CC_GAME_STATE_INTRO_DONE = 99`.

---

## Next steps (testing)

All five fixes build clean and are wired into the frame loop. They have **not**
been tested in real matches yet. Suggested test order:

1. **Smoke test on localhost** — two game instances on one machine. Verify:
   - Chara-select can't confirm for the first 2.5s (gap 3).
   - The match enters InGame cleanly (gap 2) — check the log for
     `CharaIntro -> InGame (intro_state=0...)`.
   - Round end transitions to Skippable (gap 4) — log shows
     `Round over -> skippable`.
   - No spurious SyncHash desync aborts (gap 1) — the log should NOT show
     `DESYNC detected`. If it does, the per-field dump tells you what
     diverged.

2. **Real internet test** — the real validation. Watch for:
   - SyncHash aborts: if these fire, the dump identifies the root cause.
     Most likely candidates are the un-ported items below.
   - State-machine drift: if peers end up in different states, the
     `Invalid state transition` log will fire.

3. **If desyncs persist**, the SyncHash dump is now the primary diagnostic.
   The un-ported items most likely to cause residual desyncs are:
   - **Pointer-following MemDumpPtr regions** (context.md issue #3) —
     ~5% of state (effect sub-structures) isn't restored on rollback.
   - **Replay table fixup** (issue #4) — only affects replay saving.

## Files changed

- `src/netplay_manager.zig` — SyncHash struct + exchange/detection; intro
  transition (`checkIntroDone`); 150f chara-select guard; `checkRoundOver` +
  `tickRoundOverTimer`; `clearIntroStateDuringRollback`; game-memory address
  constants.
- `src/dllmain.zig` — frame loop calls for all of the above; desync force-exit.
- `docs/desync-investigation.md` — this file.
