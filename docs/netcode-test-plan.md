# ZZCaster — Netcode Test Plan

> **Status:** Proposed. Read alongside `context.md` §8 (Known Issues) and §13.1.
>
> **Goal:** Get the lockstep+rollback netcode working between two running
> instances, starting from the documented blocker: *"ENet connection between
> two Wine processes had issues."*

---

## Environment Decision

**Use localhost with two Wine instances (separate `WINEPREFIX` each).**
A Windows VM is **escalation only** (Stage 4), not the starting point.

### Why localhost Wine first
- The documented ENet blocker was **never captured in logs** — every existing
  `dll_*.log` in the game dir is an offline training run. We cannot fix what
  we cannot reproduce, and reproduction needs the fast rebuild→relaunch loop
  that only local Wine gives (seconds, not VM minutes).
- **CLI mode is purpose-built for this** and, critically, CLI mode never calls
  `ui.run()`, so the launcher process does **not** init SDL2. That sidesteps
  the §8.6 "both init SDL2 in one process" conflict entirely. Two launchers
  get two unique IPC pipes (`zzcaster_<pid>_pipe`), so no collision.
- UDP over `127.0.0.1` between two `WINEPREFIX`es maps to real Linux loopback
  sockets — fine for exercising the netcode logic.

### Why a VM is Stage 4, not Stage 1
Worth doing only if we hit a Wine-specific failure *after* the logic is
verified, or for final real-network validation (context §13.1). Doing it first
throws away the fast debug loop.

---

## Verified Facts (CLI mode)

`src/main.zig` parses `--mode=`, `--port=`, `--peer=` and dispatches to
`ui.runCli()` (`src/ui.zig:20`).

| CLI invocation | Effect |
|---|---|
| `--mode=host --port=46318` | Launches MBAA.exe, injects DLL, sends **host** config (flags `0x06`, local=P1) |
| `--mode=join --peer=127.0.0.1:46318` | Launches MBAA.exe, injects DLL, sends **client** config (flags `0x02`, local=P2) |
| `--mode=spectate --peer=…` | Spectator (flags `0x02\|0x08`) |
| `--mode=training` / `--mode=versus` | Offline |

- Each instance gets a unique IPC pipe `zzcaster_<pid>_pipe` (`main.zig:55`).
- Config byte layout matches sender (`ui.zig:843`) ↔ parser (`dllmain.zig:219`);
  host_player=1 → host=P1, joiner=P2.
- ENet connect is **lazy in `frameStep`** (`dllmain.zig:642`): polls
  `pollAndDispatch(50)` up to 1200× (~60s). The old blocking
  `waitForEnetConnect` is now dead code.

---

## Stages

### Stage 0 — Pre-flight (no game yet)
1. Confirm build is green with Zig 0.16+:
   `zig build -Dtarget=x86-windows-gnu -Doptimize=Debug`
   (Debug for log fidelity; switch to ReleaseFast later.)
2. Deploy via `scripts/build-and-deploy.sh`.
3. **Add ENet diagnostics to the DLL log** (the only code change):
   - In `initEnet()` (`netplay_manager.zig:193`): log `enet_host_create`
     result; for client, log the resolved `addr.host`/`addr.port` after
     `enet_address_set_host`; log `enet_host_connect` return (peer ptr).
   - In the frameStep connect loop (`dllmain.zig:642`): on the 60s cap,
     distinguish "no CONNECT event ever received" from "REFUSE received" by
     logging each non-CONNECT event type during the connect-poll loop.
   - The CONNECT path already has one `DIAG:` log (`netplay_manager.zig:375`).
   - Pure additive logging — cannot itself change the connect outcome.
4. Truncate (archive, don't delete) old `dll_*.log` files.

**Stop criteria:** build OK, binaries in game dir, diagnostics in place.

### Stage 1 — Bring up two instances on localhost
Goal: get past the documented "ENet connect" failure.

5. Host terminal:
   ```
   WINEPREFIX=~/.wine-zz-host WINEDEBUG=-all \
     wine zzcaster.exe --mode=host --port=46318
   ```
6. Join terminal:
   ```
   WINEPREFIX=~/.wine-zz-join WINEDEBUG=-all \
     wine zzcaster.exe --mode=join --peer=127.0.0.1:46318
   ```
7. `tail -f` both `dll_<pid>.log` files. Look for:
   - Host: `ENet listening on port 46318` → `Main peer connected`
   - Join: `ENet connecting to 127.0.0.1:46318` → `ENet peer connected!`
8. If connect fails, the Stage-0 diagnostics pinpoint the cause
   (bind fail / REFUSE / silent timeout). Likely suspects, in order:
   bind under a shared prefix; `enet_address_set_host` resolving `127.0.0.1`;
   the 60s cap firing.

**Stop criteria:** both sides log a successful CONNECT.

### Stage 2 — Verify the sync handshake
Goal: confirm the lockstep pipeline works once connected.

9. With both connected, navigate both to versus/chara-select. Confirm
   `TransitionIndex` exchange (0x03) and RNG sync (0x02, host→client) fire —
   visible in logs as `onStateTransition` / `syncRngState` lines.
10. Verify `isRemoteInputReady()` stops stalling — both games should advance
    frames in lockstep. The frameStep wait loop (`dllmain.zig:721`) logs
    `Waiting for remote input... (5s elapsed)` if it stalls — that's the
    signal of a sync bug.

**Stop criteria:** lockstep advances frames on both sides, no 5s stall.

### Stage 3 — Exercise rollback
Goal: confirm misprediction → load state → re-run works.

11. Play a few seconds; force a desync by pausing one side briefly
    (simulates jitter). Confirm `checkRollback()` triggers,
    `loadStateForFrame` runs, and the game doesn't visibly desync or hang.
12. Check the known-issue §8.5 `CharaIntro → InGame` trap: if rollback never
    fires during the intro, that's the bug to fix next.

**Stop criteria:** survives a forced desync without hang/visual break.

### Stage 4 — Escalation (only if blocked by Wine)
13. If a failure is clearly Wine-specific (logic correct, fails under Wine,
    would pass on Windows): spin up a Windows VM, run **two localhost
    instances inside the one VM** first, then two VMs for real-network
    validation. Defer until needed.

---

## Safety / Rollback
- All changes are additive logging + Debug builds; the ReleaseFast deploy
  path is unchanged.
- Each Wine instance is isolated in its own `WINEPREFIX`; killing wineserver
  per prefix cleans up fully.
- Old `dll_*.log` files are archived (not deleted) before truncating.

## Definition of Done
- Two localhost instances connect (Stage 1 ✓), exchange the handshake
  (Stage 2 ✓), and survive a forced desync via rollback (Stage 3 ✓) —
  **or**, if a real bug surfaces, we have precise logs identifying it as the
  next fix.
