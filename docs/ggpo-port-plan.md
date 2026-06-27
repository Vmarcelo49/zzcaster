# GGPO-x Port Plan for zzcaster

**Branch**: `feature/ggpo-port`
**Status**: Planning
**Author**: vmarcelo49
**Created**: 2026-06-27

---

## Executive Summary

This document is the implementation plan for porting the most impactful improvements from the `thomashenry79/ggpo-x` fork (an actively maintained fork of `pond3r/ggpo`) into zzcaster's hand-made rollback netcode.

zzcaster's rollback was ported from CCCaster, which predates GGPO's mature iteration cycle. The ggpo-x fork accumulated 6 years of battle-tested improvements over the original GGPO: per-frame desync detection, smoothed RTT, ping-aware time-sync, larger ring buffers, and an architectural cleanup that moves input delay out of the rollback core.

We are **not** replacing zzcaster's rollback with GGPO — zzcaster's design has MBAACC-specific strengths (RNG sync, coalesced memory regions, FPU control-word-only save, indexed-frame coordinates, TransitionIndex packets) that GGPO doesn't have and that must be preserved. Instead, we are cherry-picking the ggpo-x ideas that improve zzcaster's weak spots: desync detection latency, time-sync, and packet-loss resilience.

### Expected outcomes

| Metric | Current | Target | How |
|--------|---------|--------|-----|
| Desync detection latency | up to 300 frames (5s) | ~16-20 frames (~280ms) | Per-frame checksums piggybacked on input packets |
| Ping measurement | none | EMA-smoothed, 10s window | Read ENet's `roundTripTime`, apply EMA |
| Frame advantage estimation | none (pure lockstep) | ping-aware float estimate | `last_received + (rtt/2)*fps + 0.5` |
| Cooperative time-sync | none | GGPO-style `recommendFrameWait` | Float frame advantage, symmetric formula |
| Input history depth | unbounded (grows over match) | bounded + discardable | `discardConfirmedFrames` + ring sizing |
| Connection issue warning | 120s heartbeat timeout | immediate `NetworkError` event | Surface ENet send failures |

### What we are NOT doing

- **Not** replacing zzcaster's `InputBuffer` (hashmap) with GGPO's `InputQueue` (fixed ring). zzcaster's design handles MBAACC's round transitions cleanly.
- **Not** removing zzcaster's RNG sync protocol. MBAACC needs it; GGPO's "deterministic from frame 0" assumption doesn't hold.
- **Not** removing zzcaster's `SyncHash`. It stays as a diagnostic fallback with richer field-level diffing. The per-frame checksum becomes the *primary* detector.
- **Not** moving input delay out of the rollback core in this port. That's a high-effort architectural refactor (Idea 5) — filed as a future milestone, not part of this branch.

---

## Current State Assessment

### zzcaster's rollback today

**Wire protocol** (application-level, on top of ENet):
| Type byte | Packet | Channel | Reliable | Cadence |
|-----------|--------|---------|----------|---------|
| `0x01` | PlayerInputs `[4 start_frame][4 index][N×2 inputs]` | 1 | no | every frame |
| `0x02` | RNG state `[4 index][4 rng0][4 rng1][4 rng2][220 rng3]` | 0 | yes | on round transition, re-sent every 30f until acked |
| `0x03` | TransitionIndex `[4 index]` | 0 | yes | on state transition |
| `0x04` | SyncHash `[136 body]` | 0 | yes | every 300f + at frame 149 of each 150-cycle |
| `0x05` | RNG_ACK `[4 index]` | 0 | yes | on receiving RNG state |
| `0x20` | BothInputs (spectator) `[4 start_frame][4 index][N×4 (p1:u16,p2:u16)]` | 0 | yes | host→spectator |

**Desync detection**: `SyncHash` captures a 136-byte snapshot (RNG MD5 + round_timer + real_timer + camera + per-player chara hashes) every 300 frames and at frame 149 of each 150-cycle. `checkSyncHashDesync()` compares paired local/remote hashes. Worst-case detection latency: 300 frames (5 seconds).

**RTT/ping**: none. `enet_transport.zig` exposes `peer.roundTripTime` in `getNetworkStats()` but `NetplayManager` never reads it.

**Time-sync**: none. Pure lockstep-with-rollback. No frame advantage computation, no cooperative sleep recommendation.

**Input buffer**: `InputBuffer` uses an unbounded `AutoHashMap(u64, u16)`. Inputs are never garbage-collected — memory grows over a long match. (Round transitions call `reset()` which clears everything, so per-round memory is bounded, but within a round it grows.)

**State pool**: 60 states (1 second at 60fps). Fixed ring with coalesced memory regions (~61 contiguous chunks after merging ~270 raw regions).

### zzcaster's strengths to preserve

1. **RNG sync protocol** — MBAACC's RNG is global state that diverges during chara-select (random character pick, preview animations). GGPO assumes determinism from frame 0; zzcaster can't. Keep `syncRngState`/`applyRemoteRng`/`confirmRngAck`.
2. **Coalesced memory regions** — `StatePool.coalesceRegions()` merges adjacent regions for faster `@memcpy`. GGPO uses a single flat buffer. Keep this.
3. **FPU control-word-only save** — `SavedFpu` saves only `cw + MXCSR`, avoiding the stale-TOP crash that `fldenv` would trigger. Battle-tested fix. Keep this.
4. **Indexed-frame `(index, frame)` coordinates** — cleanly separates inputs from different rounds. GGPO uses a flat frame counter. Keep this.
5. **TransitionIndex packet** — explicit round-transition notification. GGPO has no equivalent. Keep this.

---

## Phase 1 — Foundation: Per-frame Checksums + RTT Tracking (Ideas 1, 2, 8)

**Goal**: Fast desync detection (16-frame latency) + ping measurement foundation for later time-sync work.

**Branch milestone**: First PR on `feature/ggpo-port`.

### Idea 1: Per-frame checksums in input packets

#### Current state
`SyncHash` (136 bytes) sent every 300 frames. Detection latency up to 5 seconds.

#### Target state
Every input packet carries a `u16 checksum` for a frame old enough to be "confirmed" (no future rollback can change it). Receiver stores it; `checkChecksumDesync()` compares local vs remote every frame.

#### Why per-frame is better
1. **30x faster detection**: 16 frames (~280ms) vs 300 frames (5s).
2. **No extra packets**: checksum piggybacks on the input packet already sent every frame.
3. **Rollback-safe**: `CHECKSUM_DELAY = 16` ensures the checksummed frame is older than the max rollback window, so no rollback can invalidate it.
4. **Per-frame granularity**: you know exactly which frame desynced, not "somewhere in the last 5 seconds".

#### Wire format change

**Current input packet (type 0x01)**:
```
[1 type=0x01][4 start_frame][4 index][N×2 inputs]
```

**New input packet (type 0x01)**:
```
[1 type=0x01][4 start_frame][4 index][2 checksum][2 checksum_frame][N×2 inputs]
```

- `checksum`: u16 little-endian, the checksum of the saved state at frame `checksum_frame`.
- `checksum_frame`: u16 little-endian (sufficient — frames within a round rarely exceed 65535), the frame this checksum is for. Equals `start_frame - CHECKSUM_DELAY` (or 0xFFFF if no checksum available yet, e.g. first 16 frames of a round).

**Backward compatibility**: This is a breaking wire-protocol change. Both peers must run the new version. We bump the ENet connect_data protocol version (currently used to signal host/spectator/chara-select) so old clients reject new clients cleanly at the ENet CONNECT level. The launcher already validates peers before the DLL takes over, so this is low-risk in practice.

#### Checksum computation

The checksum covers the saved state buffer for a given frame. Two options:

**Option A (recommended): hash the saved StatePool buffer.**
- `StatePool.saveState()` already copies all coalesced regions into a contiguous buffer.
- After saving, compute `Wyhash.hash(0, buffer) & 0xFFFF` — a 16-bit checksum.
- Wyhash throughput is ~5 GB/s. The saved buffer is ~850KB (dominated by the 1000-element effects array). Per-frame cost: ~170μs. At 60fps that's ~1% of the frame budget — acceptable.
- Store the checksum alongside the saved state: add `checksum: u16` field to `SavedState`.

**Option B (cheaper): hash a representative subset.**
- Hash only RNG state (232 bytes) + player positions (32 bytes) + round timer (4 bytes) + camera (8 bytes) = ~280 bytes.
- Per-frame cost: ~0.06μs. Negligible.
- Risk: misses desyncs in regions NOT covered by the subset (e.g. effects array, super state). The existing SyncHash already covers a subset, so this is no worse.
- Trade-off: cheaper but less coverage.

**Decision**: Start with Option A (full buffer hash) for maximum coverage. If profiling shows the 170μs/frame is a problem, fall back to Option B. The StatePool already pays the `@memcpy` cost for the full buffer; adding a hash pass is a small marginal cost.

#### Storage

New fields on `NetplayManager`:
```zig
// Checksums for frames we've saved locally.
// Keyed by frame number (within current index). Cleared on state transition.
pending_checksums: std.AutoHashMap(u32, u16),    // frame -> checksum, awaiting confirmation
confirmed_checksums: std.AutoHashMap(u32, u16),  // frame -> checksum, old enough to compare

// Checksums received from the remote peer.
// Keyed by frame number (within current index). Cleared on state transition.
remote_checksums: std.AutoHashMap(u32, u16),
```

All three are cleared in `onStateTransition` (when `indexed_frame.index` increments) — checksums are per-round, not cross-round.

#### Send-side flow (`sendLocalInputs`)

```
1. Compute current_frame = indexed_frame.frame
2. checksum_frame = current_frame - CHECKSUM_DELAY
3. If checksum_frame >= 0 and pending_checksums has checksum_frame:
     checksum = pending_checksums.get(checksum_frame)
     Move to confirmed_checksums (it's now old enough to compare)
   Else:
     checksum = 0, checksum_frame = 0xFFFF (sentinel: "no checksum")
4. Build packet: [1 type][4 start_frame][4 index][2 checksum][2 checksum_frame][N×2 inputs]
5. sendInputs (unreliable, channel 1)
```

#### Receive-side flow (`setRemoteInputs`)

```
1. Parse: start_frame, index, checksum, checksum_frame, inputs[]
2. Apply inputs to remote_inputs (existing logic)
3. If checksum_frame != 0xFFFF:
     remote_checksums.put(checksum_frame, checksum)
```

#### Desync check (`checkChecksumDesync`)

Called every frame from `frameStepNetplay`, after `checkRollback`:
```
1. For each frame in remote_checksums:
     if confirmed_checksums has that frame:
       if confirmed_checksums[frame] != remote_checksums[frame]:
         log desync (frame, local checksum, remote checksum)
         set desync_detected = true
         return
2. Garbage-collect: remove entries from remote_checksums and confirmed_checksums
   for frames older than (current_frame - CHECKSUM_DELAY - 64) [keep a 64-frame window]
```

#### Where checksums get computed

In `frame_step.zig` `frameStepNetplay`, right after `state_pool.saveState(...)`:
```zig
_ = n.state_pool.saveState(n.indexed_frame.frame, n.indexed_frame.index);
// NEW: compute and store checksum for this frame
if (n.state_pool.saved_states.items.len > 0) {
    const last = n.state_pool.saved_states.items[n.state_pool.saved_states.items.len - 1];
    const cksum = @as(u16, @truncate(std.hash.Wyhash.hash(0, last.data)));
    n.pending_checksums.put(n.indexed_frame.frame, cksum) catch {};
}
```

During rollback re-run (`isRerunning()` path in `frameStepNetplay`), the same logic runs — re-simulated frames get new checksums that overwrite the old (wrong) ones in `pending_checksums`. This is correct: the re-run produces the authoritative state.

### Idea 2: RTT tracking via ENet + EMA

#### Current state
`enet_transport.zig:getNetworkStats()` reads `peer.roundTripTime` but `NetplayManager` never calls it. No ping measurement, no EMA.

#### Target state
`NetplayManager` reads `enet_peer.?.roundTripTime` every frame, applies an EMA (10-second window), and exposes `rttMs()` for use in Phase 2 (remote frame estimation).

#### Why EMA
ENet's `roundTripTime` is updated on every acknowledged reliable packet — it's already somewhat smoothed internally, but it still jitters. A 10-second EMA (matching ggpo-x's `emaPeriodMS = 10000`) gives a stable estimate that doesn't overreact to transient spikes.

#### Implementation

New fields on `NetplayManager`:
```zig
rtt_ema_ms: f64 = 0,           // smoothed round-trip time in milliseconds
rtt_ema_initialized: bool = false,
```

New constant:
```zig
const rtt_ema_period_ms: f64 = 10_000;  // 10s smoothing window
const rtt_ema_alpha: f64 = 2.0 / (1.0 + rtt_ema_period_ms / 16.6); // ~0.0033 per frame at 60fps
```

New method, called every frame from `frameStepNetplay` (after `pollAndDispatch`):
```zig
pub fn updateRttEma(self: *NetplayManager) void {
    if (self.enet_peer == null or !self.enet_connected) return;
    const instant = @as(f64, @floatFromInt(self.enet_peer.?.roundTripTime));
    if (!self.rtt_ema_initialized) {
        self.rtt_ema_ms = instant;
        self.rtt_ema_initialized = true;
    } else {
        self.rtt_ema_ms = instant * rtt_ema_alpha + self.rtt_ema_ms * (1.0 - rtt_ema_alpha);
    }
}

pub fn rttMs(self: *const NetplayManager) f64 {
    return self.rtt_ema_ms;
}
```

#### Why no new packets
ggpo-x implements its own `QualityReport`/`QualityReply` packet pair because it uses raw UDP and needs to measure RTT itself. zzcaster uses ENet, which already measures RTT internally via its reliable-channel ACK mechanism. We just read `peer.roundTripTime` — no new packets, no new wire format, zero additional network traffic.

### Idea 8: NetworkError event

#### Current state
`sendReliable` and `sendInputs` silently swallow send failures (the `if (packet != null)` guard). The only connection-issue signal is the 120-second heartbeat timeout.

#### Target state
Track send failures; expose a `networkError()` method that `frameStepNetplay` checks. On sustained failures (e.g. 10 consecutive send failures), log a warning and optionally surface to the UI.

#### Implementation

New fields on `NetplayManager`:
```zig
consecutive_send_failures: u32 = 0,
network_error: bool = false,
```

Modify `sendInputs` and `sendReliable`:
```zig
pub fn sendInputs(self: *NetplayManager, inputs: []const u8) void {
    if (self.enet_peer == null or !self.enet_connected) return;
    var tagged: [1 + 128]u8 = .{0x01} ++ .{0} ** 128;
    const copy_len = @min(inputs.len, tagged.len - 1);
    @memcpy(tagged[1..][0..copy_len], inputs[0..copy_len]);
    const packet = enet.enet_packet_create(&tagged, 1 + copy_len, 0);
    if (packet != null) {
        if (enet.enet_peer_send(self.enet_peer, 1, packet) < 0) {
            self.consecutive_send_failures += 1;
            if (self.consecutive_send_failures >= 10) self.network_error = true;
        } else {
            self.consecutive_send_failures = 0;
            self.network_error = false;
        }
        enet.enet_host_flush(self.enet_host);
    } else {
        self.consecutive_send_failures += 1;
        if (self.consecutive_send_failures >= 10) self.network_error = true;
    }
}
```

In `frameStepNetplay`, after `pollAndDispatch`:
```zig
if (n.network_error) {
    state.log.?.warn("Network send failures detected ({} consecutive)", .{n.consecutive_send_failures});
    // Don't force-exit — ENet will recover if the connection is just congested.
    // The heartbeat timeout (120s) handles true disconnects.
}
```

### Phase 1 testing

**Unit tests** (in a new `src/dll/ggpo_port_tests.zig`, imported from `test_simulation.zig`):
1. `test "checksum computation is deterministic"` — save a state, compute checksum, save again, verify same checksum.
2. `test "checksum detects state change"` — save state, modify a region, save again, verify different checksum.
3. `test "per-frame checksum send/receive round-trip"` — mock two peers, send input packet with checksum, verify receiver stores it correctly.
4. `test "checkChecksumDesync detects mismatch"` — inject a remote checksum that differs from local, verify `desync_detected` is set.
5. `test "checkChecksumDesync ignores frames not yet confirmed"` — send a checksum for a frame newer than `current - CHECKSUM_DELAY`, verify no false positive.
6. `test "RTT EMA converges"` — feed a sequence of RTT samples, verify EMA converges to the mean.
7. `test "RTT EMA smooths spikes"` — feed stable RTT then a spike, verify EMA barely moves.
8. `test "NetworkError trips after 10 failures"` — simulate 10 send failures, verify `network_error` is set.

**Integration tests** (extending `test_simulation.zig`'s MockPeer/MockNetwork):
9. `test "desync detected within 20 frames with per-frame checksums"` — inject a state divergence at frame X, verify desync detected by frame X + 16 + 4 (16 for CHECKSUM_DELAY, 4 for network transit).

**Manual playtest checklist** (post-merge):
- [ ] Two peers can connect and play a full match.
- [ ] Desync (forced by killing one peer's RNG) is detected within ~1 second.
- [ ] Ping displays correctly in any debug overlay.
- [ ] No regressions in rollback behavior.

### Phase 1 risks & mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Wire-protocol break strands old clients | Medium | Bump ENet connect_data protocol version; launcher already validates peers. |
| Checksum computation too slow (170μs/frame) | Low | Fall back to Option B (subset hash) if profiling shows >5% frame budget. |
| False-positive desyncs from checksum collisions | Low (1/65536 per frame) | Keep SyncHash as secondary check; only force-exit if BOTH disagree. |
| EMA alpha miscalibrated | Low | Make `rtt_ema_alpha` configurable via config; start with ggpo-x's value. |
| Rollback re-run produces different checksum than original | Medium | This is EXPECTED — the re-run overwrites the wrong checksum in `pending_checksums`. Document clearly. |

### Phase 1 files touched

| File | Changes |
|------|---------|
| `src/dll/netplay_manager.zig` | Add checksum maps, `CHECKSUM_DELAY`, `updateRttEma`, `rttMs`, `checkChecksumDesync`, `network_error` tracking; modify `sendLocalInputs`, `setRemoteInputs`, `handleMessage`, `onStateTransition`, `onEnterInGame` |
| `src/dll/rollback.zig` | Add `checksum: u16` field to `SavedState`; compute in `saveState` |
| `src/dll/frame_step.zig` | Call `updateRttEma`, `checkChecksumDesync` each frame; check `network_error` |
| `src/dll/ggpo_port_tests.zig` | New file: 8 unit tests |
| `src/dll/test_simulation.zig` | Import `ggpo_port_tests.zig` |
| `src/net/enet_transport.zig` | Expose `peer.roundTripTime` accessor (already exists in `getNetworkStats`, may need a direct getter) |

---

## Phase 2 — Time-Sync Layer (Ideas 3, 4)

**Goal**: Cooperative frame-rate adjustment so the faster peer slows down to let the slower peer catch up, reducing prediction load and rollback frequency.

**Branch milestone**: Second PR on `feature/ggpo-port`. Depends on Phase 1 (RTT EMA).

### Idea 3: Ping-aware remote frame estimation

#### Current state
`isRemoteInputReady()` uses `remote_inputs.getEndFrame()` — "where was the remote peer when they last sent a packet". This is stale by ~1 RTT.

#### Target state
Estimate the remote peer's current frame as `last_received_frame + (rtt_ms / 2) * fps / 1000 + 0.5`. This is "where the remote peer probably is right now, accounting for packets in flight".

#### Implementation

New method on `NetplayManager`:
```zig
pub fn remoteFrameEstimate(self: *const NetplayManager) f32 {
    if (self.remote_inputs.getEndIndex() == 0) return 0;
    const last_received = @as(f32, @floatFromInt(self.remote_inputs.getEndFrame(self.indexed_frame.index)));
    const single_trip_ms = self.rtt_ema_ms / 2.0;
    const single_trip_frames = single_trip_ms * 60.0 / 1000.0;
    return last_received + single_trip_frames + 0.5;
}

pub fn localFrameAdvantage(self: *const NetplayManager) f32 {
    return self.remoteFrameEstimate() - @as(f32, @floatFromInt(self.indexed_frame.frame));
}
```

#### Where it's used
- Phase 2 Idea 4 (recommend frame wait).
- Future: `isRemoteInputReady` could use this to allow more aggressive prediction when remote is estimated ahead. (Deferred — the current lockstep gate is safe; changing it risks new bugs.)

### Idea 4: Float frame advantage + symmetric recommendation

#### Current state
No frame advantage math, no sleep recommendation. Game runs at fixed 60fps regardless of peer alignment.

#### Target state
Every `RECOMMENDATION_INTERVAL = 120` frames, compute a `recommendFrameWait()` that tells the frame loop how many milliseconds to sleep. Matches ggpo-x's formula (float, symmetric, delay-aware).

#### Implementation

New constants (matching ggpo-x):
```zig
const recommendation_interval: u32 = 120;  // frames between recommendations
const max_frame_advantage: f32 = 30.0;     // max sleep/speedup in frames
const min_frame_advantage: f32 = 3.0;      // ignore drift below this
```

New method:
```zig
pub fn recommendFrameWaitMs(self: *const NetplayManager) i32 {
    const advantage = self.localFrameAdvantage();  // positive = we're behind, negative = ahead
    // Symmetric formula from ggpo-x: sleep_frames = -((radvantage + advantage) / 2)
    // But we only have local advantage (radvantage is the remote's view of us).
    // Approximate: if we're ahead (advantage < 0), recommend sleep; if behind, recommend 0.
    const sleep_frames = -advantage / 2.0;
    if (@abs(sleep_frames) < min_frame_advantage) return 0;
    const clamped = if (sleep_frames > 0)
        @min(sleep_frames, max_frame_advantage)
    else
        @max(sleep_frames, -max_frame_advantage);
    // Convert frames to milliseconds (negative = speed up = don't sleep)
    return @intFromFloat(clamped * (1000.0 / 60.0));
}
```

#### Where it's used

In `frameStepNetplay`, at the top of the frame (before reading input):
```zig
if (n.indexed_frame.frame % recommendation_interval == 0 and n.indexed_frame.frame > 0) {
    const wait_ms = n.recommendFrameWaitMs();
    if (wait_ms > 0) {
        std.Thread.sleep(@as(u64, @intCast(wait_ms)) * std.time.ns_per_ms);
    }
}
```

**Caveat**: MBAACC's frame loop is driven by the game's own vsync/timer, not by `frameStepNetplay`. We can't actually slow down the game's simulation — we can only delay our INPUT reading. This is a significant difference from ggpo-x's vectorwar sample, where the app owns the frame loop.

**Realistic scope for zzcaster**: Use `recommendFrameWaitMs` as a diagnostic only — log it, display in the debug overlay, but don't actually sleep. True cooperative time-sync would require hooking the game's frame timer, which is a much larger effort. File this as a known limitation.

### Phase 2 testing

1. `test "remoteFrameEstimate accounts for RTT"` — mock RTT = 100ms, last_received = 100, verify estimate ≈ 100 + 3 + 0.5 = 103.5.
2. `test "localFrameAdvantage is negative when we're ahead"` — mock remote behind, verify negative advantage.
3. `test "recommendFrameWaitMs returns 0 for small drift"` — advantage = 1.0, verify returns 0.
4. `test "recommendFrameWaitMs clamps to max"` — advantage = -100, verify clamped to 30 frames worth of ms.

### Phase 2 files touched

| File | Changes |
|------|---------|
| `src/dll/netplay_manager.zig` | Add `remoteFrameEstimate`, `localFrameAdvantage`, `recommendFrameWaitMs`, recommendation constants |
| `src/dll/frame_step.zig` | Log recommendation every 120 frames (no actual sleep — see caveat) |
| `src/dll/ggpo_port_tests.zig` | Add 4 time-sync tests |

---

## Phase 3 — Reliability: Ring Buffer Sizing + discardConfirmedFrames (Idea 6)

**Goal**: Better packet-loss recovery and bounded memory usage.

**Branch milestone**: Third PR on `feature/ggpo-port`. Independent of Phase 2.

### Idea 6: Bounded input history + discardConfirmedFrames

#### Current state
`InputBuffer.inputs` is an unbounded `AutoHashMap(u64, u16)`. Within a round, it grows by 1 entry per frame. A 99-second round (MBAACC's round timer) at 60fps = ~5940 entries × ~48 bytes (hashmap overhead) ≈ 285KB per round. Not catastrophic, but wasteful, and old entries are never useful once the remote has confirmed them.

#### Target state
Add `discardConfirmedFrames(frame)` that removes inputs older than the last confirmed frame. Call it from `setLastConfirmedFrame` (new method, called when we receive a remote input packet — the highest frame in that packet is the remote's confirmed frame for our inputs).

Also bump `StatePool` from 60 → 90 states (1.5s) for high-latency connections.

#### Implementation

New method on `InputBuffer`:
```zig
/// Remove all inputs for `index` with frame < min_frame.
/// Called when the remote confirms it has received our inputs up to min_frame.
pub fn discardConfirmedFrames(self: *InputBuffer, index: u32, min_frame: u32) void {
    var to_remove: std.ArrayList(u64) = .empty;
    defer to_remove.deinit(self.allocator);
    var it = self.inputs.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const key_index = @as(u32, @intCast(key >> 32));
        const key_frame = @as(u32, @intCast(key & 0xFFFFFFFF));
        if (key_index == index and key_frame < min_frame) {
            to_remove.append(self.allocator, key) catch return;
        }
    }
    for (to_remove.items) |key| {
        _ = self.inputs.remove(key);
    }
}
```

Call site in `NetplayManager.setRemoteInputs`: after applying the remote's inputs, we know the remote has confirmed our inputs up to `start_frame + num - 1` (because their packet includes their view of our inputs via the input-ack mechanism — actually, zzcaster doesn't have input-ack; the remote just sends their own inputs).

**Correction**: zzcaster's input packet doesn't include an ack of the remote's inputs (unlike GGPO's `InputAck`). So we can't know exactly which of our inputs the remote has confirmed. We can approximate: the remote's `start_frame` in their input packet tells us they're at least at that frame, which means they've processed our inputs up to `start_frame - 1` (assuming lockstep).

**Approximate discard**:
```zig
// In setRemoteInputs, after parsing:
// The remote is at start_frame, so they've processed our inputs up to start_frame - 1.
// Discard our local inputs older than start_frame - 16 (keep a 16-frame safety margin).
const discard_before = if (start_frame >= 16) start_frame - 16 else 0;
self.local_inputs.discardConfirmedFrames(index, discard_before);
```

#### StatePool sizing

Change `onEnterInGame`:
```zig
self.state_pool.allocate(90, 0) catch {  // was 60
    self.log.warn("StatePool allocate failed — rollback disabled", .{});
};
```

90 states = 1.5 seconds at 60fps. Memory cost: 90 × ~850KB ≈ 76MB. Acceptable for a 32-bit Windows game (MBAACC's address space is 2-4GB).

### Phase 3 testing

1. `test "discardConfirmedFrames removes old inputs"` — set inputs at frames 1-100, discard before 50, verify frames 1-49 removed and 50-100 retained.
2. `test "discardConfirmedFrames preserves other indices"` — set inputs at index 5 frame 10 and index 6 frame 10, discard index 5 before frame 20, verify index 6 frame 10 retained.
3. `test "InputBuffer memory bounded after discard"` — set 1000 inputs, discard all but last 16, verify hashmap size ≤ 16.
4. `test "StatePool 90 states survives 1.5s rollback"` — save 90 states, verify `loadStateForFrame` for the oldest succeeds.

### Phase 3 files touched

| File | Changes |
|------|---------|
| `src/dll/rollback.zig` | Add `InputBuffer.discardConfirmedFrames` |
| `src/dll/netplay_manager.zig` | Call `discardConfirmedFrames` in `setRemoteInputs`; bump StatePool to 90 |
| `src/dll/ggpo_port_tests.zig` | Add 4 reliability tests |

---

## Phase 4 — Architectural (Idea 5) — DEFERRED

**Move input delay out of the rollback core.**

This is a high-effort refactor: `config.delay` is woven into `sendLocalInputs`, `getNetplayInput`, the `InputBuffer` key scheme, and the spectator `BothInputs` format. Ripping it out requires:
1. Making `InputBuffer` always use delay=0.
2. Implementing a display-delay buffer in the frame loop (like ggpo-x's `stateHistory` vector in vectorwar.cpp).
3. Updating the spectator protocol to carry delay-0 inputs.

**Filing as a future milestone, not part of this branch.** The payoff (fixing asymmetric-delay bugs, simpler prediction) is real but the cost is high and the current delay-inside-rollback design works for the common case (both peers use the same delay).

---

## Cross-Cutting Concerns

### Protocol versioning

The Phase 1 wire-format change (adding checksum fields to the input packet) is breaking. We need a protocol version so old clients reject new clients cleanly.

**Current**: ENet's `connect_data` field carries a single byte encoding `is_host | is_spectator | chara_select_ready`. No version field.

**Change**: Expand `connect_data` to 32 bits. Low byte = flags (as before). Byte 1 = protocol version (start at 1). Bytes 2-3 = reserved.

In `initEnet`:
```zig
const protocol_version: u32 = 1;
const connect_data = protocol_version << 8 | flags;
self.enet_peer = enet.enet_host_connect(self.enet_host, &addr, 3, connect_data);
```

In the CONNECT receive handler:
```zig
const remote_version = (event.data >> 8) & 0xFF;
if (remote_version != protocol_version) {
    self.log.err("Protocol version mismatch: local={d} remote={d}", .{protocol_version, remote_version});
    // Disconnect
    enet.enet_peer_disconnect(event.peer, 0);
    return;
}
```

### Performance budget

| Operation | Per-frame cost | Budget % (16.6ms) |
|-----------|---------------|-------------------|
| StatePool saveState (existing) | ~500μs | 3.0% |
| Wyhash of saved buffer (new) | ~170μs | 1.0% |
| checkChecksumDesync (new) | ~5μs | 0.03% |
| updateRttEma (new) | ~0.1μs | 0.001% |
| discardConfirmedFrames (new, every ~30f) | ~20μs amortized | 0.01% |
| **Total new overhead** | **~175μs** | **~1.05%** |

Acceptable. If Wyhash of the full buffer is too slow in practice, fall back to Option B (subset hash, ~0.06μs).

### Backward compatibility with SyncHash

The existing `SyncHash` (type 0x04) stays. It serves as:
1. A secondary desync check (catches the 1/65536 false-match case from 16-bit checksums).
2. A diagnostic (it includes field-level diffs: "P1 health: 1000 vs 950").
3. A cross-round check (per-frame checksums are per-index; SyncHash spans indices).

The per-frame checksum becomes the PRIMARY detector (fast, every frame). SyncHash becomes the SECONDARY detector (slow, every 300 frames, richer diagnostics). Both must agree to force-exit; either can flag `desync_detected`.

### Logging

All new code paths log at `info` level for normal operation and `err` for desyncs/failures. Existing log volume is already high; the new logs are infrequent (desync detection, RTT updates every 120 frames, network errors only on failure).

---

## Milestone Checklist

### Phase 1 — Foundation (first PR)
- [ ] Add `protocol_version` to ENet connect_data; reject mismatched peers
- [ ] Add `checksum: u16` field to `SavedState`; compute in `saveState`
- [ ] Add `pending_checksums`, `confirmed_checksums`, `remote_checksums` maps to `NetplayManager`
- [ ] Add `CHECKSUM_DELAY = 16` constant
- [ ] Modify `sendLocalInputs`: attach checksum + checksum_frame to input packet
- [ ] Modify `setRemoteInputs`: parse checksum + checksum_frame, store in `remote_checksums`
- [ ] Add `checkChecksumDesync` method; call from `frameStepNetplay`
- [ ] Clear checksum maps in `onStateTransition` and `onEnterInGame`
- [ ] Add `rtt_ema_ms`, `rtt_ema_initialized` fields; `updateRttEma` method
- [ ] Call `updateRttEma` from `frameStepNetplay`
- [ ] Add `network_error`, `consecutive_send_failures` tracking to `sendInputs`/`sendReliable`
- [ ] Write 8 unit tests in `ggpo_port_tests.zig`
- [ ] Write 1 integration test in `test_simulation.zig`
- [ ] Manual playtest: 2 peers, full match, forced desync detected in <1s

### Phase 2 — Time-Sync (second PR)
- [ ] Add `remoteFrameEstimate`, `localFrameAdvantage` methods
- [ ] Add `recommendFrameWaitMs` method with ggpo-x's symmetric formula
- [ ] Log recommendation every 120 frames from `frameStepNetplay`
- [ ] Write 4 time-sync unit tests
- [ ] Document the "can't actually slow down MBAACC's frame loop" limitation

### Phase 3 — Reliability (third PR)
- [ ] Add `InputBuffer.discardConfirmedFrames` method
- [ ] Call from `setRemoteInputs` with 16-frame safety margin
- [ ] Bump `StatePool` from 60 → 90 states
- [ ] Write 4 reliability unit tests
- [ ] Manual playtest: long match (3+ rounds), verify memory doesn't grow unboundedly

### Phase 4 — Architectural (deferred, separate branch)
- [ ] File as issue: "Move input delay out of rollback core"
- [ ] Not part of this branch

---

## References

- **ggpo-x repo**: https://github.com/thomashenry79/ggpo-x
- **Original GGPO repo**: https://github.com/pond3r/ggpo
- **Comparison doc** (this branch): `docs/ggpo-x-comparison.md` (the analysis this plan is based on)
- **ggpo-x `CheckDesync`**: `src/lib/ggpo/backends/p2p.cpp:107-161`
- **ggpo-x `HowFarBackForChecksums`**: `src/lib/ggpo/backends/p2p.cpp:505-508` (returns 16)
- **ggpo-x RTT EMA**: `src/lib/ggpo/network/udp_proto.cpp:700-720` (`OnQualityReply`)
- **ggpo-x remote frame estimate**: `src/lib/ggpo/network/udp_proto.cpp:745-767`
- **ggpo-x time-sync formula**: `src/lib/ggpo/timesync.cpp:74-86`
- **zzcaster SyncHash**: `src/dll/netplay_manager.zig:231-384`
- **zzcaster StatePool**: `src/dll/rollback.zig:179-535`
- **zzcaster ENet RTT accessor**: `src/net/enet_transport.zig:268` (`peer.roundTripTime`)
