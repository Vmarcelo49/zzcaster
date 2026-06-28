# In-Game ImGui Overlay — Feasibility & Implementation Plan

> **Status**: Documentation only. User explicitly deferred UX/scope decisions.
> **Goal**: Render an ImGui overlay inside the MBAA.exe process by hooking its D3D9 device from `hook.dll`.
> **Approach**: Port CCCaster's `3rdparty/d3dhook/` approach to Zig, using zgui for the ImGui API (per user's directive).
> **Reference**: `https://github.com/Rhekar/CCCaster` — `3rdparty/d3dhook/D3DHook.cc`, `targets/DllOverlayUi*.cpp`

---

## 1. Why this is feasible

zzcaster's `hook.dll` is **already injected** into MBAA.exe via `CreateRemoteThread(LoadLibraryA)` from the launcher. We have:

1. **Arbitrary code execution in MBAA's address space** — `dllmain.zig:frameStep()` runs once per game frame, patched in via `asm_hacks.applyPreLoadHacks()` (the main-loop hook at `0x440D16` etc.).
2. **A working `writeBytes` primitive** (`asm_hacks.zig:342`) that does `VirtualProtect(PAGE_EXECUTE_READWRITE)` → `memcpy` → `VirtualProtect(restore)` → `FlushInstructionCache`. This is exactly what we need for inline JMP hooks on D3D9 vtable methods.
3. **An existing zgui dependency** in `build.zig.zon` (commit `bfbebed3`), currently linked only into `launcher_mod`. Adding a second link into `dll_mod` is a one-liner.
4. **CCCaster's reference implementation** — `D3DHook.cc` is ~340 lines of straightforward Win32 + D3D9 vtable patching. We don't need to invent anything new.

MBAACC is a 32-bit DirectX 9 game (confirmed: `CC_D3DX9_OBJ_ADDR = 0x76E7D4` is a `uint32_t*` pointing at the IDirect3DDevice9 vtable; CCCaster's `InitDirectX` creates a temp device to read vtable offsets, then `HookDirectX` patches `Present`/`Reset`/`EndScene` at vtable indices 17/16/42). The same approach works for zzcaster.

---

## 2. CCCaster's reference architecture

### 2.1 Component map

```
3rdparty/d3dhook/
├── D3DHook.cc        — vtable patching (Present/Reset/EndScene), temp-device creation
├── D3DHook.h
├── CHookJump.cc      — generic 5-byte JMP hook (e9 rel32) with save/restore
├── CHookJump.h
├── CDllFile.h        — LoadLibrary / GetProcAddress wrapper
└── IRefPtr.h         — COM-style smart pointer

targets/
├── DllOverlayUi.cpp          — orchestrator: PresentFrameBegin → InitializeDirectX → renderOverlayText + doEndScene
├── DllOverlayUiImGui.cpp     — ImGui init + EndScene hook body (only compiled with -DLOGGING)
├── DllOverlayUiText.cpp      — plain-text overlay (the actual production overlay; no ImGui)
└── DllOverlayPrimitives.hpp  — D3D9 DrawRectangle/Box/Circle helpers
```

### 2.2 CCCaster's hook sequence

```c
// DllHacks.cpp:222 — called from initializePostLoad (after the game's main loop is hooked)
InitDirectX(windowHandle);   // create temp device, read vtable, store offsets
HookDirectX();               // install inline-JMP hooks on Present/Reset/EndScene
```

`InitDirectX` (D3DHook.cc:231-290):
1. `LoadLibrary("d3d9.dll")` → `GetProcAddress("Direct3DCreate9")`
2. `Direct3DCreate9(D3D_SDK_VERSION)` → `IDirect3D9*`
3. `GetAdapterDisplayMode(D3DADAPTER_DEFAULT, &d3ddm)` to get the back-buffer format
4. `CreateDevice(D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd, D3DCREATE_SOFTWARE_VERTEXPROCESSING, &d3dpp, &pD3DDevice)`
5. Read the device's vtable: `UINT_PTR* pVTable = *(UINT_PTR**)pD3DDevice;`
6. Compute offsets: `m_nDX9_Present = pVTable[17] - dllBase;` etc.
7. Release the temp device.

`HookDirectX` (D3DHook.cc:292-321):
1. Resolve absolute addresses: `s_D3D9_Present = dllBase + m_nDX9_Present;` (same for Reset, EndScene)
2. `m_Hook_Present.InstallHook(s_D3D9_Present, DX9_Present)` — writes a 5-byte `JMP rel32` at the start of the real Present.
3. Same for Reset and EndScene.

The hooks (D3DHook.cc:146-229) follow a "swap-call-restore" pattern:
```c
HRESULT __stdcall DX9_EndScene(IDirect3DDevice9* pDevice) {
    m_Hook_EndScene.SwapOld(s_D3D9_EndScene);   // restore original bytes
    g_pDevice = pDevice;                          // capture for later
    if (first_time) DX9_HooksInit(pDevice);       // vtable AddRef/Release hooks
    EndScene(pDevice);                             // ← our overlay code runs here
    HRESULT hRes = s_D3D9_EndScene(pDevice);      // call the real EndScene
    DX9_HooksVerify(pDevice);                      // re-hook if vtable was restored
    m_Hook_EndScene.SwapReset(s_D3D9_EndScene);  // re-plant the JMP
    return hRes;
}
```

The `SwapOld`/`SwapReset` dance is necessary because inline JMP hooks are not thread-safe and the game may call Present/EndScene from multiple threads. By un-hooking for the duration of the real call, re-entrant calls work correctly.

### 2.3 CCCaster's ImGui wiring

`DllOverlayUiImGui.cpp` (only compiled with `#ifdef LOGGING` — debug builds):
- `initImGui(device)` runs once on first Present: creates ImGui context, calls `ImGui_ImplWin32_Init(windowHandle)` + `ImGui_ImplDX9_Init(device)`.
- `EndScene(device)` runs every frame the `doEndScene` flag is set (set by `PresentFrameBegin`, cleared by `EndScene`):
  ```c
  ImGui_ImplDX9_NewFrame();
  ImGui_ImplWin32_NewFrame();
  // Manually feed left mouse button (CCCaster doesn't use ImGui's full input backend)
  ImGui::GetIO().MouseDown[0] = (GetAsyncKeyState(VK_LBUTTON) != 0);
  ImGui::NewFrame();
  // ... user code (their demo window) ...
  ImGui::EndFrame();
  ImGui::Render();
  ImGui_ImplDX9_RenderDrawData(ImGui::GetDrawData());
  ```

Note that CCCaster's `Present` hook calls `BeginScene()` + `EndScene()` itself before the real `Present` — this is because the game's natural `EndScene` happens many times per frame (intermediate scene batches), and ImGui needs to render exactly once per actual presented frame. The `doEndScene` flag is set on `Present` and cleared on the next `EndScene` after our render — so we render in the `EndScene` immediately preceding `Present`.

**Important**: The production CCCaster overlay is **not** ImGui — it's `DllOverlayUiText.cpp`, which uses raw D3D9 vertex buffers + texture atlases to render text primitives. ImGui (`DllOverlayUiImGui.cpp`) is debug-only. We will go with ImGui from the start because (a) the user asked for it, (b) zgui makes it easy, (c) the performance overhead of ImGui on a 60fps game is negligible (~0.3ms/frame).

### 2.4 MBAACC's D3D9 device location

CCCaster's `Constants.hpp:65` defines `CC_D3DX9_OBJ_ADDR = (uint32_t*) 0x76E7D4` — a global pointer in MBAACC's data segment that holds the `IDirect3DDevice9*`. We could read this directly instead of creating a temp device, **but only after the game has initialized D3D9**. The temp-device approach is more robust because:
- It doesn't depend on MBAACC having initialized D3D9 by the time we hook (we can hook at any time post-LoadLibrary).
- It works on any D3D9 game without reverse-engineering the device pointer address.

For zzcaster we'll use the temp-device approach (matches CCCaster). The device pointer at `0x76E7D4` is a useful **sanity check** — after hooking, we can read it and verify our hook is on the same vtable.

---

## 3. zzcaster implementation plan

### 3.1 Phasing

| Phase | Goal | Risk | LOC delta |
|-------|------|------|-----------|
| **P1 — D3D9 hook skeleton** | Port `D3DHook.cc` to Zig. Hooks fire; we log "Present called" each frame. No rendering yet. | Medium — D3D9 COM vtable layout is finicky; need to get the C ABI right. | +250 |
| **P2 — ImGui init + render** | Add zgui to dll_mod. Wire up `ImGui_ImplDX9_NewFrame` / `RenderDrawData` in the EndScene hook. Render a static "Hello world" window. | Medium — zgui doesn't ship a `win32_dx9` backend; we use `.no_backend` and wire `imgui_impl_dx9.cpp` + `imgui_impl_win32.cpp` manually via `addCSourceFiles`. | +200 |
| **P3 — Debug HUD** | Add a debug overlay window (FPS, frame time, world_timer, indexed_frame, state, RTT, spectator count). Driven by data already in `dll_state.zig` / `netplay_manager.zig`. | Low — pure UI work. | +150 |
| **P4 — Netplay status HUD** | User-facing match info (connection state, remote name, wi-fi indicator, desync/rollback counters). Toggleable. | Low. | +120 |
| **P5 — Input routing** | Mouse + keyboard routing through `ImGui_ImplWin32_WndProcHandler` so the overlay is actually interactive (click-drag windows, type in fields). Requires hooking MBAACC's WindowProc (CCCaster already does this via `MH_CreateHook` for unrelated reasons). | Medium — WindowProc hooking is invasive; need to be careful not to break game input. | +100 |

**Each phase is independently testable** by injecting the DLL and observing the game.

### 3.2 P1 — D3D9 hook skeleton (detailed)

**New file**: `src/dll/d3d9_hook.zig`

**Zig types** (use `@cImport` of `<d3d9.h>` — available via MinGW headers shipped with the SDL2 fetch):
```zig
const d3d9 = @cImport({
    @cInclude("d3d9.h");
});

const IDirect3DDevice9 = d3d9.IDirect3DDevice9;
const D3DPRESENT_PARAMETERS = d3d9.D3DPRESENT_PARAMETERS;
const D3DDISPLAYMODE = d3d9.D3DDISPLAYMODE;

// Vtable method indices (from d3d9.h IDirect3DDevice9 vtable)
const INTF_DX9_RESET: usize = 16;
const INTF_DX9_PRESENT: usize = 17;
const INTF_DX9_ENDSCENE: usize = 42;
```

**Hook storage** (file-level):
```zig
var g_d3d9_dll: ?*anyopaque = null;
var g_real_present: ?*const fn (*IDirect3DDevice9, ?*const RECT, ?*const RECT, ?HWND, ?*const RGNDATA, u32) callconv(.winapi) HRESULT = null;
var g_real_reset: ?*const fn (*IDirect3DDevice9, ?*D3DPRESENT_PARAMETERS) callconv(.winapi) HRESULT = null;
var g_real_endscene: ?*const fn (*IDirect3DDevice9) callconv(.winapi) HRESULT = null;

var g_hook_present: HookJump = .{};
var g_hook_reset: HookJump = .{};
var g_hook_endscene: HookJump = .{};

var g_initialized: bool = false;
var g_device: ?*IDirect3DDevice9 = null;
```

**5-byte JMP hook** (port of CHookJump.cc):
```zig
const HookJump = struct {
    jump: [5]u8 = .{0} ** 5,
    old_code: [5]u8 = .{0} ** 5,
    old_protect: u32 = 0,
    installed: bool = false,

    fn install(self: *HookJump, target: *anyopaque, hook: *anyopaque) bool {
        if (self.installed) return true;
        const target_ptr: [*]u8 = @ptrCast(target);
        if (k32.VirtualProtect(target_ptr, 8, 0x40, &self.old_protect) == 0) return false;
        // 0xE9 rel32
        self.jump[0] = 0xE9;
        const disp: i32 = @intCast(@intFromPtr(hook) - @intFromPtr(target) - 5);
        std.mem.writeInt(i32, self.jump[1..5], disp, .little);
        @memcpy(&self.old_code, target_ptr[0..5]);
        @memcpy(target_ptr[0..5], &self.jump);
        _ = k32.VirtualProtect(target_ptr, 8, self.old_protect, &self.old_protect);
        _ = k32.FlushInstructionCache(null, target_ptr, 5);
        self.installed = true;
        return true;
    }

    fn swapOld(self: *HookJump, target: *anyopaque) void {
        if (!self.installed) return;
        const target_ptr: [*]u8 = @ptrCast(target);
        var old: u32 = 0;
        _ = k32.VirtualProtect(target_ptr, 5, 0x40, &old);
        @memcpy(target_ptr[0..5], &self.old_code);
        _ = k32.VirtualProtect(target_ptr, 5, old, &old);
    }

    fn swapReset(self: *HookJump, target: *anyopaque) void {
        if (!self.installed) return;
        const target_ptr: [*]u8 = @ptrCast(target);
        var old: u32 = 0;
        _ = k32.VirtualProtect(target_ptr, 5, 0x40, &old);
        @memcpy(target_ptr[0..5], &self.jump);
        _ = k32.VirtualProtect(target_ptr, 5, old, &old);
    }
};
```

**Init** (port of `InitDirectX` + `HookDirectX`):
```zig
pub fn initAndHook(window: ?HWND) !void {
    if (g_initialized) return;
    g_initialized = true;

    // Step 1: Load d3d9.dll + get Direct3DCreate9
    const d3d9_dll = w32.LoadLibraryA("d3d9.dll") orelse return error.D3D9LoadFailed;
    g_d3d9_dll = d3d9_dll;
    const pCreate9 = w32.GetProcAddress(d3d9_dll, "Direct3DCreate9") orelse return error.NoCreate9;
    const create9: *const fn (u32) callconv(.winapi) ?*d3d9.IDirect3D9 = @ptrCast(@alignCast(pCreate9));

    // Step 2: Create IDirect3D9
    const d3d = create9(d3d9.D3D_SDK_VERSION) orelse return error.Create9Failed;
    defer _ = d3d.*.lpVtbl.*.Release(d3d);

    // Step 3: Get display mode + present params
    var mode: d3d9.D3DDISPLAYMODE = undefined;
    if (d3d.*.lpVtbl.*.GetAdapterDisplayMode(d3d, d3d9.D3DADAPTER_DEFAULT, &mode) < 0) return error.GetModeFailed;

    var pp: d3d9.D3DPRESENT_PARAMETERS = std.mem.zeroes(d3d9.D3DPRESENT_PARAMETERS);
    pp.Windowed = 1;
    pp.SwapEffect = d3d9.D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = mode.Format;

    // Step 4: Create temp device, read vtable, release
    var temp_dev: ?*d3d9.IDirect3DDevice9 = null;
    if (d3d.*.lpVtbl.*.CreateDevice(d3d, d3d9.D3DADAPTER_DEFAULT, d3d9.D3DDEVTYPE_HAL, window, d3d9.D3DCREATE_SOFTWARE_VERTEXPROCESSING, &pp, &temp_dev) < 0) return error.CreateDeviceFailed;
    const vtable: [*]usize = @ptrCast(@alignCast(@as(*?*anyopaque, @ptrCast(temp_dev)).*));
    const present_addr = vtable[INTF_DX9_PRESENT];
    const reset_addr = vtable[INTF_DX9_RESET];
    const endscene_addr = vtable[INTF_DX9_ENDSCENE];
    _ = temp_dev.?.*.lpVtbl.*.Release(temp_dev.?);

    // Step 5: Save real function pointers + install hooks
    g_real_present = @ptrFromInt(present_addr);
    g_real_reset = @ptrFromInt(reset_addr);
    g_real_endscene = @ptrFromInt(endscene_addr);

    _ = g_hook_present.install(@ptrFromInt(present_addr), @ptrCast(&hookPresent));
    _ = g_hook_reset.install(@ptrFromInt(reset_addr), @ptrCast(&hookReset));
    _ = g_hook_endscene.install(@ptrFromInt(endscene_addr), @ptrCast(&hookEndScene));
}
```

**Hook bodies**:
```zig
fn hookPresent(device: *IDirect3DDevice9, src: ?*const RECT, dst: ?*const RECT, hwnd: ?HWND, unused: ?*const RGNDATA, flags: u32) callconv(.winapi) HRESULT {
    g_hook_present.swapOld(@ptrCast(g_real_present.?));
    g_device = device;
    // PresentFrameBegin: set doEndScene = true, possibly call BeginScene/EndScene
    presentFrameBegin(device);
    const hr = g_real_present.?(device, src, dst, hwnd, unused, flags);
    presentFrameEnd(device);
    g_hook_present.swapReset(@ptrCast(g_real_present.?));
    return hr;
}

fn hookEndScene(device: *IDirect3DDevice9) callconv(.winapi) HRESULT {
    g_hook_endscene.swapOld(@ptrCast(g_real_endscene.?));
    g_device = device;
    if (g_do_endscene) {
        g_do_endscene = false;
        endSceneOverlay(device); // ← our ImGui render goes here
    }
    const hr = g_real_endscene.?(device);
    g_hook_endscene.swapReset(@ptrCast(g_real_endscene.?));
    return hr;
}

fn hookReset(device: *IDirect3DDevice9, params: ?*D3DPRESENT_PARAMETERS) callconv(.winapi) HRESULT {
    g_hook_reset.swapOld(@ptrCast(g_real_reset.?));
    invalidateDeviceObjects(); // ImGui_ImplDX9_InvalidateDeviceObjects
    const hr = g_real_reset.?(device, params);
    g_hook_reset.swapReset(@ptrCast(g_real_reset.?));
    return hr;
}
```

**Integration** — call `d3d9_hook.initAndHook(window)` from `dllmain.zig:applyPostLoadHacks()`, after the SDL/keyboard init. We need the MBAACC window handle: use `FindWindowA("MBAACC", null)` (window class name confirmed by CCCaster's `CC_TITLE` macro — let me grep that).

```zig
// In dllmain.zig applyPostLoadHacks, after keyboard.init():
if (builtin.os.tag == .windows) {
    const hwnd = w32.FindWindowA("MBAACC", null) orelse {
        state.log.?.warn("D3D9 hook: MBAACC window not found — overlay disabled", .{});
    };
    if (hwnd) |h| {
        d3d9_hook.initAndHook(h) catch |err| {
            state.log.?.err("D3D9 hook init failed: {s}", .{@errorName(err)});
        };
    }
}
```

### 3.3 P2 — ImGui init + render (detailed)

**Build.zig changes**: Add a second zgui dependency instance for the DLL, with `.backend = .no_backend` (we bring our own `imgui_impl_dx9` + `imgui_impl_win32`).

```zig
// build.zig — add after the existing zgui_dep block:

// === zgui for hook.dll (D3D9 overlay) ===
// The DLL uses .no_backend because zgui doesn't ship a win32_dx9 backend.
// We compile imgui_impl_dx9.cpp + imgui_impl_win32.cpp ourselves and call
// them through zgui's raw FFI.
const zgui_dll_dep = b.dependency("zgui", .{
    .target = target,
    .optimize = optimize,
    .backend = .no_backend,
});
zgui_dll_dep.artifact("imgui").step.dependOn(&patch_zgui.step);
dll_mod.addImport("zgui", zgui_dll_dep.module("root"));
dll_mod.linkLibrary(zgui_dll_dep.artifact("imgui"));

// Vendor the two backend .cpp files into the DLL build.
// Fetch from the imgui source tree that zgui already downloaded.
const imgui_src_dir = zgui_dll_dep.artifact("imgui").root_module.root_dir;
dll_mod.addCSourceFile(.{
    .file = b.pathJoin(&.{ imgui_src_dir, "imgui/backends/imgui_impl_dx9.cpp" }),
    .flags = &.{ "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS", "-DImGui_ImplDX9_GetBackendPlatformName=..." },
});
dll_mod.addCSourceFile(.{
    .file = b.pathJoin(&.{ imgui_src_dir, "imgui/backends/imgui_impl_win32.cpp" }),
    .flags = &.{},
});
dll_mod.linkSystemLibrary("d3d9", .{});
dll_mod.linkSystemLibrary("dxguid", .{});
```

(Note: the exact path to the imgui source inside the zgui dependency needs to be verified — it may be under `.zig-cache/` or `zig-out/`. We may need to vendor the two `.cpp` files into `libs/imgui-backends/` for stability. This is a P2 implementation detail.)

**New file**: `src/dll/overlay.zig`

```zig
const std = @import("std");
const zgui = @import("zgui");
const d3d9 = @cImport({ @cInclude("d3d9.h"); });
const w32 = @import("common").win32;

var g_initialized: bool = false;
var g_hwnd: ?HWND = null;

/// Called from hookEndScene on the first frame we have a device.
pub fn initIfNeeded(device: *d3d9.IDirect3DDevice9, hwnd: ?HWND) void {
    if (g_initialized) return;
    g_initialized = true;
    g_hwnd = hwnd;

    zgui.initAll();
    zgui.backend.initNoBackend(); // sets up the context but no platform/renderer

    // Manually call the C backend init functions (zgui doesn't wrap these for .no_backend)
    const imgui_impl_win32 = @cImport({
        @cInclude("imgui.h");
        @cInclude("imgui_impl_win32.h");
    });
    const imgui_impl_dx9 = @cImport({
        @cInclude("imgui.h");
        @cInclude("imgui_impl_dx9.h");
    });
    _ = imgui_impl_win32.ImGui_ImplWin32_Init(hwnd);
    _ = imgui_impl_dx9.ImGui_ImplDX9_Init(device);

    // Style
    zgui.style.styleColorsDark();
    zgui.io.setIniFilename(null); // no persistent layout
}

/// Called from hookEndScene every frame.
pub fn render(device: *d3d9.IDirect3DDevice9) void {
    if (!g_initialized) return;

    const imgui_impl_win32 = @cImport(...);
    const imgui_impl_dx9 = @cImport(...);

    imgui_impl_win32.ImGui_ImplWin32_NewFrame();
    imgui_impl_dx9.ImGui_ImplDX9_NewFrame();
    zgui.backend.newFrameNoBackend();
    zgui.newFrame();

    drawHud();

    zgui.endFrame();
    zgui.render();
    imgui_impl_dx9.ImGui_ImplDX9_RenderDrawData(zgui.getDrawData());
}

fn drawHud() void {
    // P3: actual HUD content
    if (zgui.begin("zzcaster", .{ .flags = .{ .no_resize = true, .no_move = true } })) {
        zgui.text("Hello from hook.dll!", .{});
    }
    zgui.end();
}

/// Called from hookReset before the device resets.
pub fn invalidate() void {
    if (!g_initialized) return;
    const imgui_impl_dx9 = @cImport(...);
    imgui_impl_dx9.ImGui_ImplDX9_InvalidateDeviceObjects();
}
```

### 3.4 P3 — Debug HUD content (detailed)

Read these values from `dll_state.zig` / `netplay_manager.zig` and display them:

| Field | Source | Display format |
|-------|--------|----------------|
| FPS | compute from `world_timer` delta | `60.00 fps` |
| Frame time | inverse of FPS | `16.67 ms` |
| `world_timer` | `state.world_timer_addr.*` | `world=12345` |
| `indexed_frame.index` / `.frame` | `state.nm.?.indexed_frame` | `idx=3 frame=4521` |
| `state` (NetplayState) | `state.nm.?.state` | `state=in_game` |
| RTT (EMA) | `state.nm.?.rtt_ema_ms` | `rtt=42ms` |
| Rollback timer | `state.nm.?.rollback_timer` | `rb_timer=2/3` |
| Rollback in progress | `state.nm.?.isRerunning()` | `rerunning=true/false` |
| Desync detected | `state.nm.?.desync_detected` | `DESYNC!` (red) |
| Spectator count | `state.nm.?.spectators.?.numSpectators()` | `specs=2/15` |
| Heartbeat | `state.nm.?.last_packet_ms` | `last_pkt=1.2s ago` |
| Config | `is_host/is_client/is_spectator/is_training` | `mode=host` |

Window placement: top-left corner, no title bar, semi-transparent background, auto-resize. Use `zgui.setNextWindowPos(.{0, 0})` + `zgui.setNextWindowBgAlpha(0.7)`.

### 3.5 P5 — Input routing (detailed)

CCCaster hooks MBAACC's `WindowProc` via MinHook (`MH_CREATE_HOOK(WindowProc)`). zzcaster currently doesn't hook WindowProc — we'd need to add this. The flow:

1. `SetWindowLongPtr(hwnd, GWLP_WNDPROC, &ourWndProc)` to replace the game's proc.
2. In our proc: call `ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam)` first; if it returns `true`, the event was consumed by ImGui → return 0.
3. Otherwise, call the original `CallWindowProc(original_proc, hwnd, msg, wparam, lparam)`.

We only want input routing when the overlay is visible (toggle with F1 or similar). When invisible, pass everything through.

**Caveat**: MBAACC reads input via DirectInput / raw input, not via `WM_KEYDOWN`. So hooking WindowProc may not actually intercept game input. Need to test — if it doesn't work, we'd need to hook DirectInput8Create instead (much harder). For P5 we'll start with WindowProc and see what breaks.

---

## 4. UX options (deferred — user to pick)

These are the menu items the user will choose from in a follow-up. Documenting here so the choice is informed.

### 4.1 Overlay content scope

| Option | Pros | Cons |
|--------|------|------|
| **Debug HUD only** (P3) | Smallest scope. Useful for devs. | Not user-facing; doesn't add player value. |
| **Debug + Netplay status** (P3+P4) | Useful for both devs and players. | Slightly more code; need to gate debug info behind a hotkey in production builds. |
| **Add in-game settings menu** | Players can adjust delay/rollback without exiting. | Requires IPC back to launcher or direct memory writes — adds a new IPC channel. Significant scope creep. |
| **Add Spectator HUD** | Spectator sees which slot, host chain, redirect info. | Only useful when we also have multi-spectator chain (spectator-study.md P2). |

### 4.2 Visibility model

| Option | Pros | Cons |
|--------|------|------|
| **Always-on, minimal** | No input routing needed (P5 skipped). Always see FPS/state. | Can't click windows; can obscure gameplay. |
| **Hotkey toggle (F1)** | Hidden by default; show on demand. Mouse cursor appears when visible. | Requires P5 input routing for the cursor. |
| **Multi-mode (hidden / minimal / full debug)** | Flexible. | More UI state to manage. |

### 4.3 Mouse cursor

When the overlay is interactive, we need to show a mouse cursor. MBAACC likely hides the system cursor during gameplay. Options:
- `ShowCursor(true)` while overlay is visible — simple but the cursor may flicker.
- Render our own cursor via ImGui's `io.MouseDrawCursor = true` — ImGui draws a software cursor; no system cursor needed. **Recommended.**

---

## 5. Risks & unknowns

| # | Risk | Mitigation |
|---|------|-----------|
| R1 | MBAACC may use D3D9Ex (IDirect3DDevice9Ex) instead of plain IDirect3DDevice9. The vtable layout is identical for the methods we hook, but CreateDevice would need `D3DDEVTYPE_HAL` + the Ex create path. | Try plain IDirect3DDevice9 first; if `CreateDevice` fails with `D3DERR_NOTAVAILABLE`, fall back to `IDirect3D9Ex::CreateDeviceEx`. |
| R2 | The game may call Present/EndScene from multiple threads simultaneously, racing our `swapOld`/`swapReset`. | CCCaster's pattern is single-threaded by assumption. If we see crashes, add a critical section around the hook body. |
| R3 | zgui's `no_backend` mode may not expose `newFrameNoBackend()` / `getDrawData()` cleanly. Need to verify the API. | May need to call the C `ImGui::NewFrame()` / `ImGui::Render()` / `ImGui::GetDrawData()` directly via @cImport. |
| R4 | The imgui_impl_dx9.cpp / imgui_impl_win32.cpp files may not be present in zgui's vendored imgui. | Vendor them into `libs/imgui-backends/` from the upstream imgui release that matches zgui's pin (1.92.8 per build.zig.zon). |
| R5 | Hooking WindowProc (P5) may break MBAACC's input. | Test in P5 with a "passthrough only" proc first; only enable ImGui routing when overlay is visible. |
| R6 | Wine compatibility — CCCaster skips D3D9 hooking on Wine (`ProcessManager::isWine()` check in DllHacks.cpp:211). zzcaster should do the same. | Add `isWine()` detection (registry check or `ntdll` exports). Skip D3D9 hooks on Wine; the overlay just won't appear. |
| R7 | 32-bit MinGW d3d9.h headers may be incomplete or out of date. SDL2 fetch already pulls MinGW; verify d3d9.h is included. | If missing, vendor from MinGW-w64 source. |
| R8 | ImGui's font atlas texture is created on first `ImGui_ImplDX9_NewFrame`. If the device is in a lost state, this fails silently. | Handle `D3DERR_DEVICELOST` in `hookPresent`; skip overlay render until `D3DERR_DEVICENOTRESET` → `Reset` succeeds. |

---

## 6. Build verification

After each phase, verify:

1. **Compiles**: `zig build -Dtarget=x86-windows-gnu -Doptimize=ReleaseFast` succeeds.
2. **DLL size**: `hook.dll` grows by ~500KB (ImGui + backends). Sanity-check it's not 5MB (would indicate we accidentally linked the launcher's SDL2 backend too).
3. **Imports**: `objdump -p zig-out/bin/hook.dll | grep "DLL Name"` should now list `d3d9.dll` as an import.
4. **No launcher bloat**: `zzcaster.exe` size is unchanged (we only added the zgui link to `dll_mod`, not `launcher_mod`).
5. **Tests still pass**: `zig build test --summary all` — no host-side tests touch D3D9, so they should be unaffected.

---

## 7. Summary

Rendering ImGui inside MBAACC.exe is **straightforward** because:
- The DLL is already injected.
- `asm_hacks.writeBytes` already does the `VirtualProtect` dance we need.
- zgui is already a dependency; we just link it twice (once per binary).
- CCCaster's reference implementation is ~600 lines of C++ that ports cleanly to Zig.

The main work is:
- **P1**: Port `D3DHook.cc` + `CHookJump.cc` to Zig (~250 LOC).
- **P2**: Wire up `imgui_impl_dx9` + `imgui_impl_win32` via `.no_backend` + `addCSourceFiles` (~200 LOC).
- **P3-P5**: UI content + input routing (~370 LOC).

**Recommended starting point**: P1 only, with a "Hello from hook.dll" static text overlay. Get that working end-to-end on a real Windows machine before building out the debug HUD. The biggest risk is P2's zgui `.no_backend` integration — if it doesn't expose the right APIs, we may need to drop down to raw `@cImport` of imgui.h and call `ImGui::NewFrame()` etc. directly. That's a smaller-surface alternative worth keeping in our back pocket.
