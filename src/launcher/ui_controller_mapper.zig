const std = @import("std");
const logging = @import("common").logging;
const mapper = @import("dll").controller_mapper;
const zgui = @import("zgui");

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

pub fn applyBinding(m: *mapper.ControllerMapping, target: mapper.BindingTarget, binding: mapper.InputBinding) void {
    switch (target) {
        .a => m.a = binding,
        .b => m.b = binding,
        .c => m.c = binding,
        .d => m.d = binding,
        .e => m.e = binding,
        .ab => m.ab = binding,
        .start => m.start = binding,
        .fn1 => m.fn1 = binding,
        .fn2 => m.fn2 = binding,
        .up => m.up = binding,
        .down => m.down = binding,
        .left => m.left = binding,
        .right => m.right = binding,
        .none => {},
    }
}

pub fn bindButton(label: [:0]const u8, target: mapper.BindingTarget, binding: mapper.InputBinding, bind_target: *mapper.BindingTarget, cooldown_until_ms: *i64, now_ms: i64) void {
    var buf: [64]u8 = undefined;
    const bind_label = binding.label(&buf);

    if (bind_target.* == target) {
        // This button is currently being bound — show "Press input..."
        var btn_buf: [80]u8 = undefined;
        const btn_text = std.fmt.bufPrintZ(&btn_buf, "{s}: Press...", .{label}) catch label;
        _ = zgui.button(btn_text, .{ .w = 90, .h = 0 });
    } else {
        var btn_buf: [80]u8 = undefined;
        const btn_text = std.fmt.bufPrintZ(&btn_buf, "{s}: {s}", .{ label, bind_label }) catch label;
        if (zgui.button(btn_text, .{ .w = 90, .h = 0 })) {
            bind_target.* = target;
            // 250 ms wall-clock cooldown so the same click that triggered
            // "press to bind" is not read back as the binding itself.
            // Wall-clock based — correct regardless of UI frame rate.
            cooldown_until_ms.* = now_ms + 250;
        }
    }
}

/// Draw the player panel (grid view) and return `true` if the user
/// changed any configuration (device, SOCD, deadzone, macro, defaults,
/// clear). The caller uses this to trigger autosave.
pub fn drawPlayerPanel(
    name: []const u8,
    m: *mapper.ControllerMapping,
    bind_target: *mapper.BindingTarget,
    joy: *?*anyopaque,
    device_sel: *c_int,
    dev_names: *const [16][*:0]const u8,
    dev_count: c_int,
    num_joy: c_int,
    log: *logging.Logger,
    io: std.Io,
    cooldown_until_ms: *i64,
) bool {
    var changed: bool = false;
    _ = num_joy;

    // Capture wall-clock ms once per panel draw — passed to each bindButton
    // so cooldowns are anchored to real time, not UI frame rate.
    const now_ms: i64 = std.Io.Clock.now(.real, io).toMilliseconds();

    // Build unique ID suffixes from player name to avoid ImGui ID conflicts
    var id_suffix_buf: [32]u8 = undefined;
    const id_suffix = std.fmt.bufPrintZ(&id_suffix_buf, "##{s}", .{name}) catch "##p";

    // Player label + device combo
    zgui.text("{s}", .{name});
    zgui.sameLine(.{ .spacing = 16 });

    var combo_label_buf: [48]u8 = undefined;
    const combo_label = std.fmt.bufPrintZ(&combo_label_buf, "##device_{s}", .{name}) catch "##device";

    const preview = if (device_sel.* >= 0 and device_sel.* < dev_count) dev_names[@intCast(device_sel.*)] else "";
    if (zgui.beginCombo(combo_label, .{ .preview_value = preview })) {
        defer zgui.endCombo();
        var i: i32 = 0;
        while (i < dev_count) : (i += 1) {
            const item_name = dev_names[@intCast(i)];
            const is_selected = (device_sel.* == i);
            if (zgui.selectable(std.mem.span(item_name), .{ .selected = is_selected })) {
                device_sel.* = i;
                changed = true;
            }
            if (is_selected) {
                zgui.setItemDefaultFocus();
            }
        }
    }

    // Open/close joystick when device changes
    const new_dev: c_int = device_sel.* - 1;
    if (new_dev != m.device_index) {
        if (joy.*) |j| {
            c.SDL_JoystickClose(@ptrCast(j));
            joy.* = null;
        }
        if (new_dev >= 0) {
            joy.* = @ptrCast(c.SDL_JoystickOpen(new_dev));
            if (joy.* != null) {
                log.info("{s}: opened joystick {d}", .{ name, new_dev });
            }
        }
        m.device_index = new_dev;
        changed = true;
    }

    zgui.spacing();

    // Push a unique ID stack for this player's widgets
    zgui.pushStrId(id_suffix);

    // Top row: FN1, Start, FN2
    zgui.indent(.{ .indent_w = 200 });
    bindButton("FN1", .fn1, m.fn1, bind_target, cooldown_until_ms, now_ms);
    zgui.sameLine(.{ .spacing = 8 });
    bindButton("Start", .start, m.start, bind_target, cooldown_until_ms, now_ms);
    zgui.sameLine(.{ .spacing = 8 });
    bindButton("FN2", .fn2, m.fn2, bind_target, cooldown_until_ms, now_ms);
    zgui.unindent(.{ .indent_w = 200 });

    zgui.spacing();

    // Two columns: Directions (left) + Buttons (right)
    _ = zgui.beginChild("dir", .{ .w = 250, .h = 165, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true } });
    zgui.indent(.{ .indent_w = 5 });

    const dir_title = "Directions";
    const dir_w = zgui.calcTextSize(dir_title, .{})[0];
    zgui.setCursorPosX((250.0 - dir_w) / 2 + 5);
    zgui.text(dir_title, .{});
    zgui.spacing();

    // Up (centered)
    zgui.indent(.{ .indent_w = 72 });
    bindButton("Up", .up, m.up, bind_target, cooldown_until_ms, now_ms);
    zgui.unindent(.{ .indent_w = 72 });

    // Left + Right
    bindButton("Left", .left, m.left, bind_target, cooldown_until_ms, now_ms);
    zgui.sameLine(.{ .spacing = 8 });
    zgui.dummy(.{ .w = 30, .h = 0 });
    zgui.sameLine(.{ .spacing = 8 });
    bindButton("Right", .right, m.right, bind_target, cooldown_until_ms, now_ms);

    // Down (centered)
    zgui.indent(.{ .indent_w = 72 });
    bindButton("Down", .down, m.down, bind_target, cooldown_until_ms, now_ms);
    zgui.unindent(.{ .indent_w = 72 });

    zgui.unindent(.{ .indent_w = 5 });
    zgui.endChild();

    zgui.sameLine(.{ .spacing = 8 });

    _ = zgui.beginChild("btn", .{ .w = 310, .h = 165, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true } });
    zgui.indent(.{ .indent_w = 5 });

    const btn_title = "Buttons";
    const btn_w = zgui.calcTextSize(btn_title, .{})[0];
    zgui.setCursorPosX((310.0 - btn_w) / 2 + 5);
    zgui.text(btn_title, .{});
    zgui.spacing();

    // Row 1: A, B, C
    bindButton("A", .a, m.a, bind_target, cooldown_until_ms, now_ms);
    zgui.sameLine(.{ .spacing = 8 });
    bindButton("B", .b, m.b, bind_target, cooldown_until_ms, now_ms);
    zgui.sameLine(.{ .spacing = 8 });
    bindButton("C", .c, m.c, bind_target, cooldown_until_ms, now_ms);

    zgui.spacing();

    // Row 2: D, E, AB
    bindButton("D", .d, m.d, bind_target, cooldown_until_ms, now_ms);
    zgui.sameLine(.{ .spacing = 8 });
    bindButton("E", .e, m.e, bind_target, cooldown_until_ms, now_ms);
    zgui.sameLine(.{ .spacing = 8 });
    bindButton("A+B", .ab, m.ab, bind_target, cooldown_until_ms, now_ms);

    zgui.unindent(.{ .indent_w = 5 });
    zgui.endChild();

    zgui.sameLine(.{ .spacing = 8 });

    _ = zgui.beginChild("opt", .{ .w = 340, .h = 165, .child_flags = .{ .border = true }, .window_flags = .{ .no_scrollbar = true } });
    zgui.indent(.{ .indent_w = 5 });

    const opt_title = "Options";
    const opt_w = zgui.calcTextSize(opt_title, .{})[0];
    zgui.setCursorPosX((340.0 - opt_w) / 2 + 5);
    zgui.text(opt_title, .{});
    zgui.spacing();

    // Line 1: SOCD mode
    const old_socd = m.socd_mode;
    zgui.text("SOCD:", .{});
    zgui.sameLine(.{ .spacing = 6 });
    if (zgui.radioButton("L+R", .{ .active = m.socd_mode == 1 })) m.socd_mode = 1;
    zgui.sameLine(.{ .spacing = 6 });
    if (zgui.radioButton("U+D", .{ .active = m.socd_mode == 2 })) m.socd_mode = 2;
    zgui.sameLine(.{ .spacing = 6 });
    if (zgui.radioButton("Both", .{ .active = m.socd_mode == 3 })) m.socd_mode = 3;
    if (m.socd_mode == 0) m.socd_mode = 1;
    if (m.socd_mode != old_socd) changed = true;

    zgui.spacing();

    // Line 2: Macro & Deadzone slider
    const old_macro = m.air_dash_macro;
    _ = zgui.checkbox("AD Macro (9AB)", .{ .v = &m.air_dash_macro });
    if (m.air_dash_macro != old_macro) changed = true;
    zgui.sameLine(.{ .spacing = 12 });
    const old_dz = m.deadzone;
    var dz_float: f32 = @as(f32, @floatFromInt(m.deadzone)) / 32767.0;
    zgui.pushItemWidth(65.0);
    _ = zgui.sliderFloat("Deadzone", .{ .v = &dz_float, .min = 0.0, .max = 1.0, .cfmt = "%.2f" });
    zgui.popItemWidth();
    m.deadzone = @intFromFloat(dz_float * 32767.0);
    if (m.deadzone != old_dz) changed = true;

    zgui.spacing();

    // Line 3: Default Bindings / Clear
    if (zgui.button("Default Bindings", .{ .w = 120, .h = 0 })) {
        m.* = mapper.defaultXboxMapping();
        m.device_index = device_sel.* - 1;
        changed = true;
    }
    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.button("Clear", .{ .w = 50, .h = 0 })) {
        m.a = .{};
        m.b = .{};
        m.c = .{};
        m.d = .{};
        m.e = .{};
        m.ab = .{};
        m.start = .{};
        m.fn1 = .{};
        m.fn2 = .{};
        m.up = .{};
        m.down = .{};
        m.left = .{};
        m.right = .{};
        changed = true;
    }

    zgui.unindent(.{ .indent_w = 5 });
    zgui.endChild();

    zgui.popId();
    return changed;
}

/// Draw the player panel (list view) and return `true` if the user
/// changed any configuration. The caller uses this to trigger autosave.
pub fn drawListPanel(
    name: []const u8,
    m: *mapper.ControllerMapping,
    bind_target: *mapper.BindingTarget,
    joy: *?*anyopaque,
    device_sel: *c_int,
    dev_names: *const [16][*:0]const u8,
    dev_count: c_int,
    log: *logging.Logger,
    io: std.Io,
    cooldown_until_ms: *i64,
) bool {
    var changed: bool = false;
    // Capture wall-clock ms once per panel draw — passed to each bindButton
    // so cooldowns are anchored to real time, not UI frame rate.
    const now_ms: i64 = std.Io.Clock.now(.real, io).toMilliseconds();
    // Build unique ID suffix for ImGui ID stack
    var id_suffix_buf: [32]u8 = undefined;
    const id_suffix = std.fmt.bufPrintZ(&id_suffix_buf, "##list_{s}", .{name}) catch "##list_p";
    zgui.pushStrId(id_suffix);

    // Player name header
    zgui.text("{s}", .{name});
    zgui.spacing();

    // Device combo
    var combo_label_buf: [48]u8 = undefined;
    const combo_label = std.fmt.bufPrintZ(&combo_label_buf, "##device_{s}", .{name}) catch "##device";

    const preview = if (device_sel.* >= 0 and device_sel.* < dev_count) dev_names[@intCast(device_sel.*)] else "";
    if (zgui.beginCombo(combo_label, .{ .preview_value = preview })) {
        defer zgui.endCombo();
        var i: i32 = 0;
        while (i < dev_count) : (i += 1) {
            const item_name = dev_names[@intCast(i)];
            const is_selected = (device_sel.* == i);
            if (zgui.selectable(std.mem.span(item_name), .{ .selected = is_selected })) {
                device_sel.* = i;
                changed = true;
            }
            if (is_selected) {
                zgui.setItemDefaultFocus();
            }
        }
    }

    // Open/close joystick when device changes
    const new_dev: c_int = device_sel.* - 1;
    if (new_dev != m.device_index) {
        if (joy.*) |j| {
            c.SDL_JoystickClose(@ptrCast(j));
            joy.* = null;
        }
        if (new_dev >= 0) {
            joy.* = @ptrCast(c.SDL_JoystickOpen(new_dev));
            if (joy.* != null) {
                log.info("{s}: opened joystick {d}", .{ name, new_dev });
            }
        }
        m.device_index = new_dev;
        changed = true;
    }

    zgui.spacing();
    zgui.separator();
    zgui.spacing();

    // Each row: [in-game button name (fixed width)] [bind button]
    // Use a table-like layout with align_text_to_frame_padding for clean
    // vertical alignment. The name column is 90px wide; the bind button
    // fills the rest.
    const rows = [_]struct { label: [:0]const u8, target: mapper.BindingTarget, binding: mapper.InputBinding }{
        .{ .label = "Up", .target = .up, .binding = m.up },
        .{ .label = "Down", .target = .down, .binding = m.down },
        .{ .label = "Left", .target = .left, .binding = m.left },
        .{ .label = "Right", .target = .right, .binding = m.right },
        .{ .label = "A", .target = .a, .binding = m.a },
        .{ .label = "B", .target = .b, .binding = m.b },
        .{ .label = "C", .target = .c, .binding = m.c },
        .{ .label = "D", .target = .d, .binding = m.d },
        .{ .label = "E", .target = .e, .binding = m.e },
        .{ .label = "A+B", .target = .ab, .binding = m.ab },
        .{ .label = "Start", .target = .start, .binding = m.start },
        .{ .label = "FN1", .target = .fn1, .binding = m.fn1 },
        .{ .label = "FN2", .target = .fn2, .binding = m.fn2 },
    };

    for (rows) |row| {
        // In-game button name (left column, fixed width)
        zgui.alignTextToFramePadding();
        zgui.text("{s}", .{row.label});
        zgui.sameLine(.{ .offset_from_start_x = 90, .spacing = 8 }); // 90px name column + 8px spacing
        // Bind button (right column)
        bindButton(row.label, row.target, row.binding, bind_target, cooldown_until_ms, now_ms);
    }

    zgui.spacing();
    zgui.separator();
    zgui.spacing();

    // SOCD mode radio buttons
    const old_socd = m.socd_mode;
    zgui.text("SOCD:", .{});
    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.radioButton("L+R neg", .{ .active = m.socd_mode == 1 })) m.socd_mode = 1;
    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.radioButton("U+D neg", .{ .active = m.socd_mode == 2 })) m.socd_mode = 2;
    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.radioButton("Both neg", .{ .active = m.socd_mode == 3 })) m.socd_mode = 3;
    if (m.socd_mode == 0) m.socd_mode = 1;
    if (m.socd_mode != old_socd) changed = true;

    zgui.spacing();

    // Air Dash Macro toggle (per-player; see drawPlayerPanel for details).
    const old_macro = m.air_dash_macro;
    _ = zgui.checkbox("Air Dash Macro (9AB/7AB)", .{ .v = &m.air_dash_macro });
    if (m.air_dash_macro != old_macro) changed = true;

    zgui.spacing();

    // Analog Deadzone (0.0-1.0 float, small field)
    const old_dz = m.deadzone;
    var dz_float: f32 = @as(f32, @floatFromInt(m.deadzone)) / 32767.0;
    zgui.pushItemWidth(120.0);
    _ = zgui.sliderFloat("Analog Deadzone", .{ .v = &dz_float, .min = 0.0, .max = 1.0, .cfmt = "%.2f" });
    zgui.popItemWidth();
    m.deadzone = @intFromFloat(dz_float * 32767.0);
    if (m.deadzone != old_dz) changed = true;

    zgui.spacing();

    // Default Bindings + Clear buttons
    if (zgui.button("Default Bindings", .{ .w = 130, .h = 0 })) {
        m.* = mapper.defaultXboxMapping();
        m.device_index = device_sel.* - 1;
        changed = true;
    }
    zgui.sameLine(.{ .spacing = 8 });
    if (zgui.button("Clear", .{ .w = 60, .h = 0 })) {
        m.a = .{};
        m.b = .{};
        m.c = .{};
        m.d = .{};
        m.e = .{};
        m.ab = .{};
        m.start = .{};
        m.fn1 = .{};
        m.fn2 = .{};
        m.up = .{};
        m.down = .{};
        m.left = .{};
        m.right = .{};
        changed = true;
    }

    zgui.popId();
    return changed;
}

/// Build the device-name combo box array used by the Controllers tab.
pub fn buildDeviceList(
    dev_names_buf: *[16][64]u8,
    dev_names: *[16][*:0]const u8,
    num_joy: c_int,
) c_int {
    var dev_count: c_int = 1;
    dev_names[0] = "Keyboard";
    {
        var j: c_int = 0;
        while (j < num_joy and dev_count < 16) : (j += 1) {
            const name = c.SDL_JoystickNameForIndex(j);
            if (name != null) {
                const span = std.mem.span(name);
                const max_len = 58; // leave space for null terminator and ##{j} suffix (up to ##15)
                const n = @min(span.len, max_len);
                const printed = std.fmt.bufPrintZ(&dev_names_buf[@intCast(dev_count)], "{s}##{d}", .{ span[0..n], j }) catch blk: {
                    @memcpy(dev_names_buf[@intCast(dev_count)][0..n], span[0..n]);
                    dev_names_buf[@intCast(dev_count)][n] = 0;
                    break :blk dev_names_buf[@intCast(dev_count)][0..n :0];
                };
                _ = printed;
                dev_names[@intCast(dev_count)] = @ptrCast(&dev_names_buf[@intCast(dev_count)]);
            } else {
                const fallback = "Unknown Joystick";
                const printed = std.fmt.bufPrintZ(&dev_names_buf[@intCast(dev_count)], "{s}##{d}", .{ fallback, j }) catch fallback;
                _ = printed;
                dev_names[@intCast(dev_count)] = @ptrCast(&dev_names_buf[@intCast(dev_count)]);
            }
            dev_count += 1;
        }
    }
    return dev_count;
}
