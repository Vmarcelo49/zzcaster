# Spectator Mode — Audit + CCCaster Parity Plan

> **Status**: Documentation only — code changes follow in a separate commit.
> **Scope**: Full CCCaster parity for spectator mode (zzcaster ↔ zzcaster, then zzcaster ↔ CCCaster).
> **Out of scope**: Spectate-via-relay (relay server side is independent); replay-mode spectator.

---

## 1. Current zzcaster state

### 1.1 What works

| Component | Where | Notes |
|-----------|-------|-------|
| Spectator launch path (launcher) | `src/launcher/ui_pages.zig:355`, `src/launcher/game_launcher.zig:138/460` | Launcher sends IPC config with bit3 set; DLL boots into spectator mode. |
| `is_spectator` config flag flows through | `game_launcher.zig:213`, `dllmain.zig:319`, `netplay_manager.zig:215` | Correctly plumbed all the way to `frameStepSpectator`. |
| Spectator connect_data sentinel (`0x5FEC`) | `netplay_manager.zig:745` | Host distinguishes spectator connect from main peer. |
| Host accepts spectator connect | `netplay_manager.zig:768` `drainSpectatorEvents` | Routes to `SpectatorManager.onNewPeer`. |
| Spectator input writeback | `netplay_manager.zig:2433` `writeGameInputs` → `getSpectatorInputs` | Pulls both P1+P2 from `local_inputs`/`remote_inputs` buffers populated from `0x20 BothInputs`. |
| Spectator skips rollback | `netplay_manager.zig:1102` `isInRollback` | Spectators never roll back — correct, mirrors CCCaster. |
| RNG forward to spectators | `spectator_manager.zig:279` `frameStepSpectators` | Calls `getCachedRngCallback` to look up host's cached RNG for the spectator's current index. |
| Heartbeat / disconnect | `frame_step.zig:55` `frameStepSpectator` | Exits on disconnect. |

### 1.2 What's broken or stubbed

The spectator code path is **structurally incomplete** — it compiles and the spectator connects, but several handshake steps are missing or wrong, so the spectator never receives match data and disconnects after the 20-second pending timeout.

| # | Bug | Where | Severity |
|---|-----|-------|----------|
| **B1** | Spectator never sends `HELLO (0x01)` message after ENet CONNECT. Host waits for `0x01` in `handleSpectatorMessage` (`netplay_manager.zig:828`); without it the spectator stays in `pending` state for 20s then gets disconnected by `checkPendingTimeouts`. | missing — no send path on the spectator side after CONNECT | **Blocker** |
| **B2** | `SpectatorManager.sendInitialState` (spectator_manager.zig:343) is defined but **never called**. CCCaster sends `InitialGameState` immediately on `pushSpectator` (DllSpectatorManager.cpp:87). Without it the spectator's MBAACC instance has no clue what state/index to start at. | `spectator_manager.zig:343`, `handleSpectatorMessage` should call it | **Blocker** |
| **B3** | `Spectator.redirect_addr` / `redirect_port` fields are never populated. They are read by `sendRedirectAndDisconnect` (spectator_manager.zig:140) to advertise a redirect target — they're always `0.0.0.0:0`. CCCaster populates these from the spectator's `IpAddrPort` message (DllMain.cpp:1424). | `spectator_manager.zig:19,34-35` and `onNewPeer`/`activateSpectator` | **Blocker** for chain forwarding |
| **B4** | `max_root_spectators = 1` causes **every spectator beyond the first** to be redirected, regardless of host/client/spectator mode. CCCaster only applies this cap to Host/Client (root) peers — a `Spectate`-mode client should accept up to `MAX_SPECTATORS = 15` direct spectators (CCCaster `SHOULD_REDIRECT_SPECTATORS` macro at DllMain.cpp:59-61). zzcaster is missing the `clientMode.isSpectate()` branch entirely. | `spectator_manager.zig:105-108` | **Blocker** for multi-spectator chain |
| **B5** | Wire-format tags diverge from CCCaster (see §2.2 below). zzcaster can never interop with a CCCaster host, and the in-code comments flag this everywhere. | scattered — see table below | Parity |
| **B6** | `SpectatorManager.sendRedirectAndDisconnect` uses tag `0xFE` (ZZCaster-specific) — CCCaster uses `IpAddrPort` (tag `0x0B`). Format also differs: zzcaster writes `[2 byte header][addr\0][2 byte port]`; CCCaster uses cereal-serialized `IpAddrPort { string addr; uint16 port; bool isV4; }`. | `spectator_manager.zig:135` | Parity |
| **B7** | `SpectatorManager.sendInitialState` uses tag `0x10` (ZZCaster-specific) and only 11 bytes — CCCaster uses `InitialGameState` (tag `0x0A`) with full chara/moon/color/stage fields (see Messages.hpp:216-243). | `spectator_manager.zig:346` | Parity |
| **B8** | `BothInputs` tag is `0x20` in zzcaster; CCCaster uses `0x02`. zzcaster also omits the compression-level byte and trailing MD5 hash that CCCaster's serialization prepends/appends. | `spectator_manager.zig:300`, `netplay_manager.zig:991,2452` | Parity |
| **B9** | Redirect pick uses `prng.random().intRangeLessThan` (random); CCCaster uses round-robin via `_spectatorMapPos` (DllSpectatorManager.cpp:127-134 + `getRandomSpectatorAddress`). Random is OK functionally but causes uneven load distribution. | `spectator_manager.zig:141` | Minor |
| **B10** | `SpectatorManager.frameStepSpectators` skips `RetryMenuIndex` forwarding entirely. CCCaster sends `MenuIndex` once per index to spectators (DllSpectatorManager.cpp:193-200). Without this, a spectator's retry-menu UI diverges from the players'. | `spectator_manager.zig` (no equivalent) | Medium — affects retry-menu only |
| **B11** | No `SpectateConfig` message. CCCaster exchanges `SpectateConfig` (tag `0x18`) BEFORE the spectator joins — carries player names, winCount, hostPlayer, delay, rollback, sessionId, InitialGameState. zzcaster's launcher handshake skips this entirely. | `netplay_manager.zig` (no equivalent) | Parity — affects spectator UX (no player names displayed) |
| **B12** | `frameStepSpectators`'s broadcast-pacing formula has a `pos_frame +%= num_inputs_per_packet` advance but **never advances `pos_index`** when the spectator's local index moves past the host's tracked index. The CCCaster version relies on `getBothInputs(spectator.pos)` returning null when inputs aren't ready, and the spectator's `pos.index` is only advanced when the host's `indexed_frame.index` advances — but zzcaster's `fillBothInputsForBroadcast` (`netplay_manager.zig:2450`) doesn't bump `pos_index` either. Need to confirm: does the spectator's `pos` ever advance past the first round? | `spectator_manager.zig:307`, `netplay_manager.zig:2450` | **Suspected blocker** for multi-round spectator |
| **B13** | `preserveStartIndex` / `currentMinIndex` bookkeeping runs but is never consumed — no GC of input history is gated on it. CCCaster uses it to know how long to keep input history before dropping old frames. | `spectator_manager.zig:51-52,259` | Memory leak in long matches |
| **B14** | `spectator_manager.zig:36` field comment says "spectator's external address (for redirect advertisement)" but the field is only ever read, never written. | struct field | Source of B3 |
| **B15** | `pending_timeout_ms = 20000` matches CCCaster's `DEFAULT_PENDING_TIMEOUT`, but `checkPendingTimeouts` is only called from `drainSpectatorEvents` (host-side, `netplay_manager.zig:821`). CCCaster also has a per-spectator `Timer` that fires `timerExpired` independently — not critical because we poll every frame, but worth noting. | `spectator_manager.zig:196` | Minor |
| **B16** | `SpectatorManager.init` takes `std.Io` for seeding the PRNG. This works on the DLL side (DLL has its own `app_io_backend`), but the **launcher** has no spectator-manager instance — `drainSpectatorEvents` etc. are DLL-only. Fine for now, but worth flagging if we ever want launcher-side tests. | `spectator_manager.zig:54` | Test infra |

### 1.3 What's already correct vs. CCCaster

These match CCCaster closely and should NOT be changed:

- Broadcast pacing formula: `multiplier = 1 + (n_spec * 2) / (NUM_INPUTS + 1)`, `interval = (multiplier * NUM_INPUTS / 2) / n_spec` (spectator_manager.zig:246-249 vs DllSpectatorManager.cpp:137-140). Identical.
- `NUM_INPUTS_PER_PACKET = 30` matches CCCaster `NUM_INPUTS`.
- `MAX_SPECTATORS = 15` matches CCCaster.
- Round-robin broadcast position advance (`broadcast_pos`) mirrors CCCaster's `_spectatorListPos`.
- "Send RNG once per index, reset on index advance" logic (spectator_manager.zig:279-318) mirrors DllSpectatorManager.cpp:177-191.
- Spectator does not send RNG ACK — correct (matches CCCaster; spectator is passive).
- Spectator's RNG forward-accept window (`rng_index <= current + 1` for spectators vs. strict for clients) at `netplay_manager.zig:1446` is intentional and matches the comment rationale.

---

## 2. CCCaster reference

### 2.1 Spectator connect flow (CCCaster)

```
Spectator side (MainApp.cpp)             Host side (DllMain.cpp)
--------------------------              ------------------------
1. TCP connect to host:port (ctrl)
2. Send VersionConfig ────────────────►
                                        socketAccepted (line 1280)
                                        if SHOULD_REDIRECT_SPECTATORS (line 1296):
                                            pick redirectAddr = getRandomRedirectAddress()
                                            send IpAddrPort(redirectAddr) ◄─────
                                            add to redirectedSockets
                                            (spectator disconnects & retries elsewhere)
                                        else:
                                            send VersionConfig ◄─────
3. Receive VersionConfig or IpAddrPort
   if IpAddrPort: retry connect to new addr
   if VersionConfig:
       send ConfirmConfig ─────────────►
                                        socketRead (line 1373) → case ConfirmConfig:
                                            "Wait for IpAddrPort before actually adding this new spectator"
                                            (just returns — spectator stays pending)
4. Send IpAddrPort(localCtrlAddr) ─────►  (line 1420 case IpAddrPort)
                                          pushSpectator(socket, {socket->address.addr, msg.port})
                                            → SpectatorManager.pushSpectator (DllSpectatorManager.cpp:19)
                                              a. pos.frame = NUM_INPUTS - 1; pos.index = host.getSpectateStartIndex()
                                              b. preserveStartIndex = min(preserveStartIndex, pos.index)
                                              c. send RngState(pos.index [+1/+2 based on state])
                                              d. send InitialGameState(pos, netplayState, isTraining)
5. Receive RngState + InitialGameState
   - Apply RNG to game memory
   - Use InitialGameState.indexedFrame as start coord
6. Each frame: receive BothInputs ◄────  frameStepSpectators() broadcasts BothInputs
   - Apply via setBothInputs → game inputs
```

**Critical insight**: CCCaster uses **two sockets per spectator** — a TCP control socket (`ctrlSocket`) and a UDP data socket (`dataSocket`). The ctrl socket carries the handshake + control messages; the data socket carries `BothInputs` / `RngState` / `TransitionIndex` (high-frequency). zzcaster uses a **single ENet host with 3 channels** (0=reliable, 1=inputs, 2=spectator). This is a structural simplification — functionally equivalent (ENet channels replace the TCP/UDP split), but it means we don't need to mirror the two-socket dance; we just need to mirror the **message sequence**.

### 2.2 Wire-format tag map

CCCaster `MsgType` enum is **alphabetically sorted** (lib/ProtocolEnums.hpp + Protocol.hpp:34). Mapped to numeric values:

| MsgType (alpha order) | Decimal | Hex | zzcaster tag | zzcaster name | Match? |
|-----------------------|---------|-----|--------------|---------------|--------|
| AckSequence           | 1       | 0x01 | —            | —             | n/a (not used) |
| BothInputs            | 2       | 0x02 | 0x20         | BothInputs    | ❌ |
| ChangeConfig          | 3       | 0x03 | —            | —             | n/a |
| ClientMode            | 4       | 0x04 | —            | —             | n/a |
| ConfirmConfig         | 5       | 0x05 | —            | —             | n/a |
| ControllerMappings    | 6       | 0x06 | —            | —             | n/a |
| ErrorMessage          | 7       | 0x07 | 0x06         | ErrorMessage  | ❌ |
| GoBackN               | 8       | 0x08 | —            | —             | n/a |
| InitialConfig         | 9       | 0x09 | —            | —             | n/a |
| InitialGameState      | 10      | 0x0A | 0x10         | INITIAL_GAME_STATE | ❌ |
| IpAddrPort            | 11      | 0x0B | 0xFE         | REDIRECT (custom) | ❌ |
| IpcConnected          | 12      | 0x0C | —            | —             | n/a |
| JoystickMappings      | 13      | 0x0D | —            | —             | n/a |
| KeyboardEvent         | 14      | 0x0E | —            | —             | n/a |
| KeyboardMappings      | 15      | 0x0F | —            | —             | n/a |
| MenuIndex             | 16      | 0x10 | —            | —             | n/a |
| NetplayConfig         | 17      | 0x11 | —            | —             | n/a |
| OptionsMessage        | 18      | 0x12 | —            | —             | n/a |
| Ping                  | 19      | 0x13 | —            | —             | n/a |
| PingStats             | 20      | 0x14 | —            | —             | n/a |
| PlayerInputs          | 21      | 0x15 | 0x01         | PlayerInputs  | ❌ |
| RngState              | 22      | 0x16 | 0x02         | RNG state     | ❌ |
| SocketShareData       | 23      | 0x17 | —            | —             | n/a |
| SpectateConfig        | 24      | 0x18 | —            | —             | n/a |
| SplitMessage          | 25      | 0x19 | —            | —             | n/a |
| Statistics            | 26      | 0x1A | —            | —             | n/a |
| SyncHash              | 27      | 0x1B | 0x04         | SyncHash      | ❌ |
| TestMessage           | 28      | 0x1C | —            | —             | n/a |
| UdpControl            | 29      | 0x1D | —            | —             | n/a |
| Version               | 30      | 0x1E | —            | —             | n/a |
| VersionConfig         | 31      | 0x1F | 0x07         | VersionConfig | ❌ |
| JoysticksChanged      | 32      | 0x20 | —            | —             | n/a |
| TransitionIndex       | 33      | 0x21 | 0x03         | TransitionIndex | ❌ |
| PaletteManager        | 34      | 0x22 | —            | —             | n/a |
| RNG_ACK (zzcaster-only) | —     | 0x05 | —            | RNG_ACK       | n/a (zzcaster extension; CCCaster relies on re-send timer instead) |

**Every currently-used tag mismatches.** zzcaster's tag choices were arbitrary and pre-date the parity goal.

### 2.3 CCCaster message body formats (relevant subset)

CCCaster uses **cereal BinaryArchive** for serialization. Each message is serialized as:
```
[1 byte msgType][1 byte compressionLevel][cereal-serialized fields...][16 byte MD5 hash]
```
The `compressionLevel` byte is set to 0 by default; the MD5 is computed over the serialized body (used for dedup / integrity — see `Serializable::save` in Protocol.hpp).

#### InitialGameState (Messages.hpp:216-243)
```
[1 byte type=0x0A]
[1 byte compressionLevel=0]
[8 bytes indexedFrame.value (u64)]   // { u32 frame; u32 index; } as a u64
[4 bytes stage (u32)]
[1 byte netplayState (u8)]
[1 byte isTraining (u8)]
[2 bytes chara (u8[2])]
[2 bytes moon (u8[2])]
[2 bytes color (u8[2])]
[16 bytes MD5]
```
Total body: 1 + 1 + 8 + 4 + 1 + 1 + 2 + 2 + 2 + 16 = **38 bytes**. zzcaster's `sendInitialState` writes 11 bytes.

#### IpAddrPort (lib/IpAddrPort.hpp:30-90, Messages.hpp implicit)
```
[1 byte type=0x0B]
[1 byte compressionLevel=0]
[cereal string: 4-byte size + N bytes addr]
[2 bytes port (u16, little-endian via cereal)]
[1 byte isV4 (u8)]
[16 bytes MD5]
```
For an IPv4 address like "1.2.3.4", body is 1 + 1 + (4 + 7) + 2 + 1 + 16 = **32 bytes**.

#### BothInputs (Messages.hpp:497-507)
```
[1 byte type=0x02]
[1 byte compressionLevel=0]
[8 bytes indexedFrame.value (u64)]
[2 * 30 * 2 = 120 bytes inputs (u16[2][30])]   // [player][frame] = u16
[16 bytes MD5]
```
Total body: 1 + 1 + 8 + 120 + 16 = **146 bytes**. zzcaster's `fillBothInputsForBroadcast` writes `1 + 8 + 120 = 129 bytes` (no compression level, no MD5) and uses `[8 bytes start_frame+start_index]` instead of `indexedFrame.value` as a u64 (same bytes, different field name).

#### RngState (Messages.hpp:288-308)
```
[1 byte type=0x16]
[1 byte compressionLevel=0]
[4 bytes index (u32)]
[4 bytes rngState0 (u32)]
[4 bytes rngState1 (u32)]
[4 bytes rngState2 (u32)]
[220 bytes rngState3 (char[220])]
[16 bytes MD5]
```
Total body: 1 + 1 + 4 + 4 + 4 + 4 + 220 + 16 = **254 bytes**. zzcaster writes `1 + 4 + 4 + 4 + 4 + 220 = 237 bytes` (no compression level, no MD5).

#### TransitionIndex (Messages.hpp:454-463)
```
[1 byte type=0x21]
[1 byte compressionLevel=0]
[4 bytes index (u32)]
[16 bytes MD5]
```
Total: 22 bytes. zzcaster writes 5 bytes (1 + 4).

#### VersionConfig (Messages.hpp:120-129)
```
[1 byte type=0x1F]
[1 byte compressionLevel=0]
[1 byte ClientMode.value (u8)]
[1 byte ClientMode.flags (u8)]
[4 bytes Version (u32 — version code)]
[16 bytes MD5]
```
Total: 24 bytes. zzcaster writes 5 bytes.

#### PlayerInputs (Messages.hpp:484-494)
```
[1 byte type=0x15]
[1 byte compressionLevel=0]
[8 bytes indexedFrame.value (u64)]
[60 bytes inputs (u16[30])]
[16 bytes MD5]
```
Total: 86 bytes. zzcaster writes variable length.

### 2.4 CCCaster `getSpectateStartIndex`

Referenced in DllSpectatorManager.cpp:58 as `_netManPtr->getSpectateStartIndex()`. Definition: returns the host's **current** `indexed_frame.index` minus a small lookahead so the spectator starts a few rounds behind (avoiding the "spectator joins mid-round and desyncs because host has already advanced" race). zzcaster's `handleSpectatorMessage` reads `start_index` from the spectator's HELLO packet — **inverted**: CCCaster has the host decide; zzcaster has the spectator decide. Need to flip this.

### 2.5 CCCaster `SHOULD_REDIRECT_SPECTATORS`

```cpp
// DllMain.cpp:59-61
#define SHOULD_REDIRECT_SPECTATORS  ( clientMode.isSpectate() \
                                      ? numSpectators() >= MAX_SPECTATORS
                                      : numSpectators() >= MAX_ROOT_SPECTATORS )
```

- A **root** host/client accepts at most `MAX_ROOT_SPECTATORS = 1` direct spectator.
- A **spectator** (chain-forwarding) accepts up to `MAX_SPECTATORS = 15` direct spectators.
- Beyond the cap, the new peer is redirected to a random existing spectator's address.

zzcaster has the root cap but is missing the `isSpectate` branch — every peer beyond the first is redirected regardless of role.

### 2.6 CCCaster `getRandomRedirectAddress`

```cpp
// DllMain.cpp:2067-2075
const IpAddrPort& getRandomRedirectAddress() const {
    size_t r = rand() % ( 1 + numSpectators() );
    if ( r == 0 && !clientServerAddr.empty() )
        return clientServerAddr;   // redirect back to the original host's client-server addr
    else
        return getRandomSpectatorAddress();
}
```

Two important details:
1. With probability `1/(N+1)`, the redirect points to `clientServerAddr` — the address the host's *own* client got from its upstream. This lets a spectator reconnect directly to the original host if all chain links are full.
2. `getRandomSpectatorAddress` (DllSpectatorManager.cpp:209-235) walks `_spectatorMapPos` (round-robin) and skips entries with `port == 0` (DEBUG-only safety).

zzcaster's `sendRedirectAndDisconnect` uses pure-random pick with no `clientServerAddr` fallback.

---

## 3. Implementation plan

### 3.1 Phasing

| Phase | Goal | Risk | Estimated LOC delta |
|-------|------|------|---------------------|
| **P1 — Minimum viable spectator** | Fix B1 (HELLO) + B2 (sendInitialState call) + B12 (pos_index advance). One zzcaster spectator can watch one zzcaster host. | Low — all changes are local to spectator_manager.zig + a 5-line send in netplay_manager.zig. | +40 / -10 |
| **P2 — Multi-spectator chain** | Fix B3 (redirect_addr population) + B4 (isSpectate branch in redirect cap). Up to 15 spectators can chain-forward. | Medium — touches `onNewPeer` signature and adds a `clientServerAddr` field to `NetplayManager`. | +60 / -15 |
| **P3 — Wire-format parity** | Fix B5/B6/B7/B8: align all message tags + bodies to CCCaster. zzcaster spectator can watch CCCaster host (and vice versa). | High — touches every message site in netplay_manager.zig + spectator_manager.zig + adds MD5 + compression byte. Need to add a cereal-compatible serializer or hand-roll the byte layout. | +250 / -120 |
| **P4 — UX parity** | Fix B11 (SpectateConfig exchange). Spectator sees player names, winCount, hostPlayer in the launcher waiting-for-peer screen. | Medium — adds a new message type + launcher-side UI changes. | +180 / -10 |
| **P5 — Cleanup** | Fix B9 (round-robin redirect) + B10 (MenuIndex forward) + B13 (preserveStartIndex GC) + B14 (field comment). | Low — quality-of-life. | +80 / -20 |

**User asked for "full CCCaster parity" → we will do P1 → P5.** P3 is the high-risk phase; we'll gate it behind a feature flag (`-Dcccaster-wire-parity`) for the first iteration so we can ship P1+P2 independently if P3 runs long.

### 3.2 P1 — Minimum viable spectator (detailed)

**Files touched**:
- `src/dll/spectator_manager.zig` — call `sendInitialState` after activation
- `src/dll/netplay_manager.zig` — add `sendSpectatorHello()` called from `pollEnet` on the CONNECT event when `is_spectator == true`; advance `pos_index` in `fillBothInputsForBroadcast` when the host's `indexed_frame.index > spectator.pos_index`

**New `sendSpectatorHello`** (in NetplayManager):
```zig
/// Spectator → host: announce we're ready. Host responds with
/// InitialGameState + cached RngState, then starts broadcasting BothInputs.
/// Body: [1 byte type=0x01 HELLO][4 bytes desired_start_index]
/// desired_start_index = 0 means "host decides" (CCCaster-compatible).
fn sendSpectatorHello(self: *NetplayManager) void {
    if (self.enet_peer == null or !self.enet_connected) return;
    if (!self.config.is_spectator) return;
    var buf: [5]u8 = undefined;
    buf[0] = 0x01; // HELLO
    std.mem.writeInt(u32, buf[1..5], 0, .little); // host decides start index
    self.sendReliable(&buf);
    self.log.info("Sent spectator HELLO", .{});
}
```
Called from `pollEnet`'s CONNECT branch when `is_spectator == true` (right after `self.enet_connected = true`).

**`sendInitialState` call site** — in `handleSpectatorMessage` case `0x01`, after `activateSpectator`:
```zig
self.spectators.?.activateSpectator(peer, start_index);
// Send InitialGameState so the spectator's MBAACC starts at the right (index, frame).
self.spectators.?.sendInitialState(
    peer,
    @intFromEnum(self.state),
    self.config.is_training,
    start_index,
    0, // start_frame — CCCaster uses indexedFrame.parts.frame, which is 0 at round start
);
```

**`pos_index` advance** — in `fillBothInputsForBroadcast`, before the loop:
```zig
// If the host has advanced to a new transition index, advance the spectator's
// pos too (the spectator's local pos is just a cursor for what to send next;
// it doesn't have to match the spectator's local indexed_frame).
if (index > spectator.pos_index) {
    spectator.pos_index = index;
    spectator.pos_frame = 0;
}
```
But `fillBothInputsForBroadcast` doesn't have a pointer to the `Spectator` struct — it's called via a function pointer (`fillBothInputsCallback`). We have two options:
- **Option A**: Pass the host's current `indexed_frame.index` into `fillBothInputsForBroadcast` and let it return 0 (no inputs ready) if the spectator's `pos_index` is stale — then handle the index advance in `frameStepSpectators` itself.
- **Option B**: Have `frameStepSpectators` advance `pos_index` before calling `fill_inputs`, by passing `current_index` (already a parameter, currently `_ = current_index`).

**Option B is cleaner.** Replace `_ = current_index` in `frameStepSpectators` with:
```zig
if (current_index > s.pos_index) {
    s.pos_index = current_index;
    s.pos_frame = 0;
    s.sent_rng_state = false; // new round → re-send RNG
}
```

### 3.3 P2 — Multi-spectator chain (detailed)

**Files touched**:
- `src/dll/spectator_manager.zig` — fix `onNewPeer` cap logic, populate `redirect_addr`/`redirect_port` from peer's ENet address
- `src/dll/netplay_manager.zig` — add `clientServerAddr` field; expose `isSpectate()` helper; route `IpAddrPort` (0x0B) messages from main peer to populate `clientServerAddr`

**Cap logic fix** in `onNewPeer`:
```zig
pub fn onNewPeer(self: *SpectatorManager, peer: ?*enet.ENetPeer, now_ms: i64) void {
    const cap = if (self.is_spectator_role) max_spectators else max_root_spectators;
    if (self.spectators.items.len >= cap) {
        self.sendRedirectAndDisconnect(peer);
        return;
    }
    // ... rest unchanged
}
```
where `is_spectator_role` is a new bool field on `SpectatorManager`, set by `NetplayManager.configure` based on `cfg.is_spectator`.

**`redirect_addr` population** — in `activateSpectator` (we don't have the spectator's external port until they send HELLO+IpAddrPort in P3; for now we use the ENet peer's remote address):
```zig
// Populate from the peer's ENet remote address (best effort; CCCaster uses
// the spectator's advertised IpAddrPort message — wire-format parity phase
// will replace this with the proper handshake).
if (peer) |p| {
    const a = p.address;
    // Format a.b.c.d as a string into redirect_addr
    _ = std.fmt.bufPrint(&s.redirect_addr, "{d}.{d}.{d}.{d}", .{
        (a.host >> 0) & 0xFF, (a.host >> 8) & 0xFF,
        (a.host >> 16) & 0xFF, (a.host >> 24) & 0xFF,
    }) catch {};
    s.redirect_port = a.port;
}
```

**`clientServerAddr`** — new field on `NetplayManager`:
```zig
client_server_addr: [64]u8 = [_]u8{0} ** 64,  // populated when we (as spectator) receive an IpAddrPort redirect
client_server_port: u16 = 0,
```
Used by `sendRedirectAndDisconnect` as the fallback redirect target.

### 3.4 P3 — Wire-format parity (detailed)

**Files touched**:
- `src/dll/netplay_manager.zig` — rename all `0xNN` tags to CCCaster values; add MD5 + compression byte to every serialized message; add cereal-compatible string serialization
- `src/dll/spectator_manager.zig` — same for spectator-side messages
- `src/dll/dll_state.zig` — update `fillBothInputsCallback` if the body format changes (it shouldn't — just the tag)
- `src/dll/netplay_manager.zig` `handleMessage` switch — update case labels

**Strategy**: Add a `wire.zig` module with helpers:
```zig
pub const MD5_HASH_SIZE: usize = 16;
pub const COMPRESSION_LEVEL: u8 = 0;

/// Write a CCCaster-compatible message frame:
/// [1 byte type][1 byte compressionLevel=0][body...][16 byte MD5 of body]
pub fn writeMessage(out: []u8, msg_type: u8, body: []const u8) usize {
    if (out.len < 2 + body.len + MD5_HASH_SIZE) return 0;
    out[0] = msg_type;
    out[1] = COMPRESSION_LEVEL;
    @memcpy(out[2 .. 2 + body.len], body);
    var hash: [16]u8 = undefined;
    md5(body, &hash);
    @memcpy(out[2 + body.len .. 2 + body.len + 16], &hash);
    return 2 + body.len + 16;
}

/// Parse a CCCaster message frame. Returns the body slice (into `buf`)
/// or null if the frame is malformed / MD5 doesn't match.
pub fn readMessage(buf: []const u8) ?struct { msg_type: u8, body: []const u8 } {
    if (buf.len < 2 + MD5_HASH_SIZE) return null;
    const msg_type = buf[0];
    const body = buf[2 .. buf.len - MD5_HASH_SIZE];
    var hash: [16]u8 = undefined;
    md5(body, &hash);
    if (!std.mem.eql(u8, &hash, buf[buf.len - MD5_HASH_SIZE ..])) return null;
    return .{ .msg_type = msg_type, .body = body };
}
```

**MD5 implementation**: Zig std.crypto.hash.Md5 — already available, no vendoring needed.

**Cereal string format**: cereal writes a 4-byte little-endian size prefix + the bytes (no null terminator). For IpAddrPort's `addr` field (a `std::string`), we'd write:
```zig
fn writeCerealString(out: []u8, s: []const u8) usize {
    if (out.len < 4 + s.len) return 0;
    std.mem.writeInt(u32, out[0..4], @intCast(s.len), .little);
    @memcpy(out[4 .. 4 + s.len], s);
    return 4 + s.len;
}
```

**Tag rename table** (zzcaster → CCCaster):
| zzcaster | → CCCaster | Constant name |
|----------|------------|---------------|
| 0x01 PlayerInputs | 0x15 | `MSG_PLAYER_INPUTS` |
| 0x02 RNG state | 0x16 | `MSG_RNG_STATE` |
| 0x03 TransitionIndex | 0x21 | `MSG_TRANSITION_INDEX` |
| 0x04 SyncHash | 0x1B | `MSG_SYNC_HASH` |
| 0x05 RNG_ACK | — | (delete; CCCaster uses re-send timer) |
| 0x06 ErrorMessage | 0x07 | `MSG_ERROR_MESSAGE` |
| 0x07 VersionConfig | 0x1F | `MSG_VERSION_CONFIG` |
| 0x10 INITIAL_GAME_STATE | 0x0A | `MSG_INITIAL_GAME_STATE` |
| 0x20 BothInputs | 0x02 | `MSG_BOTH_INPUTS` |
| 0xFE REDIRECT (custom) | 0x0B | `MSG_IP_ADDR_PORT` |
| (new) | 0x18 | `MSG_SPECTATE_CONFIG` |
| (new) | 0x05 | `MSG_CONFIRM_CONFIG` |
| (new) | 0x10 | `MSG_MENU_INDEX` |

### 3.5 P4 — SpectateConfig exchange (detailed)

**New message** `SpectateConfig` (CCCaster Messages.hpp:246-279):
```
[1 byte type=0x18]
[1 byte compressionLevel]
[1 byte ClientMode.value]
[1 byte ClientMode.flags]
[1 byte delay]
[1 byte rollback]
[1 byte rollbackDelay]
[1 byte winCount]
[1 byte hostPlayer]
[cereal string[2] names]   // 2 × (4-byte size + N bytes)
[cereal string sessionId]
[InitialGameState initial] // nested — 8 + 4 + 1 + 1 + 2 + 2 + 2 = 20 bytes
[16 byte MD5]
```

**Flow change**: Currently the spectator connects → sends HELLO → host activates. With SpectateConfig, the flow becomes:
1. Spectator connects → sends `VersionConfig`
2. Host responds with `SpectateConfig` (instead of immediately activating)
3. Spectator displays the config in the launcher waiting-for-peer screen, sends `ConfirmConfig`
4. Spectator sends `IpAddrPort` (its local ctrl addr — for redirect chain)
5. Host calls `pushSpectator` → sends `InitialGameState` + `RngState` → starts broadcasting `BothInputs`

This is a bigger refactor than P1-P3 because it changes the launcher side too. **Recommendation**: Defer P4 to a follow-up session; P1+P2+P3 give us a working zzcaster↔zzcaster spectator with CCCaster wire compatibility for the data path (BothInputs/RngState/TransitionIndex), even without the SpectateConfig handshake. Spectator just won't see player names until P4.

### 3.6 P5 — Cleanup (detailed)

- **B9**: Replace `prng.random().intRangeLessThan` with a round-robin index (`redirect_pick_pos`) that increments per redirect. Mirrors CCCaster's `_spectatorMapPos`.
- **B10**: Add `getRetryMenuIndex(index)` to NetplayManager; send `MenuIndex (0x10)` once per index in `frameStepSpectators`. Spectator side: handle `0x10` in `handleMessage` → `setRetryMenuIndex`.
- **B13**: Add `gcInputHistory(preserveStartIndex)` to InputBuffer — drop entries with `index < preserveStartIndex - 1`. Call from `frameStepSpectators` after `preserveStartIndex` updates.
- **B14**: Field comment fix only.

---

## 4. Test plan

### 4.1 Host-side unit tests (P1+P2)

Add `src/dll/spectator_manager_test.zig`:
- `test_onNewPeer_accepts_under_cap` — push N spectators, assert all accepted
- `test_onNewPeer_redirects_over_cap` — push cap+1 spectators, assert last is redirected
- `test_onNewPeer_spectator_role_uses_max_spectators` — set `is_spectator_role=true`, push 15, assert all accepted
- `test_activateSpectator_sets_pos` — activate with start_index=5, assert pos.index=5
- `test_sendRedirectAndDisconnect_picks_round_robin` — populate 3 spectators, redirect 3 times, assert each picked once
- `test_frameStepSpectators_advances_pos_index` — host index=2, spectator pos.index=0, after frameStep pos.index=2

### 4.2 Wire-format tests (P3)

Add `src/dll/wire_test.zig`:
- `test_writeMessage_md5_correct` — write a known body, parse it back, assert MD5 matches
- `test_readMessage_rejects_bad_md5` — flip a byte, assert null
- `test_writeCerealString_roundtrip` — write "1.2.3.4", read back, assert equal
- `test_BothInputs_format_matches_cccaster` — hardcode a 146-byte CCCaster BothInputs packet, parse it, assert fields

### 4.3 Build verification

- `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast` — must succeed with no errors
- `zig build test --summary all` — all tests pass
- `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast -Dcccaster-wire-parity` — P3 feature flag build succeeds

### 4.4 Manual smoke test (deferred — needs Windows)

Cannot run MBAA.exe in this environment. Once P1+P2 ship, the user should:
1. Host a netplay match on Windows machine A.
2. On Windows machine B, run `zzcaster.exe --mode=spectate --peer=A_IP:46318`.
3. Verify B's MBAACC window shows the match (chara select through gameplay).
4. On Windows machine C, repeat step 2 — should be redirected to B (chain forwarding).
5. Verify C's MBAACC window shows the match.

---

## 5. Open questions (resolve before P3)

1. **MD5 strictness**: CCCaster's `Serializable::save` computes MD5 over the body. Does CCCaster's `Serializable::load` actually **verify** the MD5 on receive, or is it advisory? If advisory, we can skip MD5 verification on receive (saves CPU). Need to grep cereal/Serializable.cpp.
2. **compressionLevel**: Always 0 in practice, or does CCCaster actually use levels 1-9 for large messages (BothInputs)? If used, we need to implement matching compression (looks like lz4 or miniz based on the `compressionLevel` field name).
3. **Version negotiation**: CCCaster's `VersionConfig` carries a 4-byte version code + revision string + buildTime string. zzcaster uses a single `protocol_version` u32. For P3 interop we need to match the format — but what version number do we claim? Probably "zzcaster-1.0" so CCCaster hosts reject us cleanly rather than silently mismatching.
4. **`getSpectateStartIndex` semantics**: Need to read CCCaster's `NetplayManager::getSpectateStartIndex` to know the exact lookahead formula. Suspect it's `current_index - 1` (so spectator starts at the previous round, giving them time to receive RNG before the next round starts).

---

## 6. Summary

The spectator code was **scaffolded** but never **wired up**. The host side accepts connections and broadcasts inputs; the spectator side connects and reads inputs. But the handshake in between is missing — the spectator never says HELLO, the host never says "here's your start state", and the redirect/chain-forwarding path advertises `0.0.0.0:0`. P1+P2 fix the handshake and the chain; P3 aligns the wire format for CCCaster interop; P4 adds SpectateConfig for player-name UX; P5 cleans up the long tail.

**Recommended order**: P1 → P2 → build+test → P3 → build+test → P4 → P5. Each phase is independently shippable.
