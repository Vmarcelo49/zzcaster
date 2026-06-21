# Performance optimization for Dear ImGui

ImGui is fast — typical UIs render in under a millisecond. But once you have large lists,
frequent rebuilds, or many windows, the cost adds up. This file covers the optimization
patterns that keep ImGui apps responsive.

## Table of contents

1. [The frame budget](#the-frame-budget)
2. [Where time goes](#where-time-goes)
3. [ListClipper for long lists](#listclipper-for-long-lists)
4. [Draw call batching](#draw-call-batching)
5. [Avoiding per-frame allocation](#avoiding-per-frame-allocation)
6. [Sleep when idle](#sleep-when-idle)
7. [Multi-viewport costs](#multi-viewport-costs)
8. [Font atlas size](#font-atlas-size)
9. [Profiling ImGui itself](#profiling-imgui-itself)
10. [When to stop optimizing](#when-to-stop-optimizing)

## The frame budget

At 60 FPS you have **16.67 ms per frame**. For a typical desktop app:

| Phase                          | Typical cost    |
|--------------------------------|-----------------|
| Event polling                  | 0.1-0.5 ms      |
| App logic update               | 0.5-5 ms        |
| ImGui NewFrame + widget calls  | 0.5-2 ms        |
| ImGui Render                   | 0.2-1 ms        |
| GPU upload + draw              | 0.5-3 ms        |
| SwapBuffers (vsync wait)       | 0-16 ms         |

Total without vsync wait: ~2-12 ms. Comfortable headroom.

If you're hitting 16ms regularly, profile before optimizing. The bottleneck is often not
where you think.

## Where time goes

Three usual suspects:

1. **Per-frame allocation** — `std.fmt.allocPrint` in your UI code, allocating arrays to
   pass to ImGui.
2. **Too many widgets** — drawing 10,000 list rows without ListClipper.
3. **Draw call breaks** — using `AddCallback` or changing shaders mid-frame.

Each has a specific fix. See below.

## ListClipper for long lists

The #1 ImGui performance mistake: drawing a list of 10,000 items every frame. Each
`selectable` or `text` call adds to the draw list, even if it's clipped off-screen.

The fix is `ImGuiListClipper`. It computes which rows are visible and only draws those:

```zig
// BAD — draws all 10000 rows every frame
for (0..10_000) |i| {
    zgui.text("Item {d}", .{i});
}
// Total cost: ~5ms for 10000 rows

// GOOD — only draws visible rows
var clipper = zgui.listClipper();
defer clipper.deinit();
clipper.begin(10_000);
while (clipper.step()) {
    const start: i32 = clipper.display_start;
    const end: i32 = clipper.display_end;
    var i: i32 = start;
    while (i < end) : (i += 1) {
        zgui.text("Item {d}", .{i});
    }
}
// Total cost: ~0.1ms (only ~30 visible rows drawn)
```

The speedup is proportional to `total / visible`. For a 1,000,000-row list visible 30 at
a time, you draw 30 instead of 1,000,000 — a 33,000× speedup.

### With variable row heights

If your rows have different heights (e.g. some have multi-line content), use the
`ListClipper` with an explicit height function:

```zig
clipper.begin(items.len, .{
    .items_height = 0,   // 0 = measure each row
});
```

When `items_height = 0`, ListClipper measures each row's height as it draws. After the
first pass, it uses the max height for estimation. Less efficient than fixed-height, but
still much faster than drawing everything.

## Draw call batching

ImGui batches widgets into one draw call per window. Draw call breaks happen when you:

1. Use `AddCallback` (forces a break to switch GPU state).
2. Change the active texture (e.g. drawing an image, then text, then an image — the
   texture switches force breaks).
3. Push a clipping rectangle that's smaller than the window (rare).

### Avoid texture thrashing

```zig
// BAD — alternates textures, breaks batch
for (items) |item| {
    zgui.image(item.icon_texture, .{ .w = 32, .h = 32 });
    zgui.text("{s}", .{item.name});
}
// Each image-text pair is 2 draw calls.

// GOOD — group images, then text
for (items) |item| {
    zgui.image(item.icon_texture, .{ .w = 32, .h = 32 });
}
for (items) |item| {
    zgui.text("{s}", .{item.name});
}
// Two draw calls total (or one, if all icons share a texture atlas).
```

For icon-heavy UIs, use a **texture atlas** — pack all icons into one big texture. Then
each `image` call just changes the UV coordinates, no texture switch.

### Custom draw callbacks

If you must use `AddCallback` (e.g. to switch to a different shader for a custom widget),
do it as few times as possible. Each callback forces a draw call break and a state
restoration.

## Avoiding per-frame allocation

Every `allocPrint` in your UI code is per-frame allocation. At 60 FPS, that's 60
allocations per second per call site. They add up.

### Pattern 1: stack buffers

```zig
// BAD — heap allocation every frame
const label = try std.fmt.allocPrint(gpa, "Item {d}", .{i});
defer gpa.free(label);
zgui.text("{s}", .{label});

// GOOD — stack buffer, no allocation
var buf: [128]u8 = undefined;
const label = std.fmt.bufPrint(&buf, "Item {d}", .{i}) catch "Item ?";
zgui.text("{s}", .{label});
```

### Pattern 2: pre-format once

If the label doesn't change every frame, format it once when the data changes:

```zig
const Item = struct {
    name: []const u8,         // formatted once when the item is created
    cached_label: []const u8, // or: pre-formatted string
};

// In the UI:
zgui.text("{s}", .{item.cached_label});
// No allocation.
```

### Pattern 3: arena per frame

For complex UIs that need many allocations per frame, use a per-frame arena:

```zig
const App = struct {
    frame_arena: std.heap.ArenaAllocator,

    fn update(self: *App) !void {
        _ = self.frame_arena.reset(.retain_with_limit = 1 * 1024 * 1024);
        const a = self.frame_arena.allocator();

        // Now allocations during this frame are fast and freed at frame end
        const label = try std.fmt.allocPrint(a, "Item {d}: {s}", .{ i, item.name });
        zgui.text("{s}", .{label});
    }
};
```

This is the cleanest pattern: allocate freely, free once per frame. The arena keeps a
1 MB cache so most frames don't touch the heap.

## Sleep when idle

If your app doesn't need to render at 60 FPS when idle (e.g. a text editor with no
animations), sleep between frames:

```zig
var last_input_time: std.Io.Timestamp = io.clock.now();
const idle_threshold_ms: u32 = 1000;   // sleep after 1 second of no input

while (running) {
    const now = io.clock.now();
    const since_input = now.since(last_input_time).ms;

    var had_input = false;
    var ev: zsdl.events.Event = undefined;
    while (zsdl.events.poll(&ev)) {
        had_input = true;
        // process event
    }

    if (had_input) last_input_time = now;

    if (since_input > idle_threshold_ms and !has_animations) {
        // Wait for next event with a 100ms timeout
        zsdl.events.waitTimeout(100);
        continue;
    }

    // Normal frame
    renderFrame();
    zsdl.video.GL.swapWindow(window);
}
```

This cuts idle CPU from 100% (60 FPS render loop) to ~0% (waiting for events).

### VSync still applies

Even with the sleep pattern, vsync caps your frame rate when you're actively rendering.
The combination: 60 FPS when active, 0% CPU when idle. Ideal for laptop battery.

## Multi-viewport costs

Each detached ImGui window (when `ViewportsEnable` is on) gets its own OS window and GPU
swapchain. Costs:

- One swapchain per viewport (~10 MB GPU memory on modern APIs).
- One swap per frame per viewport (vsync interactions can be tricky).
- OS window management overhead.

For a typical editor with 3-5 viewports, this is fine. For pathological cases (50+
viewports), it gets expensive.

### Mitigation

Limit the number of detached windows in your UI design. Encourage users to dock windows
instead of floating them.

If a user creates many viewports, consider warning them or auto-docking:

```zig
if (zgui.io.config_flags & ImGuiConfigFlags_ViewportsEnable != 0) {
    if (count of viewports > 10) {
        zgui.openPopup("Too Many Windows", .{});
        // Suggest docking
    }
}
```

## Font atlas size

Every loaded font adds to the atlas. A typical Latin font is 256×512 = 512 KB. CJK fonts
can be 4096×4096 = 64 MB.

### Mitigation

1. **Don't load full CJK fonts.** Use `getGlyphRangesChineseSimplifiedCommon()` (3 MB
   atlas) instead of `getGlyphRangesChineseFull()` (80 MB atlas).
2. **Don't load fonts you don't use.** If you load 5 fonts "in case", ship with 2.
3. **Use 1.92's dynamic glyph loading** (`ConfigFlags.font_allow_dynamic_glyphs`) if you
   need arbitrary text.

### Atlas upload cost

The atlas is uploaded to the GPU on first `NewFrame` after `build()`. A 64 MB atlas takes
~10ms to upload — a noticeable hitch at startup.

Mitigation: build the atlas at startup (not on first frame):

```zig
zgui.io.fonts.build();
// Atlas is now built; it'll upload on first NewFrame but at least the build cost is paid.
```

Or show a loading screen for the first few frames.

## Profiling ImGui itself

ImGui's metrics window shows draw call counts, vertex counts, and per-window breakdowns:

```zig
if (show_metrics) {
    zgui.showMetricsWindow(&show_metrics);
}
```

Useful for:
- Identifying which window has the most vertices.
- Spotting draw call breaks.
- Checking input state (mouse, keyboard) live.

### Custom performance overlay

```zig
fn drawPerfOverlay(stats: *const Stats) void {
    zgui.setNextWindowPos(.{ .x = 10, .y = 10, .cond = .always });
    zgui.setNextWindowBgAlpha(0.7);

    if (zgui.begin("Perf", .{
        .flags = .{
            .no_title_bar = true, .no_resize = true, .no_move = true,
            .no_scrollbar = true, .no_collapse = true, .no_saved_settings = true,
        },
    })) {
        zgui.text("FPS: {d:.1}", .{stats.fps});
        zgui.text("Frame: {d:.2} ms", .{stats.frame_ms});
        zgui.text("  Update: {d:.2} ms", .{stats.update_ms});
        zgui.text("  UI: {d:.2} ms", .{stats.ui_ms});
        zgui.text("  Render: {d:.2} ms", .{stats.render_ms});
        zgui.text("Draw calls: {d}", .{stats.draw_calls});
        zgui.text("Vertices: {d}", .{stats.vertices});
        zgui.text("Windows: {d}", .{stats.window_count});
        zgui.text("Allocs/frame: {d}", .{stats.frame_allocs});
    }
    zgui.end();
}
```

Track these metrics across development. If any of them spike, you'll see it immediately.

### zgui's built-in profiler

If you enable `with_test_engine`, you get ImGui's Test Engine which includes a profiler.
Overkill for most apps — the manual overlay is sufficient.

## When to stop optimizing

ImGui is fast. For most apps, you don't need to optimize at all. Signs you should stop:

- Your UI renders in <2ms per frame.
- Your draw call count is <100.
- Your vertex count is <50k.
- The user can't perceive any lag.

Signs you should optimize:

- UI render time >5ms.
- Draw call count >500.
- Vertex count >500k.
- Visible hitching when scrolling long lists.
- Fan noise on laptops.

The first three are quantitative; the last two are what the user actually cares about.
Optimize for perception, not for numbers.

## Common performance bugs

### 1. String formatting in hot loops

```zig
// BAD
for (items) |item| {
    const label = try std.fmt.allocPrint(gpa, "{s} ({d})", .{item.name, item.count});
    defer gpa.free(label);
    zgui.text("{s}", .{label});
}
```

Fix: use `zgui.text` with the format directly (zgui uses std.fmt):

```zig
for (items) |item| {
    zgui.text("{s} ({d})", .{item.name, item.count});
}
```

### 2. Image without atlas

```zig
// BAD — each image uses a separate texture
for (items) |item| {
    zgui.image(item.icon_texture, .{ .w = 32, .h = 32 });
}
```

Fix: pack all icons into one texture atlas.

### 3. Unclipped canvas

```zig
// BAD — drawing 10000 lines, all visible
const dl = zgui.getWindowDrawList();
for (0..10000) |i| {
    dl.addLine(.{ .x = 0, .y = @floatFromInt(i) }, .{ .x = 1000, .y = @floatFromInt(i) }, 0xFFFFFFFF, 1.0);
}
```

Fix: only draw what's in the visible region:

```zig
const visible_min = zgui.getCursorScreenPos();
const visible_max = .{ .x = visible_min.x + zgui.getWindowWidth(), .y = visible_min.y + zgui.getWindowHeight() };

for (0..10000) |i| {
    const y: f32 = @floatFromInt(i);
    if (y < visible_min.y or y > visible_max.y) continue;
    dl.addLine(.{ .x = 0, .y = y }, .{ .x = 1000, .y = y }, 0xFFFFFFFF, 1.0);
}
```

### 4. Rebuilding layouts every frame

```zig
// BAD — re-runs DockBuilder every frame
if (first_frame) {
    zgui.dockBuilderRemoveNode(dock_id);
    // ... rebuild layout ...
}
```

Fix: only run once, store the result:

```zig
if (!layout_initialized) {
    zgui.dockBuilderRemoveNode(dock_id);
    // ... rebuild layout ...
    layout_initialized = true;
}
```

### 5. VSync off

```zig
// BAD — burns 100% CPU, runs at 1000+ FPS
try zsdl.video.GL.setSwapInterval(.vsync_off);
```

Fix: enable vsync:

```zig
try zsdl.video.GL.setSwapInterval(.vsync_on);
```

If you need lower latency than vsync allows, use adaptive vsync (vsync_on but tear if
behind) or rendering at the display's refresh rate with frame pacing.

## See also

- [patterns.md](patterns.md) — The UIs that need this optimization
- [fundamentals.md](fundamentals.md#draw-lists) — How draw lists work
- [build-zig.md](build-zig.md) — VSync and swap interval setup
