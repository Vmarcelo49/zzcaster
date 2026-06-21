# Network protocol: UDP packets, reliability, acks

GGPO uses UDP — never TCP. TCP's head-of-line blocking, retransmission, and congestion
control are all wrong for real-time games: a single dropped packet would stall every
subsequent frame. UDP gives you the option to lose a packet and recover via the next one,
which is exactly what rollback needs.

This file documents the wire format, the reliability-via-repetition strategy, and the ack
protocol.

## Table of contents

1. [Why UDP, not TCP](#why-udp-not-tcp)
2. [Packet types](#packet-types)
3. [Packet format](#packet-format)
4. [Reliability via repetition](#reliability-via-repetition)
5. [Ack strategy](#ack-strategy)
6. [Keep-alive](#keep-alive)
7. [Quality reports and frame advantage](#quality-reports-and-frame-advantage)
8. [Sync handshake](#sync-handshake)
9. [NAT considerations](#nat-considerations)
10. [Packet size budget](#packet-size-budget)

## Why UDP, not TCP

TCP has three properties that ruin it for rollback:

1. **Head-of-line blocking** — if packet N is lost, packets N+1, N+2, ... are queued in
   the kernel until N is retransmitted. For real-time games, this stalls the sim.
2. **Reliable retransmission** — TCP will retransmit a lost packet forever. For real-time
   games, by the time the retransmit arrives, it's too late — the rollback layer has
   already predicted around the gap.
3. **Congestion control** — TCP backs off on packet loss, which is appropriate for file
   transfers but catastrophic for games (you'd rather drop packets than slow down).

UDP gives you unreliable, unordered datagrams. The rollback layer builds its own
"reliability" on top — but it's reliability that understands the semantics of the data
(old inputs don't need to be retransmitted; the next packet carries enough history to
recover).

## Packet types

GGPO uses six packet types:

| Type            | Purpose                                                          |
|-----------------|------------------------------------------------------------------|
| `Input`         | Carries local input + recent input history + ack of remote input |
| `InputAck`      | Standalone ack when no new local input to send                   |
| `SyncRequest`   | During handshake: "what's your random seed + state hash?"        |
| `SyncReply`     | Reply to SyncRequest                                              |
| `QualityReport` | Periodic stats: frame advantage, ping, bandwidth                 |
| `KeepAlive`     | Empty packet to refresh NAT mappings and silence timers          |

Each has a 5-byte header followed by a type-specific body.

## Packet format

### Header (5 bytes, all packets)

```zig
const PacketHeader = packed struct {
    magic: u16,            // 0xFEED — version check
    kind: PacketKind,      // u8 enum
    seq: u16,              // sequence number for dedup
};
```

### Input packet body

```zig
const InputPacket = struct {
    header: PacketHeader,
    start_frame: i32,          // the frame this input is for
    ack_frame: i32,            // the last remote frame we've received
    bytes_per_input: u8,       // typically 1 or 2
    num_inputs: u8,            // how many inputs are packed (history depth)
    input_bits: [MAX_INPUT_BYTES]u8,   // the actual input
    history: [PACKET_HISTORY_BITS][MAX_INPUT_BYTES]u8,  // recent inputs
};
```

`PACKET_HISTORY_BITS` is typically 2 — the current frame plus the previous frame. This
means a single dropped Input packet is recovered by the next one, with no retransmit
needed.

For 2-player games with 1-byte inputs and 2-deep history, an Input packet is ~22 bytes.
At 60 FPS that's ~1.3 KB/s per peer — trivial bandwidth.

### SyncRequest / SyncReply

```zig
const SyncRequestPacket = struct {
    header: PacketHeader,
    random_request: u64,    // sender's random challenge
};

const SyncReplyPacket = struct {
    header: PacketHeader,
    random_reply: u64,      // echo of the request
    sender_random: u64,     // sender's own challenge (if not yet sync'd)
};
```

The handshake is:

```text
A: pick random_a, send SyncRequest{ random_a }
B: pick random_b, send SyncReply{ random_a, random_b }
A: send SyncReply{ random_b, 0 }   // confirms receipt of B's challenge
A, B: synchronizing = false, sim can start
```

Once both peers have echoed each other's challenges, they're synced. The challenges are
also useful as session IDs for logging.

### QualityReport

```zig
const QualityReportPacket = struct {
    header: PacketHeader,
    frame_advantage: i8,    // sender's local advantage (frames ahead)
    ping: u16,              // sender's measured RTT to receiver, in ms
    remote_frame: i32,      // sender's last received frame from receiver
};
```

Sent every `RECOMMENDATION_INTERVAL_MS = 240ms`. The receiver uses `frame_advantage` to
update its TimeSync.

### KeepAlive

```zig
const KeepAlivePacket = struct {
    header: PacketHeader,
};
```

Just the header. Sent when a player has no new local input for >100ms. Keeps NAT mappings
from expiring and refreshes the disconnect timer.

## Reliability via repetition

The trick: **every Input packet carries the current frame plus the last few frames'
inputs.** If packet N is lost, packet N+1 carries the missing frame's bits. No
retransmit needed.

```zig
pub fn sendInput(self: *UdpTransport, io: std.Io, frame: i32, input: GameInput,
                 queue: *const InputQueue) !void {
    var pkt: InputPacket = .{
        .header = .{ .magic = 0xFEED, .kind = .input, .seq = self.next_seq },
        .start_frame = frame,
        .ack_frame = queue.last_added_frame,
        .bytes_per_input = MAX_INPUT_BYTES,
        .num_inputs = PACKET_HISTORY_BITS + 1,
        .input_bits = input.bits,
        .history = undefined,
    };
    self.next_seq +%= 1;

    // Pack the history: previous PACKET_HISTORY_BITS frames.
    for (0..PACKET_HISTORY_BITS) |i| {
        const hist_frame = frame - @as(i32, @intCast(i + 1));
        if (hist_frame >= queue.tail) {
            const idx = queue.frameIndex(hist_frame);
            pkt.history[i] = queue.inputs[idx].bits;
        } else {
            pkt.history[i] = std.mem.zeroes([MAX_INPUT_BYTES]u8);
        }
    }

    for (self.peers) |addr| {
        try self.socket.sendTo(io, addr, std.mem.asBytes(&pkt));
    }
}
```

This is why UDP works for rollback: the data is so cheap to send that we just keep sending
it. A 22-byte packet 60 times per second is 1.3 KB/s — the protocol is "reliable" in the
sense that the next packet always carries everything you missed.

## Ack strategy

Every Input packet includes `ack_frame` — the highest frame we've successfully received
from the remote peer. This tells the remote peer "you can stop sending inputs for frames
≤ ack_frame in your history."

The remote peer responds to a high `ack_frame` by:
1. Trimming its send history (no need to send frames ≤ ack_frame).
2. Marking those frames as "confirmed received" in its own queue.

If `ack_frame` doesn't advance for several packets, the remote peer may suspect packet
loss and start sending more aggressively (more history bits per packet).

### InputAck-only packets

When the local player has no new input (e.g. their character is idle in a fighting game),
we still need to send acks so the remote peer can advance. The `InputAck` packet is a
lightweight way to do this:

```zig
pub fn sendInputAck(self: *UdpTransport, io: std.Io, ack_frame: i32) !void {
    const pkt = InputAckPacket{
        .header = .{ .magic = 0xFEED, .kind = .input_ack, .seq = self.next_seq },
        .ack_frame = ack_frame,
    };
    self.next_seq +%= 1;
    for (self.peers) |addr| {
        try self.socket.sendTo(io, addr, std.mem.asBytes(&pkt));
    }
}
```

Sent at most once per frame, even if no local input was produced. 7 bytes × 60 FPS = 420
bytes/sec — negligible.

## Keep-alive

If a player stops producing input AND stops acking (i.e., the network has gone silent in
both directions), we still need to:
1. Refresh NAT mappings (home routers drop UDP mappings after 30-60 seconds of silence).
2. Reset the disconnect timer.

`KeepAlive` packets do both:

```zig
fn maybeSendKeepAlive(self: *UdpTransport, io: std.Io) !void {
    const now_ms = io.clock.now().ms;
    if (now_ms - self.last_send_ms < 100) return;   // we've sent something recently
    const pkt = KeepAlivePacket{ .header = .{ .magic = 0xFEED, .kind = .keep_alive, .seq = self.next_seq } };
    self.next_seq +%= 1;
    for (self.peers) |addr| {
        try self.socket.sendTo(io, addr, std.mem.asBytes(&pkt));
    }
    self.last_send_ms = now_ms;
}
```

Called every frame from `UdpTransport.pump`. If the local player is idle, this fires
roughly every 100ms — well within NAT mapping refresh windows.

## Quality reports and frame advantage

Every 240ms, each peer sends a QualityReport containing:
- Their local frame advantage (how far ahead they are).
- Their measured RTT to the remote peer.
- The last frame they received from the remote peer.

The receiver uses this to update its TimeSync:

```zig
fn handleQualityReport(self: *UdpTransport, io: std.Io, session: *Session,
                       pkt: QualityReportPacket) !void {
    // The remote peer's frame advantage, from their perspective.
    // Our advantage is the negation.
    session.time_sync.remoteAdvantageReported(pkt.frame_advantage);

    // Update ping stats.
    session.stats.ping_ms = pkt.ping;

    // Ack the report so the sender can measure RTT.
    const ack = QualityReportAckPacket{
        .header = .{ .magic = 0xFEED, .kind = .quality_ack, .seq = self.next_seq },
        .original_seq = pkt.header.seq,
    };
    self.next_seq +%= 1;
    for (self.peers) |addr| {
        try self.socket.sendTo(io, addr, std.mem.asBytes(&ack));
    }
}
```

The sender measures RTT by timing how long the ack takes to come back. This isn't
precise (a single measurement has jitter) but averaged over time it's useful.

## Sync handshake

The handshake negotiates the start of the session:

```text
Both peers: synchronizing = true, sync_count = 0
A → B: SyncRequest{ random_a }
B → A: SyncReply{ random_a, random_b }
A → B: SyncReply{ random_b, 0 }   // A has confirmed B's challenge
A: sync_count = 1
B: sync_count = 1
(Both send a few more SyncRequests to verify round-trip stability)
A: synchronizing = false
B: synchronizing = false
A → B: SendInput{ frame=0, input=... }
```

The handshake also verifies that the round-trip is reasonable (a few hundred ms). If it
takes more than a few seconds, the session aborts with `error.SyncFailed`.

In code:

```zig
fn pollSync(self: *Session) !void {
    if (self.sync_state == .done) return;

    const now_ms = self.io.clock.now().ms;
    if (now_ms - self.last_sync_send_ms > 200) {
        try self.network.sendSyncRequest(self.io);
        self.last_sync_send_ms = now_ms;
    }

    if (now_ms - self.sync_started_ms > 5000) {
        return error.SyncFailed;
    }
}

fn handleSyncReply(self: *Session, pkt: SyncReplyPacket) !void {
    if (pkt.random_reply == self.sync_random) {
        self.sync_count += 1;
        if (self.sync_count >= SYNC_COUNT_THRESHOLD) {
            self.synchronizing = false;
            self.callbacks.on_event(self.ctx, .{ .running = {} });
        }
    }
}
```

`SYNC_COUNT_THRESHOLD` is typically 5 — five successful round-trips before declaring the
session synced. This filters out transient packet loss during handshake.

## NAT considerations

UDP NAT traversal is a deep topic; this section just covers the rollback-specific
concerns.

### symmetric NAT

Most home routers use full-cone or restricted-cone NAT, which work fine for
peer-to-peer UDP. Symmetric NAT (used by some carriers and corporate networks) assigns
a different external port per destination, which breaks the standard STUN approach.

If you need to support symmetric NAT, you'll need TURN (relay) — typically a small VPS
that forwards packets between peers. This adds latency but works.

### Keep-alive frequency

NAT mappings typically expire after 30-60 seconds of silence. The 100ms KeepAlive
interval above is plenty — the mapping will never expire during an active session.

If you suspend the process (e.g. laptop sleep), the mapping may expire while you're
asleep. On resume, send a few extra KeepAlives immediately to refresh.

### LAN play

On LAN, NAT isn't a concern. The handshake typically completes in <5ms and the round-trip
is <1ms. Rollback rarely triggers because inputs arrive before they're needed.

## Packet size budget

| Packet type    | Size (bytes) | Frequency          | Bandwidth (per peer) |
|----------------|--------------|--------------------|----------------------|
| Input          | ~22          | 60/sec             | 1.3 KB/s             |
| InputAck       | ~9           | 60/sec             | 540 B/s              |
| QualityReport  | ~14          | ~4/sec             | 56 B/s               |
| KeepAlive      | 5            | ~10/sec when idle  | 50 B/s               |
| SyncRequest    | ~13          | ~5/sec during sync | ~65 B/s (brief)      |
| SyncReply      | ~21          | ~5/sec during sync | ~105 B/s (brief)     |

Total: ~2 KB/s per peer during active play. For a 4-player game, that's 6 KB/s in each
direction. Trivial by modern standards.

### Jumbo frames

Don't. The protocol is designed for small packets that fit in a single UDP datagram
(<MTU, typically 1500 bytes). If your input grows beyond that (which would be very
unusual), compress it or split it across multiple packets with sequence numbers.

## See also

- [algorithm.md](algorithm.md) — How the Input packets feed the InputQueues
- [time-sync.md](time-sync.md) — How QualityReports drive TimeSync
- [data-structures.md](data-structures.md#udptransport) — The `UdpTransport` Zig struct
