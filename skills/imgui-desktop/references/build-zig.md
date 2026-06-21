# Complete build.zig for a desktop app

Drop-in starting point for a Zig 0.16 desktop app with Dear ImGui, SDL3, OpenGL3, docking,
and multi-viewport. Copy this directory structure and adapt.

## Table of contents

1. [Project layout](#project-layout)
2. [`build.zig.zon`](#buildzigzon)
3. [`build.zig`](#buildzig)
4. [`src/main.zig`](#src-mainzig)
5. [`src/app.zig`](#src-appzig)
6. [`assets/` directory](#assets-directory)
7. [Common variations](#common-variations)

## Project layout

```text
my-app/
├── build.zig
├── build.zig.zon
├── src/
│   ├── main.zig          — entry point + SDL3/GL setup
│   ├── app.zig           — your application logic
│   └── ui/
│       ├── menu.zig      — menu bar
│       ├── inspector.zig — property editor
│       └── viewport.zig  — main content area
├── assets/
│   ├── Roboto-Medium.ttf
│   └── icons.ttf          — FontAwesome or similar
└── README.md
```

## `build.zig.zon`

```zig
.{
    .name = .my_app,
    .fingerprint = 0x9a3c1f8b7e2d4a01,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        // Dear ImGui wrapper + standard backends
        .zgui = .{
            .url = "git+https://github.com/zig-gamedev/zgui.git#v0.6.0",
            .hash = "1220f1e2d3c4b5a6978877665544332211009988776655443322110099887766",
        },
        // SDL3 (windowing, input, events)
        .zsdl = .{
            .url = "git+https://github.com/zig-gamedev/zsdl.git#v0.2.0",
            .hash = "1220e1b4c8f5e9c0d8a3b7e6c5d4e3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4",
        },
        // OpenGL function pointer loader
        .zopengl = .{
            .url = "git+https://github.com/zig-gamedev/zopengl.git#v0.1.0",
            .hash = "1220a1b2c3d4e5f60718293a4b5c6d7e8f90010203a4b5c6d7e8f9001020304a5b6",
        },
    },
    .paths = .{
        "src",
        "assets",
        "build.zig",
        "build.zig.zon",
        "README.md",
    },
}
```

### Generating the fingerprint

```bash
bash /home/z/my-project/skills/zig-0-16/scripts/gen-fingerprint.sh
```

Or:

```bash
openssl rand -hex 8 | sed 's/^/0x/'
```

## `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----- Main module -----
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ----- zgui (Dear ImGui + SDL3/OpenGL3 backend + ImPlot) -----
    const zgui_dep = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3_opengl3,
        .with_implot = true,
    });
    exe_mod.addImport("zgui", zgui_dep.module("root"));
    exe_mod.linkLibrary(zgui_dep.artifact("imgui"));

    // ----- zsdl (SDL3 windowing + events) -----
    const zsdl_dep = b.dependency("zsdl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zsdl", zsdl_dep.module("zsdl3"));
    exe_mod.linkLibrary(zsdl_dep.artifact("sdl3"));

    // ----- zopengl (GL function pointers) -----
    const zopengl_dep = b.dependency("zopengl", .{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zopengl", zopengl_dep.module("zopengl"));

    // ----- Executable -----
    const exe = b.addExecutable(.{
        .name = "my_app",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // ----- Run step -----
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // ----- Test step -----
    const unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ----- Release step (for cross-compiling) -----
    // Example: zig build release -Dtarget=x86_64-windows-gnu
    const release_step = b.step("release", "Build release binaries");
    release_step.dependOn(&exe.step);
}
```

## `src/main.zig`

```zig
const std = @import("std");
const zgui = @import("zgui");
const zsdl = @import("zsdl");
const zgl = @import("zopengl");

const app = @import("app.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // ----- 1. Init SDL3 -----
    try zsdl.init(.{ .video = true, .events = true });
    defer zsdl.quit();

    // ----- 2. Set OpenGL attributes -----
    // Request OpenGL 3.3 Core (required by ImGui's OpenGL3 backend)
    zsdl.video.GL.setAttribute(.{ .context_major_version = 3 });
    zsdl.video.GL.setAttribute(.{ .context_minor_version = 3 });
    zsdl.video.GL.setAttribute(.{ .context_profile_mask = .core });
    zsdl.video.GL.setAttribute(.{ .red_size = 8 });
    zsdl.video.GL.setAttribute(.{ .green_size = 8 });
    zsdl.video.GL.setAttribute(.{ .blue_size = 8 });
    zsdl.video.GL.setAttribute(.{ .alpha_size = 8 });
    zsdl.video.GL.setAttribute(.{ .doublebuffer = 1 });
    zsdl.video.GL.setAttribute(.{ .stencil_size = 8 });   // for ImGui's clipping

    // ----- 3. Create window -----
    const window = try zsdl.video.Window.create(
        "My App",
        1280, 720,
        .{
            .opengl = true,
            .high_pixel_density = true,   // critical for HiDPI displays
            .resizable = true,
            .borderless = false,
        },
    );
    defer window.destroy();

    const gl_ctx = try zsdl.video.GL.createContext(window);
    defer zsdl.video.GL.deleteContext(gl_ctx);
    try zsdl.video.GL.makeCurrent(window, gl_ctx);

    // VSync: 1 = on, 0 = off, -1 = adaptive
    try zsdl.video.GL.setSwapInterval(.vsync_on);

    // ----- 4. Init zopengl (load GL function pointers via SDL) -----
    var gl: zgl.ProcTable = .{};
    try gl.init(zsdl.video.GL.getProcAddress);
    zgl.bindInstance(gl);

    // ----- 5. Init ImGui -----
    try zgui.init(gpa);
    defer zgui.deinit();

    // Load a font (optional — falls back to ProggyClean if missing)
    _ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", 18.0);

    // Load an icon font (merge with default)
    const fa_config = zgui.io.FontConfig{
        .merge_mode = true,
        .glyph_min_advance_x = 14.0,
    };
    const fa_ranges = [_]u16{ 0xe005, 0xf8ff, 0 };
    _ = zgui.io.addFontFromFileWithConfig(
        "assets/fa-solid-900.ttf",
        14.0,
        &fa_config,
        &fa_ranges,
    );

    // Enable features
    zgui.io.setConfigFlags(.{
        .nav_enable_keyboard = true,
        .nav_enable_gamepad = true,
        .docking_enable = true,
        .viewports_enable = true,
    });

    // Dark theme by default
    zgui.styleColorsDark(null);

    // Scale style by DPI
    const display_scale: f32 = window.getDisplayContentScale();
    zgui.getStyle().scaleAllSizes(display_scale);
    zgui.getStyle().font_scale_dpi = display_scale;

    // ----- 6. Init ImGui's SDL3 + OpenGL3 backend -----
    try zgui.backend.init(@ptrCast(window), @ptrCast(gl_ctx));
    defer zgui.backend.deinit();

    // ----- 7. Init the app -----
    var my_app = try app.App.init(io, gpa, window);
    defer my_app.deinit();

    // ----- 8. Main loop -----
    var done = false;
    while (!done) {
        // Poll events
        var ev: zsdl.events.Event = undefined;
        while (zsdl.events.poll(&ev)) {
            switch (ev.type) {
                .quit => done = true,
                .window_close_requested => |w| {
                    if (w.window_id == window.getID()) done = true;
                },
                else => {},
            }
            _ = zgui.backend.processEvent(@ptrCast(&ev));
        }

        // Begin frame
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(fb_size.width, fb_size.height);

        // Update the app (one frame of logic)
        try my_app.update(io);

        // Render
        const draw_data = zgui.getDrawData();

        // Set GL viewport and clear
        zgl.viewport(0, 0, @intCast(fb_size.width), @intCast(fb_size.height));
        zgl.clearColor(0.1, 0.1, 0.12, 1.0);
        zgl.clear(.{ .color = true, .depth = true, .stencil = true });

        // Draw ImGui
        zgui.backend.draw(draw_data);

        // Swap
        zsdl.video.GL.swapWindow(window);
    }
}
```

## `src/app.zig`

```zig
const std = @import("std");
const zgui = @import("zgui");
const zsdl = @import("zsdl");

pub const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    window: *zsdl.video.Window,

    // App state
    counter: u32 = 0,
    float_value: f32 = 0.0,
    text_buf: [256]u8 = std.mem.zeroes([256]u8),
    selected_item: u32 = 0,
    show_demo_window: bool = false,
    show_metrics: bool = false,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, window: *zsdl.video.Window) !App {
        return .{
            .io = io,
            .gpa = gpa,
            .window = window,
        };
    }

    pub fn deinit(self: *App) void {
        _ = self;
    }

    pub fn update(self: *App, io: std.Io) !void {
        _ = io;

        // Main menu bar
        self.drawMenuBar();

        // Dockspace (fills the host window)
        self.drawDockspace();

        // Main window
        if (zgui.begin("Main", .{})) {
            zgui.text("Counter: {d}", .{self.counter});
            if (zgui.button("Increment", .{})) self.counter += 1;
            zgui.sameLine();
            if (zgui.button("Decrement", .{})) self.counter -|= 1;

            zgui.separator();
            _ = zgui.sliderFloat("Float", .{ .v = &self.float_value, .min = 0, .max = 1 });
            _ = zgui.inputText("Name", .{
                .buf = &self.text_buf,
                .buf_size = self.text_buf.len,
            });
        }
        zgui.end();

        // Inspector window
        if (zgui.begin("Inspector", .{})) {
            zgui.text("Selected: {d}", .{self.selected_item});
            const items = [_][]const u8{ "Apple", "Banana", "Cherry" };
            _ = zgui.listBox("##items", .{
                .current_item = &self.selected_item,
                .items = &items,
                .height_in_items = 5,
            });
        }
        zgui.end();

        // Debug windows
        if (self.show_demo_window) {
            zgui.showDemoWindow(&self.show_demo_window);
        }
        if (self.show_metrics) {
            zgui.showMetricsWindow(&self.show_metrics);
        }
    }

    fn drawMenuBar(self: *App) void {
        if (zgui.beginMainMenuBar()) {
            if (zgui.beginMenu("File")) {
                if (zgui.menuItem("New", .{ .shortcut = "Ctrl+N" })) self.newFile();
                if (zgui.menuItem("Open...", .{ .shortcut = "Ctrl+O" })) self.openFile();
                zgui.separator();
                if (zgui.menuItem("Quit", .{ .shortcut = "Ctrl+Q" })) std.process.exit(0);
                zgui.endMenu();
            }
            if (zgui.beginMenu("View")) {
                _ = zgui.menuItem("Demo Window", .{ .selected = &self.show_demo_window });
                _ = zgui.menuItem("Metrics", .{ .selected = &self.show_metrics });
                zgui.endMenu();
            }
            if (zgui.beginMenu("Help")) {
                zgui.text("My App v0.1.0", .{});
                zgui.endMenu();
            }
            zgui.endMainMenuBar();
        }
    }

    fn drawDockspace(self: *App) void {
        _ = self;
        const viewport = zgui.getMainViewport();
        zgui.setNextWindowPos(viewport.work_pos);
        zgui.setNextWindowSize(viewport.work_size);
        zgui.setNextWindowViewport(viewport.id);
        zgui.pushStyleVar(.{ .idx = .window_rounding, .v = 0 });
        zgui.pushStyleVar(.{ .idx = .window_border_size, .v = 0 });
        zgui.pushStyleVar(.{ .idx = .window_padding, .v = .{ .x = 0, .y = 0 } });
        defer zgui.popStyleVar(3);

        const flags: zgui.WindowFlags = .{
            .no_title_bar = true,
            .no_collapse = true,
            .no_resize = true,
            .no_move = true,
            .no_docking = false,
            .no_nav_input = true,
            .no_nav_focus = true,
            .no_bring_to_front_on_focus = true,
            .menu_bar = true,
        };
        _ = zgui.begin("##Dockspace", .{ .flags = flags });
        zgui.end();
    }

    fn newFile(self: *App) void {
        self.counter = 0;
        self.float_value = 0;
        self.text_buf = std.mem.zeroes([256]u8);
    }

    fn openFile(self: *App) void {
        _ = self;
        // Use zgui's file dialog extension, or zsdl's native dialog, or a custom popup
    }
};
```

## `assets/` directory

You need at least:

- `Roboto-Medium.ttf` — the recommended default font. Download from
  [Google Fonts](https://fonts.google.com/specimen/Roboto).
- `fa-solid-900.ttf` (optional) — FontAwesome icons for `##Save`, `##Open`, etc.

Without these, ImGui falls back to `ProggyClean.ttf` (built-in monospace) — usable but
ugly.

### Listing assets in `build.zig.zon`

The `paths` array must include `assets` so the package manager includes the files:

```zig
.paths = .{
    "src",
    "assets",
    "build.zig",
    "build.zig.zon",
},
```

If you forget this, the build succeeds but `addFontFromFile` fails at runtime with
"file not found."

### Embedding assets at compile time (optional)

For a single-binary distribution, embed fonts with `@embedFile`:

```zig
const roboto_ttf = @embedFile("../assets/Roboto-Medium.ttf");

// Load from memory
const font_config = zgui.io.FontConfig{
    .font_data = roboto_ttf.ptr,
    .font_data_size = roboto_ttf.len,
    .font_no = 0,
    .size_pixels = 18.0,
};
_ = zgui.io.addFontFromMemory(&font_config);
```

The binary is bigger, but you ship one file.

## Common variations

### Cross-compile to Windows from Linux

```bash
zig build -Dtarget=x86_64-windows-gnu
# Output: zig-out/bin/my_app.exe
```

zgui, zsdl, and zopengl all cross-compile cleanly. The Windows binary runs without any
extra DLLs (SDL3 is statically linked).

### Cross-compile to macOS

```bash
zig build -Dtarget=aarch64-macos
# Output: zig-out/bin/my_app
```

Note: macOS binaries need to be codesigned to run. For development, run with
`xattr -d com.apple.quarantine zig-out/bin/my_app` after copying to a Mac.

### Web (WASM) build

Switch to the GLFW + WebGPU backend:

```zig
// build.zig
.backend = .glfw_wgpu,
```

Then build with:

```bash
zig build -Dtarget=wasm32-emscripten
```

You need Emscripten installed. The output is an HTML file + JS + WASM bundle.

### Headless (for testing)

If you want to run your UI logic without a window (for property-based tests), use the
`no_backend` mode:

```zig
.backend = .no_backend,
```

Then in tests, you can call `zgui.io.setDisplaySize(1280, 720)`, drive `NewFrame`,
submit widgets, and inspect the draw data — all without a real GPU.

This is how ImGui's own test engine works.

### Embedding in an existing game

If you already have a SDL3/GLFW window and a GL/Vulkan context for your game, you don't
need a separate window for ImGui. Just init ImGui with the existing window/context:

```zig
// Your game's existing window
const game_window: *zsdl.video.Window = ...;
const game_gl_ctx: zsdl.video.GL.Context = ...;

// Init ImGui on top
try zgui.init(gpa);
defer zgui.deinit();
try zgui.backend.init(@ptrCast(game_window), @ptrCast(game_gl_ctx));
defer zgui.backend.deinit();

// In your game's frame loop:
zgui.backend.newFrame(fb_w, fb_h);
drawDebugUI();   // your ImGui calls
const draw_data = zgui.getDrawData();

// Render your game scene first, then ImGui on top
renderGameScene();
zgui.backend.draw(draw_data);   // overlays on top
swapBuffers();
```

Use `zgui.io.want_capture_mouse` / `want_capture_keyboard` to decide whether to forward
input to the game or to ImGui.

## See also

- [backends.md](backends.md) — All backend options
- [zgui-setup.md](zgui-setup.md) — zgui configuration details
- [fundamentals.md](fundamentals.md) — What to put inside `update()`
