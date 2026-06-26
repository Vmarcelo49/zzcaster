# zzcaster NAT Traversal Protocol

**Status:** Draft (Slice 1 — server skeleton)
**Last updated:** 2026-06-26
**Source:** Adapted from CCCaster's `lib/SmartSocket.cpp` + `scripts/server.py`,
extended with room codes.

This document is the **authoritative spec** for the wire format used
between zzcaster clients and the zzcaster-relay server. Both the Go
server (in `server/`) and the Zig client (in `src/net/`, forthcoming)
must implement exactly what's described here.

---

## 1. Overview

The relay is a **signaling-only** server. It does NOT relay game packets.
Game traffic flows peer-to-peer via ENet once the hole-punch is complete.
The relay's job is:

1. **Match** a host and a client by room code (over TCP).
2. **Learn** each peer's public UDP endpoint (via 5-byte `UdpData` packets on UDP).
3. **Forward** each peer's endpoint to the opposite peer (via `TunInfo` over TCP).
4. **Get out of the way.** Game traffic now flows directly between peers.

After both `TunInfo` messages have been sent, the relay deletes the room
state. The TCP connections are kept open until the peers disconnect, but
no further protocol traffic flows.

```
Host                                    Relay (TCP 3939 + UDP 3939)
 │                                       │
 │  1. TCP connect ─────────────────────►│
 │  2. send HostRegister                  │  store room, generate code if empty
 │  3. ◄── Hosted + room code ───────────┤
 │                                       │
Client                                   │
 │  4. TCP connect ─────────────────────►│
 │  5. send ClientJoin                    │  lookup room by code
 │                                       │  generate matchId
 │  6. ◄── MatchInfo + matchId ──────────┤  (sent to BOTH host and client)
 │                                       │
 │  7. UDP sendto(relay, UdpData)        │  (5 bytes: isClient + matchId, every 50ms)
 │                                       │  relay learns public UDP endpoint of each peer
 │  8. ◄── TunInfo + matchId + addr ────┤  relay tells each peer the OTHER's public UDP endpoint
 │                                       │
 │  9. UDP sendto(peer_addr, NullMsg)    │  (hole-punch probes, every 50ms, from same socket)
 │                                       │
Host ◄──── UDP peer-to-peer ENet ───────►│  (game traffic flows directly, relay is done)
```

---

## 2. Wire format conventions

- **Endianness:** All integers are **LITTLE-ENDIAN** (`<` in Python `struct`,
  `binary.LittleEndian` in Go). This matches CCCaster.
- **No length-prefix on TCP:** Initial messages (HostRegister / ClientJoin) are
  self-delimiting (the type byte + length bytes tell the receiver how many to
  read). Subsequent TCP messages from the server (`Hosted`, `MatchInfo`,
  `TunInfo`, `Error`) are also self-delimiting via their magic header.
- **No length-prefix on UDP:** UDP datagrams are atomic — one message per
  datagram. The first byte(s) identify the message type.
- **Strings:** `TunInfo`'s address string is **null-terminated** (for easier
  parsing in C-style clients). All other strings have explicit length prefixes.

---

## 3. TCP messages — client → server (initial message)

A fresh TCP connection's first packet is either a `HostRegister` or a
`ClientJoin`. The relay distinguishes them by length:

- **HostRegister** is 4 + `code_len` bytes (i.e. 4 to 8 bytes).
- **ClientJoin** is 2 + `code_len` bytes (i.e. 2 to 6 bytes).

The 4th byte of `HostRegister` is the `code_len` (0..4), so the receiver
can peek 4 bytes and check if `data[3] <= 4` to decide which kind it is.

### 3.1 HostRegister

Sent by the host when it starts hosting.

```
Offset  Length  Field       Description
------  ------  ----------  ----------------------------------------
0       1       type        'T' (TCP) or 'U' (UDP) — socket type
                            the host is listening on for direct
                            connections. zzcaster always sends 'U'
                            (ENet is UDP). CCCaster sends 'T' or 'U'.
1       2       port        u16 LE — local port the host is listening
                            on. Informational only — the relay doesn't
                            use this. Useful for "you can also connect
                            directly to <ip>:<port>" hints.
3       1       code_len    u8 — length of room code, 0 to 4.
                            0 means "server, please generate one".
4       varies  code        ASCII room code, code_len bytes.
                            Must use the unambiguous alphabet
                            ABCDEFGHJKLMNPQRSTUVWXYZ23456789
                            (no I/O/0/1).
```

Example (host wants code "ABCD", UDP, port 46318):
```
55 B4 00 04 41 42 43 44
│  │     │  │  └─────── "ABCD"
│  │     │  └────────── code_len=4
│  └─────┴───────────── port=0xB400=46080 LE (example)
└────────────────────── type='U' (0x55)
```

(Note: 46318 decimal = 0xB50E. The bytes would be `0E B5`.)

### 3.2 ClientJoin

Sent by the client when it wants to join a hosted room.

```
Offset  Length  Field       Description
------  ------  ----------  ----------------------------------------
0       1       type        'T' or 'U'. zzcaster always sends 'U'.
1       1       code_len    u8 — must be 4 (room codes are always 4 chars).
2       4       code        ASCII room code, 4 bytes.
```

Example (client joining "ABCD"):
```
55 04 41 42 43 44
│  │  └────────── "ABCD"
│  └───────────── code_len=4
└──────────────── type='U'
```

### 3.3 Server response: Hosted

Sent to the host immediately after `HostRegister`, confirming the room
was created and telling the host its assigned code (which may differ from
what the host requested if the host sent `code_len=0`).

```
Offset  Length  Field       Description
------  ------  ----------  ----------------------------------------
0       6       header      "Hosted" (ASCII)
6       4       code        ASCII room code, 4 bytes.
```

Total: 10 bytes.

### 3.4 Server response: MatchInfo

Sent to BOTH host and client when a match is made (i.e. when a client
joins a host's room). Tells both peers the `matchId` they should use
in subsequent `UdpData` packets.

```
Offset  Length  Field       Description
------  ------  ----------  ----------------------------------------
0       9       header      "MatchInfo" (ASCII)
9       4       matchId     u32 LE — non-zero, unique per match.
```

Total: 13 bytes.

### 3.5 Server response: TunInfo

Sent to the OPPOSITE peer when a `UdpData` packet arrives. Tells the
receiver the public UDP endpoint of the OTHER peer.

- When the host's `UdpData` arrives, the relay sends `TunInfo` with the
  client's address to the **client**.
- When the client's `UdpData` arrives, the relay sends `TunInfo` with the
  host's address to the **host**.

```
Offset   Length   Field       Description
------   ------   ----------  ----------------------------------------
0        7        header      "TunInfo" (ASCII)
7        4        matchId     u32 LE — same matchId as in MatchInfo.
11       varies   addr        "ip:port" ASCII, null-terminated.
```

Example (peer's public UDP endpoint is 203.0.113.10:54321):
```
54 75 6E 49 6E 66 6F  ── "TunInfo"
xx xx xx xx           ── matchId (4 bytes LE)
32 30 33 2E 30 2E 31 31 33 2E 31 30 3A 35 34 33 32 31 00
└── "203.0.113.10:54321" ─────────────────────────────┘  └ null
```

### 3.6 Server response: Error

Sent when a join fails (room not found, expired, etc.) or when the
initial message can't be parsed.

```
Offset  Length  Field       Description
------  ------  ----------  ----------------------------------------
0       5       header      "Error" (ASCII)
5       1       code        u8 — see error codes below.
6       varies  msg         ASCII error message (no length prefix;
                            receiver reads to end of TCP packet or
                            connection close).
```

Error codes:

| Code | Constant             | Meaning                                |
|------|----------------------|----------------------------------------|
| 1    | `ErrRoomNotFound`   | ClientJoin referenced a code that doesn't exist. |
| 2    | `ErrRoomExpired`    | Room existed but TTL elapsed.          |
| 3    | `ErrProtocolError`  | Malformed message or unexpected state. |
| 4    | `ErrRoomTaken`      | HostRegister with a code that already exists. |

---

## 4. UDP messages — client → server (after MatchInfo)

### 4.1 UdpData

Sent by both peers every 50ms after receiving `MatchInfo`. The relay
uses the source address of this packet to learn each peer's public UDP
endpoint, then forwards `TunInfo` to the opposite peer.

```
Offset  Length  Field       Description
------  ------  ----------  ----------------------------------------
0       1       isClient    u8 — 0 = host, 1 = client.
1       4       matchId     u32 LE — same matchId as in MatchInfo.
```

Total: 5 bytes.

The relay only forwards `TunInfo` once per side (idempotent). Duplicate
`UdpData` packets (which are expected, since peers keep blasting them
every 50ms) are silently ignored after the first.

**Keep sending UdpData even after TunInfo arrives.** This keeps the NAT
mapping on your local router fresh for the relay-bound flow, which is
the same socket you'll use to talk to the peer.

### 4.2 STUN probe (any non-UdpData UDP packet)

Any UDP packet that is NOT a valid 5-byte `UdpData` (e.g., 1 byte, 8
bytes, or 5 bytes with `matchId=0`) is treated as a STUN probe. The
relay replies with 8 bytes:

```
Offset  Length  Field       Description
------  ------  ----------  ----------------------------------------
0       4       ip          u32 BE — sender's public IPv4 address
                            (4 octets, big-endian / network order).
4       2       port        u16 BE — sender's public UDP port.
6       2       padding     u16 = 0.
```

Total: 8 bytes.

(Note: IP and port are BIG-ENDIAN here — this matches the standard STUN
RFC 5389 wire format. The rest of the protocol is little-endian.)

The client uses this to detect its NAT type:
1. Send a probe, observe the public port the relay sees.
2. If it matches the local port — direct connection (no NAT).
3. If it differs — behind NAT. Open a new socket on a different local
   port and probe again.
4. If the second probe's public port differs from the first probe's
   public port — symmetric NAT (hole-punch will fail).
5. Otherwise — cone NAT (full/restricted/port-restricted — hole-punch
   will work).

---

## 5. State machine — host side

```
[Idle]
   │ user picks "Host via Relay"
   │ generate or accept room code
   ▼
[TCP connecting to relay]
   │ TCP connect succeeds
   ▼
[Send HostRegister]
   │ receive Hosted reply
   ▼
[Waiting for client]
   │ (relay holds TCP open, polling room state)
   │ receive MatchInfo
   ▼
[Got MatchInfo]
   │ open UDP socket, bind to local port
   │ start 50ms timer: send UdpData(0, matchId) to relay
   │ (keep this going for the rest of the flow)
   ▼
[Waiting for TunInfo]
   │ receive TunInfo from relay (with client's UDP addr)
   ▼
[Got TunInfo]
   │ (still sending UdpData to relay every 50ms)
   │ start sending NullMsg (1 zero byte) to peer's UDP addr every 50ms
   ▼
[Hole-punching]
   │ poll UDP socket for incoming
   │ first packet from peer_addr → SUCCESS
   ▼
[Connected] ── hand off peer_addr to ENet ──► [ENet handshake]
```

Timeouts:
- TCP connect: 5s
- Wait for Hosted: 5s
- Wait for MatchInfo: 60s (relay TTL — if no client joins, give up)
- Wait for TunInfo: 10s after MatchInfo
- Hole-punch: 10s after first NullMsg sent

## 6. State machine — client side

```
[Idle]
   │ user enters room code, clicks "Join via Relay"
   ▼
[TCP connecting to relay]
   │ TCP connect succeeds
   ▼
[Send ClientJoin]
   │ receive MatchInfo (or Error)
   │ if Error: fail with friendly message
   ▼
[Got MatchInfo]
   │ open UDP socket, bind to local port
   │ start 50ms timer: send UdpData(1, matchId) to relay
   │ (keep this going for the rest of the flow)
   ▼
[Waiting for TunInfo]
   │ receive TunInfo from relay (with host's UDP addr)
   ▼
[Got TunInfo]
   │ (still sending UdpData to relay every 50ms)
   │ start sending NullMsg (1 zero byte) to peer's UDP addr every 50ms
   ▼
[Hole-punching]
   │ poll UDP socket for incoming
   │ first packet from peer_addr → SUCCESS
   ▼
[Connected] ── hand off peer_addr to ENet ──► [ENet handshake]
```

Same timeouts as host side.

---

## 7. Compatibility with CCCaster

zzcaster's protocol is **wire-compatible with CCCaster's** for the
following messages:

- `MatchInfo` — identical format ("MatchInfo" + u32 LE matchId)
- `TunInfo` — identical format ("TunInfo" + u32 LE matchId + "ip:port\0")
- `UdpData` — identical format (u8 isClient + u32 LE matchId, 5 bytes)

The differences are:

| Aspect | CCCaster | zzcaster |
|--------|----------|----------|
| Host's initial TCP message | `TypedHostingPort` = `'T'/'U' + u16 port` (3 bytes, no code) | `HostRegister` = `'T'/'U' + u16 port + u8 code_len + code` (4-8 bytes) |
| Client's initial TCP message | `TypedConnectionAddress` = `'T'/'U' + "ip:port"` (10-22 bytes) | `ClientJoin` = `'T'/'U' + u8 code_len + code` (6 bytes) |
| Match key | string-equal on host's public IP:port | string-equal on 4-letter room code |
| Hosted reply | (none) | `Hosted` + 4-byte code |
| Error reply | (none — server just closes TCP) | `Error` + u8 code + msg |
| STUN probe | (not in original) | Any non-UdpData UDP packet triggers an 8-byte reply |

A zzcaster client cannot talk to a CCCaster relay (different initial
message format). A CCCaster client cannot talk to a zzcaster relay
(same reason). This is intentional — the protocols diverge on the most
fundamental design point (IP-based matching vs. room codes), so
interoperability at the wire level wouldn't help.

If you ever want to support CCCaster clients on a zzcaster relay, you'd
need to detect the initial-message format on the server side (3 bytes =
CCCaster host, 10-22 bytes = CCCaster client, 4-8 bytes = zzcaster
host, 6 bytes = zzcaster client) and dispatch accordingly. Not
recommended for the first release.

---

## 8. Open questions / future extensions

1. **IPv6 support.** Currently the STUN probe rejects IPv6 senders. If
   you ever want to support IPv6 peers, extend the probe reply format
   to include an address-family byte.

2. **Multiple relays.** The protocol supports client-side iteration
   through a list of relays (try first, fall back on TCP disconnect).
   The wire format doesn't need to change — the client just maintains
   a list and tries each in order.

3. **True relay mode (fallback for symmetric NAT).** If hole-punching
   fails, the relay could optionally forward UDP packets between the
   two peers. This would require:
   - A new TCP message: `RelayMode` from client after hole-punch timeout.
   - The relay starts forwarding UDP packets: any UDP packet from peer A
     with the room's matchId is forwarded to peer B's recorded UDP
     address, and vice versa.
   - Bandwidth cost: ~5-20 KB/s per peer, plus spectators. Real money
     at scale. Don't build this unless users complain.

4. **Lobby / public room listing.** A `ListRooms` TCP message that
   returns all currently-waiting hosts. The relay already has this
   data in `RoomManager.rooms`. UI would show a list of "ABCD — Alice
   is waiting" entries that the user can click to join.

5. **Spectator support.** Currently each match is 1 host + 1 client.
   To support spectators, the relay would need to allow N clients per
   room, with the host's `TunInfo` going to all of them. This is a
   non-trivial protocol extension — defer until v3.
