# ZZCaster — Zig 0.15 → 0.16 Migration Plan

> **Status:** Proposed. Grounded in an actual build attempt against the system
> Zig 0.16.0 (`zig version` → `0.16.0`) and inspection of `/usr/lib/zig/std`.

## TL;DR

Zig 0.16 **rewrote the entire I/O subsystem**. This is ~90% of the work.
Everything else (`@cImport`, inline asm, `@ptrCast`/`@intCast`/`@setEvalBranchQuota`,
`callconv(.c)`/`callconv(.winapi)`, the **build API**) is **unchanged** —
context.md §11 assumptions largely hold, **except §11.4 and §11.9** which are
now *more* broken (the shim is gone).

The good news: the migration is **mechanical and scoped** — one `build.zig`
fix + a handful of source files, all touching the same few API families.

---

## Ground Truth (from attempting `zig build` on 0.16)

First real error:
```
build.zig:13:25: error: root source file struct 'fs' has no member named 'cwd'
        var dir = std.fs.cwd().openDir(sdl2_mingw_dir, .{}) ...
```
Zig halts at the first error in `build.zig`, so source-file errors are not yet
visible — but the affected APIs are fully inventoried below from the codebase.

---

## What's UNCHANGED in 0.16 (no work needed)

Verified against `/usr/lib/zig/std/`:

| API | 0.16 status |
|---|---|
| `b.addLibrary(.{ .linkage=…, .root_module=… })` | ✅ present (`Build.zig:842`) |
| `b.createModule(.{…})` | ✅ present (`Build.zig:918`) |
| `b.addExecutable(…)` | ✅ present (`Build.zig:787`) |
| `mod.addCSourceFiles(.{ .files=… })` | ✅ present (`Module.zig:408`) |
| `b.pathFromRoot` / `b.pathJoin` / `b.path` | ✅ present |
| `@cImport` / `@cInclude` | ✅ unchanged |
| `callconv(.c)` / `callconv(.winapi)` | ✅ unchanged |
| `@ptrCast` / `@alignCast` / `@intCast` / `@intFromPtr` | ✅ unchanged |
| `@setEvalBranchQuota` / inline asm | ✅ unchanged |
| `std.ArrayList(T)` default = **unmanaged**, `.empty` init | ✅ — `ArrayListUnmanaged` is now aliased to `ArrayList`; existing `.empty` usage (`rollback.zig`, `spectator_manager.zig`) is **already correct** |
| `std.mem.writeInt` / `sliceTo` / `indexOfScalar` | ✅ unchanged |
| `std.process.argsWithAllocator` / `exit` | ✅ unchanged |

So context.md §11.1, §11.2, §11.3, §11.5, §11.6, §11.7, §11.8, §11.10, §11.11,
§11.12 are **no longer relevant** (they describe 0.15→0.14 pains; the APIs
they protect are stable in 0.16). §11.4 and §11.9 need updating (see below).

---

## What CHANGED in 0.16 — and the fix for each

### 1. The I/O rewrite (the big one)

In 0.16, **every `std.fs.Dir`/`File` method takes an `Io` handle as its first
argument**, and lowercase `std.io` no longer exists. There is no global
implicit I/O backend.

| 0.15 (current) | 0.16 |
|---|---|
| `std.fs.cwd()` | `std.Io.Dir.cwd()` — but methods need `io: Io` |
| `std.fs.cwd().openFile(p, .{})` | `dir.openFile(io, p, .{})` |
| `std.fs.cwd().createFile(p, .{})` | `dir.createFile(io, p, .{})` |
| `std.fs.cwd().openDir(p, .{})` | `dir.openDir(io, p, .{})` |
| `std.fs.cwd().access(p, .{})` | `dir.access(io, p, .{})` |
| `std.fs.cwd().makePath(p)` | `dir.makePath(io, p)` (or `makePathAbsolute`) |
| `std.fs.path.dirname(p)` | `std.fs.path.dirname(p)` ✅ unchanged |
| `file.readAll(&buf)` | `file.reader(io, &buf).readSliceAllNTimes(&buf)` or `file.readStreamingAll` |
| `file.writeAll(bytes)` | `file.writeStreamingAll(io, bytes)` |
| `file.writer(&buf)` (0.15) | `file.writer(io, &buf)` (0.16 — needs `io`) |
| `std.io.fixedBufferStream(&buf)` | `std.Io.Writer.fixed(&buf)` |
| `std.fs.File.stdout().deprecatedWriter()` (0.15 shim) | **GONE** — use `std.Io.File.stdout().writeStreamingAll(io, …)` or a `Writer` built from `io` |
| `stream.writer().print(...)` | `writer.print(...)` on a `std.Io.Writer` |

**The hard part:** obtaining the `Io` handle. In 0.16 the app owns its I/O
backend:

```zig
var io_backend = std.Io.Threaded.init(allocator, .{});
defer io_backend.deinit();
const io = io_backend.io();   // -> std.Io (the vtable handle)
```

For a single-threaded launcher (`main.zig`, `config.zig`, `ui.zig`,
`logging.zig`, `controller_mapper.zig`), `std.Io.Threaded.init_single_threaded`
is the simpler path. For the injected DLL (`hook.dll` / `dllmain.zig`), which
runs *inside the game's process and threads*, `init_single_threaded.io()` is
also the safe choice — it avoids spawning worker threads that could interfere
with the game.

### 2. `main()` signature

**Unchanged** — still `pub fn main() !void`. But the body must construct the
`Io` backend and thread it (or a small I/O "context" wrapper) down to every
function that touches files/stdout. This is the plumbing work.

### 3. context.md §11.4 / §11.9 updates (writer & stdout)

These were already painful in 0.15 (`deprecatedWriter()` shim). In 0.16 the
shim is **removed entirely**. The clean replacement:

- **stdout prints** (used in `main.zig`, `ui.zig`, `logging.zig`):
  ```zig
  std.Io.File.stdout().writeStreamingAll(io, "msg\n");
  ```
  or build a `std.Io.Writer` once and `.print(...)` into it.

- **file writes** (`controller_mapper.zig:301` already uses the 0.15
  `file.writer(&buf)` + `writer.interface.print` pattern — this becomes
  `file.writer(io, &buf)` and `writer.print(...)`).

### 4. `build.zig` — one-line fix

```zig
// 0.15:
var dir = std.fs.cwd().openDir(sdl2_mingw_dir, .{}) catch break :blk false;
// 0.16:
var dir = std.Io.Dir.cwd().openDir(io, sdl2_mingw_dir, .{}) catch break :blk false;
```
**Problem:** `build.zig` runs in the build runner, which sets up its own `Io`.
The build runner exposes the `Io` handle how? — **needs verification** (the
build runner may provide `b.io` or require `std.Io.Threaded.init` inside
`build`). This is the one unknown to resolve in Phase 1.

---

## Affected Files & Call Sites

From grepping `src/`:

### `build.zig`
- **1 call**: `std.fs.cwd().openDir(...)` (line 13) → `std.Io.Dir.cwd().openDir(io, ...)`

### `src/logging.zig`
- `std.fs.cwd().createFile(path, ...)` (init) → needs `io`
- `f.writeAll(...)` ×4 (log fn) → `f.writeStreamingAll(io, ...)`
- `std.fs.File.stdout().deprecatedWriter()` (stdout path) → removed

### `src/config.zig`
- `std.fs.cwd().openFile("zzcaster/config.ini", .{})` → `cwd().openFile(io, ...)`
- `file.readAll(&buf)` → streaming read with `io`
- `std.io.fixedBufferStream(&buf)` + `stream.writer().print(...)` → `std.Io.Writer.fixed(&buf)` + `writer.print(...)`
- `file.writeAll(...)` → `f.writeStreamingAll(io, ...)`

### `src/main.zig`
- `std.fs.File.stdout().deprecatedWriter()` → `std.Io.File.stdout().writeStreamingAll(io, ...)`
- Constructs `config`/`logging`/`ui` — these need `io` threaded in.

### `src/ui.zig`
- `std.fs.File.stdout().deprecatedWriter()` (runCli) → same fix
- `std.fs.cwd().access(...)` ×4 (in `launchGame`/`launchNetplayPeerImpl`) → `cwd().access(io, ...)`

### `src/controller_mapper.zig`
- `std.fs.cwd().createFile(...)` (saveMapping) → needs `io`
- `file.writer(&write_buf)` + `w.interface.print(...)` (line ~301) → `file.writer(io, &write_buf)` + `writer.print(...)`
- `std.fs.cwd().openFile(...)` (loadMapping) → needs `io`
- `file.readAll(&buf)` → streaming read

### `src/dllmain.zig` (hook.dll)
- Uses `std.heap.page_allocator` and the `logging.Logger` (which needs `io`).
- **Constraint:** runs inside the game process; must use
  `std.Io.Threaded.init_single_threaded.io()` (no worker threads).
- No direct `std.fs` calls in `dllmain.zig` itself — I/O is via `logging.Logger`.

### `src/keyboard.zig`
- `file.readAll(&config)` (line 52) → streaming read with `io`

### `src/rollback.zig`
- `file.readAll(data)` (line 275) → streaming read
- `.empty` inits (lines 126-128) → ✅ already correct

### `src/ipc.zig`, `src/netplay_manager.zig`, `src/spectator_manager.zig`, `src/session.zig`, `src/gamepad.zig`, `src/rollback_regions.zig`, `src/net.zig`
- **No `std.fs`/`std.io` file/stdout calls** — only Win32 `extern`s, `@cImport`,
  `std.mem`, `std.Thread`. ✅ **No changes needed.**

---

## Phased Plan

### Phase 1 — Resolve the unknown + build.zig (½ day)
1. **Verify the build-runner `Io` story.** Either `b.io` exists in 0.16's
   `std.Build`, or `build.zig` must call `std.Io.Threaded.init` itself. Check
   `/usr/lib/zig/std/Build.zig` and a current 0.16 project. This unblocks all
   other work.
2. Fix `build.zig` line 13 (`std.fs.cwd()` → `std.Io.Dir.cwd()` + `io` arg).
3. Confirm the build now proceeds past `build.zig` to surface source errors.

**Stop criteria:** `build.zig` compiles; remaining errors are all in `src/`.

### Phase 2 — Introduce an I/O context (½ day)
4. Decide the threading pattern:
   - **Launcher** (`zzcaster.exe`): create `io_backend = std.Io.Threaded.init(...)`
     once in `main()`, pass `io` (or a small `Io` struct/alias) into
     `config`/`logging`/`ui`/`controller_mapper`.
   - **DLL** (`hook.dll`): use `std.Io.Threaded.init_single_threaded.io()` in
     `DllMain` attach, store as a module-level `var io: std.Io`.
5. Add a tiny helper to avoid peppering `io` through every signature where
   it's awkward — e.g. a module-level `var app_io: std.Io` in each binary,
   set once at startup, read by the file helpers. (Trade-off: global state vs.
   plumbing depth. Recommend the global for the DLL; plumbing for the launcher.)

**Stop criteria:** every file-touching function can reach an `Io` handle.

### Phase 3 — Migrate file/stdout calls (1 day)
6. `logging.zig` first (everything depends on it): `createFile(io,...)`,
   `writeStreamingAll`, drop `deprecatedWriter`.
7. `config.zig`: `openFile`, `readAll`→streaming, `fixedBufferStream`→
   `Writer.fixed`, `writeAll`→`writeStreamingAll`.
8. `controller_mapper.zig`: `createFile`/`openFile`/`readAll`, `writer(io,&buf)`,
   `writer.print`.
9. `main.zig` + `ui.zig`: stdout writes, `access(io,...)`, thread `io`.
10. `keyboard.zig`, `rollback.zig`: `readAll`→streaming.

**Stop criteria:** `zig build -Dtarget=x86-windows-gnu` succeeds for both
artifacts on system Zig 0.16.0.

### Phase 4 — Update build-and-deploy.sh + context.md (½ day)
11. `scripts/build-and-deploy.sh` currently hard-fails on non-0.15 zig
    (`build-and-deploy.sh:68-72`). Loosen the version check to accept
    `0.15.*` **or** `0.16.*`, and prefer 0.16 when present.
12. Update `context.md` §11 (Zig quirks) to reflect that §11.4/§11.9 are
    resolved and the project now builds on 0.16. Update §2 prerequisites
    ("Zig 0.15.1+ (NOT 0.16)" → "Zig 0.16+").

**Stop criteria:** one command (`./scripts/build-and-deploy.sh`) builds +
deploys on the default environment.

### Phase 5 — Verify the DLL still loads in-game (½ day)
13. Deploy and launch offline training (fastest smoke test — the existing
    `dll_*.log` workflow). Confirm the hook attaches, `forceGotoTraining`
    fires, controller maps load — i.e. the I/O migration didn't break the
    DLL's file reads (`mapping.ini`, `config.ini`, debug log).
14. If green, the netcode-test-plan can proceed against a 0.16 build.

**Stop criteria:** offline training works identically to the 0.15 build.

---

## Risks & Open Questions

| Risk | Mitigation |
|---|---|
| **Build-runner `Io` story unknown** | Phase 1 resolves this first; it's a 1-line fix once known. |
| **DLL `Io` backend must not spawn threads** | Use `init_single_threaded.io()` — no worker threads. Verified this exists (`Threaded.zig:1674`). |
| **`readAll`/`writeAll` semantics differ under streaming** | The new streaming APIs return byte counts; wrap in a loop or use the `…All` variants that loop internally. |
| **Cross-compilation from Linux to Windows still works** | The I/O rewrite is host-independent; `win32` externs are untouched. Low risk — but Phase 5 confirms. |
| **Performance regression from Io indirection** | Negligible for this workload (a few config reads + a log file). `writeStreamingAll` is the fast path. |
| **`@cImport` of SDL2/ImGui/ENet still parses** | `@cImport` is unchanged in 0.16; the `cimgui_shim.h` workaround stays. Low risk. |

## Definition of Done
- `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast` succeeds with
  system Zig 0.16.0 — both `zzcaster.exe` and `hook.dll`.
- `./scripts/build-and-deploy.sh` builds + deploys on 0.16.
- Offline training launches and runs (Phase 5 smoke test green).
- `context.md` §11 and §2 updated; `docs/` reflects the new minimum Zig.

## Effort Estimate
~2–3 days of focused work. Phase 1 is the gate (the `Io`-in-build.zig
question); everything after is mechanical.
