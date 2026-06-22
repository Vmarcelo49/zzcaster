# Air Dash Macro — Technical Design Document

**Issue:** Feature request — optional "Air Dash Macro" input transformation
**Status:** Design phase (not yet implemented)
**Date:** 2026-06-22

---

## 1. Executive Summary

**Feasibility: YES** — the feature is implementable with moderate complexity and low risk, provided it is placed correctly in the input pipeline and operates **before** inputs enter the rollback InputBuffer.

The macro detects `9AB` / `7AB` (up-forward + AB / up-back + AB) and replaces it with a 2-frame sequence: jump on frame N, then air-dash on frame N+1. The transformation happens at the `setLocalInput` boundary — after gamepad/keyboard polling but before inputs are stored in the InputBuffer / sent over the network.

**Key constraint:** The macro MUST run identically on both clients in netplay (or be disabled on both). If only one client has it enabled, the generated input sequence differs from what the remote predicts, causing rollback storms and visible desyncs.

**Estimated complexity:** Medium (1-2 days of implementation + testing)
**Risk level:** Low-Medium (rollback correctness is the main concern)

---

## 2. Current Input Pipeline Analysis

### 2.1 The input flow (per frame)

```
frameStep() [dllmain.zig]
  │
  ├─ Read raw input from gamepad/keyboard
  │   reader.readInput() or keyboard.readInput()
  │   → returns u16 (dir nibble + 12-bit button field)
  │
  ├─ Apply per-state filtering (netplay only)
  │   n.getNetplayInput(raw_input) → filtered u16
  │   (catch-up mash, mask Cancel, Confirm/Cancel-only, etc.)
  │
  ├─ Store local input WITH DELAY
  │   n.setLocalInput(local_input)
  │   → stores at frame = indexed_frame.frame + config.delay
  │   → goes into local_inputs InputBuffer (keyed by (index, frame))
  │
  ├─ Send to peer
  │   n.sendLocalInputs()
  │   → reads last 30 frames from local_inputs, sends as packet
  │
  ├─ Wait for remote input (lock-step)
  │   n.isRemoteInputReady() → blocks if remote behind
  │
  ├─ Rollback check
  │   n.checkRollback() → if remote input differs from prediction,
  │   load saved state and re-run frames
  │
  ├─ Save state for this frame
  │   n.state_pool.saveState(frame, index)
  │
  └─ Write both players' inputs to game memory
      n.writeGameInputs()
      → getLocalInput() / getRemoteInput() from InputBuffer
      → writeGameInput(player, input) → writes u16 to game memory
```

### 2.2 Critical timing invariant

**One `frameStep()` call = one game frame.** This is guaranteed by the world-timer gate at the top of `frameStep`:

```zig
const world_timer = world_timer_addr.*;
if (world_timer == last_world_timer) return;  // not a new frame yet
last_world_timer = world_timer;
```

This means the macro can reliably produce a 2-frame sequence: the first input is stored for the current frame, and the second input is stored for the next frame. Both go into the InputBuffer keyed by `(index, frame)`.

### 2.3 Input encoding

The combined `u16` input is `dir | (btns << 4)`:
- **dir** (bits 0-3): numpad notation (0=neutral, 2=down, 4=left, 6=right, 8=up, 9=up-right, 7=up-left)
- **btns** (bits 4-15): button field where `button_a=0x0010`, `button_b=0x0020`, `button_ab=0x0040`, etc.

So `9AB` in the combined u16 = `0x09 | (0x0040 << 4)` = `0x0900 | 0x0400` = `0x0D00`... wait, let me re-derive:

- dir = 9 (up-right) → bits 0-3 = 0x9
- btns = button_a | button_b | button_ab = 0x0010 | 0x0020 | 0x0040 = 0x0070
- combined = dir | (btns << 4) = 0x9 | (0x0070 << 4) = 0x9 | 0x0700 = **0x0709**

So `9AB` = `0x0709`, `7AB` = `0x0707`, `6AB` = `0x0706`, `4AB` = `0x0704`.

---

## 3. Proposed Implementation Location

### 3.1 The interception point

**Location:** Between `getNetplayInput()` (state filtering) and `setLocalInput()` (buffer storage).

```
raw_input
    │
    ▼
getNetplayInput() ──── per-state filtering (existing)
    │
    ▼
applyAirDashMacro() ──── NEW: macro transformation
    │                   (may store 1 or 2 inputs in the buffer)
    ▼
setLocalInput() ─────── stores into InputBuffer (existing)
    │
    ▼
sendLocalInputs() ───── sends to peer (existing)
```

### 3.2 Why this location?

1. **Before the InputBuffer:** The macro-generated inputs become the "source of truth" that gets stored, sent, and rolled back. The original `9AB` is never seen by the game or the network — only the expanded `9` + `6AB` sequence.

2. **After state filtering:** The macro only makes sense in `in_game` state. In chara-select/loading, the state filter already masks non-Confirm/Cancel buttons, so `9AB` would never reach the macro.

3. **Before network send:** Both clients see the same generated sequence. The macro output is what gets synchronized — there's no mismatch between "what I sent" and "what I stored locally."

4. **Before rollback state save:** When a rollback re-runs frames, it reads from the InputBuffer. Since the buffer already contains the expanded sequence, re-runs replay the same `9` + `6AB` — deterministic.

### 3.3 Why NOT other locations?

| Alternative location | Problem |
|---|---|
| Inside `readInput()` (gamepad.zig) | The gamepad reader doesn't know about frames or the InputBuffer. Can't produce a 2-frame sequence. |
| After `setLocalInput()` | The original `9AB` is already in the buffer. Overwriting it with `9` then needing `6AB` next frame requires complex buffer manipulation. |
| Inside `writeGameInput()` (game memory write) | The write happens at the END of frameStep, after rollback. The macro needs to inject the sequence at the START so both the buffer and the game see it. |
| In the DLL's `writeInput()` directly | This bypasses the InputBuffer entirely, so netplay and rollback wouldn't see the macro output — instant desync. |

---

## 4. Macro State Machine

### 4.1 States

```
                    ┌──────────┐
                    │  IDLE    │◄──────────────────────────┐
                    └────┬─────┘                            │
                         │ raw_input == 9AB or 7AB          │
                         │ AND macro enabled                │
                         ▼                                  │
                    ┌──────────┐                            │
                    │ FRAME_N  │ output = 9 (or 7)          │
                    │ (jump)   │ store at frame N           │
                    └────┬─────┘                            │
                         │ next frameStep call              │
                         ▼                                  │
                    ┌──────────┐                            │
                    │ FRAME_N1 │ output = 6AB (or 4AB)      │
                    │ (dash)   │ store at frame N+1         │
                    └────┬─────┘                            │
                         │ done                             │
                         └──────────────────────────────────┘
```

### 4.2 Per-player state

The macro needs per-player state (one state machine per local player). In offline Versus, P1 and P2 each need their own macro state. In netplay, only the local player needs it.

```zig
const MacroState = enum { idle, frame_n, frame_n1 };

const AirDashMacro = struct {
    enabled: bool = false,
    state: MacroState = .idle,
    // The dash direction to inject on frame N+1 (6 or 4).
    // Set when we detect 9AB (→6) or 7AB (→4).
    dash_dir: u8 = 0,

    fn reset(self: *AirDashMacro) void {
        self.state = .idle;
        self.dash_dir = 0;
    }
};
```

### 4.3 The transformation function

```zig
/// Called every frame with the raw (post-state-filter) input.
/// Returns the input to actually store for THIS frame.
/// If the macro is active (frame_n1 state), also stores the next
/// frame's input directly into the InputBuffer via setLocalInput.
fn applyAirDashMacro(
    macro: *AirDashMacro,
    nm: *NetplayManager,
    raw_input: u16,
) u16 {
    if (!macro.enabled) return raw_input;

    // Extract direction and buttons from the combined u16.
    const dir: u8 = @intCast(raw_input & 0x0F);
    const btns: u16 = (raw_input >> 4) & 0x0FFF;

    // Check for AB (A+B+A+B macro button) — button_ab = 0x0040,
    // but we also accept A+B pressed simultaneously (0x0010 | 0x0020 = 0x0030).
    const has_ab = (btns & 0x0040 != 0) or (btns & 0x0030 == 0x0030);
    const other_buttons = btns & ~@as(u16, 0x0070); // A, B, AB bits

    switch (macro.state) {
        .idle => {
            // Detect 9AB or 7AB
            if (has_ab and (dir == 9 or dir == 7) and other_buttons == 0) {
                macro.state = .frame_n;
                macro.dash_dir = if (dir == 9) 6 else 4;
                // Frame N: just the jump direction (9 or 7), no buttons.
                return @as(u16, dir);
            }
            return raw_input;
        },
        .frame_n => {
            // We're now on frame N+1. Inject the dash: dash_dir + AB.
            const dash_input = @as(u16, macro.dash_dir) | (0x0070 << 4); // dir + A+B+AB
            macro.state = .idle;
            macro.dash_dir = 0;
            return dash_input;
        },
        .frame_n1 => {
            // Should not reach here — frame_n1 transitions to idle in one step.
            macro.reset();
            return raw_input;
        },
    }
}
```

**Wait — there's a subtlety.** The macro needs to produce TWO inputs over TWO frames. But `setLocalInput` is called once per frame. So the flow is:

- **Frame N (IDLE → FRAME_N):** Macro detects `9AB`, returns `9` (just the jump). `setLocalInput(9)` stores it for frame N.
- **Frame N+1 (FRAME_N → IDLE):** Macro is in `frame_n` state, returns `6AB`. `setLocalInput(6AB)` stores it for frame N+1.

So the state names should be:

```zig
const MacroState = enum {
    idle,    // waiting for 9AB/7AB
    pending, // detected last frame, inject dash THIS frame
};
```

Revised:

```zig
fn applyAirDashMacro(macro: *AirDashMacro, raw_input: u16) u16 {
    if (!macro.enabled) return raw_input;

    // If we're in "pending" state, we MUST inject the dash this frame
    // regardless of what the player is currently pressing. The jump
    // already happened last frame; the dash is committed.
    if (macro.state == .pending) {
        const dash_input = @as(u16, macro.dash_dir) | (0x0070 << 4);
        macro.state = .idle;
        macro.dash_dir = 0;
        return dash_input;
    }

    // IDLE state: check for macro trigger.
    const dir: u8 = @intCast(raw_input & 0x0F);
    const btns: u16 = (raw_input >> 4) & 0x0FFF;
    const has_ab = (btns & 0x0040 != 0) or (btns & 0x0030 == 0x0030);
    const other_buttons = btns & ~@as(u16, 0x0070);

    if (has_ab and (dir == 9 or dir == 7) and other_buttons == 0) {
        macro.state = .pending;
        macro.dash_dir = if (dir == 9) 6 else 4;
        // Frame N: just the jump direction, no buttons.
        return @as(u16, dir);
    }

    return raw_input;
}
```

---

## 5. Rollback / Netplay Implications

### 5.1 Where the macro sits relative to rollback

```
                    ┌─────────────────────────┐
  raw_input ──────► │  Macro transformation   │ ────► InputBuffer ────► Network
                    │  (deterministic, local) │           │
                    └─────────────────────────┘           │
                                                          │
                                          ┌───────────────▼───────────────┐
                                          │  Rollback StatePool           │
                                          │  (saves/restores game memory) │
                                          │  reads from InputBuffer       │
                                          └───────────────────────────────┘
```

The macro runs **before** inputs enter the InputBuffer. This means:

1. **The expanded sequence (`9`, `6AB`) is what gets stored in the InputBuffer.** The original `9AB` is never stored.

2. **The expanded sequence is what gets sent over the network.** The remote peer receives `9` on frame N and `6AB` on frame N+1 — they never see `9AB`.

3. **Rollback re-runs read the expanded sequence from the buffer.** When a rollback loads a saved state and re-runs frames, it calls `getLocalInput()` / `getRemoteInput()` which read from the InputBuffer. The buffer contains `9` and `6AB`, so the re-run is deterministic.

### 5.2 Is the macro deterministic in rollback?

**YES** — because the macro output is stored in the InputBuffer BEFORE any rollback can happen. The macro state machine is:

- **Frame N:** IDLE → detects `9AB` → stores `9` in buffer → sets state to PENDING
- **Frame N+1:** PENDING → stores `6AB` in buffer → sets state to IDLE

If a rollback occurs at frame N+5 and re-runs frames N through N+4, it reads `9` and `6AB` from the buffer — the macro is NOT re-invoked during rollback. The macro state machine only runs forward, on new frames.

**Critical invariant:** The macro state (`pending`/`idle`) must NOT be rolled back. It's a forward-only state machine that tracks "did I just detect a macro trigger last frame." If we rolled back the macro state, we'd re-detect `9AB` on the re-run and produce a different sequence.

### 5.3 Must the macro be enabled on both clients?

**YES — for netplay.** Here's why:

| Scenario | Local (macro ON) | Remote (macro OFF) | Result |
|---|---|---|---|
| Frame N | Detects `9AB`, stores `9`, sends `9` to remote | Receives `9`, stores `9` | ✓ Both see `9` |
| Frame N+1 | PENDING, stores `6AB`, sends `6AB` | Player releases buttons, local polls `0` (neutral), stores `0`, sends `0` | ✗ Local has `6AB`, remote has `0` |

On frame N+1, the local player (macro ON) injects `6AB` from the macro state. The remote player (macro OFF) just polls their gamepad normally — if the local player released the buttons after frame N, the remote sees `0`. But the local buffer has `6AB`.

In netplay, the local player sends their `local_inputs` to the remote. So the remote receives `6AB` for frame N+1 and stores it in `remote_inputs`. The remote's game then reads `6AB` for the local player. **This actually works!** — because the remote doesn't need to run the macro; it just receives the already-expanded sequence.

**Wait — but the remote also polls THEIR OWN gamepad.** The macro only affects the LOCAL player's input. The remote's own input is unchanged. So:

- **Local player's input:** Macro expands `9AB` → `9` + `6AB`. This is stored in `local_inputs` and sent to remote. Remote stores it in `remote_inputs`. Both sides see the same sequence. ✓
- **Remote player's input:** Remote polls their own gamepad, stores in their `local_inputs`, sends to local. Local stores in `remote_inputs`. Macro doesn't touch remote input. ✓

**Conclusion: The macro only needs to be enabled on the local client.** The expanded sequence is what gets sent over the network, so the remote sees the same inputs regardless of whether they have the macro enabled.

**BUT** — if BOTH clients have the macro enabled and BOTH players press `9AB` on the same frame, both expand to `9` + `6AB` independently. This is fine — each client runs the macro on their own local input only.

### 5.4 Desync risk analysis

| Risk | Likelihood | Mitigation |
|---|---|---|
| Macro state not reset on round transition | Medium | Reset macro state in `onStateTransition` / `onEnterInGame` |
| Macro triggers during chara-select (where `9AB` means nothing) | Low | State filter already masks non-Confirm buttons in chara-select; macro also checks `state == .in_game` |
| Player holds `9AB` for 3+ frames | Medium | Macro only triggers on the IDLE→PENDING transition; holding produces `9`, `6AB`, then raw input for subsequent frames |
| Rollback re-invokes macro | None | Macro runs before InputBuffer; rollback reads from buffer, not from macro |
| Input delay interacts with macro timing | Low | Macro operates on raw input before delay is applied; the 2-frame sequence is stored at `frame+delay` and `frame+1+delay` — consistent |

### 5.5 Recommendation for netplay

- **Allow asymmetric enable:** Local player can enable macro independently. The expanded sequence is sent to remote, so no client-side requirement.
- **Log macro triggers:** When macro fires, log `"AirDashMacro: 9AB → 9 + 6AB at frame N"` for debugging.
- **Reset on state transition:** Clear macro state when entering `in_game` (round start) to avoid stale PENDING state from a previous round.

---

## 6. Edge Cases and Failure Scenarios

### 6.1 Player holds 9AB for multiple frames

```
Frame N:   raw=9AB → macro IDLE→PENDING, output=9
Frame N+1: raw=9AB → macro PENDING→IDLE, output=6AB
Frame N+2: raw=9AB → macro IDLE→PENDING, output=9    ← another macro trigger!
Frame N+3: raw=9AB → macro PENDING→IDLE, output=6AB
```

This is **correct behavior** — holding `9AB` produces repeated jump→dash sequences. The player gets alternating jumps and dashes. This matches the physical input (they're holding the buttons).

**Concern:** Is this what the player wants? If they want a single dash after one jump, they should release after frame N. The macro faithfully translates "holding 9AB" into "repeated jump-dash cycles."

### 6.2 Player presses 9AB then releases immediately

```
Frame N:   raw=9AB → macro IDLE→PENDING, output=9
Frame N+1: raw=0    → macro PENDING→IDLE, output=6AB  ← dash still fires
```

**This is correct.** The macro commits to the dash on frame N+1 regardless of whether the player is still holding the buttons. The jump already happened; the dash must follow. This matches the spec: "The order is critical. The feature must never send the dash before the jump."

### 6.3 Player presses 9AB then 7AB on the next frame

```
Frame N:   raw=9AB → macro IDLE→PENDING, dash_dir=6, output=9
Frame N+1: raw=7AB → macro PENDING→IDLE, output=6AB    ← forward dash, not back dash
```

The macro ignores frame N+1's input because it's committed to the forward dash from frame N. The `7AB` on frame N+1 is lost. **This is the correct behavior** — once the macro commits, it must complete the sequence. The player's frame N+1 input is only seen if they press it again on frame N+2 (when macro is back in IDLE).

### 6.4 SOCD conflict (9AB with both left and right)

The input pipeline applies SOCD resolution in `readInputMapped` / `readInput` BEFORE the macro sees the input. So if the player presses left+right+up+AB, SOCD cancels left+right (depending on `socd_mode`), leaving just up+AB = `8AB`. The macro checks for `dir == 9 or dir == 7`, so `8AB` doesn't trigger the macro. **No issue.**

### 6.5 Macro triggers during rollback re-run

**Cannot happen.** The macro only runs in the forward `frameStep` path, before `setLocalInput`. During a rollback re-run, `frameStep` reads from the InputBuffer (which already contains the expanded sequence). The macro state machine is not invoked during re-run.

### 6.6 Macro state survives across rounds

If a round ends while macro is in PENDING state (e.g., player pressed `9AB` on the last frame of a round), the next round would start with PENDING state, injecting a spurious `6AB` on frame 0 of the new round.

**Fix:** Reset macro state in `onStateTransition` when entering `in_game`:

```zig
fn onEnterInGame(self: *NetplayManager) void {
    // ... existing code ...
    if (self.air_dash_macro) |*m| m.reset();
}
```

### 6.7 Input delay > 0

The macro stores inputs at `frame + delay`. So if delay=2:

```
Frame N (real time): macro detects 9AB, stores 9 at frame N+2
Frame N+1 (real time): macro PENDING, stores 6AB at frame N+3
```

The game reads inputs from the buffer at the current frame. So the game sees `9` on frame N+2 and `6AB` on frame N+3. The 2-frame sequence is preserved, just shifted by the delay. **No issue.**

### 6.8 Spectator mode

Spectators don't read local input — they receive BothInputs from the host. The macro should NOT run in spectator mode. Add a guard:

```zig
if (n.config.is_spectator) return raw_input;
```

---

## 7. Configuration

### 7.1 Per-player setting

Add `air_dash_macro: bool = false` to `ControllerMapping` in `controller_mapper.zig`:

```zig
pub const ControllerMapping = struct {
    // ... existing fields ...
    air_dash_macro: bool = false, // disabled by default
};
```

This allows P1 and P2 to toggle independently. The setting is saved/loaded in `mapping.ini` alongside the other per-player config:

```ini
[Player1]
device=0
a=btn:2
b=btn:3
...
air_dash_macro=1
```

### 7.2 UI

Add a checkbox in the controller mapper UI (both grid view and list view):

```
[ ] Enable Air Dash Macro (9AB/7AB → jump + dash)
```

Place it near the SOCD radio buttons and deadzone slider — it's a per-player input option.

### 7.3 DLL-side config loading

The DLL loads `mapping.ini` in `applyPostLoadHacks` / `initSdlOnMainThread`. The `air_dash_macro` flag is read into `ControllerMapping` and passed to the `AirDashMacro` struct in the `NetplayManager` (or a standalone per-player struct in `dllmain.zig` for offline mode).

---

## 8. Implementation Plan

### Phase 1: Core macro logic (offline only)
1. Add `AirDashMacro` struct to a new file `src/air_dash_macro.zig`
2. Add `air_dash_macro: bool = false` to `ControllerMapping`
3. Add `air_dash_macro` serialization to `saveMapping` / `loadMapping`
4. In `dllmain.zig` offline branch: instantiate per-player macro state, call `applyAirDashMacro` before `writeInput`
5. Add checkbox to UI (grid view + list view)
6. Test: offline training mode, verify `9AB` produces jump→dash

### Phase 2: Netplay integration
7. In `netplay_manager.zig`: add `AirDashMacro` field to `NetplayManager` for the local player
8. In `frameStep` netplay branch: call `applyAirDashMacro` between `getNetplayInput` and `setLocalInput`
9. Reset macro state in `onEnterInGame` and `onStateTransition`
10. Test: netplay with macro enabled on one client, disabled on other — verify no desync

### Phase 3: Polish
11. Log macro triggers for debugging
12. Add guard: macro only runs in `.in_game` state
13. Add guard: macro doesn't run in spectator mode
14. Documentation: update README with macro usage

### Estimated effort
- Phase 1: 4-6 hours (core logic + offline test)
- Phase 2: 2-3 hours (netplay integration + test)
- Phase 3: 1-2 hours (polish + docs)
- **Total: 1-2 days**

---

## 9. Complexity and Risk Assessment

| Dimension | Rating | Notes |
|---|---|---|
| **Implementation complexity** | Medium | State machine is simple; integration with existing pipeline requires care |
| **Rollback risk** | Low | Macro runs before InputBuffer; rollback reads from buffer, not macro |
| **Netplay desync risk** | Low | Expanded sequence is sent to remote; no client-side requirement |
| **UX risk** | Low-Medium | Holding 9AB produces repeated dash cycles; may surprise players |
| **Testing difficulty** | Medium | Need to test offline, netplay, rollback, and edge cases (holding, direction change) |

### Key risks to watch:
1. **Macro state not resetting on round transition** → spurious dash at round start. Mitigated by reset in `onEnterInGame`.
2. **Player expectation mismatch** → holding 9AB produces repeated dashes. Mitigated by documentation; behavior matches physical input.
3. **Interaction with input delay** → the 2-frame sequence is shifted by delay but preserved. No issue, but worth testing with delay=2+.

---

## 10. Summary of Recommendations

1. **Implement the feature.** It's feasible, low-risk, and the pipeline supports it naturally.

2. **Place the macro between `getNetplayInput()` and `setLocalInput()`.** This is the correct interception point — before the InputBuffer, before network send, before rollback state save.

3. **Make it per-player and disabled by default.** Add `air_dash_macro: bool` to `ControllerMapping`, serialize in `mapping.ini`, toggle via UI checkbox.

4. **No requirement for both clients to enable it.** The expanded sequence is sent over the network, so the remote sees the same inputs regardless.

5. **Reset macro state on round transitions.** Prevents stale PENDING state from leaking into the next round.

6. **Log macro triggers.** Essential for debugging desync reports.

7. **Test with rollback.** Verify that a rollback re-run produces the same sequence as the original run.
