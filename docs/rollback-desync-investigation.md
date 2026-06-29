# Rollback Desync Investigation — zzcaster vs CCCaster

## Summary

After fixing the delay-mode desync (intro-animation timing race), an intermittent desync remains in **rollback mode only**. Delay mode (rollback=0) now works correctly on localhost.

This document analyzes three suspect code paths in zzcaster's rollback implementation by comparing them against the CCCaster reference. The most significant finding: **CCCaster in RELEASE build does not detect desyncs at all in rollback mode** — it silently runs with divergent state if rollback fails to correct. This means zzcaster's "desync at frame 149" is exposing a real rollback bug that CCCaster hides.

---

## Revelation: CCCaster RELEASE has no desync detection in rollback mode

### Evidence

**Send side** (`DllMain.cpp:782-784`):
```cpp
if ( !netMan.isInRollback()                        // delay mode → true
        || ( netMan.getFrame() == 0 )              // frame 0 of any round
        || ( randomInputs && netMan.getFrame() % 150 == 149 ) )  // debug only
```

- `isInRollback()` = `isInGame() && config.rollback > 0 && isNetplay()` — checks if rollback is **enabled**, not if currently re-running
- `randomInputs` is defined in `#ifndef RELEASE` (`DllMain.cpp:178`), default `false`

**Receive side** (`DllMain.cpp:1432-1436`):
```cpp
#ifndef RELEASE
    case MsgType::SyncHash:
        remoteSync.push_back ( msg );
        return;
#endif // NOT RELEASE
```

The `SyncHash` message handler is **gated behind `#ifndef RELEASE`**. In RELEASE builds, the message is silently dropped — `remoteSync` never receives entries.

### Consequence

The comparison loop at `DllMain.cpp:793` (`while ( !localSync.empty() && !remoteSync.empty() )`) never iterates in RELEASE because `remoteSync` is always empty. **RELEASE builds of CCCaster cannot detect desyncs in any mode.** The `localSync` queue accumulates sent hashes but nothing compares them.

In DEBUG builds, detection exists but only fires at frame 0 of each round (the `getFrame() == 0` condition). A divergence at frame 5 that rollback fails to correct goes undetected until the next round's frame 0.

### Implication for zzcaster

**There is no "working CCCaster rollback" to use as a behavioral reference.** The question is not "why does zzcaster desync when CCCaster doesn't?" — CCCaster likely desyncs too, it just doesn't tell you. The real question is: **"why is zzcaster's rollback failing to correct divergences?"**

The zzcaster detects at frame 149 (or 300, whichever comes first), which is *better* than CCCaster's DEBUG-only frame-0-of-next-round detection. The desync log showing `camera_x` and `P1.x`/`P2.x` divergence with matching RNG is a real bug, not a false positive.

---

## Suspect 1: `rollback_min_frame_delay = 8` — silently drops early-frame mispredictions

### What zzcaster does

`netplay_manager.zig:193`:
```zig
const rollback_min_frame_delay: u32 = 8;
```

`netplay_manager.zig:2389-2404`:
```zig
// Don't rollback to early frames (0-7). The state at frame 0 may
// differ between peers because both peers enter in_game at slightly
// different absolute world_timer values. Rolling back to frame 0 or 1
// loads a divergent state → desync.
//
// However, we only skip the rollback — we do NOT clear the lcf.
// This means the misprediction is still tracked. On the next frame,
// if we're past the delay window, the rollback will fire and correct
// it. This prevents the "wrong RNG persists uncorrected" problem
// while still avoiding loading divergent early states.
if (lcf_frame < rollback_min_frame_delay)
{
    // Can't safely rollback to early frames — but DON'T clear lcf.
    // The misprediction will be corrected once we're past the delay.
    return false;
}
```

### What CCCaster does

`DllMain.cpp:592-594`:
```cpp
if ( netMan.isInRollback()
        && rollbackTimer == minRollbackSpacing
        && netMan.getLastChangedFrame().value < netMan.getIndexedFrame().value )
{
    // ... trigger rollback immediately, no frame-number guard ...
    if ( rollMan.loadState ( netMan.getLastChangedFrame(), netMan ) )
```

**CCCaster has NO `rollback_min_frame_delay` guard.** If a misprediction is detected at frame 3, CCCaster rolls back to frame 3 immediately.

### The bug

The comment in zzcaster claims: *"The misprediction will be corrected once we're past the delay."* **This is false.**

Here's why: `lcf_frame` is the frame where the misprediction was detected. It's a **fixed value** — it doesn't advance. The check is `lcf_frame < 8`. If `lcf_frame` is 5, this is true at frame 6, frame 7, frame 8, frame 100, forever. The rollback is **never** triggered for this misprediction.

The only way the misprediction gets "corrected" is if a *new* misprediction is detected at a later frame (`lcf_frame >= 8`), which would overwrite `last_changed_frame`. But if the early-frame misprediction is the only one, it persists uncorrected for the entire round.

### Why this matters

The first remote input arrives at `frame + delay` (typically frame 1-2 with delay=1). If the local peer predicted `remote_input = 0` (the default) and the actual input was non-zero, `setRemote` detects a change at frame 1-2. This is `lcf_frame < 8`, so the rollback is skipped. The misprediction propagates: the local peer simulated frame 1-7 with the wrong remote input, diverging from the remote peer.

In rollback mode this *should* be corrected by rolling back to frame 1 and re-simulating with the correct input. The `rollback_min_frame_delay` guard prevents this correction.

### Test to confirm

Add logging at the skip point:
```zig
if (lcf_frame < rollback_min_frame_delay) {
    self.log.warn("ROLLBACK SKIPPED: lcf_frame={d} < min={d} (current frame={d})", .{
        lcf_frame, rollback_min_frame_delay, self.indexed_frame.frame,
    });
    return false;
}
```

If you see this log line followed by a desync at frame 149, this is the cause.

### Fix options

1. **Remove the guard entirely** (match CCCaster). Risk: the comment about "state at frame 0 may differ between peers" suggests this was added to fix a real desync. Need to verify whether the race fix (commit `5a5c13c`) made this guard unnecessary.

2. **Clear `lcf` when skipping**, so the misprediction is "accepted" and the peer continues with the wrong state but doesn't trigger repeated rollback attempts. This is worse than option 1 (the divergence persists) but at least doesn't lie about "will be corrected later."

3. **Keep the guard but advance `lcf_frame` to `rollback_min_frame_delay`** when skipping, so the rollback fires on the next eligible frame. This corrects the misprediction at the cost of 1-7 frames of divergence.

**Recommendation:** Try option 1 first. The race fix should have eliminated the "state at frame 0 differs between peers" problem (that was the intro-animation-timing race). If the guard was added to work around that race, it's now obsolete.

---

## Suspect 2: State pool regions — appears complete

### What zzcaster saves

`rollback_regions.zig` defines:
- **Misc global state** (~50 regions): timers, RNG, intro state, camera position, camera scaling, super flash, effects array, etc.
- **4× player structs** (P1, P2, Puppet1, Puppet2): ~47 regions each, covering input history, sequences, health, meter, position, etc.
- **Effects array**: 1000 elements × 0x33C bytes as a single contiguous region
- **Effects pointer chain**: 3-level pointer dereference per effect (12 bytes each)

### What CCCaster saves

`tools/Generator.cpp` generates `rollback.bin` from the same source data:
- `miscAddrs` (line 175) — same addresses as zzcaster's `misc_addrs`
- `playerAddrs` (line 50) — same addresses as zzcaster's `player_addrs`
- `firstEffect` (line 291) — same pointer-chain structure

### Comparison

The region lists match. zzcaster's `rollback_regions.zig` was ported from the same `Generator.cpp` source. The addresses and sizes are identical.

**One potential gap:** CCCaster's `MemDump` supports nested pointer-following (`MemDumpPtr` chains). zzcaster handles this separately via `CC_EFFECT_PTR_DATA_SIZE` (the 12-byte pointer chain per effect). This appears equivalent but would need runtime verification to confirm the pointer dereferences produce the same bytes.

### Conclusion

**State pool regions are likely NOT the cause of the desync.** The region list matches CCCaster. If a region were missing, the desync would be consistent (always diverge on the same action), not intermittent.

---

## Suspect 3: `clearIntroStateDuringRollback` — runs outside re-runs

### What zzcaster does

`netplay_manager.zig:2464-2469`:
```zig
pub fn clearIntroStateDuringRollback(self: *NetplayManager) void {
    if (!self.isInRollback()) return;
    if (self.indexed_frame.frame <= pre_game_intro_frames) return;
    if (intro_state_addr.* == 0) return;
    intro_state_addr.* = 0;
}
```

`isInRollback()` (`netplay_manager.zig:1156-1161`):
```zig
pub fn isInRollback(self: *const NetplayManager) bool {
    if (self.config.is_spectator) return false;
    return self.isInGame() and self.config.rollback > 0 and self.config.is_netplay;
}
```

This returns `true` whenever rollback is **enabled** and we're in-game — not just during a re-run.

`dllmain.zig:838` calls this every frame:
```zig
n.clearIntroStateDuringRollback();
```

### What CCCaster does

`DllMain.cpp:974-976`:
```cpp
// Need to manually set the intro state to 0 during rollback
if ( netMan.isInRollback() && netMan.getFrame() > CC_PRE_GAME_INTRO_FRAMES && *CC_INTRO_STATE_ADDR )
    *CC_INTRO_STATE_ADDR = 0;
```

With `isInRollback()` = `isInGame() && config.rollback > 0 && isNetplay()` (`DllNetplayManager.hpp:79`).

### Comparison

**The behavior is identical.** Both implementations:
- Check `isInRollback()` (rollback enabled, not re-running)
- Check `frame > pre_game_intro_frames` (zzcaster uses `<=`, CCCaster uses `>` — equivalent)
- Force `intro_state = 0` if non-zero

This runs **every frame** in rollback mode, not just during re-runs. This is by design — the comment says it's needed because "a loaded state from before the intro finished may carry a non-zero intro flag." But since it runs every frame (not just after a load), it also clears `intro_state` during normal play if the game sets it for any reason after frame 224.

### Conclusion

**This is NOT a bug — it matches CCCaster exactly.** Both implementations have the same behavior. If this were causing desyncs, CCCaster would have the same problem.

However, note that `pre_game_intro_frames` (zzcaster) and `CC_PRE_GAME_INTRO_FRAMES` (CCCaster) should be the same value. Worth verifying they match.

---

## Suspect 4 (new): `clearLastChangedFrame` timing differs

### What zzcaster does

`frame_step.zig:106-113`:
```zig
// Per-frame clearLastChangedFrame (matches CCCaster's behavior).
if (n.rollback_timer == n.min_rollback_spacing) {
    n.remote_inputs.clearLastChanged();
}
```

This runs **before** `pollAndDispatch` (which receives new inputs).

### What CCCaster does

`DllMain.cpp:536-538`:
```cpp
// Clear the last changed frame before we get new inputs
if ( rollbackTimer == minRollbackSpacing )
    netMan.clearLastChangedFrame();
```

This runs **before** the `for (;;)` poll loop (which receives new inputs).

### Comparison

**Behaviorally equivalent.** Both clear `lcf` at the start of the frame, before receiving new inputs, when `rollback_timer` has reached `min_rollback_spacing`.

### Conclusion

NOT a bug. Matches CCCaster.

---

## Summary of findings

| Suspect | Verdict | Action |
|---|---|---|
| CCCaster has no desync detection in RELEASE | **Confirmed** | Reframes the problem — zzcaster's detection is correct, the rollback itself is broken |
| `rollback_min_frame_delay = 8` skips rollbacks | **Likely bug** | Remove the guard or test with logging |
| State pool regions incomplete | **Not the cause** | Regions match CCCaster |
| `clearIntroStateDuringRollback` runs outside re-runs | **Not a bug** | Matches CCCaster |
| `clearLastChangedFrame` timing | **Not a bug** | Matches CCCaster |

## Recommended next step

**Test Suspect 1.** Add logging to the `rollback_min_frame_delay` skip path and play a rollback match. If the log shows "ROLLBACK SKIPPED" before the desync, remove the guard and retest.

If removing the guard causes the "state at frame 0 differs" desync to return, that means the race fix (commit `5a5c13c`) didn't fully solve the intro-animation timing issue, and we need a different approach to early-frame safety.
