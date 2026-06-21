# Backends: platform + renderer pairs

Dear ImGui doesn't render anything itself. You pair a **platform backend** (window + input)
with a **renderer backend** (graphics API). The pair must match — wrong pairing = silent
failures.

This file catalogs every standard backend, shows how to pick the right pair, and walks
through the SDL3 + OpenGL3 setup in detail.

## Table of contents

1. [The backend model](#the-backend-model)
2. [Standard backends](#standard-backends)
3. [Picking a pair](#picking-a-pair)
4. [SDL3 + OpenGL3 (the default)](#sdl3--opengl3-the-default)
5. [GLFW + OpenGL3](#glfw--opengl3)
6. [SDL3 + Vulkan](#sdl3--vulkan)
7. [Win32 + DirectX 11](#win32--directx-11)
8. [macOS + Metal](#macos--metal)
9. [Web (WASM) + WebGPU](#web-wasm--webgpu)
10. [Custom backends](#custom-backends)

## The backend model

A backend implements three pieces:

1. **Event processing** — convert OS events (mouse, keyboard, window resize) into ImGui
   input events.
2. **Frame setup** — tell ImGui the current window size, DPI scale, and time delta before
   `NewFrame`.
3. **Draw data rendering** — upload ImGui's vertex/index buffers to the GPU and submit
   the draw calls.

Each backend is a `imgui_impl_xxx.cpp/.h` pair in the official `backends/` directory.
zgui bundles them; with raw FFI you compile them yourself.

### The Init/Shutdown/NewFrame/RenderDrawData API

Every backend exposes the same four functions:

```c
// Init: pair the backend with your window + context
bool ImGui_ImplXXX_InitForYYY(SDL_Window* window, ...);
void ImGui_ImplXXX_Shutdown();

// Per-frame
void ImGui_ImplXXX_NewFrame();              // call before ImGui::NewFrame
void ImGui_ImplXXX_RenderDrawData(ImDrawData* draw_data);  // call after ImGui::Render
```

The `InitFor<Renderer>` part is critical — platform backends have multiple init
functions, one per renderer pair:

```c
ImGui_ImplSDL3_InitForOpenGL(SDL_Window*, void* gl_context);
ImGui_ImplSDL3_InitForVulkan(SDL_Window*);
ImGui_ImplSDL3_InitForD3D(SDL_Window*);
ImGui_ImplSDL3_InitForMetal(SDL_Window*);
ImGui_ImplSDL3_InitForSDLRenderer(SDL_Window*, SDL_Renderer*);
ImGui_ImplSDL3_InitForSDLGPU(SDL_Window*, SDL_GPUDevice*);
ImGui_ImplSDL3_InitForOther(SDL_Window*);
```

Pick the one that matches your renderer. Wrong pairing = no input events.

## Standard backends

### Platform backends

| Backend   | Windowing                  | Notes                                              |
|-----------|----------------------------|----------------------------------------------------|
| SDL3      | Cross-platform             | Default for new projects                           |
| SDL2      | Cross-platform             | Legacy; use SDL3 for new code                      |
| GLFW      | Cross-platform             | Lighter than SDL; no audio/gamepad                 |
| Win32     | Windows native             | No external dependency on Windows                  |
| OSX       | macOS native (AppKit)      | No external dependency on macOS                    |
| Android   | Android NDK                | Touch input                                        |

### Renderer backends

| Backend     | API           | Notes                                              |
|-------------|---------------|----------------------------------------------------|
| OpenGL3     | OpenGL 3.2+   | Default; works everywhere                          |
| OpenGL2     | OpenGL 2.1    | Legacy; for old hardware                           |
| Vulkan      | Vulkan 1.x    | Cross-platform; complex setup                      |
| DirectX9    | D3D9          | Legacy Windows                                     |
| DirectX10   | D3D10         | Legacy Windows                                     |
| DirectX11   | D3D11         | Modern Windows                                     |
| DirectX12   | D3D12         | Modern Windows; complex                            |
| Metal       | Metal         | macOS / iOS                                        |
| WebGPU      | WebGPU        | Web (WASM) and modern native                       |
| SDL_Renderer| SDL2/3 2D API | SDL's own 2D renderer                              |
| SDL_GPU     | SDL3 GPU API  | SDL3's new GPU abstraction                         |

## Picking a pair

Decision tree:

```text
Is this a web (WASM) build?
├─ Yes → GLFW + WebGPU
└─ No
   Is this macOS-only, want Metal?
   ├─ Yes → OSX + Metal
   └─ No
      Is this Windows-only?
      ├─ Yes, want max perf → Win32 + DX11
      ├─ Yes, want D3D12 → Win32 + DX12 (be prepared for complexity)
      └─ No
         Need Vulkan specifically?
         ├─ Yes → SDL3 + Vulkan
         └─ No → SDL3 + OpenGL3 (the default)
```

**For new projects: SDL3 + OpenGL3.** Cross-platform, simple, well-supported.

## SDL3 + OpenGL3 (the default)

The setup, end-to-end:

### build.zig.zon

```zig
.{
    .name = .my_imgui_app,
    .fingerprint = 0x123456789abcdef0,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .zsdl = .{
            .url = "git+https://github.com/zig-gamedev/zsdl.git#v0.2.0",
            .hash = "1220e1b4c8f5e9c0d8a3b7e6c5d4e3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4",
        },
        .zopengl = .{
            .url = "git+https://github.com/zig-gamedev/zopengl.git#v0.1.0",
            .hash = "1220a1b2c3d4e5f60718293a4b5c6d7e8f90010203a4b5c6d7e8f9001020304a5b6",
        },
        .zgui = .{
            .url = "git+https://github.com/zig-gamedev/zgui.git#v0.6.0",
            .hash = "1220f1e2d3c4b5a6978877665544332211009988776655443322110099887766",
        },
    },
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}
```

### build.zig

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

    // zgui with the SDL3 + OpenGL3 backend
    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3_opengl3,   // <-- the magic line
    });
    exe_mod.addImport("zgui", zgui.module("root"));
    exe_mod.linkLibrary(zgui.artifact("imgui"));

    // zsdl (for window creation + event polling)
    const zsdl = b.dependency("zsdl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zsdl", zsdl.module("zsdl3"));

    // zopengl (for the GL function table)
    const zopengl = b.dependency("zopengl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zopengl", zopengl.module("zopengl"));

    const exe = b.addExecutable(.{
        .name = "my_imgui_app",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

### main.zig

```zig
const std = @import("std");
const zgui = @import("zgui");
const zsdl = @import("zsdl");
const zgl = @import("zopengl");

pub fn main(init: std.process.Init) !void {
    // 1. Init SDL3
    try zsdl.init(.{ .video = true, .events = true });
    defer zsdl.quit();

    // 2. Set OpenGL attributes (3.3 core profile)
    zsdl.video.GL.setAttribute(.{ .context_major_version = 3 });
    zsdl.video.GL.setAttribute(.{ .context_minor_version = 3 });
    zsdl.video.GL.setAttribute(.{ .context_profile_mask = .core });

    // 3. Create window + GL context
    const window = try zsdl.video.Window.create(
        "ImGui App",
        1280, 720,
        .{ .opengl = true, .high_pixel_density = true, .resizable = true },
    );
    defer window.destroy();

    const gl_ctx = try zsdl.video.GL.createContext(window);
    defer zsdl.video.GL.deleteContext(gl_ctx);

    try zsdl.video.GL.makeCurrent(window, gl_ctx);
    try zsdl.video.GL.setSwapInterval(.vsync_on);

    // 4. Init zopengl (loads GL function pointers via SDL)
    var gl: zgl.ProcTable = .{};
    try gl.init(zsdl.video.GL.getProcAddress);
    zgl.bindInstance(gl);

    // 5. Init ImGui
    try zgui.init(init.gpa);
    defer zgui.deinit();

    _ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", 18.0);
    zgui.io.setConfigFlags(.{
        .nav_enable_keyboard = true,
        .docking_enable = true,
        .viewports_enable = true,
    });
    zgui.styleColorsDark(null);

    // 6. Init the SDL3 + OpenGL3 backend (this calls ImGui_ImplSDL3_InitForOpenGL)
    try zgui.backend.init(@ptrCast(window), @ptrCast(gl_ctx));
    defer zgui.backend.deinit();

    // 7. Main loop
    var done = false;
    while (!done) {
        // Poll events
        var ev: zsdl.events.Event = undefined;
        while (zsdl.events.poll(&ev)) {
            if (ev.type == .quit) done = true;
            if (ev.type == .window_close_requested and ev.window.window_id == window.getID()) {
                done = true;
            }
            _ = zgui.backend.processEvent(@ptrCast(&ev));
        }

        // Begin frame
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(fb_size.width, fb_size.height);

        // Build UI
        drawUI();

        // Render
        const draw_data = zgui.getDrawData();
        zgl.viewport(0, 0, @intCast(fb_size.width), @intCast(fb_size.height));
        zgl.clearColor(0.1, 0.1, 0.1, 1.0);
        zgl.clear(.{ .color = true });
        zgui.backend.draw(draw_data);

        // Swap
        zsdl.video.GL.swapWindow(window);
    }
}

fn drawUI() void {
    if (zgui.begin("Hello", .{})) {
        zgui.text("Hello, Dear ImGui!");
    }
    zgui.end();
}
```

That's the entire setup. zgui handles:
- Compiling the C++ ImGui source
- Compiling the SDL3 + OpenGL3 backend source
- Wrapping the `ImGui_ImplSDL3_InitForOpenGL` / `NewFrame` / `RenderDrawData` calls
- Multi-viewport rendering (when `ViewportsEnable` is on)

## GLFW + OpenGL3

Same pattern, different windowing library:

```zig
const zglfw = @import("zglfw");

pub fn main(init: std.process.Init) !void {
    try zglfw.init();
    defer zglfw.terminate();

    glfw.windowHint(.context_version_major, 3);
    glfw.windowHint(.context_version_minor, 3);
    glfw.windowHint(.opengl_profile, .opengl_core_profile);
    glfw.windowHint(.scale_to_monitor, true);

    const window = try zglfw.Window.create(1280, 720, "ImGui App", null);
    defer window.destroy();

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);

    var gl: zgl.ProcTable = .{};
    try gl.init(zglfw.getProcAddress);
    zgl.bindInstance(gl);

    try zgui.init(init.gpa);
    defer zgui.deinit();
    zgui.io.setConfigFlags(.{ .docking_enable = true, .viewports_enable = true });
    zgui.styleColorsDark(null);

    // Use the glfw_opengl3 backend
    try zgui.backend.init(@ptrCast(window));
    defer zgui.backend.deinit();

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(fb_size[0], fb_size[1]);

        drawUI();

        const draw_data = zgui.getDrawData();
        zgl.viewport(0, 0, @intCast(fb_size[0]), @intCast(fb_size[1]));
        zgl.clearColor(0.1, 0.1, 0.1, 1.0);
        zgl.clear(.{ .color = true });
        zgui.backend.draw(draw_data);

        window.swapBuffers();
    }
}
```

Use `backend = .glfw_opengl3` in build.zig. The only meaningful difference from SDL3 is
GLFW is smaller (no audio, no gamepad by default) and slightly more portable to ancient
Linux distros.

## SDL3 + Vulkan

Vulkan is much more setup-heavy than OpenGL. The pattern:

```zig
// 1. Create SDL3 window with Vulkan flag
const window = try zsdl.video.Window.create(
    "ImGui Vulkan",
    1280, 720,
    .{ .vulkan = true },
);

// 2. Create VkInstance via zvk (or your own Vulkan wrapper)
const instance = try vk.createInstance(...);

// 3. Create VkSurfaceKHR via SDL3
const surface = try zsdl.video.Vulkan.createSurface(window, instance);

// 4. Pick a VkPhysicalDevice, create VkDevice, get a graphics queue
const device = ...;

// 5. Create swapchain, render pass, framebuffers (lots of code)

// 6. Init ImGui's Vulkan backend
try zgui.backend.initVulkan(
    instance,
    physical_device,
    device,
    queue_family_index,
    queue,
    descriptor_pool,
    .{ .min_image_count = 2, .msaa_samples = .count_1 },
);
```

zgui's `backend = .sdl3_vulkan` enables this. You write ~200 lines of Vulkan setup
boilerplate; ImGui is the easy part.

## Win32 + DirectX 11

For Windows-only apps that want maximum native performance:

```zig
// 1. Create HWND via Win32 API (CreateWindowEx)
const hwnd = win32.createWindow(...);

// 2. Create D3D11 device + swapchain
const device = d3d11.createDeviceAndSwapchain(hwnd, ...);

// 3. Init ImGui's DX11 backend
zgui.backend.initWin32(hwnd);
zgui.backend.initD3D11(device, ...);
```

Use `backend = .win32_dx12` for D3D12 (more complex, lower overhead).

## macOS + Metal

For macOS-native apps:

```zig
// 1. Create MTKView (MetalKit view)
const mtk_view = metal.createMTKView(...);

// 2. Create Metal device + command queue
const device = mtk_view.device;
const command_queue = device.newCommandQueue();

// 3. Init ImGui's Metal backend
zgui.backend.initMetal(device, command_queue);
```

Use `backend = .osx_metal`. Note: on macOS, you typically wrap this in an NSApplication
and run the Cocoa event loop, not a manual `while (running)` loop.

## Web (WASM) + WebGPU

For browsers:

```zig
// 1. Get the canvas element from JS
const canvas = emscripten.getCanvas();

// 2. Create WebGPU device
const device = webgpu.requestDevice(...);

// 3. Init ImGui's WebGPU backend
zgui.backend.initWebGPU(device, ...);
```

Use `backend = .glfw_wgpu` or build a custom Emscripten setup. Browser apps must run at
the browser's refresh rate (typically 60 FPS), not a manual loop.

## Custom backends

If your game has its own renderer (custom OpenGL wrapper, custom Vulkan setup, in-house
engine), you write a custom backend by implementing four functions:

```zig
// Your custom renderer backend
const MyBackend = struct {
    pub fn init() void {
        // Upload font atlas, create shaders, etc.
    }

    pub fn shutdown() void {
        // Free GPU resources
    }

    pub fn newFrame() void {
        // Tell ImGui the window size, time, etc.
    }

    pub fn renderDrawData(draw_data: *const ImDrawData) void {
        // Iterate draw_data.CmdLists, upload vertices/indices, issue draw calls
    }
};
```

You also implement a platform backend (event handling). The official `imgui_impl_*`
backends in `backends/` are good references — copy one and modify.

zgui's `backend = .no_backend` mode gives you ImGui without any backend, so you can wire
up your own.

## Backend gotchas

### DPI scaling

On a 4K display at 150% scaling, SDL3 reports the window size in "logical" pixels (1280×720
logical) but the framebuffer size in physical pixels (1920×1080). You must pass the
**framebuffer** size to `newFrame`, not the window size:

```zig
const fb_size = window.getFramebufferSize();   // physical pixels
zgui.backend.newFrame(fb_size.width, fb_size.height);
```

And set the display framebuffer scale so ImGui knows to scale mouse coordinates:

```zig
const window_size = window.getSize();   // logical pixels
zgui.io.display_framebuffer_scale = .{
    .x = @as(f32, @floatFromInt(fb_size.width)) / @as(f32, @floatFromInt(window_size.width)),
    .y = @as(f32, @floatFromInt(fb_size.height)) / @as(f32, @floatFromInt(window_size.height)),
};
```

zgui's backend handles this automatically — but if you're writing a custom backend, watch
out.

### VSync

Always enable VSync (`swap_interval = .vsync_on`) for ImGui apps. Without it, the app
will burn 100% CPU rendering 1000+ FPS, the mouse cursor will jitter, and laptop
batteries will drain.

### Key map

ImGui needs to know which physical key corresponds to which logical key (Tab, Enter,
arrows, etc.). The standard backends set this up automatically:

```c
io.KeyMap[ImGuiKey_Tab] = SDL_SCANCODE_TAB;
io.KeyMap[ImGuiKey_LeftArrow] = SDL_SCANCODE_LEFT;
// ...
```

Custom backends must do this manually.

### Clipboard

ImGui calls `io.SetClipboardTextFn` and `io.GetClipboardTextFn` to access the system
clipboard. The standard backends wire these up to SDL3's clipboard API. Custom backends
must too, or copy-paste won't work.

### Cursor

By default, ImGui hides the OS cursor and draws its own. If you want the OS cursor:

```zig
zgui.io.setConfigFlags(.{ .mouse_no_cursor = false });
zgui.io.setBackendFlags(.{ .has_mouse_cursors = true });
```

The backend then changes the OS cursor shape (IBeam over text inputs, Resize over window
borders, etc.) based on `io.MouseCursor`.

## See also

- [build-zig.md](build-zig.md) — Complete build.zig for SDL3 + OpenGL3
- [fundamentals.md](fundamentals.md#the-frame-lifecycle) — How backends fit into the
  frame lifecycle
- [zgui-setup.md](zgui-setup.md) — zgui's backend selection
