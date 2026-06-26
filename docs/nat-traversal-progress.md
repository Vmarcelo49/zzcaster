# NAT Traversal — Progress Notes

**Branch:** `nat-traversal-skeleton`
**Started:** 2026-06-26
**Author:** vmarcelo49 <vmarcelo49@gmail.com>

This branch implements NAT traversal for zzcaster, adapting the proven
hole-punch design from [CCCaster](https://github.com/Rhekar/CCCaster).

The plan is incremental — each slice is independently testable, builds
on the previous, and doesn't break the existing direct-IP netplay path.

---

## Goal

Allow players behind NAT to host matches without port forwarding,
without VPNs. Both modes will coexist:

- **Direct IP** (existing) — works if host has port forwarded, or both
  players on same LAN. Unchanged.
- **Room Code / Relay-assisted** (new) — works for ~85-95% of home users
  behind cone NATs. Symmetric NAT / CGNAT users still need direct IP or
  VPN (documented limit of UDP hole-punching).

---

## What's done (Slices 1 + 2)

### Slice 1 — Relay server skeleton

**Path:** `server/`

A self-contained Go server that does TCP signaling + UDP endpoint
discovery + STUN probe. Does **not** relay game packets — only forwards
peer endpoint info, then gets out of the way. Game traffic flows P2P
via ENet.

**Files:**
- `server/main.go` — entry point, flag parsing, starts TCP+UDP listeners
- `server/protocol.go` — wire format encode/decode (the contract)
- `server/room.go` — Room struct + RoomManager (in-memory state, thread-safe)
- `server/tcp_listener.go` — TCP accept loop + per-conn host/client handlers
- `server/udp_listener.go` — UDP recvfrom loop — UdpData dispatch + STUN probe reply
- `server/Dockerfile` — multi-stage Go→scratch (~10MB image)
- `server/docker-compose.yml` — single-service deploy with port mapping
- `server/README.md` — deploy instructions + smoke test guide

**Spec:** `docs/nat-traversal-protocol.md` (authoritative wire format)

**Test script:** `scripts/probe_zzcaster_relay.py` — exercises the full
host+client match flow + STUN probe + error cases.

**Status:** Ready to build + deploy. Not yet deployed anywhere.

### Slice 2 — Client foundation (Zig)

**Paths:** `src/net/relay_protocol.zig`, `src/net/relay_config.zig`, `src/net/nat_probe.zig`

Wire-format codec, relay list parser with failover, and STUN probe
client. No UI yet — just the building blocks the next slices will use.

**Key design decision — room-code based protocol:**

The client speaks the zzcaster relay protocol (room codes, `Hosted` reply,
`Error` replies). This is a single, self-contained protocol — we no longer
support the original CCCaster relay protocol (IP-based matching), since
testing showed those servers don't have working UDP and can't help with
hole-punching.

**Failover chain** (from `relay_list.txt`):
1. `zzcaster.duckdns.org:3939` (primary, deployed)
2. (commented out) `127.0.0.1:3939` — for local dev

**Files:**
- `src/net/relay_protocol.zig`
  - Encoders: `encodeHostRegister`, `encodeClientJoin`,
    `encodeUdpData`, `encodeStunProbe`
  - Decoders: `decodeServerMsg` (handles MatchInfo/TunInfo/Hosted/Error)
  - `decodeStunReply` (8-byte STUN response)
  - Room code generation + validation (unambiguous alphabet)
- `src/net/relay_config.zig`
  - `RelayEntry` struct (host + port)
  - `RelayList` with `.empty` + per-call allocator (Zig 0.16 pattern)
  - `parseLine` / `parseList` — format `host[:port]`
  - `DEFAULT_RELAY_LIST` constant (hardcoded fallback)
- `src/net/nat_probe.zig` (383 lines, 3 tests)
  - `NatType` enum (direct / full_cone / restricted / port_restricted /
    symmetric / unknown)
  - `detectNatType(host, port)` — sends 2 STUN probes from different
    local ports; if public ports match → cone NAT (works); if differ →
    symmetric (hole-punch will fail)
  - `initWinsock()` / `deinitWinsock()` — must be called by the launcher
    main() before any ws2_32 socket ops (one-liner, will add in Slice 3)

**Modified:**
- `src/common/config.zig` — added `relay_servers: []u8` field, parses
  `relayServers=` INI key (multi-line accumulator), 3 new tests
- `src/net/mod.zig` — exports the 3 new modules
- `build.zig` — added `net_tests` target wired into `zig build test`
- `relay_list.txt` (new, repo root) — default relay list
- `docs/roadmap.md` — Slices 1 + 2 marked done, dual-protocol design
  documented

**Tests:** 36 new tests total (24 in `relay_protocol`, 9 in
`relay_config`, 3 in `nat_probe`). All cross-compile to x86-windows-gnu
alongside the existing test suite. Run with `zig build test`.

**Zig 0.16 compatibility:**
- Caught and fixed: `std.Thread.Mutex` is removed in 0.16 (replaced by
  `Io.Mutex` which needs an `io` param). Removed the mutex-based
  refcounting in `nat_probe.zig` — WSAStartup/WSACleanup is process-
  global and the OS already refcounts it.
- Caught and fixed: `std.ArrayList.init(allocator)` is removed. Updated
  `RelayList` to use the new `.empty` + per-call allocator pattern.

---

## What's next

### Slice 3 — Client relay handshake state machine

**Path:** `src/net/relay_client.zig` (new file, ~400 lines)

The actual TCP+UDP state machine that drives the hole-punch. Will use
the protocol + config from Slice 2.

**State machine** (host side):
```
Idle → TCP connecting → Sent HostRegister → Got Hosted →
Waiting for MatchInfo → Got MatchInfo → Open UDP, send UdpData every 50ms →
Got TunInfo (peer's addr) → Send NullMsg to peer every 50ms →
Hole-punched (first packet from peer received) → Hand off to ENet
```

**State machine** (client side): same but starts with `ClientJoin`
instead of `HostRegister`.

**Key gotchas** (from CCCaster analysis):
- Keep sending `UdpData` to relay every 50ms even after `TunInfo`
  (refreshes NAT mapping on the same socket used to talk to peer)
- Bind UDP socket BEFORE sending any packets (preserves source port)
- Use raw `sendto()` for hole-punch probes, not `enet_host_connect()`
  (ENet's connect retransmit timing isn't tuned for hole-punch)
- Once first UDP packet from peer arrives, hand off to ENet via
  `enet_host_connect(peer_addr)` — NAT mapping is open, ENet's connect
  will succeed

**Will modify:**
- `src/launcher/main.zig` — call `nat_probe.initWinsock()` at startup
- (Slice 4) `src/launcher/session.zig` — new `SessionState` values for
  relay flow

### Slice 4 — NetplaySession integration

New `SessionState` values: `.relay_hosting`, `.relay_joining`,
`.relay_hole_punching`, `.relay_failed`. The existing direct-IP flow is
untouched — the relay path is a sibling state machine.

### Slice 5 — UI: mode toggle + room code

Adds a "Direct IP" / "Room Code" radio toggle to the Play page. In
Room Code mode: 4-letter input + Generate button. Waiting screen shows
the room code prominently with a Copy button.

### Slice 6 — Cross-NAT testing + release

Test matrix: same LAN, cross-NAT cone (works), cross-NAT symmetric
(fails gracefully with clear error), relay down (fallback to direct
mode). Bump version, tag release.

---

## How to verify what's done

```bash
cd /path/to/zzcaster

# 1. Run the new tests
zig build test

# 2. Verify the main binary still builds (no regressions — the new
#    code is dead-code-eliminated since nothing imports it yet)
zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast

# 3. (Optional) Build the relay server
cd server
go build .
./zzcaster-relay -addr :3939 -ttl 60s -log info

# 4. (Optional) Smoke-test the relay server
python3 ../scripts/probe_zzcaster_relay.py 127.0.0.1 3939
```

---

## Open questions for the user

1. **Default relay domain.** Currently `relay_list.txt` has CCCaster
   relays as defaults + a commented-out `nat.zzcaster.com` placeholder.
   When you deploy, just uncomment + update with the real IP/domain.

2. **Direct vs. room-code default.** Should the UI default to direct IP
   (existing behavior, no surprise for current users) or room code
   (easier UX but new)? Recommendation: keep direct IP as default for
   the first release, flip the default in v3 once the relay has been
   live for a few weeks.

3. **STUN port.** Currently the relay uses port 3939 for BOTH TCP
   signaling AND UDP UdpData/STUN. Original plan had a separate 3940
   for STUN — collapsed into 3939 to simplify deployment. Can split
   later if needed.
