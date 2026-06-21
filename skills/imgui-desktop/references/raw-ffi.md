# Raw FFI: calling Dear ImGui via dear_bindings / cimgui.zig

For projects that need full access to ImGui's API (including `imgui_internal.h`) or want
to track upstream daily, raw FFI is the alternative to zgui. This file walks through the
setup using [tiawl/cimgui.zig](https://github.com/tiawl/cimgui.zig), which pre-packages
the [dear_bindings](https://github.com/dearimgui/dear_bindings) C wrapper for Zig.

## Table of contents

1. [When to use raw FFI](#when-to-use-raw-ffi)
2. [The wrapper landscape](#the-wrapper-landscape)
3. [Installing cimgui.zig](#installing-cimgui-zig)
4. [Build setup](#build-setup)
5. [Including backends](#including-backends)
6. [Calling ImGui from Zig](#calling-imgui-from-zig)
7. [Variadic functions](#variadic-functions)
8. [String lifetimes](#string-lifetimes)
9. [Callbacks](#callbacks)
10. [Struct layout](#struct-layout)
11. [Migrating from `@cImport`](#migrating-from-cimport)

## When to use raw FFI

Use raw FFI when:

1. **You need `imgui_internal.h`** — internal functions like `FocusWidget`, `ImRect`,
   `ScrollToRect`, layout helpers. zgui doesn't expose these.
2. **You need the latest ImGui commit** — dear_bindings is regenerated daily; zgui
   tracks releases.
3. **You're writing a custom backend** — you need direct access to
   `ImGui_ImplXXX_*` functions without zgui's wrapping.
4. **You want to call ImGui from a non-Zig language too** — the C wrapper is reusable.

Don't use raw FFI when:
- zgui's API is sufficient (it usually is).
- You're new to Zig — raw FFI requires more boilerplate and a deeper understanding of
  ABI.

## The wrapper landscape

Dear ImGui is C++, not C. To call it from Zig (or any C-only language), you need a C
wrapper that flattens the C++ API. Two options:

### cimgui (legacy)

The original, Lua-generated C wrapper. Renames functions with `ig` prefix:
`ImGui::Begin` → `igBegin`. Battle-tested since 2015, used by hundreds of projects.
Latest: 1.92.8-docking.

### dear_bindings (modern)

Python-generated, official (in the `dearimgui/` org on GitHub). Preserves the original
names: `ImGui::Begin` → `ImGui_Begin`. Generates `imgui_internal.h` separately (cimgui
doesn't). Designed as cimgui's replacement.

### tiawl/cimgui.zig

[github.com/tiawl/cimgui.zig](https://github.com/tiawl/cimgui.zig) pre-packages
dear_bindings for Zig. Daily updates. Supports Zig 0.16. This is what we'll use.

## Installing cimgui.zig

### Step 1: Fetch

```bash
cd your-project
zig fetch --save git+https://github.com/tiawl/cimgui.zig.git
```

This adds cimgui.zig to your `build.zig.zon`:

```zig
.{
    .name = .my_app,
    .fingerprint = 0x123456789abcdef0,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .cimgui = .{
            .url = "git+https://github.com/tiawl/cimgui.zig.git#<commit>",
            .hash = "1220...",
        },
    },
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}
```

### Step 2: Fetch a windowing library

```bash
zig fetch --save git+https://github.com/zig-gamedev/zsdl.git
```

(zsdl gives you SDL3 + you can use SDL3's own GL backend. If you want a Zig GL wrapper,
also fetch zopengl.)

## Build setup

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

    // 1. Add cimgui as a static library
    const cimgui_dep = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
        .docking = true,    // enable the docking branch
    });
    exe_mod.linkLibrary(cimgui_dep.artifact("cimgui"));

    // 2. Add zsdl for windowing
    const zsdl_dep = b.dependency("zsdl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zsdl", zsdl_dep.module("zsdl3"));

    // 3. Compile the SDL3 + OpenGL3 backend sources into a separate lib
    const backend_lib = b.addStaticLibrary(.{
        .name = "imgui_backends",
        .target = target,
        .optimize = optimize,
    });
    backend_lib.linkLibCpp();
    backend_lib.addCSourceFiles(&.{
        "vendor/imgui/backends/imgui_impl_sdl3.cpp",
        "vendor/imgui/backends/imgui_impl_opengl3.cpp",
    }, &.{
        "-std=c++17",
        "-fno-exceptions",
        "-fno-rtti",
        "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
    });
    backend_lib.addIncludePath(b.path("vendor/imgui"));
    backend_lib.addIncludePath(b.path("vendor/imgui/backends"));

    // cimgui.zig already includes imgui.h, but the backends need to find it
    // (cimgui.zig's include path)
    backend_lib.addIncludePath(cimgui_dep.path("include"));

    backend_lib.linkLibrary(cimgui_dep.artifact("cimgui"));
    backend_lib.linkSystemLibrary("SDL3");
    exe_mod.linkLibrary(backend_lib);

    // 4. Translate the C headers to a Zig module via addTranslateC
    const c_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/c_imports.h"),
        .target = target,
        .optimize = optimize,
    });
    c_mod.addIncludePath(cimgui_dep.path("include"));
    c_mod.addIncludePath(b.path("vendor/imgui/backends"));
    exe_mod.addImport("c", c_mod);

    // 5. Build the exe
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

### The umbrella header

```c
// src/c_imports.h

// cimgui.zig's main header (dear_bindings output)
#include "dcimgui.h"

// ImGui's internal header (if you need it)
#include "dcimgui_internal.h"

// Backend headers
#include "imgui_impl_sdl3.h"
#include "imgui_impl_opengl3.h"
```

cimgui.zig installs `dcimgui.h` and `dcimgui_internal.h` into its `include/` directory.
The backend headers come from the upstream ImGui repo — clone it into `vendor/imgui/`:

```bash
git clone --depth 1 --branch docking https://github.com/ocornut/imgui.git vendor/imgui
```

## Including backends

Unlike zgui, cimgui.zig doesn't bundle backends. You compile them yourself, as shown
above (`backend_lib`). The setup is more verbose but gives you full control:

- Choose exactly which backends to compile.
- Patch them if you need (e.g. to add a `void* user_data` parameter to event callbacks).
- Use unreleased patches from ImGui's master.

### Common backend combos

```zig
// SDL3 + OpenGL3
backend_lib.addCSourceFiles(&.{
    "vendor/imgui/backends/imgui_impl_sdl3.cpp",
    "vendor/imgui/backends/imgui_impl_opengl3.cpp",
}, &.{ ... });

// GLFW + Vulkan
backend_lib.addCSourceFiles(&.{
    "vendor/imgui/backends/imgui_impl_glfw.cpp",
    "vendor/imgui/backends/imgui_impl_vulkan.cpp",
}, &.{ ... });

// Win32 + DX11
backend_lib.addCSourceFiles(&.{
    "vendor/imgui/backends/imgui_impl_win32.cpp",
    "vendor/imgui/backends/imgui_impl_dx11.cpp",
}, &.{ ... });
```

Each backend needs its corresponding include path (for `SDL3/SDL.h`, `GLFW/glfw3.h`, etc.)
and link library (`SDL3`, `glfw3`, `d3d11`, etc.).

## Calling ImGui from Zig

```zig
const std = @import("std");
const c = @import("c");
const zsdl = @import("zsdl");

pub fn main(init: std.process.Init) !void {
    try zsdl.init(.{ .video = true, .events = true });
    defer zsdl.quit();

    zsdl.video.GL.setAttribute(.{ .context_major_version = 3 });
    zsdl.video.GL.setAttribute(.{ .context_minor_version = 3 });
    zsdl.video.GL.setAttribute(.{ .context_profile_mask = .core });

    const window = try zsdl.video.Window.create(
        "ImGui Raw FFI", 1280, 720,
        .{ .opengl = true, .high_pixel_density = true },
    );
    defer window.destroy();

    const gl_ctx = try zsdl.video.GL.createContext(window);
    defer zsdl.video.GL.deleteContext(gl_ctx);

    // Init ImGui via dear_bindings
    var imctx: *c.ImGuiContext = c.ImGui_CreateContext(null);
    defer c.ImGui_DestroyContext(imctx);
    c.ImGui_SetCurrentContext(imctx);

    const io: *c.ImGuiIO = c.ImGui_GetIO();
    io.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable | c.ImGuiConfigFlags_ViewportsEnable;
    io.IniFilename = "imgui.ini";

    // Init backends
    _ = c.ImGui_ImplSDL3_InitForOpenGL(@ptrCast(window), @ptrCast(gl_ctx));
    defer c.ImGui_ImplSDL3_Shutdown();

    _ = c.ImGui_ImplOpenGL3_Init("#version 330");
    defer c.ImGui_ImplOpenGL3_Shutdown();

    // Load a font
    _ = c.ImGuiIO_AddFontFromFileTTF(io, "assets/Roboto-Medium.ttf", 18.0, null, null);

    var done = false;
    while (!done) {
        var ev: zsdl.events.Event = undefined;
        while (zsdl.events.poll(&ev)) {
            if (ev.type == .quit) done = true;
            _ = c.ImGui_ImplSDL3_ProcessEvent(@ptrCast(&ev));
        }

        c.ImGui_ImplOpenGL3_NewFrame();
        c.ImGui_ImplSDL3_NewFrame();
        c.ImGui_NewFrame();

        // Build UI
        if (c.ImGui_Begin("Hello", null, 0)) {
            c.ImGui_Text("Hello from raw FFI!");
            _ = c.ImGui_Button("Click", c.ImVec2{ .x = 100, .y = 30 });
            c.ImGui_End();
        }

        c.ImGui_Render();
        const draw_data: *c.ImDrawData = c.ImGui_GetDrawData();

        const fb = window.getFramebufferSize();
        // (Set up OpenGL viewport / clear color here — omitted)
        c.ImGui_ImplOpenGL3_RenderDrawData(draw_data);

        zsdl.video.GL.swapWindow(window);
    }
}
```

### Notable differences from zgui

1. **Positional args, not named params.** `c.ImGui_Button("Click", ImVec2{...})` instead
   of `zgui.button("Click", .{ .w = 100, .h = 30 })`.

2. **Manual context management.** You create the `ImGuiContext*` explicitly and set it
   current. zgui hides this.

3. **C format strings.** `c.ImGui_Text("Frame: %d", frame)` — printf-style, not Zig's
   `{d}`. No compile-time checking.

4. **Flags as bitflags.** `io.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable` — manual
   `|=` instead of a packed struct.

5. **Explicit pointer types.** `*c.ImGuiIO` instead of `zgui.io`. Need to pass `io` to
   some functions; zgui hides this.

## Variadic functions

ImGui has many variadic functions (`ImGui::Text`, `ImGui::TextColored`, etc.). Calling
them from Zig requires `@cVaStart` / `@cVaArg` / `@cVaEnd`:

```zig
fn text(comptime fmt: []const u8, args: anytype) void {
    // Build a C-style format string from the Zig format
    var c_fmt_buf: [256]u8 = undefined;
    const c_fmt = zigFmtToCFmt(&c_fmt_buf, fmt);

    var va = @cVaStart(args);
    c.ImGui_TextV(c_fmt, &va);
}
```

Most cimgui.zig / dear_bindings builds include both the variadic and the `V` (va_list)
variants — prefer the `V` variant for type safety:

```zig
// Instead of:
// c.ImGui_Text("Hello %s", name);

// Use:
c.ImGui_TextUnformatted("Hello");   // simple case, no format
// Or for the va_list variant:
var va = @cVaStart(.{name});
c.ImGui_TextV("Hello %s", &va);
```

In practice, for simple text without formatting, `TextUnformatted` is the cleanest.

## String lifetimes

Several ImGui functions keep the string you pass:

- `io.IniFilename` — used to save/restore window layout. Must be a stable C string.
- Drag-drop payload — ImGui keeps a copy, but the type tag is a string you pass each
  frame; the pointer is kept.
- `OpenPopup` with a string ID — kept only for the duration of the popup.

For IniFilename:

```zig
// BAD — pointer to a Zig slice, may be freed
io.IniFilename = "imgui.ini";   // ok, string literal is static

// BAD — pointer to a heap string, freed when caller returns
const path = try std.fmt.allocPrint(gpa, "{s}/imgui.ini", .{config_dir});
io.IniFilename = path.ptr;   // dangling after gpa.free(path)

// GOOD — use a stable static buffer
var ini_path_buf: [256]u8 = undefined;
const ini_path = std.fmt.bufPrintZ(&ini_path_buf, "{s}/imgui.ini", .{config_dir}) catch unreachable;
io.IniFilename = ini_path.ptr;
```

For `InputText`, the buffer must be mutable:

```zig
var buf: [256]u8 = std.mem.zeroes([256]u8);
@memcpy(buf[0..5], "hello");
_ = c.ImGui_InputText("Name", &buf, buf.len, 0, null, null);
// buf may have been modified; read it back
const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
const new_name = buf[0..len];
```

## Callbacks

ImGui has a few callbacks (e.g. `io.SetClipboardTextFn`). They must be `callconv(.c)`:

```zig
fn setClipboardText(user_data: ?*anyopaque, text: [*c]const u8) callconv(.c) void {
    _ = user_data;
    // Copy text into our clipboard buffer
    const len = std.mem.indexOfSentinel(u8, 0, text);
    clipboard_buf.resize(len) catch return;
    @memcpy(clipboard_buf.items, text[0..len]);
}

fn getClipboardText(user_data: ?*anyopaque) callconv(.c) [*c]const u8 {
    _ = user_data;
    return clipboard_buf.items.ptr;
}

// In init:
io.SetClipboardTextFn = setClipboardText;
io.GetClipboardTextFn = getClipboardText;
// (user_data is left null; we use globals)
```

## Struct layout

`ImVec2`, `ImVec4`, and `ImColor` are passed as extern structs by value:

```zig
const size = c.ImVec2{ .x = 100, .y = 30 };
_ = c.ImGui_Button("Click", size);

const color = c.ImVec4{ .x = 1, .y = 0, .z = 0, .w = 1 };
c.ImGui_PushStyleColor_Vec4(c.ImGuiCol_Button, color);
defer c.ImGui_PopStyleColor(1);
```

Some functions take an `ImVec2` by pointer (for output):

```zig
var pos: c.ImVec2 = undefined;
c.ImGui_GetWindowPos(&pos);
// pos.x and pos.y now hold the window position
```

For your own structs passed to ImGui (rare — usually only happens in custom backends),
use `extern struct` for layout compatibility.

## Migrating from `@cImport`

If you have an existing project that uses `@cImport`:

```zig
// OLD (deprecated in Zig 0.16)
const c = @cImport({
    @cInclude("imgui.h");
    @cInclude("imgui_impl_sdl3.h");
    @cInclude("imgui_impl_opengl3.h");
});
```

Migrate to `b.addTranslateC`:

1. Create `src/c_imports.h`:
   ```c
   #include "imgui.h"
   #include "imgui_impl_sdl3.h"
   #include "imgui_impl_opengl3.h"
   ```

2. In `build.zig`, replace `@cImport` with `addTranslateC`:
   ```zig
   const c_mod = b.addTranslateC(.{
       .root_source_file = b.path("src/c_imports.h"),
       .target = target,
       .optimize = optimize,
   });
   c_mod.addIncludePath(b.path("vendor/imgui"));
   c_mod.addIncludePath(b.path("vendor/imgui/backends"));
   exe_mod.addImport("c", c_mod);
   ```

3. The Zig code `const c = @import("c");` works unchanged.

4. If you had `@cDefine` or `@cUndef`, move them into `c_imports.h` as `#define` / `#undef`.

5. If you had `@cInclude` of platform-specific headers, use `#if defined(...)` in
   `c_imports.h`:
   ```c
   #if defined(_WIN32)
   #define WIN32_LEAN_AND_MEAN
   #include <windows.h>
   #elif defined(__APPLE__)
   #include <TargetConditionals.h>
   #endif
   ```

The migration is mechanical. Plan on an hour for a moderately sized codebase.

## Common pitfalls

### Forgetting `linkLibCpp()`

```zig
backend_lib.linkLibCpp();   // REQUIRED — backends are C++
```

Forget this and you get linker errors about `__cxa_allocate_exception`, `operator new`,
or `std::string`.

### Wrong include paths

`addTranslateC` needs to find every header in your umbrella `c_imports.h`. If it can't
find one, you get a parse error. Add every directory with `addIncludePath`.

### Mismatched ImGui versions

If cimgui.zig is at 1.92.5 but your local backend snapshot is 1.92.1, you may get
mismatches. Always update both together.

### Backend pointer-to-pointer args

Some backend init functions take `void**` for the GL context:

```zig
// WRONG — passing *anyopaque instead of *?*anyopaque
_ = c.ImGui_ImplSDL3_InitForOpenGL(@ptrCast(window), @ptrCast(gl_ctx));

// CORRECT — pass a pointer to the context pointer
var gl_ctx_ptr: ?*anyopaque = @ptrCast(gl_ctx);
_ = c.ImGui_ImplSDL3_InitForOpenGL(@ptrCast(window), &gl_ctx_ptr);
```

Check the backend header for the exact signature — they vary.

## See also

- [zgui-setup.md](zgui-setup.md) — The simpler alternative
- [build-zig.md](build-zig.md) — Complete build.zig (uses zgui, but raw FFI follows the
  same pattern)
- [c-interop in the zig-0-16 skill](../../skills/zig-0-16/references/c-interop.md) — More
  on `b.addTranslateC`
