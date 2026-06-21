# Production patterns for Dear ImGui

The fundamentals file covers *how* ImGui works. This file covers *how to use it well* —
patterns for real applications where you have state that outlives a frame, modals, asset
browsers, property editors, and node graphs.

## Table of contents

1. [Retained state in immediate mode](#retained-state-in-immediate-mode)
2. [Modal dialogs](#modal-dialogs)
3. [Asset browsers](#asset-browsers)
4. [Property editors / inspectors](#property-editors--inspectors)
5. [Node editors](#node-editors)
6. [Command palettes](#command-palettes)
7. [Persistent layouts](#persistent-layouts)
8. [Notifications and toasts](#notifications-and-toasts)
9. [Multi-window workflows](#multi-window-workflows)
10. [Undo / redo](#undo--redo)

## Retained state in immediate mode

The fundamental tension of immediate-mode UI: the UI is reissued every frame, but some
state must persist between frames (scroll position, text input cursor, "is this dialog
open", etc.).

ImGui handles *widget-level* state for you (slider values, checkbox state, tree node
open/closed) — it stores them keyed by ID. But *application-level* state (which file is
selected, is the modal open, what's the user typing) must live in your code.

### The pattern: state lives in your structs

```zig
const App = struct {
    // Application state — lives across frames
    selected_file: ?[]const u8 = null,
    is_find_open: bool = false,
    find_query: [256]u8 = std.mem.zeroes([256]u8),
    recent_files: std.ArrayList([]const u8),

    fn drawUI(self: *App) void {
        // UI references self.* — ImGui doesn't own the state
        if (zgui.button("Find", .{})) self.is_find_open = true;

        if (self.is_find_open) {
            self.drawFindDialog();
        }
    }

    fn drawFindDialog(self: *App) void {
        if (zgui.begin("Find", .{
            .flags = .{ .no_resize = true, .always_auto_resize = true },
        })) {
            _ = zgui.inputText("Query", .{
                .buf = &self.find_query,
                .buf_size = self.find_query.len,
            });
            if (zgui.button("Find Next", .{})) {
                self.findNext();
            }
            zgui.sameLine();
            if (zgui.button("Close", .{})) {
                self.is_find_open = false;
            }
        }
        zgui.end();
    }
};
```

### The C "static var" pattern (don't use)

In C, ImGui tutorials often show:

```cpp
void ShowFindDialog() {
    static char buf[256] = "";
    static bool open = true;
    ImGui::InputText("Query", buf, sizeof(buf));
    // ...
}
```

The `static` keyword makes the variable persist across calls. In Zig, you'd use a
module-level `var`:

```zig
var find_buf: [256]u8 = std.mem.zeroes([256]u8);
var find_open: bool = true;
```

**Don't do this.** It works for a single-instance demo, but:
- You can't have two find dialogs (no isolation).
- It's not testable (state leaks between tests).
- It's not composable (the dialog can't be embedded in another window).

Always lift state into a struct that owns its own lifetime.

### State by ID

Sometimes you want state that's per-instance but you don't want a struct. ImGui's
`Storage` API lets you store arbitrary values keyed by ID:

```zig
// Store a value
zgui.getStorage().setInt(@intFromPtr(unique_id), 42);

// Retrieve it
const val = zgui.getStorage().getInt(@intFromPtr(unique_id), 0);   // 0 is default
```

Useful for: per-item collapse state in a list, per-item edit mode. Don't abuse it — if
you find yourself storing lots of state in `Storage`, lift it into a struct.

## Modal dialogs

A modal dialog blocks interaction with the rest of the UI until dismissed. Use for
confirmations ("Delete this file?"), critical errors, and one-shot inputs.

```zig
const Modal = struct {
    open: bool = false,
    title: []const u8,
    message: []const u8,
    on_confirm: *const fn(*App) void,

    fn show(self: *Modal, app: *App) void {
        if (!self.open) return;

        // Center the modal on screen
        const viewport = zgui.getMainViewport();
        zgui.setNextWindowPos(.{
            .x = viewport.work_pos.x + viewport.work_size.w / 2,
            .y = viewport.work_pos.y + viewport.work_size.h / 2,
            .cond = .always,
            .pivot_x = 0.5,
            .pivot_y = 0.5,
        });

        if (zgui.beginPopupModal(self.title, .{
            .flags = .{ .always_auto_resize = true, .no_move = true },
        })) {
            zgui.text("{s}", .{self.message});
            zgui.separator();

            if (zgui.button("OK", .{})) {
                self.on_confirm(app);
                self.open = false;
                zgui.closeCurrentPopup();
            }
            zgui.sameLine();
            if (zgui.button("Cancel", .{}) or zgui.isKeyPressed(.escape, .{})) {
                self.open = false;
                zgui.closeCurrentPopup();
            }
            zgui.endPopup();
        }
    }
};

// Usage
var confirm_delete = Modal{
    .title = "Confirm Delete",
    .message = "Are you sure you want to delete this file?",
    .on_confirm = doDelete,
};

if (zgui.button("Delete", .{})) {
    confirm_delete.open = true;
    zgui.openPopup("Confirm Delete", .{});
}
confirm_delete.show(&app);
```

### Modal stacks

If you can open a modal from inside another modal (e.g. "are you sure?" from inside a
wizard), you need a stack. ImGui handles this with nested `beginPopupModal` calls — each
one blocks until closed, and the parent unblocks when the child closes.

## Asset browsers

A file browser / asset browser is one of the most common ImGui widgets. The shape:

```zig
const AssetBrowser = struct {
    current_dir: []const u8,
    selected: ?[]const u8 = null,
    history: std.ArrayList([]const u8),
    history_idx: usize = 0,
    io: std.Io,
    gpa: std.mem.Allocator,

    pub fn draw(self: *AssetBrowser) void {
        if (!zgui.begin("Asset Browser", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        // Toolbar: back, forward, up, current path
        if (zgui.button("<", .{ .flags = .{ .disabled = self.history_idx == 0 } })) {
            self.history_idx -= 1;
            self.current_dir = self.history.items[self.history_idx];
        }
        zgui.sameLine();
        if (zgui.button(">", .{ .flags = .{ .disabled = self.history_idx + 1 >= self.history.items.len } })) {
            self.history_idx += 1;
            self.current_dir = self.history.items[self.history_idx];
        }
        zgui.sameLine();
        if (zgui.button("^", .{})) {
            self.navigateUp();
        }
        zgui.sameLine();
        zgui.text("{s}", .{self.current_dir});

        zgui.separator();

        // File list as a table
        if (zgui.beginTable("Files", .{
            .column = 3,
            .flags = .{ .resizable = true, .borders_inner_v = true, .row_bg = true },
        })) {
            zgui.tableSetupColumn("Name", .{ .flags = .{ .width_stretch = true } });
            zgui.tableSetupColumn("Size", .{ .flags = .{ .width_fixed = true }, .init_width_or_weight = 80 });
            zgui.tableSetupColumn("Modified", .{ .flags = .{ .width_fixed = true }, .init_width_or_weight = 140 });
            zgui.tableHeadersRow();

            // List entries
            var cwd: std.Io.Dir = .cwd(self.io);
            defer cwd.close(self.io);
            var iter = cwd.openDir(self.io, self.current_dir, .{ .iterate = true }) catch {
                zgui.text("Error: cannot open directory", .{});
                zgui.endTable();
                return;
            };
            defer iter.close(self.io);

            var it = iter.iterate(self.io);
            while (it.next(self.io) catch null) |entry| {
                self.drawFileRow(entry);
            }

            zgui.endTable();
        }
    }

    fn drawFileRow(self: *AssetBrowser, entry: anytype) void {
        zgui.tableNextRow(.{});
        _ = zgui.tableSetColumnIndex(0);

        // Tree node behavior: leaf for files, expandable for dirs
        const flags: zgui.TreeNodeFlags = .{
            .leaf = entry.kind == .file,
            .no_tree_push_on_open = true,
            .span_all_columns = true,
            .span_avail_width = true,
            .selected = if (self.selected) |s| std.mem.eql(u8, s, entry.name) else false,
        };

        zgui.pushStrId(entry.name);
        defer zgui.popId();

        if (zgui.treeNodeEx(entry.name, .{ .flags = flags })) {
            // For directories, double-click navigates
            if (entry.kind == .directory and zgui.isItemHovered(.{}) and zgui.isMouseDoubleClicked(.left)) {
                self.navigateTo(entry.name);
            }
            // For files, single-click selects
            if (entry.kind == .file and zgui.isItemClicked(.left)) {
                self.selected = entry.name;
            }
        }

        _ = zgui.tableSetColumnIndex(1);
        if (entry.kind == .file) {
            zgui.text("{d}", .{entry.size});
        } else {
            zgui.textDisabled("--", .{});
        }

        _ = zgui.tableSetColumnIndex(2);
        zgui.text("{s}", .{formatTime(entry.mtime)});
    }

    fn navigateTo(self: *AssetBrowser, name: []const u8) void {
        const new_dir = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{self.current_dir, name}) catch return;
        self.history.shrinkRetainingCapacity(self.history_idx + 1);
        self.history.append(self.gpa, new_dir) catch return;
        self.history_idx += 1;
        self.current_dir = new_dir;
    }

    fn navigateUp(self: *AssetBrowser) void {
        if (std.mem.lastIndexOfScalar(u8, self.current_dir, '/')) |idx| {
            if (idx > 0) {
                self.navigateTo(self.current_dir[0..idx]);
            }
        }
    }
};
```

### Asset previews

For an image asset browser, show thumbnails instead of names:

```zig
// Cache thumbnails by file path
const thumb_cache = std.StringHashMap(TextureId).init(gpa);

fn drawThumbnail(path: []const u8) void {
    if (thumb_cache.get(path)) |tex_id| {
        zgui.image(.{ .user_texture_id = tex_id, .w = 64, .h = 64 });
    } else {
        // Load asynchronously and add to cache
        zgui.text("...", .{});
        asyncLoadThumbnail(path);
    }
}
```

Use `Io.Group` to load thumbnails in the background:

```zig
var load_group = io.createGroup(gpa);
defer load_group.cancelAndWait(io);

fn asyncLoadThumbnail(io: std.Io, gpa: std.mem.Allocator, path: []const u8) void {
    _ = io.async(load_group, loadAndDecodeImage, .{ io, gpa, path }) catch return;
}
```

## Property editors / inspectors

A property editor shows the fields of a selected object, with appropriate widgets per
field type:

```zig
const Inspector = struct {
    selected: ?*Entity = null,

    pub fn draw(self: *Inspector) void {
        if (!zgui.begin("Inspector", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        if (self.selected == null) {
            zgui.textDisabled("Nothing selected", .{});
            return;
        }

        const entity = self.selected.?;

        zgui.text("Entity: {s}", .{entity.name});
        zgui.separator();

        if (zgui.collapsingHeader("Transform", .{ .default_open = true })) {
            _ = zgui.dragFloat3("Position", .{ .v = &entity.pos, .v_speed = 0.1, .v_min = -1000, .v_max = 1000 });
            _ = zgui.dragFloat3("Rotation", .{ .v = &entity.rot, .v_speed = 0.1, .v_min = -360, .v_max = 360 });
            _ = zgui.dragFloat3("Scale", .{ .v = &entity.scale, .v_speed = 0.1, .v_min = 0.01, .v_max = 100 });
        }

        if (zgui.collapsingHeader("Material", .{ .default_open = true })) {
            _ = zgui.colorEdit4("Color", .{ .col = &entity.color });

            if (zgui.beginCombo("Shader", .{
                .current_item = &entity.shader_idx,
                .items_separated_by_zeros = "Standard\0Unlit\0Wireframe\0",
            })) {
                zgui.endCombo();
            }

            _ = zgui.sliderFloat("Roughness", .{ .v = &entity.roughness, .min = 0, .max = 1 });
            _ = zgui.sliderFloat("Metallic", .{ .v = &entity.metallic, .min = 0, .max = 1 });
        }

        if (zgui.collapsingHeader("Behavior", .{})) {
            _ = zgui.checkbox("Visible", .{ .v = &entity.visible });
            _ = zgui.checkbox("Cast Shadow", .{ .v = &entity.cast_shadow });
            _ = zgui.checkbox("Receive Shadow", .{ .v = &entity.receive_shadow });
        }
    }
};
```

### Generic property reflection

For data-driven inspectors (where fields are defined at runtime, e.g. in a script):

```zig
fn drawProperty(label: []const u8, value: anytype) void {
    const T = @TypeOf(value.*);
    switch (@typeInfo(T)) {
        .bool => _ = zgui.checkbox(label, .{ .v = value }),
        .int => {
            if (T == u8 or T == u16) {
                _ = zgui.sliderInt(label, .{ .v = value, .min = 0, .max = 255 });
            } else {
                _ = zgui.dragInt(label, .{ .v = value, .v_speed = 1, .v_min = std.math.minInt(T), .v_max = std.math.maxInt(T) });
            }
        },
        .float => _ = zgui.dragFloat(label, .{ .v = value, .v_speed = 0.1, .v_min = -1000, .v_max = 1000 }),
        .@"enum" => {
            // Build a combo from enum fields
            const fields = std.meta.fields(T);
            // ...
        },
        .@"struct" => {
            if (zgui.treeNode(label)) {
                inline for (std.meta.fields(T)) |field| {
                    drawProperty(field.name, &@field(value.*, field.name));
                }
                zgui.treePop();
            }
        },
        else => zgui.text("{s}: (unsupported type)", .{label}),
    }
}

// Usage:
drawProperty("Entity", &entity);
```

This recursive reflection walks any struct and draws an appropriate widget for each
field. Very powerful for debug tools and editors.

## Node editors

For graph UIs (shader graphs, blueprint editors, dialogue trees), zgui's `with_im_nodes`
flag enables [ImGuiNodeEditor](https://github.com/Nelarius/imnodes):

```zig
const imnodes = zgui.imnodes;

const Node = struct {
    id: u32,
    name: []const u8,
    pos: [2]f32,
    inputs: []const u32,
    outputs: []const u32,
};

const Graph = struct {
    nodes: std.ArrayList(Node),
    links: std.ArrayList(Link),

    fn draw(self: *Graph) void {
        imnodes.beginNodeEditor();

        for (self.nodes.items) |node| {
            imnodes.beginNode(node.id);
            imnodes.name(node.name);
            imnodes.beginStaticAttribute(node.id * 1000 + 1);
            // ... draw node body ...
            imnodes.endStaticAttribute();

            for (node.inputs) |input| {
                imnodes.beginInputAttribute(input);
                zgui.text("in", .{});
                imnodes.endInputAttribute();
            }
            for (node.outputs) |output| {
                imnodes.beginOutputAttribute(output);
                zgui.text("out", .{});
                imnodes.endOutputAttribute();
            }
            imnodes.endNode();
        }

        for (self.links.items) |link| {
            imnodes.link(link.id, link.from, link.to);
        }

        imnodes.endNodeEditor();
    }
};
```

This is a big topic — see the ImGuiNodeEditor examples for the full API.

## Command palettes

The Ctrl+P / Ctrl+Shift+P command palette (popularized by VS Code, Sublime). Quick
access to any action.

```zig
const CommandPalette = struct {
    open: bool = false,
    query: [128]u8 = std.mem.zeroes([128]u8),
    selected: u32 = 0,
    commands: []const Command,

    const Command = struct {
        name: []const u8,
        shortcut: []const u8 = "",
        action: *const fn(*App) void,
    };

    fn show(self: *CommandPalette, app: *App) void {
        if (zgui.isKeyPressed(.p, .{ .ctrl = true, .shift = true })) {
            self.open = true;
            self.query = std.mem.zeroes([128]u8);
            self.selected = 0;
        }

        if (!self.open) return;

        // Center on screen
        const vp = zgui.getMainViewport();
        zgui.setNextWindowPos(.{
            .x = vp.work_pos.x + vp.work_size.w / 2,
            .y = vp.work_pos.y + vp.work_size.h / 4,
            .pivot_x = 0.5,
            .pivot_y = 0.5,
        });
        zgui.setNextWindowSize(.{ .w = 600, .h = 0 });

        if (zgui.begin("Command Palette", .{
            .flags = .{ .no_title_bar = true, .always_auto_resize = true, .no_move = true },
        })) {
            _ = zgui.inputText("##query", .{
                .buf = &self.query,
                .buf_size = self.query.len,
                .flags = .{ .auto_select_all = true },
            });
            zgui.separator();

            // Filter commands by query
            const query_slice = sliceTo: {
                const idx = std.mem.indexOfScalar(u8, &self.query, 0) orelse self.query.len;
                break :sliceTo self.query[0..idx];
            };

            var match_count: u32 = 0;
            for (self.commands, 0..) |cmd, i| {
                if (!std.mem.indexOf(u8, cmd.name, query_slice)) |_| continue;
                _ = i;

                const is_selected = match_count == self.selected;
                if (zgui.selectable(cmd.name, .{ .selected = is_selected })) {
                    cmd.action(app);
                    self.open = false;
                }
                if (cmd.shortcut.len > 0) {
                    zgui.sameLine();
                    zgui.textDisabled("{s}", .{cmd.shortcut});
                }
                match_count += 1;
            }
        }
        zgui.end();
    }
};
```

## Persistent layouts

ImGui saves window positions / sizes / dock layouts to `imgui.ini` automatically. The
file lives in the working directory by default.

### Custom location

```zig
const io = zgui.io;
io.IniFilename = "config/imgui.ini";   // relative path
// or absolute:
// io.IniFilename = "/home/user/.config/myapp/imgui.ini";
```

### Disable persistence

```zig
zgui.io.setConfigFlags(.{ .no_saved_settings = true });
```

Useful for tests and demos where you want fresh state every run.

### Saving extra state

ImGui's ini file only saves window state. If you want to save app state alongside, use
your own file:

```zig
fn saveAppState(app: *App) !void {
    var f = try std.Io.Dir.cwd(io).createFile(io, "config/app.json", .{});
    defer f.close(io);
    var w = f.writer(io, &buf);
    try w.print(
        \\{{"selected_file": "{s}", "recent": [
    , .{app.selected_file orelse ""});
    // ...
}
```

Load it at startup, save it on exit / on change.

## Notifications and toasts

For "saved successfully" / "error: ..." popups that auto-dismiss:

```zig
const Notifications = struct {
    items: std.ArrayList(Item),

    const Item = struct {
        text: []const u8,
        kind: enum { info, warning, error_ },
        spawn_time: f32,
        duration: f32 = 4.0,
    };

    fn info(self: *Notifications, text: []const u8) !void {
        try self.items.append(.{
            .text = text,
            .kind = .info,
            .spawn_time = @floatCast(zgui.getTime()),
        });
    }

    fn draw(self: *Notifications) void {
        const now: f32 = @floatCast(zgui.getTime());

        // Expire old notifications
        var i: usize = 0;
        while (i < self.items.items.len) {
            const item = self.items.items[i];
            if (now - item.spawn_time > item.duration) {
                _ = self.items.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        // Draw as overlay in the bottom-right
        const vp = zgui.getMainViewport();
        var y: f32 = vp.work_pos.y + vp.work_size.h - 20;
        for (self.items.items) |item| {
            const age = now - item.spawn_time;
            const fade: f32 = if (age < 0.3) age / 0.3
                else if (age > item.duration - 0.5) (item.duration - age) / 0.5
                else 1.0;

            zgui.setNextWindowPos(.{
                .x = vp.work_pos.x + vp.work_size.w - 20,
                .y = y,
                .cond = .always,
                .pivot_x = 1.0,
                .pivot_y = 1.0,
            });
            zgui.setNextWindowBgAlpha(fade);
            zgui.pushStyleColor(.{ .col = .window_bg, .c = .{ .x = 0.1, .y = 0.1, .z = 0.1, .w = 0.9 } });
            defer zgui.popStyleColor(1);

            if (zgui.begin("##notification", .{
                .flags = .{ .no_title_bar = true, .no_resize = true, .no_move = true,
                            .no_scrollbar = true, .no_saved_settings = true },
            })) {
                switch (item.kind) {
                    .info => zgui.text("{s}", .{item.text}),
                    .warning => zgui.textColored(.{ .x = 1, .y = 0.7, .z = 0, .w = 1 }, "{s}", .{item.text}),
                    .error_ => zgui.textColored(.{ .x = 1, .y = 0.3, .z = 0.3, .w = 1 }, "{s}", .{item.text}),
                }
            }
            zgui.end();
            y -= 60;
        }
    }
};
```

## Multi-window workflows

For multi-document editors (like a code editor with multiple tabs), use ImGui's
dockspace + one window per document:

```zig
const DocumentManager = struct {
    documents: std.ArrayList(*Document),
    active: ?*Document = null,

    fn draw(self: *DocumentManager) void {
        for (self.documents.items) |doc| {
            const is_open = true;
            zgui.setNextWindowDockID(self.dock_id, .first_use_ever);
            if (zgui.begin(doc.title, .{
                .flags = .{ .no_saved_settings = false },
            })) {
                if (zgui.isWindowFocused(.{})) self.active = doc;
                doc.draw();
            }
            zgui.end();
        }
    }
};
```

The dockspace lets users arrange documents however they like; the saved layout is
restored next launch.

## Undo / redo

For editors with undo/redo, use the command pattern:

```zig
const Command = struct {
    name: []const u8,
    execute: *const fn(*App) void,
    undo: *const fn(*App) void,
};

const History = struct {
    undo_stack: std.ArrayList(Command),
    redo_stack: std.ArrayList(Command),

    fn execute(self: *History, app: *App, cmd: Command) !void {
        cmd.execute(app);
        try self.undo_stack.append(cmd);
        self.redo_stack.clearRetainingCapacity();
    }

    fn undo(self: *History, app: *App) void {
        if (self.undo_stack.popOrNull()) |cmd| {
            cmd.undo(app);
            self.redo_stack.append(cmd) catch {};
        }
    }

    fn redo(self: *History, app: *App) void {
        if (self.redo_stack.popOrNull()) |cmd| {
            cmd.execute(app);
            self.undo_stack.append(cmd) catch {};
        }
    }

    fn handleShortcuts(self: *History, app: *App) void {
        if (zgui.isKeyPressed(.z, .{ .ctrl = true, .shift = false })) self.undo(app);
        if (zgui.isKeyPressed(.z, .{ .ctrl = true, .shift = true }) or
            zgui.isKeyPressed(.y, .{ .ctrl = true }))
        {
            self.redo(app);
        }
    }
};
```

Wire `history.handleShortcuts(&app)` into your main UI loop. Each editing action calls
`history.execute(&app, cmd)`.

## See also

- [api-reference.md](api-reference.md) — The widget signatures used in these patterns
- [examples.md](examples.md) — Full worked examples using these patterns
- [performance.md](performance.md) — Keeping these UIs fast
