# Networking Improvements Plan

**Date:** 2026-06-22
**Status:** Planning / In Progress

---

## Overview

Four networking improvements to bring zzcaster closer to parity with the original CCCaster and improve the user experience:

1. **Connection visibility** — both players see connection info
2. **Connection type detection** — show WiFi vs Ethernet
3. **CGNAT tester** — warn users who can't host
4. **Relay server + hole punching** — NAT traversal fallback

---

## Feature 1: Connection Visibility (Low priority)

### Current state
Only the host sees connection info. The client just sees "Connecting to host..." with no feedback about who they're connecting to.

### Original CCCaster behavior
Auto-accepts connections — no accept/reject gate. Both sides see each other's name only AFTER the TCP/ENet connect + InitialConfig exchange.

### Proposed improvement
- **Client side:** Show "Connected to host!" immediately when the ENet CONNECT event fires (already done)
- **Host side:** Show "Player X is connecting..." when the ENet CONNECT event fires, BEFORE the handshake completes (already done)
- **Both sides:** Show the peer's display name + connection type (Feature 2) after the name exchange phase
- **Optional:** Add an accept/reject prompt on the host side when a connection arrives

### Effort
2-3 hours if we add the accept/reject gate; 30 minutes if we just improve the existing display.

---

## Feature 2: Connection Type Detection (WiFi vs Ethernet)

### Current state
No detection. The original CCCaster also doesn't detect this.

### Windows API
`GetAdaptersAddresses` from `iphlpapi.dll`. Returns adapter info including `IfType`:
- `IF_TYPE_ETHERNET_CSMACD` (6) = Ethernet
- `IF_TYPE_IEEE80211` (71) = WiFi
- `IF_TYPE_SOFTWARE_LOOPBACK` (24) = Loopback (skip)

### Implementation approach
1. Call `GetAdaptersAddresses` with `GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER`
2. Filter for adapters that are `Up` and have a unicast IP address
3. Check `IfType` — if any up adapter is WiFi (71), the connection is "WiFi"; if all up adapters are Ethernet (6), it's "Wired"
4. Return the result as a string: `"Wired (Ethernet)"` or `"Wireless (WiFi)"`

### Non-intrusive
`GetAdaptersAddresses` is a read-only local query — no network traffic, no admin privileges needed, runs in <1ms.

### Where to add it
- New file: `src/net_util.zig` with `pub fn getConnectionType() []const u8`
- Call it during `lookupHostAddresses()` (already runs when hosting)
- Add it to the `NetplayConfig` struct as a new field: `connection_type: [16]u8`
- Exchange it during the name exchange phase (alongside `local_name`)
- Display it on the `waiting_confirmation` screen: `"Opponent: Bob (WiFi)"`

### Wine compatibility
`GetAdaptersAddresses` is implemented in Wine's `iphlpapi.dll` and should work. If it fails, fall back to `"Unknown"`.

### Effort
3-4 hours (API externs + parsing + exchange protocol + UI display).

---

## Feature 3: CGNAT Tester

### Current state
No NAT detection. The original CCCaster also has none.

### The problem with CGNAT
CGNAT (Carrier-Grade NAT) means the user's "public" IP (from checkip services) is shared among many customers. The user's router doesn't have a real public IP, so port forwarding doesn't work and UDP hole punching often fails. The user can't host.

### Detection approach using a server
1. User hosts: zzcaster opens a UDP socket on the configured port and sends a "STUN binding request" to a server
2. Server responds with the user's public `ip:port` as seen from the server
3. Compare: If the port the server sees differs from the port the user opened, the user is behind NAT (port translation occurred)
4. Second request: Send a second STUN request from a DIFFERENT local port. If the server sees a DIFFERENT public port for the second request, the NAT is symmetric (CGNAT or symmetric NAT) — hole punching will likely fail
5. Warn the user: "Your connection appears to be behind CGNAT/symmetric NAT. Hosting may not work."

### Server requirements
- A simple UDP server that receives a packet and responds with the sender's `ip:port`
- Can be the same server used for the relay (Feature 4)
- Protocol: just echo back the sender's address — 8 bytes (4 IP + 2 port + 2 padding)

### When to test
- Automatically when the user clicks "Host Game" — before showing the waiting screen
- Show the result on the host screen

### Effort
4-6 hours (client-side STUN-like probe + server endpoint + UI display).

---

## Feature 4: Relay Server + Hole Punching

### Current state
No relay support. Direct ENet connection only.

### Original CCCaster architecture
- Relay servers at `melty.argoneus.com:3939` etc. (port 3939)
- Relay is a **matchmaker + STUN-like endpoint discoverer** — it does NOT relay game data
- Protocol: both peers TCP-connect to relay → relay matches them → peers send UDP to relay → relay tells each peer the other's public UDP endpoint → peers hole-punch directly
- Used as **fallback** when direct connection fails, or forced via `--tunnel` flag

### Relay protocol (from CCCaster's server.py)
```
1 - Host opens TCP to relay, sends TypedHostingPort (type + port)
2 - Client opens TCP to relay, sends TypedConnectionAddress (type + ip:port)
3 - Relay matches them, sends MatchInfo to both (matchId)
4 - Both peers create UDP socket, send UdpData (isClient + matchId) to relay
5 - Relay sends TunInfo (matchId + peer's public ip:port) to each peer over TCP
6 - Peers hole-punch directly to each other's public endpoint
```

### Proposed implementation
**Phase A — Relay server (Python):** Matchmaker + STUN endpoint discovery (port 3939)

**Phase B — Client-side relay support (zzcaster):**
1. Add relay addresses (configurable via `relay_list.txt`)
2. Try direct ENet first (current behavior)
3. If direct fails after timeout, fall back to relay
4. If hole punch succeeds, use direct UDP for game data
5. If hole punch fails, show error

**Phase C — `--tunnel` flag:** Force relay mode (skip direct connect)

### Effort
8-12 hours (relay protocol + SmartSocket-like fallback + hole punching + testing).

---

## Implementation Order

| Priority | Feature | Effort | Dependencies |
|---|---|---|---|
| 1 | Connection type detection (WiFi/Ethernet) | 3-4h | None |
| 2 | Connection visibility (accept/reject) | 2-3h | None |
| 3 | CGNAT tester | 4-6h | Server (UDP echo endpoint) |
| 4 | Relay + hole punching | 8-12h | Server (TCP+UDP matchmaker) |

Features 1 and 2 can be done immediately. Features 3 and 4 need a server.

---

## Research Sources

- Original CCCaster relay protocol: `scripts/server.py` in [Rhekar/CCCaster](https://github.com/Rhekar/CCCaster)
- `lib/SmartSocket.cpp` — direct-connect with relay-tunnel fallback
- `lib/UdpSocket.cpp` — UDP socket with GoBackN reliable layer
- Windows `GetAdaptersAddresses` API: [MSDN](https://learn.microsoft.com/en-us/windows/win32/api/iphlpapi/nf-iphlpapi-getadaptersaddresses)
