---
name: imgui-desktop
description: Authoritative guide to building desktop applications with Dear ImGui 1.92.x from Zig 0.16, covering both the idiomatic zgui wrapper (zig-gamedev/zgui) and raw extern-C FFI via dear_bindings (tiawl/cimgui.zig). Use whenever the user mentions Dear ImGui, imgui, immediate-mode GUI, game tools, debug overlays, level editors, profilers, node editors, asset browsers, property inspectors, dockspaces, viewports, or wants to build a desktop application in Zig with a UI. Covers the immediate-mode mental model (Begin/End, ID stack, draw lists), the full widget API, all standard backends (SDL3/GLFW/Win32 + OpenGL3/Vulkan/DX11/Metal/WebGPU), DPI-aware fonts, theming, docking + multi-viewport, retained-state patterns, modal dialogs, performance optimization (ListClipper, draw call batching), and complete build.zig.zon + build.zig setups. Critical for avoiding the well-known Zig 0.16 / ImGui traps: `@cImport` is deprecated (use `b.addTranslateC`), `linkLibCpp()` is mandatory for the C++ shim, SDL3 vs SDL2 backend differences, and the `InitFor<Renderer>` pairing rule. Trigger this skill on ANY imgui question even if the user does not mention Zig — the ImGui material is language-agnostic and the Zig setup is illustrative.
---

# Dear ImGui for desktop apps in Zig 0.16

Dear ImGui (v1.92.x as of June 2026) is the dominant library for in-game tools, debug
overlays, and small desktop applications. It's an **immediate-mode** GUI library — you
reissue the entire UI every frame, and ImGui tracks the minimal state it needs (focus,
hover, open/close, scroll, dock positions) internally.

This skill teaches you to build production-quality desktop apps with ImGui from Zig 0.16,
using either:

- **zgui** (zig-gamedev/zgui) — a hand-crafted Zig API layered over a C++ shim. The
  default for new projects.
- **Raw FFI via dear_bindings** (tiawl/cimgui.zig) — direct calls into the C wrapper.
  For when you need the absolute latest ImGui features or full control.

Both paths are documented in depth. The first half of the skill is language-agnostic
ImGui fundamentals; the second half is Zig-specific setup and integration.

## Why ImGui for desktop apps

The traditional desktop stack (Qt, GTK, WinForms, WPF) is **retained-mode**: you build a
tree of widget objects, the library owns them, you mutate them via property setters. This
is great for forms-based apps but terrible for:

- **Game tools** — the data you're editing changes every frame; rebuilding the widget tree
  is expensive and error-prone.
- **Debug overlays** — you want to add a slider, see the value change, and remove the
  slider. No persistent tree to clean up.
- **Profiling views** — the data is a stream; a retained tree is overkill.
- **Rapid prototyping** — you don't want to design a layout file, instantiate widgets,
  wire signals. You want to write `if (button("Run")) run();`.

Immediate mode solves all of these: you write the UI inline with your data, every frame.
The library handles input routing, layout, and rendering. There's no widget tree to
synchronize with your data model.

The trade-off: you re-render every frame, even when nothing changed. At 60 FPS with a
typical ImGui app, this is <1ms of CPU — invisible. For battery-constrained laptops, you
can throttle to "render only on input."

## When to use this skill

Use ImGui when:
- You're building a game tool, debug overlay, level editor, profiler, or asset browser.
- You want a UI for a Zig CLI tool that's more than just arguments.
- You're prototyping a UI and don't want to commit to a full desktop framework.
- You need a cross-platform UI that works on Windows, macOS, and Linux with no platform-
  specific code.

Don't use ImGui when:
- You're building a forms-heavy business app (use Qt or a web UI).
- You need accessibility features (screen readers, high-contrast themes) — ImGui's a11y
  story is weak.
- You need native platform look-and-feel (menu bar integration, file dialogs) — ImGui
  draws everything itself.
- You're shipping a touch-only mobile app — ImGui is mouse/keyboard first.

## Module map

This skill is structured as a tutorial that builds a desktop app layer by layer. Read the
SKILL.md first for the big picture, then the reference files in order.

- [references/fundamentals.md](references/fundamentals.md) — Immediate-mode philosophy,
  the Begin/End pattern, the ID stack (the single most important concept in ImGui), draw
  lists, the frame lifecycle, ImGuiIO. **Start here.**
- [references/backends.md](references/backends.md) — Platform backends (SDL3, SDL2, GLFW,
  Win32) and renderer backends (OpenGL3, Vulkan, DX11, Metal, WebGPU). How they pair, how
  they slot into ImGui's `Init*` API.
- [references/api-reference.md](references/api-reference.md) — The widget catalog: windows,
  buttons, sliders, input text, tables, menus, popups, drag-drop, draw lists. With Zig
  signatures for both zgui and raw FFI.
- [references/zgui-setup.md](references/zgui-setup.md) — Using zgui: build.zig.zon,
  build.zig, the Zig-style API, when to enable opt-in modules (ImPlot, ImGuizmo,
  ImGuiNodeEditor).
- [references/raw-ffi.md](references/raw-ffi.md) — Using dear_bindings via
  tiawl/cimgui.zig: build.zig setup, calling conventions, the C++ shim, handling variadic
  functions, struct layout.
- [references/build-zig.md](references/build-zig.md) — Complete `build.zig` and
  `build.zig.zon` for a desktop app with SDL3 + OpenGL3 + docking + multi-viewport.
  Drop-in starting point.
- [references/dpi-fonts.md](references/dpi-fonts.md) — DPI-aware fonts in 1.92
  (`FontSizeBase`, `FontScaleDpi`, `DpiEnableScaleFonts`), loading TTFs, font atlases,
  custom icon fonts (FontAwesome, Material Icons).
- [references/patterns.md](references/patterns.md) — Production patterns: retained state
  in immediate mode (the `static var` problem), modal dialogs, asset browsers, property
  editors, node editors, command palettes.
- [references/performance.md](references/performance.md) — Performance: ListClipper for
  long lists, draw call batching, avoiding per-frame allocation, sleep-when-idle,
  multi-viewport costs.
- [references/examples.md](references/examples.md) — Three worked examples: a file
  explorer, a property editor / inspector, and a debug overlay.

## The 30-second pitch (for the impatient)

```zig
const std = @import("std");
const zgui = @import("zgui");
const zsdl = @import("zsdl");
const zgl = @import("zopengl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // 1. Create SDL3 window with OpenGL context
    try zsdl.init(.{ .video = true, .events = true });
    defer zsdl.quit();

    const window = try zsdl.video.Window.create(
        "My App", 1280, 720,
        .{ .opengl = true, .high_pixel_density = true },
    );
    defer window.destroy();

    const gl_ctx = try zsdl.video.GL.createContext(window);
    defer zsdl.video.GL.deleteContext(gl_ctx);

    // 2. Init zopengl (function pointer table)
    var gl: zgl.ProcTable = .{};
    try gl.init(zsdl.video.GL.getProcAddress);
    zgl.bindInstance(gl);

    // 3. Init ImGui via zgui
    try zgui.init(gpa);
    defer zgui.deinit();

    _ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", 18.0);
    zgui.getStyle().scaleAllSizes(1.0);
    zgui.io.setConfigFlags(.{ .docking_enable = true, .viewports_enable = true });
    zgui.styleColorsDark(null);

    // 4. Init the SDL3 + OpenGL3 backend
    try zgui.backend.init(@ptrCast(window), @ptrCast(gl_ctx));
    defer zgui.backend.deinit();

    // 5. Main loop
    var counter: u32 = 0;
    var float_value: f32 = 0.0;
    var done = false;
    while (!done) {
        var ev: zsdl.events.Event = undefined;
        while (zsdl.events.poll(&ev)) {
            if (ev.type == .quit) done = true;
            _ = zgui.backend.processEvent(@ptrCast(&ev));
        }

        // Get framebuffer size for HiDPI
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(fb_size.width, fb_size.height);

        // Build the UI
        if (zgui.begin("Hello, Dear ImGui!", .{})) {
            zgui.text("Counter: {d}", .{counter});
            if (zgui.button("Increment", .{})) counter += 1;
            _ = zgui.sliderFloat("Value", .{ .v = &float_value, .min = 0, .max = 1 });
        }
        zgui.end();

        // Render
        const draw_data = zgui.getDrawData();
        zgl.viewport(0, 0, @intCast(fb_size.width), @intCast(fb_size.height));
        zgl.clearColor(0.1, 0.1, 0.1, 1.0);
        zgl.clear(.{ .color = true });
        zgui.backend.draw(draw_data);
        zsdl.video.GL.swapWindow(window);
    }
}
```

The rest of this skill fills in the details: every widget, every backend, every
production pattern.

## Key concepts to internalize

Before reading the reference files, internalize these five concepts:

### 1. The ID stack

Every widget call has an ID — usually derived from its label. ImGui hashes the entire
label-stack leading to the widget. Two widgets with the same label, in different windows,
have different IDs. Two widgets with the same label in the same window collide — and the
second one will be silently ignored.

The fix: use `##` suffixes for hidden IDs, `PushID`/`PopID` for loops, and `###` for
dynamic labels. See [fundamentals.md#the-id-stack](references/fundamentals.md#the-id-stack).

### 2. The frame lifecycle

Every frame: poll events → `NewFrame` → submit widgets → `Render` → `GetDrawData` →
your GL render pass → `RenderDrawData` → swap. Skipping `NewFrame` produces garbage
state. Calling `Begin` after `Render` is undefined.

### 3. Begin/End pairing

`Begin` returns whether the window is visible. For most container widgets, you must call
`End` regardless of the return value. For nested containers like `BeginChild`, `BeginMenu`,
`BeginPopup`, you call `End*` only if `Begin*` returned true. This is the #1 source of
ImGui bugs.

### 4. State is keyed by ID

When you call `sliderFloat("Value", .{ .v = &float })`, ImGui stores the slider's drag
state (is the mouse held? what was the start value?) keyed by the slider's ID. If you
change the ID between frames, the state is lost. If two sliders share an ID, they fight.

### 5. The backend pair

ImGui doesn't render anything itself. You pair a **platform backend** (window + input)
with a **renderer backend** (graphics API). The pair must match — SDL3 platform with
OpenGL3 renderer, GLFW platform with Vulkan renderer, etc. Mismatches cause silent
failures.

## Quick reference: which backend pair?

| Your situation                                    | Use this pair                |
|---------------------------------------------------|------------------------------|
| Cross-platform desktop, simplest setup            | SDL3 + OpenGL3               |
| Cross-platform desktop, need Vulkan compute       | SDL3 + Vulkan                |
| Windows-only, want best DX11 performance          | Win32 + DX11                 |
| macOS-only, want native Metal                     | OSX + Metal                  |
| Web (WASM/Emscripten)                             | GLFW + WebGPU                |
| Embedding into an existing SDL3 game              | SDL3 + your existing renderer|

The default for new projects: **SDL3 + OpenGL3**. It works everywhere, the API is simple,
and the performance is more than enough for tools and editors.

## Choosing between zgui and raw FFI

| Concern                              | zgui                       | Raw FFI (cimgui.zig)        |
|--------------------------------------|----------------------------|-----------------------------|
| Setup complexity                     | Trivial (~10 LOC)          | Moderate (~50 LOC)         |
| API ergonomics                       | Zig-style, named params    | C-style, positional        |
| Bundled backends                     | Yes (sdl3_opengl3, etc.)   | No, you wire them yourself |
| Latest ImGui features                | Tracks releases            | Tracks daily               |
| C++ compile time                     | ~5 sec (only the shim)     | ~5 sec (only the shim)     |
| Access to imgui_internal.h           | Limited                    | Full (dear_bindings covers it) |
| ImPlot / ImGuizmo / NodeEditor       | Opt-in via -Dwith_*        | Separate packages          |
| Recommended for new projects         | ✅ Yes                     | Only if you need imgui_internal |

For 90% of projects, **zgui** is the right choice. Use raw FFI only if you need
`imgui_internal.h` features (custom layout, custom widgets that poke at internals).

## The Zig 0.16 gotchas

Three things will trip you up coming from older Zig + ImGui tutorials:

1. **`@cImport` is deprecated.** Older tutorials show `@cImport({ @cInclude("imgui.h");
   })` — this still works in 0.16 (backed by Aro) but emits a deprecation warning. Use
   `b.addTranslateC` in build.zig. zgui handles this for you.

2. **`linkLibCpp()` is mandatory.** ImGui is C++; the C wrappers are C++; you must link
   the C++ runtime. Forget this and you get linker errors about `__cxa_allocate_exception`.

3. **The `InitFor<Renderer>` pairing.** Platform backends have multiple init functions:
   `ImGui_ImplSDL3_InitForOpenGL`, `ImGui_ImplSDL3_InitForVulkan`, etc. Pick the one
   that matches your renderer. Wrong pairing = no input.

Read [build-zig.md](references/build-zig.md) for the canonical setup that avoids all three.

## Version

This skill targets **Dear ImGui 1.92.1-docking** (the docking branch, kept in sync with
master) and **Zig 0.16.0**. The docking branch is required for `DockingEnable` and
`ViewportsEnable`; without it, multi-window and dockspace features don't work.

The zgui wrapper tracks ImGui master + docking; the tiawl/cimgui.zig tracks upstream
daily. For most projects, zgui is sufficient.
