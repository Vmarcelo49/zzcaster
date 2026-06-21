# ZZCaster — Wine UDP Blocker & Two-Machine Test Plan

> **Status:** Blocker precisely characterized; awaiting two-machine validation.
> Read alongside `docs/netcode-test-plan.md` (Stages 0–1 are done; this is the
> Stage 4 escalation).

---

## What's fixed (committed)

Three real fixes landed in the initial commit (`88a1699`) while bringing up
Stage 0/1 of the netcode-test-plan:

1. **`src/dllmain.zig` — DllMain stack overflow under Wine.**
   `PROCESS_ATTACH` ran on the remote `LoadLibraryA` thread, which under Wine
   has a small stack. Zig 0.16's `std.Io` (used by `logging.Logger.init` →
   `createDirPath` → `openFile`) is deep enough to blow it:
   `EXCEPTION_STACK_OVERFLOW (0xc00000fd)` → the loader returns 0 → the DLL is
   silently unloaded → **no `dll_*.log` was ever created** (the original
   "nothing happens" symptom).
   **Fix:** DllMain does the bare minimum (wire `frame_callback` + spawn a
   worker thread) and an **8MB-stack `initThread`** runs `lazyInit()` for all
   real init (logger, IPC, ASM hooks, config). Logger init also gained a
   fallback chain (`zzcaster/` → CWD root → `%TEMP%`) so a logging failure
   can never prevent the DLL from initializing.

2. **`src/launcher.zig` — injection result was never checked.**
   `CreateRemoteThread` + `LoadLibraryA` returned a thread handle that
   "succeeded" even when the load failed. **Fix:** resolve an absolute DLL
   path (target CWD ≠ launcher CWD under Wine) and check `GetExitCodeThread`
   so a failed `LoadLibraryA` is reported instead of silently skipped. This
   diagnostic is what surfaced the stack overflow in #1.

3. **`src/netplay_manager.zig` — Stage 0.3 ENet diagnostics.**
   Added `DIAG:` logging in `initEnet` (`host_create` result, resolved peer
   dotted-quad, `host_connect` return) and connect-phase event tracking so
   the 60s-cap error distinguishes silent timeout vs peer-refused. These are
   the lines that let us confirm both sides set up ENet correctly.

After these fixes, a single host instance runs cleanly: the DLL loads,
logs, installs all hooks, reaches chara-select, and binds ENet on port 46318.

---

## The remaining blocker (precisely characterized)

**Wine's winsock does not deliver UDP to the host's bound socket.**

This is the original *"ENet connection between two Wine processes had
issues"* from `context.md` §8 — now reproduced and explained.

### Evidence

With both instances running (host in `~/.wine-zz-host`, joiner in
`~/.wine-zz-join`), the logs show:

```
HOST:   DIAG: host_create returned 17cc8d8 — ENet listening on port 46318
JOINER: DIAG: resolved peer = 127.0.0.1:46318
JOINER: DIAG: host_connect returned 17bfdc8
JOINER: ENet connecting to 127.0.0.1:46318
```

Both sides set up ENet correctly. The joiner sends connect packets. But:

- **The joiner's `sendto` works.** A native Python listener bound to
  `127.0.0.1:46318` received the joiner's ENet connect packets (260 bytes,
  valid `8fff4c07…` reliable-connect header). So Wine → Linux loopback
  sendto is fine.
- **The Wine host's `recvfrom` gets nothing.** ENet's
  `enet_protocol_receive_incoming_commands` calls `WSARecvFrom` every
  `host_service`, and Wine's winsock trace shows it returning
  `0xc00000a3 (STATUS_NOT_FOUND)` — "no data" — every time, even while
  the joiner is actively sending.
- **The kernel socket is unreliable.** `ss` sometimes shows the host's
  socket on `0.0.0.0:46318` (co-owned by `MBAA.exe` + `wineserver`); other
  times it's absent even though ENet logged "listening". Packets sent to it
  never queue (`Recv-Q` stays 0).

### Conclusion

Wine routes socket I/O through the **wineserver** async-I/O machinery. For
this UDP bind, that machinery isn't surfacing kernel-delivered packets to
the application's `recvfrom`. This is a Wine winsock limitation, **not** a
bug in our DLL or ENet — the ENet code path is correct and would work on
real Windows.

> **Note on `SO_REUSEADDR`:** an earlier experiment set `SO_REUSEADDR`
> *before* bind, which made `host_create` succeed on a port a prior run had
> left wedged. But pre-bind `SO_REUSEADDR` also allows **multiple sockets to
> bind the same port**, and the Linux kernel then delivers each incoming UDP
> datagram to only one of them — starving the older listener. That created a
> confusing "two MBAA.exe on 46318" red herring. `libs/enet/host.c` is now
> pristine upstream; the real fix is clean process teardown between runs, not
> `SO_REUSEADDR`.

---

## Two-machine test (Stage 4 escalation)

Goal: confirm the netcode itself works when Wine's winsock is out of the
picture — i.e., on real Windows. Two sub-stages, cheapest first.

### Stage 4a — Two localhost instances inside ONE Windows machine

This matches the plan's "two localhost instances inside the one VM first".
It eliminates Wine entirely while keeping loopback-only networking.

**Setup (one Windows host):**
1. Install the MBAACC Community Edition to a folder, e.g. `C:\MBAACC`.
2. Build the binaries on the Linux dev box and copy them across, OR build
   on Windows:
   ```
   zig build -Dtarget=x86-windows-gnu -Doptimize=Debug
   # → zig-out/bin/zzcaster.exe, zig-out/bin/hook.dll
   ```
3. Deploy per `scripts/build-and-deploy.sh` layout:
   - `C:\MBAACC\zzcaster.exe`
   - `C:\MBAACC\zzcaster\hook.dll`
   - `C:\MBAACC\zzcaster\SDL2.dll` (from `libs/sdl2-mingw/i686-w64-mingw32/bin/`)

**Run (two terminals on the Windows host):**
```
:: Terminal 1 — host
cd C:\MBAACC
zzcaster.exe --mode=host --port=46318

:: Terminal 2 — joiner (after the host window appears)
cd C:\MBAACC
zzcaster.exe --mode=join --peer=127.0.0.1:46318
```

**Pass criteria:**
- Host `dll_<pid>.log`: `ENet listening on port 46318` → `Main peer connected`
- Joiner `dll_<pid>.log`: `ENet connecting to 127.0.0.1:46318` → `ENet peer connected!`
- Both advance past chara-select into a playable match, no
  `Waiting for remote input... (5s elapsed)` stall.

If 4a passes, the netcode is sound and the Wine UDP issue is confirmed as
the only blocker. Proceed to 4b for real-network validation.

### Stage 4b — Two separate Windows machines (real network)

Same binaries, but the joiner points at the host's LAN IP:

```
:: Host (machine A) — note its LAN IP, e.g. 192.168.1.10
zzcaster.exe --mode=host --port=46318

:: Joiner (machine B)
zzcaster.exe --mode=join --peer=192.168.1.10:46318
```

Ensure Windows Firewall allows UDP 46318 inbound on the host (or temporarily
disable the firewall for the test). Pass criteria same as 4a.

---

## If the Windows VM is impractical: alternate workarounds

These weren't chosen as the primary path because they're speculative, but
they're documented here in case the VM route is blocked:

- **Patch ENet's `win32.c` to bypass Wine's broken `select()`.** Probe
  readiness with `ioctlsocket(FIONREAD)` and call `recvfrom` directly,
  rather than trusting `enet_socket_wait`'s `select`. Risky — may not fully
  work, and diverges ENet from upstream.
- **Try `wine-staging`** instead of stable Wine 11.11; staging sometimes has
  winsock fixes ahead of stable.
- **Run the host on Windows and only the joiner under Wine** (hybrid). The
  joiner's sendto already works under Wine; only the host's recv is broken.

---

## Reproducing the Wine blocker (for reference)

On the Linux dev box, with both Wine prefixes created:

```
# Host
WINEPREFIX=~/.wine-zz-host WINEDEBUG=-all \
  wine zzcaster.exe --mode=host --port=46318

# Joiner (separate terminal, after host window appears)
WINEPREFIX=~/.wine-zz-join WINEDEBUG=-all \
  wine zzcaster.exe --mode=join --peer=127.0.0.1:46318
```

Expect: both reach chara-select, both log `ENet connecting...`, neither logs
a CONNECT, joiner stalls at `Waiting for remote input... (5s elapsed)`.
Always `wineserver -k` + `pkill -9 -f MBAA.exe` between runs to avoid stale
socket/PID collisions.

To prove the joiner's sendto reaches loopback:
```
python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1); s.bind(('0.0.0.0',46318));
s.settimeout(8); print('got', len(s.recvfrom(4096)[0]), 'bytes')"
# then launch the joiner in another terminal — it will receive bytes
```
