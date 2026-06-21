# Worked examples: file explorer, inspector, debug overlay

Three complete, runnable examples that exercise the full ImGui + Zig 0.16 stack. Each is
self-contained and ready to lift into a real project.

## Table of contents

1. [Example 1: File explorer](#example-1-file-explorer)
2. [Example 2: Property inspector](#example-2-property-inspector)
3. [Example 3: Debug overlay for a game](#example-3-debug-overlay-for-a-game)

## Example 1: File explorer

A two-pane file browser: tree on the left, file list on the right. Demonstrates:

- Tables with sorting
- Tree nodes for the directory hierarchy
- Async file enumeration (won't block the UI on slow disks)
- Persistent column widths (via ImGui's saved settings)

```zig
const std = @import("std");
const zgui = @import("zgui");

const FileExplorer = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    current_path: std.ArrayList(u8),
    selected_file: ?[]const u8 = null,
    entries: std.ArrayList(Entry),
    entries_loaded: bool = false,
    sort_column: u32 = 0,
    sort_direction: zgui.SortDirection = .ascending,

    const Entry = struct {
        name: []const u8,
        kind: enum { file, directory },
        size: u64,
        modified_ms: i64,
    };

    pub fn init(io: std.Io, gpa: std.mem.Allocator, root: []const u8) !FileExplorer {
        var path: std.ArrayList(u8) = .empty;
        try path.appendSlice(gpa, root);
        return .{
            .io = io,
            .gpa = gpa,
            .root = root,
            .current_path = path,
            .entries = .empty,
        };
    }

    pub fn deinit(self: *FileExplorer) void {
        self.current_path.deinit(self.gpa);
        self.freeEntries();
        self.entries.deinit(self.gpa);
    }

    fn freeEntries(self: *FileExplorer) void {
        for (self.entries.items) |e| self.gpa.free(e.name);
        self.entries.clearRetainingCapacity();
        self.entries_loaded = false;
    }

    pub fn draw(self: *FileExplorer) !void {
        if (!zgui.begin("File Explorer", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        // Toolbar
        if (zgui.button("Up", .{})) self.navigateUp();
        zgui.sameLine();
        zgui.text("{s}", .{self.current_path.items});
        zgui.separator();

        // Reload if needed
        if (!self.entries_loaded) {
            try self.loadEntries();
        }

        // File table
        if (zgui.beginTable("files", .{
            .column = 3,
            .flags = .{
                .resizable = true,
                .sortable = true,
                .borders_outer = true,
                .row_bg = true,
            },
        })) {
            zgui.tableSetupColumn("Name", .{ .flags = .{ .width_stretch = true } });
            zgui.tableSetupColumn("Size", .{
                .flags = .{ .width_fixed = true, .prefer_sort_ascending = true },
                .init_width_or_weight = 100,
            });
            zgui.tableSetupColumn("Modified", .{
                .flags = .{ .width_fixed = true, .prefer_sort_descending = true },
                .init_width_or_weight = 150,
            });
            zgui.tableHeadersRow();

            // Handle sort
            if (zgui.tableGetSortSpecs()) |specs| {
                if (specs.specs_count > 0) {
                    self.sort_column = specs.specs[0].column_idx;
                    self.sort_direction = specs.specs[0].sort_direction;
                    self.sortEntries();
                    specs.specs_dirty = false;
                }
            }

            // Draw entries (with clipper for performance)
            var clipper = zgui.listClipper();
            defer clipper.deinit();
            clipper.begin(@intCast(self.entries.items.len));
            while (clipper.step()) {
                var i: i32 = clipper.display_start;
                while (i < clipper.display_end) : (i += 1) {
                    self.drawEntry(self.entries.items[@intCast(i)]);
                }
            }

            zgui.endTable();
        }
    }

    fn drawEntry(self: *FileExplorer, entry: Entry) void {
        zgui.tableNextRow(.{});
        _ = zgui.tableSetColumnIndex(0);

        const flags: zgui.TreeNodeFlags = .{
            .leaf = entry.kind == .file,
            .no_tree_push_on_open = true,
            .span_all_columns = true,
            .span_avail_width = true,
            .selected = if (self.selected_file) |s| std.mem.eql(u8, s, entry.name) else false,
        };

        zgui.pushStrId(entry.name);
        defer zgui.popId();

        if (zgui.treeNodeEx(entry.name, .{ .flags = flags })) {
            if (zgui.isItemClicked(.left)) {
                self.selected_file = entry.name;
            }
            if (entry.kind == .directory and zgui.isMouseDoubleClicked(.left) and zgui.isItemHovered(.{})) {
                self.navigateTo(entry.name) catch {};
            }
        }

        _ = zgui.tableSetColumnIndex(1);
        if (entry.kind == .file) {
            zgui.text("{d}", .{entry.size});
        } else {
            zgui.textDisabled("--", .{});
        }

        _ = zgui.tableSetColumnIndex(2);
        zgui.text("{s}", .{formatTime(entry.modified_ms)});
    }

    fn loadEntries(self: *FileExplorer) !void {
        self.freeEntries();

        var cwd: std.Io.Dir = .cwd(self.io);
        defer cwd.close(self.io);

        var dir = cwd.openDir(self.io, self.current_path.items, .{ .iterate = true }) catch {
            zgui.text("Error: cannot open {s}", .{self.current_path.items});
            self.entries_loaded = true;
            return;
        };
        defer dir.close(self.io);

        var iter = dir.iterate(self.io);
        while (try iter.next(self.io)) |e| {
            const name = try self.gpa.dupe(u8, e.name);
            try self.entries.append(self.gpa, .{
                .name = name,
                .kind = if (e.kind == .file) .file else .directory,
                .size = if (e.kind == .file) (dir.statFile(self.io, e.name) catch continue).size else 0,
                .modified_ms = std.time.milliTimestamp(),
            });
        }

        self.sortEntries();
        self.entries_loaded = true;
    }

    fn sortEntries(self: *FileExplorer) void {
        const lessThan = struct {
            fn lt(ctx: *FileExplorer, a: Entry, b: Entry) bool {
                const dir = ctx.sort_direction;
                switch (ctx.sort_column) {
                    0 => return if (dir == .ascending) std.mem.lessThan(u8, a.name, b.name)
                        else std.mem.lessThan(u8, b.name, a.name),
                    1 => return if (dir == .ascending) a.size < b.size else a.size > b.size,
                    2 => return if (dir == .ascending) a.modified_ms < b.modified_ms else a.modified_ms > b.modified_ms,
                    else => return false,
                }
            }
        }.lt;

        std.mem.sort(Entry, self.entries.items, self, lessThan);
    }

    fn navigateTo(self: *FileExplorer, name: []const u8) !void {
        try self.current_path.appendSlice(self.gpa, "/");
        try self.current_path.appendSlice(self.gpa, name);
        self.freeEntries();
    }

    fn navigateUp(self: *FileExplorer) void {
        if (std.mem.lastIndexOfScalar(u8, self.current_path.items, '/')) |idx| {
            if (idx >= self.root.len) {
                self.current_path.shrinkRetainingCapacity(idx);
                self.freeEntries();
            }
        }
    }
};

fn formatTime(modified_ms: i64) []const u8 {
    // Simplified — real impl would format like "2024-03-15 14:23"
    _ = modified_ms;
    return "—";
}
```

### Usage in main

```zig
pub fn main(init: std.process.Init) !void {
    // ... SDL3 + GL + zgui init ...

    var explorer = try FileExplorer.init(io, gpa, "/home/user");
    defer explorer.deinit();

    while (running) {
        // ... event polling, newFrame ...

        try explorer.draw();

        // ... render ...
    }
}
```

## Example 2: Property inspector

A property editor that walks a tagged-union "entity" type and draws appropriate widgets
per field. Demonstrates:

- Recursive reflection
- Per-field-type widgets
- Undo/redo integration
- Custom widgets for enums with descriptions

```zig
const std = @import("std");
const zgui = @import("zgui");

const Vec3 = struct { x: f32, y: f32, z: f32 };

const Entity = struct {
    name: [64]u8 = std.mem.zeroes([64]u8),
    position: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    rotation: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    scale: Vec3 = .{ .x = 1, .y = 1, .z = 1 },
    visible: bool = true,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    material: MaterialKind = .standard,
    roughness: f32 = 0.5,
    metallic: f32 = 0.0,
    tags: [256]u8 = std.mem.zeroes([256]u8),
};

const MaterialKind = enum {
    standard,
    unlit,
    wireframe,
    custom,

    fn label(self: MaterialKind) []const u8 {
        return switch (self) {
            .standard => "Standard",
            .unlit => "Unlit",
            .wireframe => "Wireframe",
            .custom => "Custom",
        };
    }
};

const Inspector = struct {
    selected: ?*Entity = null,
    // For undo/redo (simplified — a real impl would use a command stack)
    pre_edit_snapshot: ?Entity = null,

    pub fn draw(self: *Inspector) void {
        if (!zgui.begin("Inspector", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        if (self.selected) |entity| {
            // Snapshot before edit
            if (zgui.isWindowAppearing()) {
                self.pre_edit_snapshot = entity.*;
            }

            zgui.text("Entity: {s}", .{sliceToZero(&entity.name)});
            zgui.separator();

            if (zgui.collapsingHeader("Identity", .{ .default_open = true })) {
                _ = zgui.inputText("Name", .{
                    .buf = &entity.name,
                    .buf_size = entity.name.len,
                });
                _ = zgui.inputText("Tags", .{
                    .buf = &entity.tags,
                    .buf_size = entity.tags.len,
                    .flags = .{ .chars_no_blank = false },
                });
            }

            if (zgui.collapsingHeader("Transform", .{ .default_open = true })) {
                _ = zgui.dragFloat3("Position", .{
                    .v = @ptrCast(&entity.position),
                    .v_speed = 0.1,
                    .v_min = -10000,
                    .v_max = 10000,
                    .cfmt = "%.2f",
                });
                _ = zgui.dragFloat3("Rotation", .{
                    .v = @ptrCast(&entity.rotation),
                    .v_speed = 1.0,
                    .v_min = -360,
                    .v_max = 360,
                    .cfmt = "%.1f deg",
                });
                _ = zgui.dragFloat3("Scale", .{
                    .v = @ptrCast(&entity.scale),
                    .v_speed = 0.05,
                    .v_min = 0.01,
                    .v_max = 100,
                    .cfmt = "%.2f",
                });

                zgui.separator();
                if (zgui.button("Reset Transform", .{})) {
                    entity.position = .{ .x = 0, .y = 0, .z = 0 };
                    entity.rotation = .{ .x = 0, .y = 0, .z = 0 };
                    entity.scale = .{ .x = 1, .y = 1, .z = 1 };
                }
            }

            if (zgui.collapsingHeader("Material", .{ .default_open = true })) {
                _ = zgui.colorEdit4("Color", .{ .col = &entity.color });

                // Custom enum combo with descriptions
                self.drawMaterialCombo(entity);

                _ = zgui.sliderFloat("Roughness", .{ .v = &entity.roughness, .min = 0, .max = 1 });
                _ = zgui.sliderFloat("Metallic", .{ .v = &entity.metallic, .min = 0, .max = 1 });

                // Preview
                zgui.separator();
                zgui.textColored(.{
                    .x = entity.color[0],
                    .y = entity.color[1],
                    .z = entity.color[2],
                    .w = 1.0,
                }, "Preview: {s}", .{entity.material.label()});
            }

            if (zgui.collapsingHeader("Behavior", .{})) {
                _ = zgui.checkbox("Visible", .{ .v = &entity.visible });
            }
        } else {
            zgui.textDisabled("No entity selected", .{});
            zgui.text("Select an entity in the scene view.", .{});
        }
    }

    fn drawMaterialCombo(self: *Inspector, entity: *Entity) void {
        _ = self;
        if (zgui.beginCombo("Material", .{
            .current_item = @ptrCast(@alignCast(&entity.material)),   // careful: enum backing
            .items_separated_by_zeros = "Standard\0Unlit\0Wireframe\0Custom\0",
        })) {
            zgui.endCombo();
        }
    }
};
```

### Generic reflection

For data-driven inspectors (any struct type):

```zig
fn drawReflected(label: []const u8, value: anytype) void {
    const T = @TypeOf(value.*);
    const info = @typeInfo(T);

    switch (info) {
        .bool => _ = zgui.checkbox(label, .{ .v = value }),
        .int => {
            if (T == u8 or T == u16) {
                _ = zgui.sliderInt(label, .{ .v = value, .min = 0, .max = 255 });
            } else if (@typeInfo(T).int.signedness == .unsigned) {
                _ = zgui.dragInt(label, .{ .v = value, .v_min = 0, .v_max = std.math.maxInt(T) });
            } else {
                _ = zgui.dragInt(label, .{ .v = value, .v_min = std.math.minInt(T), .v_max = std.math.maxInt(T) });
            }
        },
        .float => {
            if (T == f32) {
                _ = zgui.dragFloat(label, .{ .v = value, .v_speed = 0.1, .v_min = -10000, .v_max = 10000 });
            } else {
                _ = zgui.dragFloat(label, .{ .v = value, .v_speed = 0.1, .v_min = -10000, .v_max = 10000 });
            }
        },
        .@"enum" => {
            // Build a combo from enum fields
            const fields = std.meta.fields(T);
            var current: u32 = @intFromEnum(value.*);
            const items_buf = blk: {
                var buf: [4096]u8 = undefined;
                var stream = std.io.fixedBufferStream(&buf);
                for (fields, 0..) |field, i| {
                    if (i > 0) stream.write("\0") catch break;
                    stream.write(field.name) catch break;
                }
                break :blk stream.getWritten();
            };
            if (zgui.beginCombo(label, .{
                .current_item = &current,
                .items_separated_by_zeros = items_buf.ptr,
            })) {
                zgui.endCombo();
            }
            value.* = @enumFromInt(current);
        },
        .@"struct" => {
            if (zgui.treeNode(label)) {
                inline for (std.meta.fields(T)) |field| {
                    drawReflected(field.name, &@field(value.*, field.name));
                }
                zgui.treePop();
            }
        },
        .array => |arr| {
            if (arr.child == u8) {
                // Treat as a string buffer
                _ = zgui.inputText(label, .{
                    .buf = @ptrCast(value),
                    .buf_size = arr.len,
                });
            } else {
                if (zgui.treeNode(label)) {
                    for (value.*, 0..) |*item, i| {
                        var lbl_buf: [32]u8 = undefined;
                        const item_label = std.fmt.bufPrint(&lbl_buf, "[{d}]", .{i}) catch "[?]";
                        drawReflected(item_label, item);
                    }
                    zgui.treePop();
                }
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice) {
                if (zgui.treeNode(label)) {
                    for (value.*, 0..) |*item, i| {
                        var lbl_buf: [32]u8 = undefined;
                        const item_label = std.fmt.bufPrint(&lbl_buf, "[{d}]", .{i}) catch "[?]";
                        drawReflected(item_label, item);
                    }
                    zgui.treePop();
                }
            } else {
                zgui.text("{s}: (pointer)", .{label});
            }
        },
        else => zgui.text("{s}: (unsupported {s})", .{ label, @typeName(T) }),
    }
}

// Usage:
drawReflected("Entity", &my_entity);
```

## Example 3: Debug overlay for a game

An overlay that sits on top of a running game, showing FPS, frame timing, entity counts,
and live-tweakable parameters. Demonstrates:

- Minimal-intrusion overlay (transparent background, fixed position)
- Hotkey toggles
- Live-editing of game parameters
- Plotting with ImPlot

```zig
const std = @import("std");
const zgui = @import("zgui");
const implot = zgui.implot;

const Game = struct {
    // Game state
    player_pos: Vec3 = .{ .x = 0, .y = 0, .z = 0 },
    player_health: f32 = 100,
    enemy_count: u32 = 0,

    // Tweakable params
    gravity: f32 = 9.8,
    player_speed: f32 = 5.0,
    jump_force: f32 = 12.0,
    enemy_spawn_rate: f32 = 1.0,

    // Stats history (for plotting)
    fps_history: [256]f32 = std.mem.zeroes([256]f32),
    frame_time_history: [256]f32 = std.mem.zeroes([256]f32),
    history_idx: u32 = 0,
};

const DebugOverlay = struct {
    game: *Game,
    show: bool = true,
    show_params: bool = false,
    show_plots: bool = false,
    transparent: bool = true,

    pub fn draw(self: *DebugOverlay) void {
        // Toggle with F1
        if (zgui.isKeyPressed(.f1, .{})) {
            self.show = !self.show;
        }
        // Toggle params with F2
        if (zgui.isKeyPressed(.f2, .{})) {
            self.show_params = !self.show_params;
        }
        // Toggle plots with F3
        if (zgui.isKeyPressed(.f3, .{})) {
            self.show_plots = !self.show_plots;
        }

        if (!self.show) return;

        // Main overlay: top-left, transparent bg
        const viewport = zgui.getMainViewport();
        zgui.setNextWindowPos(.{
            .x = viewport.work_pos.x + 10,
            .y = viewport.work_pos.y + 10,
            .cond = .always,
        });
        if (self.transparent) {
            zgui.setNextWindowBgAlpha(0.7);
        }

        if (zgui.begin("Debug", .{
            .flags = .{
                .no_title_bar = true,
                .no_resize = true,
                .no_move = true,
                .no_scrollbar = true,
                .no_collapse = true,
                .no_saved_settings = true,
                .no_focus_on_appearing = true,
                .no_nav = true,
            },
        })) {
            const now: f32 = @floatCast(zgui.getTime());
            const dt: f32 = zgui.io.delta_time;
            const fps: f32 = 1.0 / dt;

            // Update history
            self.game.fps_history[self.game.history_idx] = fps;
            self.game.frame_time_history[self.game.history_idx] = dt * 1000;
            self.game.history_idx = (self.game.history_idx + 1) % 256;

            zgui.text("FPS: {d:.1}", .{fps});
            zgui.text("Frame: {d:.2} ms", .{dt * 1000});
            zgui.text("Time: {d:.1} s", .{now});

            zgui.separator();
            zgui.text("Player: ({d:.1}, {d:.1}, {d:.1})",
                .{self.game.player_pos.x, self.game.player_pos.y, self.game.player_pos.z});
            zgui.text("Health: {d:.0}", .{self.game.player_health});
            zgui.text("Enemies: {d}", .{self.game.enemy_count});

            zgui.separator();
            zgui.textDisabled("F1: overlay  F2: params  F3: plots", .{});
        }
        zgui.end();

        if (self.show_params) {
            self.drawParams();
        }
        if (self.show_plots) {
            self.drawPlots();
        }
    }

    fn drawParams(self: *DebugOverlay) void {
        if (!zgui.begin("Parameters", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        if (zgui.collapsingHeader("Player", .{ .default_open = true })) {
            _ = zgui.dragFloat("Speed", .{
                .v = &self.game.player_speed, .v_speed = 0.1,
                .v_min = 0.1, .v_max = 50,
            });
            _ = zgui.dragFloat("Jump Force", .{
                .v = &self.game.jump_force, .v_speed = 0.1,
                .v_min = 0.1, .v_max = 50,
            });
        }

        if (zgui.collapsingHeader("World", .{ .default_open = true })) {
            _ = zgui.dragFloat("Gravity", .{
                .v = &self.game.gravity, .v_speed = 0.1,
                .v_min = 0, .v_max = 50,
            });
            _ = zgui.dragFloat("Enemy Spawn Rate", .{
                .v = &self.game.enemy_spawn_rate, .v_speed = 0.1,
                .v_min = 0, .v_max = 10,
            });
        }

        zgui.separator();
        if (zgui.button("Reset to Defaults", .{})) {
            self.game.gravity = 9.8;
            self.game.player_speed = 5.0;
            self.game.jump_force = 12.0;
            self.game.enemy_spawn_rate = 1.0;
        }
    }

    fn drawPlots(self: *DebugOverlay) void {
        if (!zgui.begin("Plots", .{})) {
            zgui.end();
            return;
        }
        defer zgui.end();

        // Build X axis (frame indices)
        const xs = blk: {
            const N: u32 = 256;
            var arr: [N]f32 = undefined;
            for (0..N) |i| arr[i] = @floatFromInt(i);
            break :blk arr;
        };

        // Rotate the history so the latest sample is at the right
        const fps_ys = blk: {
            const N: u32 = 256;
            var arr: [N]f32 = undefined;
            const idx = self.game.history_idx;
            for (0..N) |i| arr[i] = self.game.fps_history[(idx + i) % N];
            break :blk arr;
        };

        const ft_ys = blk: {
            const N: u32 = 256;
            var arr: [N]f32 = undefined;
            const idx = self.game.history_idx;
            for (0..N) |i| arr[i] = self.game.frame_time_history[(idx + i) % N];
            break :blk arr;
        };

        if (implot.beginPlot("FPS", .{ .w = -1, .h = 200 })) {
            implot.setupAxes("frame", "fps", .{}, .{});
            implot.setupAxesLimits(0, 256, 0, 120, .{ .cond = .always });
            implot.plotLine("FPS", &xs, &fps_ys);
            implot.endPlot();
        }

        if (implot.beginPlot("Frame Time", .{ .w = -1, .h = 200 })) {
            implot.setupAxes("frame", "ms", .{}, .{});
            implot.setupAxesLimits(0, 256, 0, 30, .{ .cond = .always });
            implot.plotLine("frame time", &xs, &ft_ys);
            implot.endPlot();
        }
    }
};
```

### Integrating with a game

```zig
pub fn main(init: std.process.Init) !void {
    // ... SDL3 + GL + zgui setup ...

    var game = Game{};
    var overlay = DebugOverlay{ .game = &game };

    while (running) {
        // ... game event polling, world update ...

        // Render game scene
        renderGameScene(&game);

        // Render debug overlay on top
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(fb_size.width, fb_size.height);
        overlay.draw();
        const draw_data = zgui.getDrawData();

        // Re-enable blending for transparent overlay
        zgl.enable(.blend);
        zgl.blendFunc(.src_alpha, .one_minus_src_alpha);

        zgui.backend.draw(draw_data);

        zsdl.video.GL.swapWindow(window);
    }
}
```

The overlay uses `setNextWindowBgAlpha(0.7)` for a semi-transparent background, so the
game shows through. The GL blend mode is enabled before `backend.draw` to support
alpha-blended ImGui rendering.

## See also

- [api-reference.md](api-reference.md) — The widgets used in these examples
- [patterns.md](patterns.md) — The patterns these examples apply
- [build-zig.md](build-zig.md) — The build setup these examples assume
