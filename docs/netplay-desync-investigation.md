# zzcaster Netplay Desync Investigation

> **Purpose:** Living investigation log for zzcaster's netplay desync bugs.
> Read this entirely before making changes — it captures the history, the
> current open issues, and the hard-won findings that must not be rediscovered.
>
> **Last updated:** 2026-06-30
> **Current HEAD:** `bdad26e`

---

## Quick Status

| Issue | Status | Fixed by |
|---|---|---|
| §A chara_intro entry divergence freeze | ✅ RESOLVED | `d9ae272` always-mash during chara_intro |
| §B small drift at frame 149 (round 2+) | ✅ RESOLVED | `b098c32` always-mash during skippable |
| §C end-of-round delay desync | ❌ **OPEN** | — |
| Replay save popup | ✅ RESOLVED | `76471ba` + `c6ae0db` + `01376d6` |
| Retry menu navigation | ✅ RESOLVED | `01376d6` always mcs=2 |
| Delay mismatch (host vs client) | ✅ RESOLVED | `bdad26e` host dictates delay |
| Victory screen skip desync | ✅ RESOLVED | `b098c32` always-mash during skippable |
| Title screen freeze (menuConfirmHack) | ✅ RESOLVED | `0936798` mcs=2 in pre-game mashes |

**§C is the current open issue.** Delay mode desyncs at end of round (frame 149,
uniform position offset ~2750 units, no RNG mismatch). Details in §C below.

---

## Setup

- **Repo zzcaster:** `git@github.com:Vmarcelo49/zzcaster.git`
- **Repo CCCaster ref:** `https://github.com/Rhekar/CCCaster.git`
- **SSH:** shim at `/home/z/my-project/.ssh/ssh-shim.py` (paramiko, no openssh-client)
- **Build:** `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast`
- **Toolchain:** Zig 0.16.0
- **Usuário:** `vmarcelo49 <vmarcelo49@gmail.com>` — todos os commits authored as this user
- **TZ:** America/Sao_Paulo (fala português, responde em português)
- **CCCaster reference:** `/home/z/my-project/CCCaster` — a "pure truth". Always verify against this.

---

## §A — chara_intro entry divergence (RESOLVED)

**Status:** ✅ Fixed 2026-06-30 (`d9ae272`)

**Root cause:** Loading is I/O-bound and not lockstepped (same as CCCaster). The
two peers enter chara_intro at different `world_timer` values (typically 1-3
frames apart). With per-frame lockstep during chara_intro, both peers advance
frame-by-frame, but the underlying game state is diverged. After ~207 frames,
`round_start_counter` fires for one peer but not the other → deadlock.

**Fix:** Always mash Confirm during chara_intro. Both peers mash at the same
frame (lockstep guarantees sync), skip the intro together, and enter in_game at
the same game state — before the divergence can cause a `round_start_counter`
asymmetry.

**Key commits:**
- `9749937` — Port `menuConfirmState` ASM hack (prerequisite for mash)
- `b630ccf` — Port catch-up mash + getSkippableInput
- `0936798` — Set `menu_confirm_state=2` in pre-game mashes (title screen fix)
- `d9ae272` — Always mash Confirm during chara_intro (the actual §A fix)

---

## §B — small drift at frame 149 (RESOLVED)

**Status:** ✅ Fixed 2026-06-30 (`b098c32`)

**Root cause:** Same as §A but for the victory screen (`.skippable`). The two
peers enter skippable with a 3-frame game state difference. If both watch the
full victory animation, `round_start_counter` fires at different relative frames
→ Δ1415 uniform offset on all positions at round 2 frame 149.

**Fix:** Always mash Confirm during skippable. Same pattern as chara_intro —
both peers skip the victory screen together, enter round 2 at the same game
state.

**Key commit:** `b098c32` — Always mash Confirm during skippable

**Note:** The `fix/small-drift-animation-states` branch (3 timing fixes — skip
cooperative sleep, skip RTT EMA, reset frame limiter after lockstep wait) was
merged (`981c1fb`) but did NOT fully fix §B. The actual fix was the
always-mash approach. The branch's fixes are still beneficial (reduce timing
variability during animations) and remain in the codebase.

---

## §C — end-of-round delay desync (OPEN)

**Status:** ❌ Open — current focus

**Symptom:** Delay mode desyncs at end of round (frame 149, index 4 or 6).
Uniform position offset (~2750 units on camera_x, P1_x, P2_x), **no RNG
mismatch**. The match completes a full round but desyncs right at the end.

**Evidence (from 2026-06-30 online testing):**

Match with delay=1 on both peers (delay mismatch fixed):
```
[ERROR] DESYNC detected at indexed_frame=0x0000000400000095
[ERROR]   camera_x: -12500 vs -9750    (Δ2750)
[ERROR]   P1 x: -37880 vs -35130       (Δ2750)
[ERROR]   P2 x: (not reported)
[ERROR]   (no RNG mismatch)
```

**Key observations:**
1. The offset is **uniform** on all positions → the entire game world is shifted
2. **No RNG mismatch** → determinism root is OK, this is a position/timing offset
3. Δ2750 / 149 frames ≈ 18.5 units/frame (much smaller than §B's 472 units/frame)
4. Happens at frame 149 = `indexed_frame=0x...00000095` = the sync-hash check frame
5. Both delay=1 and delay=2 reproduce the issue

**Hypotheses (NOT YET VERIFIED):**
1. **Timing injection during in_game** — the cooperative sleep / RTT EMA / frame
   limiter interaction during active gameplay (not just animations) may cause
   small per-frame drift that accumulates to Δ2750 over 149 frames
2. **Input delay asymmetry** — even with matching delay values, the way inputs
   are buffered and applied might differ between host and client
3. **Frame limiter drift** — the busy-wait frame limiter may drift differently
   on the two peers' hardware (different CPU speeds, timer resolution)
4. **Air dash macro** — the macro modifies inputs; if it triggers at different
   frames on the two peers (due to input timing), it could cause position drift

**What to investigate next:**
1. **Get both peers' full logs** for a desync match — compare frame-by-frame
   from in_game entry (frame 0) to the desync (frame 149). Look for any
   divergence in inputs, rollback triggers, or timing.
2. **Check if the desync happens at the EXACT same frame** every time (149) or
   varies. If always 149, it's the sync-hash check catching a drift that
   accumulated over the round. If it varies, it's a specific event.
3. **Test with delay=0** (if possible) to isolate whether the delay mechanism
   itself contributes to the drift.
4. **Compare with CCCaster** — does CCCaster have this same drift in delay mode?
   CCCaster RELEASE doesn't detect desyncs, so it might have the drift but not
   crash. Test CCCaster delay mode with debug build if possible.

---

## Key Files

- `src/dll/netplay_manager.zig` — NetplayManager, FSM, lockstep, rollback, sync hash
  - `getNetplayInput` — input handling per state (chara_intro/skippable always-mash)
  - `isRemoteInputReady` — lockstep gate (chara_select + in_game only; chara_intro/skippable/retry_menu return true)
  - `checkRoundStart` — chara_intro/skippable → in_game transition via round_start_counter
  - `onStateTransition` — captures start_world_time, arms RNG sync
- `src/dll/asm_hacks.zig` — ASM hacks including menuConfirmState (commit `9749937`)
- `src/dll/frame_step.zig` — frameStepNetplay, lockstep wait loop, cooperative sleep
- `src/dll/dllmain.zig` — lazyInit, applyPostLoadHacks (auto_replay_save disable), frameStep
- `src/launcher/session.zig` — handshake, delay negotiation (host dictates, commit `bdad26e`)

---

## Important Findings (must not rediscover)

### 1. CCCaster RELEASE doesn't detect desyncs
The `SyncHash` handler is `#ifndef RELEASE` (`DllMain.cpp:1432-1436`). In RELEASE,
`remoteSync` never receives entries. zzcaster detects at frame 149; CCCaster
wouldn't. **"CCCaster works" is not proof there's no drift.**

### 2. Loading is I/O-bound — cannot lockstep
Loading completion depends on disk speed / cache warmth, not frame count.
Lockstepping loading deadlocks (Option 2, commit `bdfbfe0`, reverted `295cf06`).
The entry divergence must be handled by skipping the animation (always-mash),
not by synchronizing the entry.

### 3. Always-mash + lockstep is the winning pattern
For animation states (chara_intro, skippable): always mash Confirm + per-frame
lockstep. The mash skips the animation on both peers at the same frame; lockstep
guarantees both peers mash together. This prevents the entry divergence from
causing `round_start_counter` asymmetry.

### 4. menuConfirmState hack is required for mashing
The game's menu code ignores rapid Confirm presses. The `menuConfirmState` ASM
hack (5 patches at `0x428F52`-`0x428F82`) intercepts the menu-confirm handler
and forces it through when `menu_confirm_state > 1`. Every mash site MUST set
`menu_confirm_state = 2`.

### 5. retry_menu needs mcs=2 always
The menuConfirmHack gates ALL confirms on `mcs > 1`. With `mcs=0`, the game
detects the Confirm press (sets mcs=1) but the hack blocks it (1 is not > 1).
During retry_menu, always set `mcs=2` so confirms work for Rematch/Character
Select.

### 6. Host dictates delay
Both peers computing their own delay from RTT leads to mismatches (asymmetric
routing, jitter). Only the host computes delay; the client adopts the host's
value via the config message. (commit `bdad26e`)

### 7. auto-replay-save is disabled
The full auto-replay-save feature (saveReplay + detectAutoReplaySave ASM hacks +
currentMenuIndex tracking) is NOT ported. Writing 0 to `CC_AUTO_REPLAY_SAVE_ADDR`
(`0x553FE8`) disables the popup. The `menu_state_counter` (`0x767440`) detects
when the popup appears so `mcs=2` can dismiss it. (commits `76471ba`, `c6ae0db`)

---

## Commit History (this session, 2026-06-30)

### QA cleanup commits (earlier in session)
- `a6f0eec` — fix(launcher): CLI netplay sends 9-byte IPC header (QA A1)
- `b70b00d` — fix(launcher): drop dead orig_bytes read (QA A2)
- `d682a20` — fix(net): nat_probe.resolveHost endianness (QA A3)
- `8aa8664` — refactor(net): dedupe ws2_32 extern bindings (QA B1)
- `671a9da` — fix(ui): initialize rollback/wincount from config
- `26cb2c7` — docs: rename HANDOFF.md → netplay-desync-investigation.md

### §A investigation + fix
- `bdfbfe0` — lockstep loading state (Option 2 — FAILED, reverted)
- `295cf06` — revert Option 2
- `9749937` — port menuConfirmState ASM hack (Option 1, commit 1/3)
- `b630ccf` — port catch-up mash + getSkippableInput (Option 1, commit 2/3)
- `7338950` — remove chara_intro/skippable/retry_menu lockstep (Option 1, 3/3 — FAILED, reverted)
- `3cde42c` — revert Option 1 commit 3/3 (restore lockstep)
- `0936798` — set menu_confirm_state=2 in pre-game mashes (title screen fix)
- `d9ae272` — **always mash Confirm during chara_intro** (§A FIX)

### §B + branch merge
- `981c1fb` — merge fix/small-drift-animation-states (3 timing fixes, rebased)
- `620570f` — suppress player input during loading/chara_intro/skippable (reverted by d9ae272)
- `b587751` — logging dedup (consecutive identical lines → [Nx] prefix)
- `e23b1a3` — remove per-frame DIAG lockstep + wait-loop spam
- `b098c32` — **always mash Confirm during skippable** (§B FIX)

### Replay popup + retry menu + delay
- `76471ba` — disable game's auto-replay-save popup
- `85f20a9` — allow Confirm during skippable to dismiss replay popup
- `c6ae0db` — detect replay-save popup via menu_state_counter
- `ce95d80` — reset menu_confirm_state when popup not showing (reverted by 01376d6)
- `0a57dad` — diag: log retry_menu counter/confirm state (temporary, removed)
- `01376d6` — **always set mcs=2 during retry_menu** (retry menu FIX)
- `bdad26e` — **host dictates delay** (delay mismatch FIX)

### Failed approaches (do not retry)
- Option 2 (`bdfbfe0`): lockstep loading → deadlocks on slow disk
- Option 1 commit 3/3 (`7338950`): remove chara_intro lockstep → massive divergence
- Input suppression during chara_intro (`620570f`): §A freeze returns

---

## How the User Tests

1. Build: `bash scripts/build-and-deploy.sh`
2. Open zzcaster.exe in the game folder
3. Test online with a friend OR localhost with 2 instances
4. Config: `defaultRollback=0` for delay mode, `defaultRollback=4` for rollback
5. Logs: `dll_<pid>.log` in `zzcaster/` next to MBAA.exe
6. Look for: `DESYNC detected`, `transition to`, `Round start`, `Round over`

---

## Notes for the Next Agent

1. **§C (end-of-round desync) is the current focus.** Read §C above carefully.
2. **Always verify against CCCaster** — clone is at `/home/z/my-project/CCCaster`.
3. **Always get BOTH peers' logs.** Compare frame-by-frame.
4. **Don't guess — confirm with logs.** The see-saw history (§A) shows guessing causes regressions.
5. **The user fala português.** Responda em português.
6. **SSH push works** with the paramiko shim. Don't try to install openssh-client.
7. **menuConfirmState hack is at `0x428F52`-`0x428F82`** — 5 patches, ported in `9749937`.
8. **Always-mash + lockstep** is the proven pattern for animation states. Don't remove lockstep.
9. **Loading cannot be lockstepped** — it's I/O-bound. Handle entry divergence by skipping the animation.
10. **auto-replay-save is disabled, not ported.** Don't try to port the full feature unless needed.
