#!/usr/bin/env python3
"""
zzcaster relay — end-to-end smoke test.

Tests the full relay flow against a deployed zzcaster-relay server:

  1. Host connects, sends HostRegister, expects Hosted reply
  2. Client connects, sends ClientJoin, expects MatchInfo (both sides)
  3. Both peers send UdpData on UDP — relay should send TunInfo to each
  4. STUN probe — any non-UdpData UDP packet should get 8-byte reply

Usage:
  python3 probe_zzcaster_relay.py <relay_ip> [relay_port]

  relay_port defaults to 3939.

Run this in two terminals (host + client) on different machines,
or in two terminals on the same machine to do a loopback test.
"""

import socket
import struct
import sys
import threading
import time

# ============================================================================
# Wire format — must match server/protocol.go exactly.
# ============================================================================

TYPE_UDP = ord('U')  # 0x55
ROOM_CODE_LEN = 4
ROOM_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

def encode_host_register(port: int, code: str) -> bytes:
    """[u8 type][u16 le port][u8 code_len][code bytes]"""
    code_bytes = code.encode("ascii")
    return bytes([TYPE_UDP]) + struct.pack("<H", port) + bytes([len(code_bytes)]) + code_bytes

def encode_client_join(code: str) -> bytes:
    """[u8 type][u8 code_len][code bytes]"""
    code_bytes = code.encode("ascii")
    return bytes([TYPE_UDP, len(code_bytes)]) + code_bytes

def encode_udp_data(is_client: bool, match_id: int) -> bytes:
    """[u8 isClient][u32 le matchId]"""
    return bytes([1 if is_client else 0]) + struct.pack("<I", match_id)

def decode_hosted(data: bytes) -> str:
    """'Hosted' + 4-byte code"""
    assert data[:6] == b"Hosted", f"expected Hosted, got {data[:6]!r}"
    return data[6:10].decode("ascii")

def decode_match_info(data: bytes) -> int:
    """'MatchInfo' + u32 le matchId"""
    assert data[:9] == b"MatchInfo", f"expected MatchInfo, got {data[:9]!r}"
    return struct.unpack("<I", data[9:13])[0]

def decode_tun_info(data: bytes) -> tuple[int, str]:
    """'TunInfo' + u32 le matchId + 'ip:port\\0'"""
    assert data[:7] == b"TunInfo", f"expected TunInfo, got {data[:7]!r}"
    match_id = struct.unpack("<I", data[7:11])[0]
    addr = data[11:].split(b"\x00", 1)[0].decode("ascii")
    return match_id, addr

def decode_error(data: bytes) -> tuple[int, str]:
    """'Error' + u8 code + msg bytes"""
    assert data[:5] == b"Error", f"expected Error, got {data[:5]!r}"
    return data[5], data[6:].decode("ascii", errors="replace")

# ============================================================================
# Test runners
# ============================================================================

def run_host(relay_addr: tuple[str, int], code: str, results: dict):
    role = "HOST"
    try:
        # 1. TCP connect + HostRegister
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.settimeout(10)
        tcp.connect(relay_addr)
        print(f"  [{role}] TCP connected to {relay_addr}")

        tcp.sendall(encode_host_register(46318, code))
        print(f"  [{role}] sent HostRegister(code={code})")

        data = tcp.recv(64)
        if not data:
            print(f"  [{role}] FAIL: no Hosted reply")
            results["host_err"] = "no Hosted reply"
            return
        if data[:5] == b"Error":
            code, msg = decode_error(data)
            print(f"  [{role}] FAIL: Error code={code} msg={msg!r}")
            results["host_err"] = f"Error {code}: {msg}"
            return
        assigned_code = decode_hosted(data)
        print(f"  [{role}] got Hosted(code={assigned_code})")
        if assigned_code != code:
            print(f"  [{role}] WARNING: server assigned different code {assigned_code}, expected {code}")
        results["host_code"] = assigned_code

        # 2. Wait for MatchInfo
        print(f"  [{role}] waiting for MatchInfo...")
        data = tcp.recv(64)
        if not data:
            print(f"  [{role}] FAIL: no MatchInfo")
            results["host_err"] = "no MatchInfo"
            return
        if data[:5] == b"Error":
            code, msg = decode_error(data)
            print(f"  [{role}] FAIL: Error code={code} msg={msg!r}")
            results["host_err"] = f"Error {code}: {msg}"
            return
        match_id = decode_match_info(data)
        print(f"  [{role}] got MatchInfo(matchId={match_id})")
        results["host_match_id"] = match_id

        # 3. Open UDP socket + start sending UdpData
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("", 0))
        udp.settimeout(15)
        local_udp_port = udp.getsockname()[1]
        print(f"  [{role}] local UDP port = {local_udp_port}")

        udp_data = encode_udp_data(is_client=False, match_id=match_id)
        for _ in range(40):  # ~2 seconds of probing
            udp.sendto(udp_data, relay_addr)
            time.sleep(0.05)

        # 4. Wait for TunInfo (server tells us client's UDP addr)
        # TunInfo comes over TCP!
        tcp.settimeout(10)
        try:
            data = tcp.recv(128)
            if not data:
                print(f"  [{role}] FAIL: no TunInfo")
                results["host_err"] = "no TunInfo"
                return
            if data[:7] != b"TunInfo":
                print(f"  [{role}] FAIL: expected TunInfo, got {data!r}")
                results["host_err"] = f"expected TunInfo, got {data!r}"
                return
            tun_match_id, client_addr = decode_tun_info(data)
            print(f"  [{role}] got TunInfo(matchId={tun_match_id} clientAddr={client_addr})")
            results["host_tun_info"] = (tun_match_id, client_addr)

            # 5. Hole-punch — send NullMsg to client_addr
            chost, cport = client_addr.split(":")
            cport = int(cport)
            for _ in range(20):
                udp.sendto(b"\x00", (chost, cport))
                time.sleep(0.05)
            try:
                d, a = udp.recvfrom(4096)
                print(f"  [{role}] SUCCESS: UDP recv from {a}: {d!r}")
                results["host_recv"] = (a, d)
            except socket.timeout:
                print(f"  [{role}] UDP recv timeout (no packet from client)")
                results["host_err"] = "udp timeout"
        except socket.timeout:
            print(f"  [{role}] FAIL: TCP recv timeout waiting for TunInfo")
            results["host_err"] = "tcp timeout"

        udp.close()
        tcp.close()
    except Exception as e:
        print(f"  [{role}] EXCEPTION: {e}")
        import traceback
        traceback.print_exc()
        results["host_err"] = str(e)


def run_client(relay_addr: tuple[str, int], code: str, results: dict):
    role = "CLIENT"
    time.sleep(1.0)  # let host register first
    try:
        # 1. TCP connect + ClientJoin
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.settimeout(10)
        tcp.connect(relay_addr)
        print(f"  [{role}] TCP connected to {relay_addr}")

        tcp.sendall(encode_client_join(code))
        print(f"  [{role}] sent ClientJoin(code={code})")

        data = tcp.recv(64)
        if not data:
            print(f"  [{role}] FAIL: no MatchInfo")
            results["client_err"] = "no MatchInfo"
            return
        if data[:5] == b"Error":
            code_b, msg = decode_error(data)
            print(f"  [{role}] FAIL: Error code={code_b} msg={msg!r}")
            results["client_err"] = f"Error {code_b}: {msg}"
            return
        match_id = decode_match_info(data)
        print(f"  [{role}] got MatchInfo(matchId={match_id})")
        results["client_match_id"] = match_id

        # 2. Open UDP + send UdpData
        udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        udp.bind(("", 0))
        udp.settimeout(15)
        local_udp_port = udp.getsockname()[1]
        print(f"  [{role}] local UDP port = {local_udp_port}")

        udp_data = encode_udp_data(is_client=True, match_id=match_id)
        for _ in range(40):
            udp.sendto(udp_data, relay_addr)
            time.sleep(0.05)

        # 3. Wait for TunInfo (server tells us host's UDP addr)
        tcp.settimeout(10)
        try:
            data = tcp.recv(128)
            if not data:
                print(f"  [{role}] FAIL: no TunInfo")
                results["client_err"] = "no TunInfo"
                return
            if data[:7] != b"TunInfo":
                print(f"  [{role}] FAIL: expected TunInfo, got {data!r}")
                results["client_err"] = f"expected TunInfo, got {data!r}"
                return
            tun_match_id, host_addr = decode_tun_info(data)
            print(f"  [{role}] got TunInfo(matchId={tun_match_id} hostAddr={host_addr})")
            results["client_tun_info"] = (tun_match_id, host_addr)

            # 4. Hole-punch — send a real packet to host
            hhost, hport = host_addr.split(":")
            hport = int(hport)
            for _ in range(20):
                udp.sendto(b"HELLO_FROM_CLIENT", (hhost, hport))
                time.sleep(0.05)
        except socket.timeout:
            print(f"  [{role}] FAIL: TCP recv timeout waiting for TunInfo")
            results["client_err"] = "tcp timeout"

        udp.close()
        tcp.close()
    except Exception as e:
        print(f"  [{role}] EXCEPTION: {e}")
        import traceback
        traceback.print_exc()
        results["client_err"] = str(e)


def test_stun_probe(relay_addr: tuple[str, int]):
    """Send 1-byte UDP packet (not a valid UdpData), expect 8-byte STUN reply."""
    print("\n=== STUN probe test ===")
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.settimeout(5)
    udp.sendto(b"X", relay_addr)
    try:
        data, addr = udp.recvfrom(64)
        if len(data) == 8:
            ip = ".".join(str(b) for b in data[0:4])
            port = (data[4] << 8) | data[5]
            print(f"  STUN reply: your public UDP endpoint is {ip}:{port}")
            print(f"  (compare to your local UDP port — if different, you're behind NAT)")
        else:
            print(f"  FAIL: expected 8-byte STUN reply, got {len(data)} bytes: {data!r}")
    except socket.timeout:
        print("  FAIL: no STUN reply (timeout)")
    udp.close()


def test_room_not_found(relay_addr: tuple[str, int]):
    """ClientJoin with non-existent code should return Error code=1."""
    print("\n=== Room-not-found test ===")
    try:
        tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp.settimeout(5)
        tcp.connect(relay_addr)
        tcp.sendall(encode_client_join("ZZZZ"))
        data = tcp.recv(64)
        if data[:5] == b"Error":
            code, msg = decode_error(data)
            print(f"  OK: got Error code={code} msg={msg!r}")
            if code == 1:
                print("  (correct — ErrRoomNotFound)")
            else:
                print(f"  WARNING: expected code=1 (ErrRoomNotFound), got code={code}")
        else:
            print(f"  FAIL: expected Error, got {data!r}")
        tcp.close()
    except Exception as e:
        print(f"  FAIL: {e}")


# ============================================================================
# Main
# ============================================================================

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <relay_ip> [relay_port]")
        print(f"Example: {sys.argv[0]} 203.0.113.10")
        sys.exit(1)

    relay_ip = sys.argv[1]
    relay_port = int(sys.argv[2]) if len(sys.argv) > 2 else 3939
    relay_addr = (relay_ip, relay_port)

    print(f"=== zzcaster relay smoke test against {relay_addr} ===")
    print(f"Time: {time.strftime('%Y-%m-%d %H:%M:%S UTC%z', time.gmtime())}")

    # Test 1: STUN probe (independent — no room needed)
    test_stun_probe(relay_addr)

    # Test 2: Room not found
    test_room_not_found(relay_addr)

    # Test 3: Full host+client match (loopback test — runs both threads)
    print("\n=== Full host+client match test ===")
    code = "TEST"
    results: dict = {}
    th = threading.Thread(target=run_host, args=(relay_addr, code, results))
    tc = threading.Thread(target=run_client, args=(relay_addr, code, results))
    th.start()
    tc.start()
    th.join(timeout=30)
    tc.join(timeout=30)

    print("\n=== Results ===")
    for k, v in results.items():
        print(f"  {k}: {v}")

    # Test 4: Try to register the same code twice (should fail)
    print("\n=== Room-taken test ===")
    try:
        tcp1 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        tcp1.settimeout(5)
        tcp1.connect(relay_addr)
        tcp1.sendall(encode_host_register(46318, "DUPE"))
        data1 = tcp1.recv(64)
        if data1[:6] == b"Hosted":
            print(f"  First HostRegister(DUPE) OK — got Hosted")
            # Try second with same code
            tcp2 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            tcp2.settimeout(5)
            tcp2.connect(relay_addr)
            tcp2.sendall(encode_host_register(46318, "DUPE"))
            data2 = tcp2.recv(64)
            if data2[:5] == b"Error":
                code_e, msg = decode_error(data2)
                print(f"  Second HostRegister(DUPE) → Error code={code_e} msg={msg!r}")
                if code_e == 4:
                    print("  (correct — ErrRoomTaken)")
            else:
                print(f"  FAIL: expected Error on duplicate, got {data2!r}")
            tcp2.close()
        else:
            print(f"  First HostRegister failed: {data1!r}")
        tcp1.close()
    except Exception as e:
        print(f"  FAIL: {e}")

    print("\n=== Smoke test complete ===")
