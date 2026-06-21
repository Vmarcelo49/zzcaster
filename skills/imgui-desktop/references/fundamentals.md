# Dear ImGui fundamentals

This file covers the mental model: immediate-mode philosophy, the Begin/End pattern, the
ID stack, draw lists, the frame lifecycle, and `ImGuiIO`. If you read only one reference
file, read this one.

## Table of contents

1. [Immediate-mode philosophy](#immediate-mode-philosophy)
2. [The Begin/End pattern](#the-beginend-pattern)
3. [The ID stack](#the-id-stack)
4. [Draw lists](#draw-lists)
5. [The frame lifecycle](#the-frame-lifecycle)
6. [ImGuiIO](#imguiio)
7. [Style and colors](#style-and-colors)
8. [Fonts](#fonts)
9. [Docking and viewports](#docking-and-viewports)
10. [The ID Stack Tool](#the-id-stack-tool)

## Immediate-mode philosophy

In a retained-mode GUI (Qt, GTK, WinForms), you build a tree of widget objects:

```python
# Retained-mode (PyQt)
button = QPushButton("Click me")
button.clicked.connect(on_click)
layout.addWidget(button)
```

The library owns the widget, you mutate it via setters, and the library re-renders it when
something changes. This is great for forms but awkward when:

- The data you're displaying changes every frame (game state, profiler data).
- You want a widget to appear or disappear based on runtime conditions.
- You're prototyping and don't want to commit to a widget hierarchy.

In an immediate-mode GUI (ImGui), you reissue the UI every frame:

```zig
// Immediate-mode (ImGui)
if (zgui.button("Click me", .{})) {
    click_count += 1;
}
```

If you stop calling `button`, the button disappears. App code owns the data; the library
stores minimal state (focus, hover, open/close, scroll, dock positions) keyed by widget
ID.

### "Immediate" refers to the API, not the rendering

A common misconception: "immediate mode" means the GPU draws every widget as you call it.
That's not how ImGui works. Internally, ImGui:

1. Builds a list of vertices and indices for the entire UI, every frame.
2. Hands you an `ImDrawData*` containing the batched draw lists.
3. You submit those draw lists to your GPU in your own render pass.

So the API is immediate (you call functions, they return values), but the rendering is
batched (one big vertex buffer per window). This is why ImGui can render complex UIs at
60 FPS with sub-millisecond CPU time.

### What ImGui stores vs. what you store

ImGui stores:
- Which window is focused / hovered.
- Which window is being dragged / resized.
- Open/closed state of popups, trees, menus.
- Scroll position of scrollable areas.
- The current value of every persistent widget (sliders, checkboxes, etc.) — keyed by ID.
- Dock layout (if `DockingEnable`).
- Window positions and sizes (in the `imgui.ini` file).

You store:
- All your app's data (the things your UI displays and edits).
- Any non-trivial widget state (e.g. "which row is selected in this table") — usually
  keyed by your own IDs.

The split is clean: ImGui handles UI mechanics, you handle data.

## The Begin/End pattern

Container widgets (windows, child windows, menus, popups, tables, combos, tree nodes)
follow the Begin/End pattern:

```zig
if (zgui.begin("My Window", .{})) {
    zgui.text("Hello!");
    _ = zgui.button("Click", .{});
}
zgui.end();
```

`begin` returns whether the window is collapsed/hidden. If you skip the body when it
returns false, you save a tiny amount of CPU. But you **must** still call `end`.

### Pairing rules

The rules for when to call `End*`:

| Widget            | End rule                                               |
|-------------------|--------------------------------------------------------|
| `Begin`/`End`     | Always call `End`, regardless of return value.         |
| `BeginChild`      | Always call `EndChild`, regardless of return value.    |
| `BeginMenu`       | Call `EndMenu` only if `BeginMenu` returned true.      |
| `BeginPopup`      | Call `EndPopup` only if `BeginPopup` returned true.    |
| `BeginTable`      | Call `EndTable` only if `BeginTable` returned true.    |
| `BeginCombo`      | Call `EndCombo` only if `BeginCombo` returned true.    |
| `BeginListBox`    | Call `EndListBox` only if `BeginListBox` returned true.|
| `TreeNode`        | Call `TreePop` only if `TreeNode` returned true.       |
| `BeginTabItem`    | Call `EndTabItem` only if `BeginTabItem` returned true.|

The pattern: `Begin`/`End` (window) and `BeginChild`/`EndChild` are the only unconditional
pairs. Everything else is conditional on the return value.

### Why this matters

If you call `End` when you shouldn't have (or skip it when you should have), ImGui's
internal stack gets corrupted. The next frame's UI will be wrong, often in confusing
ways (windows appearing inside other windows, popups that won't close, crashes).

The fix is mechanical: use `if (beginX(...)) { ... endX(); }` for conditional pairs,
and `beginX(...); ...; endX();` for unconditional pairs. Don't mix them up.

```zig
// CORRECT
if (zgui.begin("Window", .{})) {
    zgui.text("hi");

    if (zgui.beginChild("child", .{})) {
        zgui.text("inside child");
    }
    zgui.endChild();

    if (zgui.beginMenu("File")) {
        if (zgui.menuItem("Open", .{})) openFile();
        zgui.endMenu();
    }
}
zgui.end();
```

## The ID stack

Every widget call has an ID. ImGui uses this ID to:

- Store the widget's persistent state (slider value, checkbox state, etc.).
- Route input (which widget gets the click?).
- Track focus and hover.

The ID is a hash of the **entire label-stack** leading to the widget: window → tree node
→ PushID → label. Two widgets with the same label, in different windows, have different
IDs. Two widgets with the same label in the same window **collide** — and the second one
will be silently ignored.

### How IDs are derived

By default, the ID is derived from the `label` argument:

```zig
zgui.button("Save", .{});   // ID = hash("WindowName" + "Save")
```

If the label contains `##`, only the part before `##` is displayed, and the part after is
part of the ID:

```zig
zgui.button("Save##main", .{});   // Display: "Save", ID includes "Save##main"
zgui.button("Save##alt", .{});    // Display: "Save", ID includes "Save##alt"
// No collision.
```

If the label contains `###`, only the part after `###` is hashed (the rest is just
displayed). This is for dynamic labels:

```zig
const label = std.fmt.allocPrint(arena, "Player {d}###player", .{player_id}) catch unreachable;
zgui.button(label, .{});
// Display: "Player 42", ID: hash("player") — same ID regardless of player_id
```

### PushID / PopID

For loops, use `PushID`/`PopID` to give each iteration a unique ID namespace:

```zig
for (items, 0..) |item, i| {
    zgui.pushIntId(@intCast(i));
    defer zgui.popId();

    zgui.text("{s}", .{item.name});
    if (zgui.button("Delete", .{})) {
        // The button's ID is hash(Window + i + "Delete"), unique per iteration.
        deleteItem(i);
    }
}
```

`pushIntId`, `pushStrId`, `pushPtrId` cover the common cases. Always `popId` after —
unbalanced pushes corrupt the stack.

### Tree nodes implicitly push

```zig
if (zgui.treeNode("Group")) {
    // Inside here, the ID stack includes "Group".
    if (zgui.button("Action", .{})) { /* ... */ }
    // This "Action" button has ID = hash(Window + "Group" + "Action") — different from
    // an "Action" button outside the tree node.
    zgui.treePop();
}
```

So you don't need explicit PushID inside tree nodes — they handle it.

### Common collision scenarios

1. **Loop with same labels:**
   ```zig
   for (items, 0..) |item, _| {
       if (zgui.button("Edit", .{})) editItem(item);   // COLLISION — all "Edit" buttons share ID
   }
   ```
   Fix: `pushIntId(i)` or `button("Edit##{d}", .{i})`.

2. **Multiple buttons with same display name:**
   ```zig
   zgui.button("Apply", .{});   // applies to current selection
   zgui.button("Apply", .{});   // COLLISION — applies to defaults
   ```
   Fix: `button("Apply##current", .{})` and `button("Apply##defaults", .{})`.

3. **Widgets with empty labels:**
   ```zig
   zgui.button("", .{});   // ID = hash(Window + "") — fragile
   ```
   Fix: `zgui.button("##my_hidden_id", .{})`.

## Draw lists

Every frame, ImGui builds three "draw lists" you can directly poke at:

- `GetBackgroundDrawList()` — fullscreen, behind all windows. Use for grid overlays,
  full-screen effects.
- `GetForegroundDrawList()` — fullscreen, in front of all windows. Use for tooltips,
  notifications, debug overlays.
- `GetWindowDrawList()` — clipped to the current window. Use for custom drawing inside a
  window (graphs, charts, custom widgets).

Each draw list has primitives:

```zig
const dl = zgui.getWindowDrawList();

// Lines
dl.addLine(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, 0xFFFFFFFF, 1.0);

// Rectangles (filled and outline)
dl.addRect(.{ .x = 10, .y = 10 }, .{ .x = 50, .y = 50 }, 0xFF0000FF, 0, 0, true);
dl.addRectFilled(.{ .x = 10, .y = 10 }, .{ .x = 50, .y = 50 }, 0xFF0000FF);

// Circles
dl.addCircle(.{ .x = 100, .y = 100 }, 30, 0xFF00FF00, 0, 2.0);
dl.addCircleFilled(.{ .x = 100, .y = 100 }, 30, 0xFF00FF00);

// Text
dl.addText(.{ .x = 10, .y = 10 }, 0xFFFFFFFF, "Hello, world!");

// Polygons
const points = [_]zgui.Vec2{
    .{ .x = 0, .y = 0 },
    .{ .x = 100, .y = 0 },
    .{ .x = 50, .y = 100 },
};
dl.addConvexPolyFilled(&points, 0xFF808080);

// Bezier curves
dl.addBezierCubic(
    .{ .x = 0, .y = 50 },
    .{ .x = 30, .y = 0 },
    .{ .x = 70, .y = 100 },
    .{ .x = 100, .y = 50 },
    0xFFFFFFFF, 2.0, 0, 0.0
);
```

Colors are `0xRRGGBBAA` (red, green, blue, alpha) — note the order, it's not RGBA.

### Use cases for custom drawing

- **Graphs and charts** — ImPlot covers common cases, but custom drawing is more flexible.
- **Custom widgets** — anything ImGui doesn't have built-in (color wheel, dial, timeline).
- **Game-world overlays** — drawing into the same window as your 3D scene.
- **Debug visualizations** — bounding boxes, ray casts, pathfinding.

### Performance

Draw lists are batched into a single vertex buffer per window. Adding 1000 lines to a
draw list is essentially free — they all go into one draw call. The cost is in vertex
processing, not in API calls.

The exception: `AddCallback` lets you insert a custom GPU command (e.g. "switch to a
different shader"). Each callback forces a draw call break, so use sparingly.

## The frame lifecycle

```text
┌─────────────────────────────────────────────────────────────┐
│  Poll events (window, input)                                 │
│       ↓                                                      │
│  ImGui_ImplXXX_ProcessEvent(event)   ← per-event             │
│       ↓                                                      │
│  ImGui_ImplXXX_NewFrame()            ← per-frame, before NewFrame│
│  ImGui::NewFrame()                                            │
│       ↓                                                      │
│  Build UI: begin/text/button/end/...                         │
│       ↓                                                      │
│  ImGui::Render()                                             │
│       ↓                                                      │
│  ImDrawData* dd = ImGui::GetDrawData()                       │
│       ↓                                                      │
│  Your render pass: clear, set up viewport, etc.              │
│       ↓                                                      │
│  ImGui_ImplXXX_RenderDrawData(dd)   ← uploads + draws        │
│       ↓                                                      │
│  SwapBuffers / Present                                       │
└─────────────────────────────────────────────────────────────┘
```

### Key invariants

1. **Call `ProcessEvent` for every event** between frames. Missed events = unresponsive
   input.
2. **Call `NewFrame` exactly once per frame** before any widget calls.
3. **Call `Render` exactly once per frame** after all widget calls.
4. **Call `RenderDrawData` exactly once per frame** after `Render`, in your render pass.
5. **Don't call widget functions outside the `NewFrame`/`Render` window.** State will
   be inconsistent.

### Multi-viewport lifecycle

If `ViewportsEnable` is set, ImGui can create secondary OS windows for detached ImGui
windows. The lifecycle adds:

- After `Render`, call `UpdatePlatformWindows()` to sync window state.
- For each platform window, call `RenderPlatformWindowDefault()` to draw its contents.

zgui's `backend.draw()` handles this for you. With raw FFI, you do it manually.

## ImGuiIO

`ImGuiIO` is the central hub. Access it via `zgui.io`:

```zig
// Display info
zgui.io.display_size;          // current window size (set by backend)
zgui.io.display_framebuffer_scale; // DPI scale
zgui.io.delta_time;            // time since last frame, in seconds

// Configuration
zgui.io.setConfigFlags(.{ .nav_enable_keyboard = true, .docking_enable = true });
zgui.io.setBackendFlags(.{ .renderer_has_vtx_offset = true });

// Input state (read these to check what's pressed)
zgui.io.mouse_pos;             // current mouse position
zgui.io.mouse_down;            // [5]bool, one per mouse button
zgui.io.keys_down;             // [512]bool, one per key
zgui.io.key_ctrl;              // modifier state

// Consumption flags (read these to know if ImGui used the input)
zgui.io.want_capture_mouse;    // true if mouse is over a window
zgui.io.want_capture_keyboard; // true if a widget has keyboard focus

// Fonts
zgui.io.fonts;                 // the font atlas
```

### Using `WantCaptureMouse` / `WantCaptureKeyboard`

If you're embedding ImGui in a game (e.g. debug overlay), you need to know whether ImGui
or the game should receive input:

```zig
// In your game's input handler:
if (!zgui.io.want_capture_mouse) {
    // Update camera based on mouse movement
    camera.yaw += mouse_delta_x;
}
if (!zgui.io.want_capture_keyboard) {
    // WASD movement
    if (isKeyPressed(.w)) player.moveForward();
}
```

Don't read these flags from inside your ImGui UI code — they're for the host application
to decide whether to handle input.

## Style and colors

`ImGuiStyle` controls all visual metrics: paddings, spacings, roundings, colors. Access
via `zgui.getStyle()`:

```zig
const style = zgui.getStyle();
style.window_padding = .{ .x = 8, .y = 8 };
style.frame_padding = .{ .x = 4, .y = 3 };
style.item_spacing = .{ .x = 8, .y = 4 };
style.item_inner_spacing = .{ .x = 4, .y = 4 };
style.window_rounding = 6.0;
style.frame_rounding = 3.0;
style.grab_rounding = 2.0;
style.window_border_size = 1.0;
style.frame_border_size = 0.0;
```

There are ~50 colors:

```zig
const colors = style.colors;
colors[ImGuiCol_WindowBg] = .{ .x = 0.1, .y = 0.1, .z = 0.1, .w = 1.0 };
colors[ImGuiCol_Button] = .{ .x = 0.3, .y = 0.3, .z = 0.3, .w = 1.0 };
colors[ImGuiCol_ButtonHovered] = .{ .x = 0.5, .y = 0.5, .z = 0.5, .w = 1.0 };
```

### Built-in themes

```zig
zgui.styleColorsDark(null);     // default
zgui.styleColorsLight(null);
zgui.styleColorsClassic(null);  // the original ImGui look
```

### Push/pop for mid-frame overrides

```zig
zgui.pushStyleColor(.{ .col = .button, .c = .{ .x = 1, .y = 0, .z = 0, .w = 1 } });
zgui.pushStyleVar(.{ .idx = .frame_rounding, .v = 8.0 });
defer zgui.popStyleColor(1);
defer zgui.popStyleVar(1);

zgui.button("Red Rounded Button", .{});
```

Always `pop` what you `push` — unbalanced pushes corrupt the style stack.

## Fonts

Fonts live in `ImGuiIO.fonts`. Load at startup:

```zig
// Default font (16px ProggyClean, monospace)
// (already loaded by zgui.init)

// Add a custom TTF
_ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", 18.0);

// Add a font with glyph ranges (e.g. for CJK)
_ = zgui.io.addFontFromFile("assets/NotoSansSC.ttf", .{
    .size_pixels = 18.0,
    .glyph_ranges = zgui.io.fonts.getGlyphRangesChineseSimplifiedCommon(),
});

// Push a different font for a section
const big_font = zgui.io.addFontFromFile("assets/Roboto-Bold.ttf", 32.0);
zgui.pushFont(big_font, 32.0);   // 1.92: PushFont takes an explicit size
defer zgui.popFont();
zgui.text("Big text!");
```

### The font atlas

ImGui bakes all loaded fonts into a single texture atlas at startup. The backend uploads
this texture to the GPU. You can't add fonts after the first frame without rebuilding the
atlas — call `zgui.io.fonts.build()` and re-upload.

In 1.92, fonts can be dynamically sized via `PushFont(font, size)` — you don't need a
separate font object for each size. Set `style.FontScaleDpi` for DPI-aware sizing.

### Icon fonts

For icons (FontAwesome, Material Icons), merge them into the default font:

```zig
const ranges = [_]u16{ 0xe005, 0xf8ff, 0 };   // FA range
const fa_config = zgui.io.FontConfig{
    .merge_mode = true,
    .glyph_ranges = &ranges,
};
_ = zgui.io.addFontFromFileWithConfig("assets/fa-solid-900.ttf", 14.0, &fa_config);

// Use in labels:
zgui.button("\xef\x80\x93 Save", .{});   //  Save (with FA icon)
```

## Docking and viewports

Enable at startup:

```zig
zgui.io.setConfigFlags(.{ .docking_enable = true, .viewports_enable = true });
```

### Docking

Allows the user to dock windows into each other, creating tabbed / split layouts:

```zig
// Create a dockspace that fills the host window
const viewport = zgui.getMainViewport();
zgui.setNextWindowPos(viewport.work_pos);
zgui.setNextWindowSize(viewport.work_size);
zgui.setNextWindowViewport(viewport.id);
zgui.pushStyleVar(.{ .idx = .window_rounding, .v = 0 });
zgui.pushStyleVar(.{ .idx = .window_border_size, .v = 0 });
zgui.pushStyleVar(.{ .idx = .window_padding, .v = .{ .x = 0, .y = 0 } });
_ = zgui.begin("Main Dockspace", .{
    .flags = .{ .no_menu_bar = true, .no_docking = false, .no_title_bar = true, .no_resize = true, .no_move = true, .no_collapse = true, .no_nav_input = true, .no_nav_focus = true },
});
defer zgui.end();
zgui.popStyleVar(3);

const dockspace_id = zgui.getID("MyDockspace");
if (zgui.dockBuilderGetNode(dockspace_id) == null or zgui.dockBuilderGetNode(dockspace_id).?.is_split == false) {
    // First run: set up the default dock layout
    zgui.dockBuilderRemoveNode(dockspace_id);
    zgui.dockBuilderAddNode(dockspace_id);
    var main_node = zgui.dockBuilderGetNode(dockspace_id).?;
    var left_node: u32 = 0;
    var right_node: u32 = 0;
    zgui.dockBuilderSplitNode(main_node.id, .left, 0.20, &left_node, &main_node.id);
    zgui.dockBuilderSplitNode(main_node.id, .right, 0.30, &right_node, &main_node.id);
    zgui.dockBuilderDockWindow("Hierarchy", left_node);
    zgui.dockBuilderDockWindow("Inspector", right_node);
    zgui.dockBuilderDockWindow("Viewport", main_node.id);
    zgui.dockBuilderFinish(dockspace_id);
}
```

This is a lot of code; you only run it once (on first launch) and ImGui saves the layout
to `imgui.ini` afterwards.

### Viewports

Viewports allow ImGui windows to detach from the main window and float as separate OS
windows. Required for multi-monitor editing.

The backend handles most of it automatically — you just need to call
`backend.draw()` after `Render`, and it handles the per-viewport drawing. Some platforms
(SDL2 on Linux without compositing) have issues; test thoroughly.

### Multi-viewport gotchas

1. **GPU context sharing.** Each viewport needs its own GPU context that shares resources
   with the main context. The backend handles this, but if you're using a custom renderer,
   you need to set up sharing yourself.

2. **DPI changes when dragging between monitors.** ImGui fires a `MonitorChanged` event;
   you may need to rebuild the font atlas at a different DPI.

3. **Input focus.** When the user clicks into a floating viewport, that viewport gets OS
   focus. Your input polling needs to handle this (most backends do).

## The ID Stack Tool

When you have a UI bug (a button doesn't respond, a slider value jumps, a popup won't
close), the cause is often an ID collision. ImGui ships with a debug tool:

```zig
zgui.showIDStackToolWindow(null);   // call once, in your debug menu
```

It shows the ID stack for the hovered widget, including the hash values. Invaluable for
debugging "why is this widget broken" issues.

Also useful:

```zig
zgui.showMetricsWindow(null);   // shows the draw lists, vertex counts, etc.
zgui.showStyleEditor(null);     // live-edit the style
zgui.showFontSelector("Font");  // switch fonts at runtime
```

Ship these in your debug builds — they save hours of debugging.

## See also

- [api-reference.md](api-reference.md) — Every widget's signature
- [backends.md](backends.md) — How the lifecycle connects to SDL3/GLFW/etc.
- [patterns.md](patterns.md) — Real-world UI patterns
