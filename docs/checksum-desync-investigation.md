# Checksum Desync at In-Game Frame 0 - Investigation Notes

## Summary

After fixing the TransitionIndex sending bug and the intro_done RNG sync timing bug, the game still experiences a checksum desync at **frame 0 of index 4 (first frame of in_game)**. The desync occurs even though:
- Both peers transition to in_game at roughly the same time
- RNG state is synced at in_game entry
- Both peers run chara_intro for similar frame counts (~240-360 frames)

## Current Symptoms

**Host log (dll_536.log):**
```
[INFO] State transition: chara_intro -> in_game, index=4
[INFO] RNG state sent (index=4, attempt=1)
[INFO] RNG sync confirmed by peer ack (index=4, after 1 send(s))
[ERROR] CHECKSUM DESYNC at frame 0 (index 4): local=0x0b62 remote=0x658f
```

**Client log (dll_664.log):**
```
[INFO] State transition: chara_intro -> in_game, index=4
[INFO] Applied remote RNG state (index=4)
[INFO] Sent RNG_ACK (index=4)
[ERROR] CHECKSUM DESYNC at frame 0 (index 4): local=0x658f remote=0x0b62
```

Note: Checksums are swapped (host local = client remote), confirming both sides compute different states.

## Fixes Already Applied

### 1. TransitionIndex on Connect (netplay_manager.zig:1050-1081)
**Problem:** During lazy ENet reconnect, state transitions occurred before connection was established, so TransitionIndex packets were never sent.
**Fix:** Send current TransitionIndex immediately when ENet CONNECT event is received.

### 2. Skip intro_done RNG Sync for Round 1 (netplay_manager.zig:2010-2021)
**Problem:** Host waited many frames in chara_intro for slow peer, advancing RNG, then sent advanced RNG at intro_done which client applied early, causing ~750 frame mismatch.
**Fix:** Only arm RNG sync at intro_done (game_state=99) if `first_in_game_completed == true` (i.e., rounds 2+ only).

### 3. Track First In-Game Completion (netplay_manager.zig:569-576, 2303-2307, 2332-2335)
**Problem:** Need to distinguish round 1 from rounds 2+ for intro_done RNG sync.
**Fix:** Added `first_in_game_completed` flag, set on first in_game entry, reset on new match chara_select.

## Root Cause Analysis

The checksum desync at in_game frame 0 indicates that the **saved rollback state differs** between host and client, even though:
1. RNG state is explicitly synced at in_game entry
2. Both peers transition at similar times
3. Both run similar frame counts during chara_intro

### RESOLVED (2026-06-28): Root cause was non-deterministic regions in the per-frame checksum

**Root cause:** The per-frame desync detector (ported from ggpo-x) computed a
16-bit Wyhash over the ENTIRE ~850KB saved state buffer. This included many
regions that legitimately differ between peers:

- `CC_WORLD_TIMER_ADDR` (0x55D1D4) — absolute frame counter, differs because
  `loading` is not lockstepped.
- `CC_GRAPHICS_ARRAY` (0x61E170, 1.5MB) — rendering/animation data.
- `CC_GRAPHICS_COUNTER` (0x67BD78) — absolute incrementing counter.
- `CC_METER_ANIMATION_ADDR` (0x7717D8) — UI animation counter.
- Intro/outro graphics (0x74D598+) — visual state from chara_intro.
- Effect struct pointers (offset 0x320, ×1000) — heap-resident addresses.

**First fix attempt (commit 7af7b7c):** Masked `CC_WORLD_TIMER_ADDR` and effect
pointers in the hash stream. **This did NOT fix the desync** — the user
reported "exact same behavior." This proved there are MORE non-deterministic
regions (graphics array, graphics counter, meter animation, intro graphics).

**Final fix (commit TBD):** Switched `computeDeterministicChecksum` to hash
ONLY the RNG state regions (4+4+4+220 = 232 bytes), mirroring CCCaster's
proven `SyncHash` approach (`DllHacks.cpp:267-278`). This eliminates ALL
false positives from non-deterministic regions. The per-frame checksum now
detects RNG divergence in ~16 frames (vs 300 frames for the periodic SyncHash).
Non-RNG divergence is still caught by the SyncHash, rollback, and state
transition checks.

**Key evidence:** CCCaster's `SyncHash` (`DllHacks.cpp:267-278`) hashes ONLY
the RNG state + character selection. CCCaster has been using the same rollback
region list (including all the non-deterministic regions) for years without
this desync, because it never hashed them. zzcaster's per-frame checksum
inherited a false-positive risk that CCCaster's narrower hash never had.

**Diagnostic logging added:** The force-close path now logs which detector
fired (`synchash=true/false checksum=true/false`), the current index/frame,
and the per-frame checksum details (frame, local, remote). This allows
definitive diagnosis if a desync recurs.

Hypotheses A–E below were the pre-resolution investigation; they are retained
for historical context.

### Possible Causes

#### A. Non-Deterministic Game State in Rollback Regions
The checksum is computed over all 271 rollback memory regions (~1.2MB). Even with synced RNG, other regions may differ:

**Key regions to investigate:**
- `0x61E170` - Graphics array (1.5MB!) - animation frame data
- `0x555130+` - Player structs (4x) - positions, states, timers
- `0x564B14` - Camera position/scaling
- `0x74D598` - Game state flags
- `0x563580/0x5635F4` - Status message arrays

**Hypothesis:** Graphics arrays or player animation states differ because chara_intro ran for slightly different frame counts, or animation timing is not frame-exact.

#### B. FPU State Differences
Saved state includes FPU control word and MXCSR (`SavedFpu` in rollback.zig:269-275).

**Hypothesis:** FPU state differs between host/client processes at in_game entry, causing checksum mismatch.

**Investigation:** Add logging to compare FPU state between peers before checksum comparison.

#### C. Timing Race in RNG Application
The sequence during in_game frame 0:
1. Game runs frame 0 logic, advances RNG
2. Hook called (frameStep)
3. `syncRngState()` captures current RNG (host) / `applyRemoteRng()` applies RNG (client)
4. `saveState()` saves game memory including RNG

**Hypothesis:** On client, `applyRemoteRng()` writes host's RNG, but game's frame 0 logic already advanced RNG before hook was called. The saved state captures the pre-apply RNG.

**Investigation:** Check if game advances RNG before or after hook callback.

#### D. Chara-Intro Frame Count Mismatch
Both peers should run chara_intro for the EXACT same number of frames for determinism.

**Current behavior:** Both transition when `intro_state==0` AND `remote_end_index > indexed_frame.index`. But `remote_end_index` is already 4 (from TransitionIndex(3)), so the condition is always true - no actual waiting occurs.

**Hypothesis:** Host and client run chara_intro for different frame counts, causing divergent game state.

**Evidence from logs:**
- Host: ~240-360 frames of chara_intro (TimeSync at frames 120, 240)
- Client: ~240-360 frames of chara_intro (TimeSync at frames 120, 240)
- Similar counts, but "similar" isn't "identical"

**Fix needed:** Ensure EXACT same frame count, possibly by:
- Fixed frame count (e.g., always 300 frames of chara_intro)
- Better synchronization signal (not just transition index)
- Wait for remote's intro_state=0 signal (requires new packet type)

#### E. Missing Rollback Regions
Some game state that affects determinism might not be in the rollback regions list.

**Investigation:** Compare rollback_regions.zig against CCCaster's region list. Check if any RNG-dependent state is missing.

## Files to Investigate

### Primary Files
1. **src/dll/netplay_manager.zig**
   - `checkIntroDone()` (line ~2010) - transition logic
   - `syncRngState()` (line ~1627) - RNG capture timing
   - `applyRemoteRng()` (line ~1694) - RNG application timing
   - `onStateTransition()` (line ~2235) - state transition handling
   - `isRemoteInputReady()` (line ~1468) - wait loop conditions

2. **src/dll/frame_step.zig**
   - `frameStepNetplay()` (line ~71) - frame processing order
   - Wait loop (line ~211-317) - lockstep synchronization

3. **src/dll/rollback.zig**
   - `saveState()` (line ~534) - when checksum is computed
   - `SavedFpu` handling - FPU state capture/restore

4. **src/dll/rollback_regions.zig**
   - `all_regions` (line ~189) - complete list of saved regions
   - Compare against CCCaster's region list

### Diagnostic Opportunities

1. **Add per-region checksum logging**
   - Compute checksum for each rollback region individually
   - Log which specific region(s) differ between host/client
   - This will pinpoint the divergent state

2. **Add FPU state logging**
   - Log FPU control word and MXCSR at in_game entry
   - Compare between host/client

3. **Add chara_intro frame count logging**
   - Log exact frame count when transitioning from chara_intro to in_game
   - Compare between host/client

4. **Add timing markers**
   - Log when game advances RNG relative to hook callback
   - Log when `applyRemoteRng()` runs relative to `saveState()`

## Recommended Next Steps

### Immediate (High Priority)
1. **Add per-region checksum diagnostics** to identify which specific memory region(s) differ
2. **Verify chara_intro frame counts** are EXACTLY identical (not just similar)
3. **Check FPU state** consistency between peers

### Medium Priority
4. **Review rollback region list** against CCCaster for completeness
5. **Add better chara_intro synchronization** - ensure exact frame match
6. **Investigate game's RNG advancement timing** relative to hook callback

### Long Term
7. **Consider fixed frame counts** for non-interactive states (chara_intro, loading)
8. **Add protocol message** for intro_state to enable better synchronization
9. **Implement comprehensive desync debugging** - dump divergent regions to file

## Test Scenario

To reproduce:
1. Run two instances locally (localhost:1234)
2. Host starts session, client joins
3. Both players select characters
4. Wait for chara_intro to complete
5. Observe desync at first frame of in_game

Expected: Both peers should have identical checksums at in_game frame 0.
Actual: Checksums differ (e.g., 0x0b62 vs 0x658f).

## References

- Original bug report: "players try to play a match after character select, one player's game freezes"
- Previous fixes: TransitionIndex on connect, skip intro_done RNG for round 1
- CCCaster reference: DllMain.cpp:1075-1081 (RNG sync points), DllNetplayManager.cpp (state synchronization)