# CCCaster Scripts Porting Plan

This document analyzes the helper scripts from the original [CCCaster scripts directory](file:///home/marcelo/Projects/CCCaster/scripts/) and defines a prioritized plan to port or adapt them to [ZZCaster](file:///home/marcelo/Projects/personal/zzcaster).

Because ZZCaster is a modern Zig-based port, compiler-related C++ scripts (like Makefiles dependency generators and custom C++ header reflection parsers) are obsolete. However, Python-based desync debug tools, GDB monitor hooks, and matchmaking relay servers remain highly relevant and can either be copied directly or adapted with minimal configuration changes.

---

## Portability & Copyability Quick Reference

- **Direct Copy (No/Minimal Changes):** Python desync analyzers and game RNG emulators (`diff.py`, `3waydiff.py`, `rand.py`, `server.py`, `lobbyserver.py`).
- **Adaptation Required (Paths & Binaries):** Testing/GDB helper scripts (`attach`, `debug`, `monitor`, `memsearch`, `rununtildesync`, `synctest`, `Add_Handler_Protocol.bat`).
- **Obsolete / Not Recommended:** Makefile and C++ code-generation scripts (`make_depend`, `make_protocol`, `make_release`, `make_version`), system setup scripts (`setup.sh`), and old deployment scripts (`upload_latest`).

---

## Prioritized Porting Task List

### Phase 1: Critical Desync Debugging Tools (High Priority)
These tools are critical for validating the correctness of the rollback netcode engine. They are written in Python and can be **copied directly**.

- [ ] **Port [diff.py](file:///home/marcelo/Projects/CCCaster/scripts/diff.py)**
  - *Purpose:* Frame-by-frame comparison tool for sync logs from different clients to identify where the state first diverged.
  - *Action:* Copy directly to the scripts folder.
- [ ] **Port [3waydiff.py](file:///home/marcelo/Projects/CCCaster/scripts/3waydiff.py)**
  - *Purpose:* Checks lines across three traces (e.g., two matching good runs vs. one bad run) to isolate the desync point.
  - *Action:* Copy directly to the scripts folder.
- [ ] **Port [rand.py](file:///home/marcelo/Projects/CCCaster/scripts/rand.py)**
  - *Purpose:* Re-implementation and inverse (`unrand`) of MBAACC's custom PRNG. Vital for diagnosing RNG state synchronization.
  - *Action:* Copy directly to the scripts folder.

### Phase 2: Matchmaking & Netplay Infrastructure (Medium-High Priority)
These servers coordinate connections and interface with lobby backends. Written in Python, they can be **copied directly** with configuration adjustments.

- [ ] **Port [server.py](file:///home/marcelo/Projects/CCCaster/scripts/server.py)**
  - *Purpose:* TCP/UDP matchmaking coordinator and NAT hole-punching relay server running on port 3939.
  - *Action:* Copy to scripts folder; adjust ENet/port logic if ZZCaster network structure differs.
- [ ] **Port [lobbyserver.py](file:///home/marcelo/Projects/CCCaster/scripts/lobbyserver.py)**
  - *Purpose:* Matchmaking client/server that manages host lists and bridges ZZCaster with the Concerto Matchmaking API.
  - *Action:* Copy to scripts folder; test integration with `zzcaster.exe`.

### Phase 3: GDB Debugger Hooks (Medium Priority)
Shell scripts to automate attaching debuggers to the running game process. Require **adaptation** for paths/DLL names.

- [ ] **Port [attach](file:///home/marcelo/Projects/CCCaster/scripts/attach)**
  - *Purpose:* Automatically locates the `MBAA.exe` PID, attaches `gdbserver` to it, and launches local `gdb`.
  - *Action:* Port and update the GDB init script to load ZZCaster's `hook.dll` instead of `cccaster` DLLs.
- [ ] **Port [monitor](file:///home/marcelo/Projects/CCCaster/scripts/monitor)**
  - *Purpose:* Polls active processes and triggers [attach](file:///home/marcelo/Projects/CCCaster/scripts/attach) once `MBAA.exe` starts.
  - *Action:* Copy and verify shell compatibility.

### Phase 4: Test Loop Automation & Memory Search (Medium-Low Priority)
Automation tools to isolate bugs and search memory states. Require **adaptation** to invoke Zig.

- [ ] **Port [memsearch](file:///home/marcelo/Projects/CCCaster/scripts/memsearch)**
  - *Purpose:* Automates desync search using binary search (bisection) over game memory ranges, recompiling the binary each step.
  - *Action:* Rewrite compiler command from `make` to `zig build`.
- [ ] **Port [rununtildesync](file:///home/marcelo/Projects/CCCaster/scripts/rununtildesync)**
  - *Purpose:* Loop runner that repeatedly starts a test match until a desync is detected in the log file.
  - *Action:* Adjust the target log path to match ZZCaster's trace logging output.
- [ ] **Port [synctest](file:///home/marcelo/Projects/CCCaster/scripts/synctest)**
  - *Purpose:* Automation script that runs caster tests and saves state traces under a desync archive directory when desyncs occur.
  - *Action:* Update target binary from `cccaster.exe` to `zzcaster.exe`.

### Phase 5: Replay & Integration Utilities (Low Priority / Optional)
User experience utilities and game notation tools.

- [ ] **Port [sync2replay](file:///home/marcelo/Projects/CCCaster/scripts/sync2replay)**
  - *Purpose:* Parses raw synchronization trace logs into a readable sequence of inputs and state changes.
  - *Action:* Copy and verify regex compatibility with ZZCaster log format.
- [ ] **Port [Add_Handler_Protocol.bat](file:///home/marcelo/Projects/CCCaster/scripts/Add_Handler_Protocol.bat)**
  - *Purpose:* Registers custom URI scheme `cccaster://` in the Windows Registry to launch matches via browser.
  - *Action:* Rename/update Registry keys to register `zzcaster://` pointing to `zzcaster.exe`.
- [ ] **Port [debug](file:///home/marcelo/Projects/CCCaster/scripts/debug)**
  - *Purpose:* Launches GDB debugger for the launcher executable.
  - *Action:* Update executable target name.
- [ ] **Port [comboparser.py](file:///home/marcelo/Projects/CCCaster/scripts/comboparser.py)**
  - *Purpose:* Lark parser converting human fighting game notation into internal game sequence codes (used for combo trials).
  - *Action:* Only needed if ZZCaster plans to support a Trial mode. Otherwise, skip.

---

## Reference: Scripts Not Recommended for Porting

These scripts are obsolete for ZZCaster's Zig build environment and should be ignored:

| Script Name | Reason for Exclusion |
| :--- | :--- |
| [make_depend](file:///home/marcelo/Projects/CCCaster/scripts/make_depend) | Zig's compiler tracks dependencies natively. |
| [make_protocol](file:///home/marcelo/Projects/CCCaster/scripts/make_protocol) | Boilerplate generation is replaced by Zig's compile-time reflection (`comptime`). |
| [make_release](file:///home/marcelo/Projects/CCCaster/scripts/make_release) | Replaced by `zig build -Doptimize=ReleaseFast`. |
| [make_version](file:///home/marcelo/Projects/CCCaster/scripts/make_version) | Version and git hashes are managed via `build.zig` option builders. |
| [profile](file:///home/marcelo/Projects/CCCaster/scripts/profile) | GNU `gprof` is superseded by modern profilers like Tracy. |
| [setup.sh](file:///home/marcelo/Projects/CCCaster/scripts/setup.sh) | Specific to original virtual machine setup. |
| [upload_latest](file:///home/marcelo/Projects/CCCaster/scripts/upload_latest) | Deployments should use ZZCaster's local release scripts or CI/CD pipelines. |
