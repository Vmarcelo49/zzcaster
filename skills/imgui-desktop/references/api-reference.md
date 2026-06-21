# Widget API reference

This file catalogs every standard ImGui widget, with Zig signatures for both zgui and
raw FFI. Use it as a lookup when you're writing UI code.

## Table of contents

1. [Windows](#windows)
2. [Child windows](#child-windows)
3. [Layout](#layout)
4. [Text](#text)
5. [Buttons](#buttons)
6. [Sliders](#sliders)
7. [Inputs](#inputs)
8. [Selectors](#selectors)
9. [Tables](#tables)
10. [Trees](#trees)
11. [Menus](#menus)
12. [Popups](#popups)
13. [Drag and drop](#drag-and-drop)
14. [Tooltips](#tooltips)
15. [Drawing](#drawing)
16. [Misc](#misc)

## Windows

### `begin` / `end`

The fundamental window container.

```zig
// zgui
if (zgui.begin("My Window", .{
    .flags = .{
        .no_collapse = true,
        .no_resize = false,
        .no_move = false,
        .no_title_bar = false,
        .always_auto_resize = false,
        .no_saved_settings = false,
    },
})) {
    // window contents
}
zgui.end();
```

```zig
// raw FFI
if (c.ImGui_Begin("My Window", null, ImGuiWindowFlags_NoCollapse)) {
    // contents
}
c.ImGui_End();
```

### Window position / size

Set before `begin`:

```zig
zgui.setNextWindowPos(.{ .x = 100, .y = 100, .cond = .first_use_ever });
zgui.setNextWindowSize(.{ .w = 400, .h = 300, .cond = .first_use_ever });
zgui.setNextWindowSizeConstraints(.{ .w = 200, .h = 100 }, .{ .w = 800, .h = 600 });
zgui.setNextWindowCollapsed(false, .first_use_ever);
zgui.setNextWindowFocus();
```

### Window queries

```zig
const is_hovered = zgui.isWindowHovered(.{});
const is_focused = zgui.isWindowFocused(.{});
const pos = zgui.getWindowPos();
const size = zgui.getWindowSize();
const width = zgui.getWindowWidth();
const height = zgui.getWindowHeight();
const content_avail = zgui.getContentRegionAvail();
```

## Child windows

A child window is a window inside a window. Useful for scrolling regions, dockable
sub-areas, custom layouts.

```zig
if (zgui.beginChild("list_panel", .{
    .w = 200,
    .h = 0,   // 0 = fill remaining
    .border = true,
    .flags = .{ .auto_resize_y = false },
})) {
    for (items) |item| {
        zgui.text("{s}", .{item.name});
    }
}
zgui.endChild();
```

Always call `endChild` regardless of return value (the only unconditional pair besides
`begin`/`end`).

## Layout

### SameLine / Spacing / Separator

```zig
zgui.text("Label:");
zgui.sameLine();       // next widget on the same line
zgui.text("Value");

zgui.spacing();        // vertical space (one item height)

zgui.separator();      // horizontal line
```

### Indent

```zig
zgui.text("Top level");
zgui.indent();
zgui.text("Indented");
zgui.unindent();
zgui.text("Back to top");
```

### Columns

Legacy column layout (use `beginTable` for new code):

```zig
zgui.columns(3, "mycolumns", true);   // 3 columns, with border
zgui.text("Col 0"); zgui.nextColumn();
zgui.text("Col 1"); zgui.nextColumn();
zgui.text("Col 2"); zgui.nextColumn();
zgui.columns(1);   // reset
```

## Text

```zig
// Plain text
zgui.text("Hello, world!");
zgui.textColored(.{ .x = 1, .y = 0, .z = 0, .w = 1 }, "Error: {d}", .{error_count});
zgui.textDisabled("Disabled text");
zgui.textWrapped("Long text that wraps to multiple lines if the window is narrow.");

// Formatted text (zgui uses std.fmt style)
zgui.text("Frame: {d}, FPS: {d:.2}", .{frame, fps});

// Bordered text
zgui.bulletText("Important item");

// Hyperlink-style
if (zgui.smallButton("[docs]")) openUrl("https://...");
```

### Text input (single line)

```zig
var buf: [256]u8 = std.mem.zeroes([256]u8);
@memcpy(buf[0..5], "hello");
if (zgui.inputText("Name", .{
    .buf = &buf,
    .buf_size = buf.len,
    .flags = .{ .chars_no_blank = true, .enter_returns_true = true },
    .callback = null,
    .user_data = null,
})) {
    // user pressed Enter
    saveName(buf[0..strlen(buf)]);
}
```

### Text input (multiline)

```zig
var text_buf: [4096]u8 = std.mem.zeroes([4096]u8);
_ = zgui.inputTextMultiline("Source", .{
    .buf = &text_buf,
    .buf_size = text_buf.len,
    .size = .{ .w = 0, .h = 300 },
    .flags = .{ .allow_tab_input = true },
});
```

## Buttons

```zig
// Standard button
if (zgui.button("Click Me", .{ .w = 100, .h = 30 })) {
    clicked_count += 1;
}

// Small button (no padding)
if (zgui.smallButton("X")) { /* close */ }

// Arrow button (for spinners, dropdowns)
if (zgui.arrowButton("##down", .down)) { /* ... */ }

// Invisible button (for custom widgets)
if (zgui.invisibleButton("canvas", .{ .w = 400, .h = 300, .flags = .{} })) {
    // user clicked anywhere in this 400x300 region
}

// Image button
const tex_id: zgui.TextureId = @ptrCast(my_texture);
if (zgui.imageButton("##img", .{
    .user_texture_id = tex_id,
    .w = 64, .h = 64,
    .uv0 = .{ .x = 0, .y = 0 },
    .uv1 = .{ .x = 1, .y = 1 },
    .bg_col = .{ .x = 0, .y = 0, .z = 0, .w = 0 },
    .tint_col = .{ .x = 1, .y = 1, .z = 1, .w = 1 },
})) {
    // image clicked
}
```

### Button flags

```zig
zgui.button("Disabled", .{ .flags = .{ .disabled = true } });
```

## Sliders

### Float sliders

```zig
var f: f32 = 0.5;
_ = zgui.sliderFloat("Value", .{
    .v = &f,
    .min = 0.0,
    .max = 1.0,
    .cfmt = "%.2f",
    .flags = .{ .always_clamp = true },
});

// Multiple values at once
var vec: [3]f32 = .{ 0, 0, 0 };
_ = zgui.sliderFloat3("Color", .{ .v = &vec, .min = 0, .max = 1 });
```

### Int sliders

```zig
var i: i32 = 50;
_ = zgui.sliderInt("Count", .{ .v = &i, .min = 0, .max = 100, .cfmt = "%d" });
```

### Angle / direction

```zig
var angle: f32 = 0;
_ = zgui.sliderAngle("Direction", .{ .v = &angle, .v_degrees_min = -180, .v_degrees_max = 180 });
```

### Custom drag (for non-linear ranges)

```zig
var log_val: f32 = 1.0;
_ = zgui.dragFloat("Speed", .{
    .v = &log_val,
    .v_speed = 0.1,
    .v_min = 0.01,
    .v_max = 100.0,
    .cfmt = "%.3f",
    .flags = .{ .logarithmic = true },
});
```

## Inputs

### Numeric input

```zig
var n: i32 = 42;
_ = zgui.inputInt("Count", .{ .v = &n, .step = 1, .step_fast = 100, .flags = .{} });

var f: f32 = 3.14;
_ = zgui.inputFloat("Pi", .{ .v = &f, .step = 0.1, .step_fast = 1.0, .cfmt = "%.3f" });
```

### Color

```zig
var color: [3]f32 = .{ 1, 0, 0 };
_ = zgui.colorEdit3("Color", .{ .col = &color, .flags = .{ .display_rgb = true } });

var color4: [4]f32 = .{ 1, 0, 0, 1 };
_ = zgui.colorEdit4("Color Alpha", .{ .col = &color4 });
```

## Selectors

### Checkbox

```zig
var enabled: bool = false;
_ = zgui.checkbox("Enabled", .{ .v = &enabled });
```

### Radio buttons

```zig
var mode: i32 = 0;
_ = zgui.radioButton("Mode A", .{ .active = mode == 0 }); if (mode == 0) {} else {}
_ = zgui.radioButton("Mode B", .{ .v = &mode, .v_button = 1 });
_ = zgui.radioButton("Mode C", .{ .v = &mode, .v_button = 2 });
```

### Combo box

```zig
var current: u32 = 0;
const items = [_][]const u8{ "Apple", "Banana", "Cherry" };
_ = zgui.combo("Fruit", .{
    .current_item = &current,
    .items_separated_by_zeros = "Apple\0Banana\0Cherry\0",
    .flags = .{},
});
```

### List box

```zig
var current: u32 = 0;
_ = zgui.listBox("##list", .{
    .current_item = &current,
    .items = &.{ "Apple", "Banana", "Cherry" },
    .height_in_items = 5,
});
```

### Selectable

For custom list rows, trees, etc:

```zig
for (items, 0..) |item, i| {
    if (zgui.selectable(item.name, .{ .selected = i == selected_index })) {
        selected_index = i;
    }
}
```

## Tables

The modern table API (replaces `columns`):

```zig
if (zgui.beginTable("Items", .{
    .column = 3,
    .flags = .{
        .resizable = true,
        .sortable = true,
        .borders = .all,
        .row_bg = true,
    },
})) {
    zgui.tableSetupColumn("Name", .{ .flags = .{ .width_stretch = true } });
    zgui.tableSetupColumn("Size", .{ .flags = .{ .width_fixed = true }, .init_width_or_weight = 80 });
    zgui.tableSetupColumn("Modified", .{ .flags = .{ .default_sort = true } });
    zgui.tableHeadersRow();

    for (items) |item| {
        zgui.tableNextRow(.{ .min_row_height = 0 });

        _ = zgui.tableSetColumnIndex(0);
        zgui.text("{s}", .{item.name});

        _ = zgui.tableSetColumnIndex(1);
        zgui.text("{d}", .{item.size});

        _ = zgui.tableSetColumnIndex(2);
        zgui.text("{s}", .{item.modified_str});
    }
    zgui.endTable();
}
```

### Table features

- **Sorting**: check `tableGetSortSpecs()` for sort direction, sort your data, redraw.
- **Selection**: use `selectable` in the first column with `span_all_columns = true`.
- **Context menus**: right-click a row → `beginPopupContextItem()`.
- **Custom widgets in cells**: anything works — sliders, color editors, images.

## Trees

```zig
if (zgui.treeNode("Group")) {
    zgui.text("Inside group");

    if (zgui.treeNode("Subgroup")) {
        zgui.text("Inside subgroup");
        zgui.treePop();
    }
    zgui.treePop();
}

// TreeNodeEx with flags
if (zgui.treeNodeEx("Advanced", .{ .flags = .{ .default_open = true, .leaf = true } })) {
    zgui.treePop();
}

// Tree as a selectable header
if (zgui.treeNode("File", .{ .flags = .{ .framed = true, .span_avail_width = true } })) {
    zgui.treePop();
}
```

## Menus

### Menu bar (inside a window)

```zig
if (zgui.begin("Main", .{ .flags = .{ .menu_bar = true } })) {
    if (zgui.beginMenuBar()) {
        if (zgui.beginMenu("File")) {
            if (zgui.menuItem("Open", .{ .shortcut = "Ctrl+O" })) openFile();
            if (zgui.menuItem("Save", .{ .shortcut = "Ctrl+S", .enabled = has_unsaved_changes })) saveFile();
            zgui.separator();
            if (zgui.menuItem("Quit", .{})) done = true;
            zgui.endMenu();
        }
        if (zgui.beginMenu("Edit")) {
            if (zgui.menuItem("Undo", .{ .shortcut = "Ctrl+Z" })) undo();
            zgui.endMenu();
        }
        zgui.endMenuBar();
    }
    zgui.text("Main content");
}
zgui.end();
```

### Main menu bar (fullscreen)

```zig
if (zgui.beginMainMenuBar()) {
    if (zgui.beginMenu("File")) { /* ... */ zgui.endMenu(); }
    zgui.endMainMenuBar();
}
```

## Popups

### Modal popup

```zig
// Trigger
if (zgui.button("Open Modal", .{})) {
    zgui.openPopup("Confirm", .{});
}

// Modal
if (zgui.beginPopupModal("Confirm", .{
    .flags = .{ .always_auto_resize = true },
})) {
    zgui.text("Are you sure?");
    if (zgui.button("Yes", .{})) {
        doThing();
        zgui.closeCurrentPopup();
    }
    zgui.sameLine();
    if (zgui.button("No", .{})) {
        zgui.closeCurrentPopup();
    }
    zgui.endPopup();
}
```

### Context menu (right-click)

```zig
zgui.text("Right-click me");
if (zgui.beginPopupContextItem("##ctx", .{})) {
    if (zgui.menuItem("Copy", .{})) copy();
    if (zgui.menuItem("Delete", .{})) delete();
    zgui.endPopup();
}
```

### Popup from ID

```zig
if (zgui.button("Open", .{})) zgui.openPopup("MyPopup", .{});
if (zgui.beginPopup("MyPopup", .{ .flags = .{ .always_auto_resize = true } })) {
    zgui.text("Popup contents");
    zgui.endPopup();
}
```

## Drag and drop

### Source

```zig
if (zgui.selectable(item.name, .{})) { /* ... */ }

const payload = DragPayload{
    .item_id = item.id,
    .item_kind = item.kind,
};
zgui.setDragDropPayload("ITEM_TYPE", &payload, @sizeOf(DragPayload), .{});
zgui.endDragDropSource();
```

### Target

```zig
if (zgui.beginDragDropTarget()) {
    if (zgui.acceptDragDropPayload("ITEM_TYPE", .{})) |payload_bytes| {
        const payload: *const DragPayload = @ptrCast(@alignCast(payload_bytes.ptr));
        handleDrop(payload.*);
    }
    zgui.endDragDropTarget();
}
```

## Tooltips

```zig
zgui.button("Hover me", .{});
if (zgui.isItemHovered(.{})) {
    zgui.beginTooltip();
    zgui.text("This button does XYZ.");
    zgui.text("Click to confirm.");
    zgui.endTooltip();
}
```

For longer tooltips, use a full `beginPopup` with `ImGuiPopupFlags_Tooltip`.

## Drawing

See [fundamentals.md#draw-lists](fundamentals.md#draw-lists). Quick reference:

```zig
const dl = zgui.getWindowDrawList();
dl.addLine(.{ .x = 0, .y = 0 }, .{ .x = 100, .y = 100 }, 0xFFFFFFFF, 1.0);
dl.addRectFilled(.{ .x = 10, .y = 10 }, .{ .x = 50, .y = 50 }, 0xFF0000FF);
dl.addCircle(.{ .x = 100, .y = 100 }, 30, 0xFF00FF00, 0, 2.0);
dl.addText(.{ .x = 10, .y = 10 }, 0xFFFFFFFF, "Hello!");
```

## Misc

### Progress bar

```zig
zgui.progressBar(0.5, .{ .w = 0, .h = 0, .overlay = "50%" });
```

### Spinner / loading

```zig
// Custom spinner using draw list
const pos = zgui.getCursorScreenPos();
const dl = zgui.getWindowDrawList();
const t = zgui.getTime();
const angle: f32 = @floatCast(t * 5.0);
for (0..8) |i| {
    const a = angle + @as(f32, @floatFromInt(i)) * std.math.pi / 4.0;
    const alpha: u8 = @intFromFloat(@as(f32, 255.0) * (1.0 - @as(f32, @floatFromInt(i)) / 8.0));
    dl.addLine(
        .{ .x = pos.x + 10 + 5 * @cos(a), .y = pos.y + 10 + 5 * @sin(a) },
        .{ .x = pos.x + 10 + 10 * @cos(a), .y = pos.y + 10 + 10 * @sin(a) },
        (@as(u32, alpha) << 24) | 0xFFFFFF,
        2.0,
    );
}
zgui.dummy(.{ .w = 20, .h = 20 });
```

### Plots (via ImPlot)

If you enable `-Dwith_implot=true` in zgui:

```zig
const implot = @import("zgui").implot;

if (implot.beginPlot("Sin / Cos", .{
    .w = -1, .h = 300,
    .flags = .{ .crosshairs = true, .mouse_position = true },
})) {
    implot.setupAxes("time", "value", .{}, .{});
    implot.plotLine("sin", &sin_xs, &sin_ys);
    implot.plotLine("cos", &cos_xs, &cos_ys);
    implot.endPlot();
}
```

### Trees with columns (file browser style)

```zig
if (zgui.beginTable("Files", .{ .column = 3, .flags = .{ .resizable = true, .borders_outer = true } })) {
    zgui.tableSetupColumn("Name", .{ .flags = .{ .width_stretch = true } });
    zgui.tableSetupColumn("Size", .{ .flags = .{ .width_fixed = true }, .init_width_or_weight = 80 });
    zgui.tableSetupColumn("Type", .{ .flags = .{ .width_fixed = true }, .init_width_or_weight = 60 });
    zgui.tableHeadersRow();

    for (entries) |entry| {
        zgui.tableNextRow(.{});

        _ = zgui.tableSetColumnIndex(0);
        const flags: zgui.TreeNodeFlags = .{
            .leaf = entry.kind == .file,
            .no_tree_push_on_open = true,
            .span_all_columns = true,
            .span_avail_width = true,
        };
        if (zgui.treeNodeEx(entry.name, .{ .flags = flags })) {
            // For directories: clicking opens them (handled elsewhere)
            // For files: clicking selects them
        }

        _ = zgui.tableSetColumnIndex(1);
        zgui.text("{d}", .{entry.size});

        _ = zgui.tableSetColumnIndex(2);
        zgui.text("{s}", .{@tagName(entry.kind)});
    }
    zgui.endTable();
}
```

## See also

- [fundamentals.md](fundamentals.md) — The mental model behind these widgets
- [patterns.md](patterns.md) — How to combine them for real UIs
- [examples.md](examples.md) — Full worked examples
