# Rollback Improvement Plan

## Context

The post-rollback RNG desync was fixed in PR #31 (`matching-cccaster-rollback`),
merged to main as `0ebc38e`. The fix addressed 4 HIGH/MEDIUM differences
between CCCaster and zzcaster:

- **Fix A:** FPU register-pointer addressing (ldmxcsr crash)
- **Fix B:** Restore `netplay_state` + `start_world_time` after rollback
- **Fix C:** Stop saving state during re-run frames
- **Fix D:** Per-frame `clearLastChangedFrame`

The desync is gone. Netplay works. This plan covers the remaining
LOW-priority differences for full CCCaster parity and rollback hardening.

## Principles

1. **One change per commit** — each improvement is independently testable
   and revertable.
2. **Test after each** — build + run a netplay match after every commit.
   If a change introduces a regression, revert it immediately.
3. **Match CCCaster exactly** — when in doubt, do what CCCaster does.
4. **No diagnostic logging** — this branch stays clean. If we need to
   debug, we branch off temporarily.

## Incremental Changes (in priority order)

### Change 1: Effects pointer-followed chain

**What:** Port CCCaster's 3-level pointer-deref chain for the effects
array. CCCaster saves 12 extra bytes per effect (12,000 bytes total per
snapshot) by following `*(effect+0x320)+0x38 → +0 → +0`. zzcaster saves
only the flat `0x33C`-byte struct.

**Why:** This is the biggest remaining gap. It's latent now (no desync
in testing), but if any effect has a non-NULL pointer at offset `0x320`
during a rollback, the dereferenced target state diverges between peers
after load.

**Files:**
- `src/dll/rollback.zig` — add effects pointer-following to `saveState`
  and `loadState` (handle effects specially, not via `[]Region`)
- `src/dll/rollback_regions.zig` — document the gap

**Effort:** ~50 LOC + `state_size` recalculation

**Test:** Run a match with heavy effects usage (supers, projectiles).
If no desync after multiple rollbacks, the fix is correct.

---

### Change 2: SFX dedup iteration range

**What:** Align the SFX dedup filter iteration with CCCaster. zzcaster
iterates `[loaded_frame, current_frame]` inclusive; CCCaster iterates
`(loaded_frame, current_frame)` exclusive.

**Why:** The inclusive iteration OR's in the loaded frame's and current
frame's SFX snapshots, which CCCaster deliberately skips. Audio-only —
no RNG impact — but eliminates a known divergence.

**Files:**
- `src/dll/sfx_dedup.zig` — `applyRollbackFilter` loop bounds

**Effort:** 2 lines

**Test:** Listen for duplicate/missing sounds during rollback. Should
match CCCaster's behavior.

---

### Change 3: MXCSR status flags

**What:** Restore the full MXCSR value (including status flags bits 0-5)
instead of masking with `0xFFC0`.

**Why:** CCCaster's `fesetenv` loads the full MXCSR. zzcaster masks off
the exception status flags. If the game reads MXCSR status flags, the
re-run would see different values. Low risk, but a known divergence.

**Files:**
- `src/dll/rollback.zig` — `restoreFpu`, remove `& 0xFFC0` mask

**Effort:** 1 character change

**Test:** Run a match and verify no `#GP` crash (the original reason
for the mask was the `m` constraint codegen bug, which is now fixed by
register-pointer addressing — the mask should no longer be needed).

---

### Change 4: RepRound input history rewind

**What:** Walk `CC_REPROUND_TBL_ENDPTR_ADDR` and decrement/remove
`RepInputState` entries for each rolled-back frame, matching CCCaster's
logic in `DllRollbackManager::loadState` (lines 158-203).

**Why:** The game's internal replay buffer grows during the re-run.
Without rewinding, a second rollback or a replay save would have
duplicate/corrupt entries. Unlikely to affect RNG, but it's a
correctness gap.

**Files:**
- `src/dll/netplay_manager.zig` — `checkRollback`, after `loadStateForFrame`
- May need `RepRound`/`RepInputContainer`/`RepInputState` struct definitions

**Effort:** ~40 LOC

**Test:** Save a replay after a rollback-heavy match and verify it
plays back correctly.

---

### Change 5: Use rollbackDelay during rollback

**What:** In `setLocalInput`, use `config.rollback_delay` when
`isInRollback()` and `config.delay` otherwise, matching CCCaster's
`getDelay()`.

**Why:** In standard netplay, `delay == rollback_delay`, so this is a
no-op. But for correctness (and to support future split-delay modes),
it should match CCCaster.

**Files:**
- `src/dll/netplay_manager.zig` — `setLocalInput`

**Effort:** 2 lines

**Test:** No behavior change in standard netplay. Only matters if
`delay != rollback_delay` is ever configured.

---

## Out of scope (not planned)

- Time-sync sleep investigation — the sleep is cooperative and shouldn't
  affect RNG. Leave as-is.
- Checksum improvements — the current RNG-only checksum works. Could
  revisit if false negatives become an issue.
- Relay/NAT traversal for CLI mode — feature request, not a rollback fix.

## Testing checklist (after each change)

- [ ] `zig build test --summary all` passes
- [ ] `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast` succeeds
- [ ] Run a netplay match on localhost (host + client)
- [ ] Reach gameplay, trigger at least one rollback (move during prediction window)
- [ ] Verify no desync force-close
- [ ] Verify no visual glitches (character teleporting, wrong states)
