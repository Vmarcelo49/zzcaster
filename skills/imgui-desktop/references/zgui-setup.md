# Setting up zgui (zig-gamedev/zgui)

zgui is the recommended Zig wrapper for Dear ImGui. It's a hand-crafted API layered over
a small C++ shim, not auto-generated bindings. This file covers installation, the build
configuration, and the Zig-style API.

## Table of contents

1. [Why zgui](#why-zgui)
2. [Installation](#installation)
3. [Backend selection](#backend-selection)
4. [Opt-in modules](#opt-in-modules)
5. [The Zig-style API](#the-zig-style-api)
6. [Common API patterns](#common-api-patterns)
7. [Bundled C++ source](#bundled-c-source)
8. [Updating zgui](#updating-zgui)
9. [When not to use zgui](#when-not-to-use-zgui)

## Why zgui

Compared to raw FFI:

| Feature                       | zgui                          | Raw FFI                |
|-------------------------------|-------------------------------|------------------------|
| Setup                         | ~10 lines                     | ~50 lines              |
| API style                     | Zig named params + std.fmt    | C positional + varargs|
| Backend wiring                | Automatic                     | Manual                 |
| ImGui version                 | Tracks releases               | Tracks daily           |
| `imgui_internal.h`            | Limited                       | Full                   |
| ImPlot / ImGuizmo / etc.      | Opt-in via build flag         | Separate packages      |
| C++ compile time              | ~5 sec (one-time)             | ~5 sec                 |
| Debuggability                 | Zig stack traces              | C++ stack traces       |

For 90% of projects, zgui is the right choice. The Zig-style API is more pleasant, the
backend wiring is automatic, and the version is recent enough.

## Installation

### Step 1: Fetch zgui

```bash
cd your-project
zig fetch --save git+https://github.com/zig-gamedev/zgui.git
```

This adds zgui to your `build.zig.zon`:

```zig
.{
    .name = .my_app,
    .fingerprint = 0x123456789abcdef0,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zgui = .{
            .url = "git+https://github.com/zig-gamedev/zgui.git#<commit>",
            .hash = "1220...",
        },
    },
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}
```

### Step 2: Add a backend

You also need a windowing library (zsdl, zglfw) and possibly a GL wrapper (zopengl).
Fetch them too:

```bash
zig fetch --save git+https://github.com/zig-gamedev/zsdl.git
zig fetch --save git+https://github.com/zig-gamedev/zopengl.git
```

### Step 3: Configure build.zig

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zgui with SDL3 + OpenGL3 backend
    const zgui_dep = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3_opengl3,
        .with_implot = true,    // optional
    });
    exe_mod.addImport("zgui", zgui_dep.module("root"));
    exe_mod.linkLibrary(zgui_dep.artifact("imgui"));

    // zsdl for windowing
    const zsdl_dep = b.dependency("zsdl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zsdl", zsdl_dep.module("zsdl3"));

    // zopengl for GL function pointers
    const zopengl_dep = b.dependency("zopengl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zopengl", zopengl_dep.module("zopengl"));

    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

### Step 4: Use zgui

```zig
const std = @import("std");
const zgui = @import("zgui");
const zsdl = @import("zsdl");
const zgl = @import("zopengl");

pub fn main(init: std.process.Init) !void {
    try zsdl.init(.{ .video = true, .events = true });
    defer zsdl.quit();

    const window = try zsdl.video.Window.create(
        "My App", 1280, 720,
        .{ .opengl = true, .high_pixel_density = true },
    );
    defer window.destroy();

    const gl_ctx = try zsdl.video.GL.createContext(window);
    defer zsdl.video.GL.deleteContext(gl_ctx);

    var gl: zgl.ProcTable = .{};
    try gl.init(zsdl.video.GL.getProcAddress);
    zgl.bindInstance(gl);

    try zgui.init(init.gpa);
    defer zgui.deinit();

    _ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", 18.0);
    zgui.io.setConfigFlags(.{ .docking_enable = true, .viewports_enable = true });
    zgui.styleColorsDark(null);

    try zgui.backend.init(@ptrCast(window), @ptrCast(gl_ctx));
    defer zgui.backend.deinit();

    var done = false;
    while (!done) {
        var ev: zsdl.events.Event = undefined;
        while (zsdl.events.poll(&ev)) {
            if (ev.type == .quit) done = true;
            _ = zgui.backend.processEvent(@ptrCast(&ev));
        }

        const fb = window.getFramebufferSize();
        zgui.backend.newFrame(fb.width, fb.height);

        // Your UI here
        if (zgui.begin("Hello", .{})) {
            zgui.text("Hello, zgui!");
        }
        zgui.end();

        const draw_data = zgui.getDrawData();
        zgl.clearColor(0.1, 0.1, 0.1, 1.0);
        zgl.clear(.{ .color = true });
        zgui.backend.draw(draw_data);

        zsdl.video.GL.swapWindow(window);
    }
}
```

## Backend selection

zgui bundles every standard backend. Pick one with the `backend` option:

```zig
const zgui_dep = b.dependency("zgui", .{
    .target = target,
    .optimize = optimize,

    // Pick ONE of:
    .backend = .sdl3_opengl3,
    // .backend = .sdl3_vulkan,
    // .backend = .sdl3_gpu,
    // .backend = .sdl3_renderer,
    // .backend = .glfw_opengl3,
    // .backend = .glfw_vulkan,
    // .backend = .glfw_wgpu,
    // .backend = .glfw_dx12,
    // .backend = .win32_dx11,
    // .backend = .win32_dx12,
    // .backend = .osx_metal,
    // .backend = .sdl2_opengl3,
    // .backend = .no_backend,    // bring your own
});
```

The backend choice determines:
- Which ImGui C++ backend sources get compiled into the static lib.
- Which `zgui.backend.init*` / `newFrame` / `draw` functions are exposed.
- Which windowing library you need alongside zgui.

### Backend compatibility matrix

| Backend              | Requires deps               | Init call                                                  |
|----------------------|-----------------------------|------------------------------------------------------------|
| `sdl3_opengl3`       | zsdl, zopengl               | `zgui.backend.init(window, gl_ctx)`                        |
| `sdl3_vulkan`        | zsdl, zvulkan               | `zgui.backend.initVulkan(instance, dev, queue, ...)`       |
| `sdl3_gpu`           | zsdl (with SDL3 GPU)        | `zgui.backend.initSDLGPU(window, gpu_device, ...)`         |
| `glfw_opengl3`       | zglfw, zopengl              | `zgui.backend.init(window)`                                |
| `glfw_vulkan`        | zglfw, zvulkan              | `zgui.backend.initVulkan(...)`                             |
| `glfw_wgpu`          | zglfw, zgpu                 | `zgui.backend.initWebGPU(device, ...)`                     |
| `win32_dx11`         | (none — Win32 native)       | `zgui.backend.initWin32(hwnd); zgui.backend.initD3D11(...)`|
| `win32_dx12`         | (none — Win32 native)       | `zgui.backend.initWin32(hwnd); zgui.backend.initD3D12(...)`|
| `osx_metal`          | (none — AppKit native)      | `zgui.backend.initMetal(device, queue)`                    |
| `no_backend`         | (your own)                  | (you write the backend)                                    |

## Opt-in modules

zgui bundles several ImGui ecosystem libraries. Enable them with build flags:

```zig
const zgui_dep = b.dependency("zgui", .{
    .target = target,
    .optimize = optimize,
    .backend = .sdl3_opengl3,

    .with_implot = true,           // plotting library
    .with_imguizmo = true,         // 3D gizmos for editors
    .with_im_nodes = true,         // node editor (graph UI)
    .with_imgui_knobs = true,      // rotary knobs (audio software)
    .with_test_engine = true,      // ImGui's test framework
});
```

Each adds:
- C++ source to compile (adds ~5 sec to first build).
- A sub-module accessible as `zgui.implot`, `zgui.imguizmo`, etc.

```zig
const zgui = @import("zgui");
const implot = zgui.implot;

if (implot.beginPlot("Sin", .{ .w = -1, .h = 300 })) {
    implot.setupAxes("t", "y", .{}, .{});
    implot.plotLine("sin(t)", &xs, &ys);
    implot.endPlot();
}
```

## The Zig-style API

zgui doesn't just expose C functions — it wraps them in a more Zig-idiomatic API:

### Named parameters with defaults

```zig
// C++ ImGui:
// bool Button(const char* label, const ImVec2& size = ImVec2(0, 0));

// zgui:
if (zgui.button("Click", .{ .w = 100, .h = 30 })) { ... }
if (zgui.button("Click", .{})) { ... }   // size defaults to (0, 0)
```

### std.fmt-style text formatting

```zig
// C++ ImGui:
// ImGui::Text("Frame: %d, FPS: %.2f", frame, fps);

// zgui:
zgui.text("Frame: {d}, FPS: {d:.2}", .{ frame, fps });
```

No more `%d` / `%f` / `%s` mistakes — Zig's compile-time format checking catches them.

### Strongly-typed flag structs

```zig
// C++ ImGui:
// ImGui::Begin("Win", nullptr, ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize);

// zgui:
zgui.begin("Win", .{
    .flags = .{
        .no_collapse = true,
        .no_resize = true,
    },
});
```

The flags are a packed struct with named fields. Typos are caught at compile time.

### Type-safe IDs

```zig
// C++ ImGui:
// PushID((const void*)ptr);

// zgui:
zgui.pushPtrId(@ptrCast(my_struct));
zgui.pushIntId(my_index);
zgui.pushStrId("my_section");
defer zgui.popId();
```

Three explicit functions instead of one overloaded `PushID` — Zig can't have function
overloads.

### Enum backing

```zig
// C++ ImGui:
// ImGuiDir dir = ImGuiDir_Left;

// zgui:
const dir: zgui.Dir = .left;
```

Enum values are enum literals, not magic constants.

### DrawList as an opaque pointer

```zig
// C++ ImGui:
// ImDrawList* dl = ImGui::GetWindowDrawList();
// dl->AddLine(...);

// zgui:
const dl = zgui.getWindowDrawList();   // returns *DrawList
dl.addLine(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, 0xFFFFFFFF, 1.0);
```

Method-style access via Zig's `*const` syntax.

## Common API patterns

### Sliders with formatting

```zig
var f: f32 = 0.5;
_ = zgui.sliderFloat("Value", .{
    .v = &f,
    .min = 0.0,
    .max = 1.0,
    .cfmt = "{d:.2}",    // Zig format string, NOT printf-style
    .flags = .{ .always_clamp = true },
});
```

Note: `cfmt` here is actually a C format string (passed to ImGui's internal `Text`).
zgui uses Zig's `std.fmt` for `text()`, but sliders still use C format for the value
display because ImGui formats them internally. This is documented in zgui's API.

### Tables with row backgrounds

```zig
if (zgui.beginTable("Data", .{
    .column = 3,
    .flags = .{
        .row_bg = true,
        .borders_inner_h = true,
        .resizable = true,
        .sortable = true,
    },
})) {
    zgui.tableSetupColumn("A", .{});
    zgui.tableSetupColumn("B", .{});
    zgui.tableSetupColumn("C", .{});
    zgui.tableHeadersRow();

    for (rows, 0..) |row, i| {
        zgui.tableNextRow(.{});
        _ = zgui.tableSetColumnIndex(0);
        zgui.text("{d}", .{row.a});
        _ = zgui.tableSetColumnIndex(1);
        zgui.text("{d}", .{row.b});
        _ = zgui.tableSetColumnIndex(2);
        zgui.text("{d}", .{row.c});
    }
    zgui.endTable();
}
```

### Modal popup pattern

```zig
fn showConfirmDialog() void {
    if (zgui.button("Delete", .{})) {
        zgui.openPopup("Confirm Delete", .{});
    }

    if (zgui.beginPopupModal("Confirm Delete", .{
        .flags = .{ .always_auto_resize = true },
    })) {
        zgui.text("Are you sure you want to delete this?");
        zgui.separator();

        if (zgui.button("Delete", .{})) {
            doDelete();
            zgui.closeCurrentPopup();
        }
        zgui.sameLine();
        if (zgui.button("Cancel", .{})) {
            zgui.closeCurrentPopup();
        }
        zgui.endPopup();
    }
}
```

### Custom widget (color picker + slider)

```zig
fn colorSlider(label: []const u8, color: *[3]f32) void {
    zgui.pushID(label);
    defer zgui.popID();

    _ = zgui.colorEdit3(label, .{ .col = color, .flags = .{ .no_inputs = true } });
    zgui.sameLine();
    _ = zgui.sliderFloat("##r", .{ .v = &color[0], .min = 0, .max = 1 });
    zgui.sameLine();
    _ = zgui.sliderFloat("##g", .{ .v = &color[1], .min = 0, .max = 1 });
    zgui.sameLine();
    _ = zgui.sliderFloat("##b", .{ .v = &color[2], .min = 0, .max = 1 });
}
```

## Bundled C++ source

zgui bundles:
- ImGui C++ source (from the `docking` branch).
- The chosen backend's C++ source (e.g. `imgui_impl_sdl3.cpp` + `imgui_impl_opengl3.cpp`).
- A small C++ shim (`src/zgui.cpp`) that wraps ImGui's C++ API in `extern "C"` functions.
- (Optional) ImPlot, ImGuizmo, ImGuiNodeEditor, etc.

All C++ is compiled into a static lib (`libimgui.a`) by zgui's `build.zig`. You link
against that lib; you never see the C++ source.

### Compile times

First build: ~5 seconds for the C++ compilation. Subsequent builds: <1 second (the C++
lib is cached). The Zig side compiles in <1 second always.

### Updating ImGui version

zgui tracks ImGui's `docking` branch. To update:

```bash
zig fetch --save git+https://github.com/zig-gamedev/zgui.git
```

This pulls the latest commit and updates the hash in `build.zig.zon`. zgui's maintainer
usually updates within a week of an upstream ImGui release.

## Updating zgui

When you want to bump to a newer zgui:

```bash
# Update the URL in build.zig.zon to the latest commit
zig fetch --save git+https://github.com/zig-gamedev/zgui.git#<new-commit>
```

Then rebuild. If anything breaks, check zgui's CHANGELOG — usually there's a small Zig
API adjustment when ImGui adds new flags or widgets.

## When not to use zgui

Use raw FFI (see [raw-ffi.md](raw-ffi.md)) instead when:

1. **You need `imgui_internal.h`.** zgui wraps the public API; it doesn't expose internal
   functions like `ImRect`, `FocusWidget`, layout helpers. Raw FFI does.
2. **You need the absolute latest ImGui commit.** zgui tracks releases; if you need a
   bugfix from master that hasn't been released yet, raw FFI can pull daily.
3. **You want to call ImGui from a non-Zig language too.** The C wrapper is reusable;
   zgui's Zig API isn't.
4. **You're writing a custom backend.** zgui's backend wrappers assume the standard
   backends. A custom backend needs raw access to `ImGui_ImplXXX_*` functions.

For all other cases, zgui is the right call.

## See also

- [backends.md](backends.md) — Backend pair details
- [raw-ffi.md](raw-ffi.md) — The alternative (dear_bindings via cimgui.zig)
- [build-zig.md](build-zig.md) — Complete build.zig for a desktop app
- [patterns.md](patterns.md) — Real-world zgui patterns
