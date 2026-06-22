// ui_controller_mapper.zig — Controller mapper UI panels + binding helpers,
// extracted from ui.zig.
//
// Contains the ImGui widgets that render the "Controllers" tab:
//   - applyBinding    : write a polled InputBinding into a ControllerMapping slot
//   - bindButton      : one bind button (shows current binding or "Press...")
//   - drawPlayerPanel : classic grid layout (directions + buttons)
//   - drawListPanel   : alt list layout (rows of [name | bind])
//   - buildDeviceList : builds the device-name combo box array
//
// These are pure rendering helpers — they don't touch any UI state outside
// the pointers passed in. ui.zig / ui_pages.zig calls them.

const std = @import("std");
const logging = @import("common").logging;
const mapper = @import("dll").controller_mapper;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_opengl.h");
    @cInclude("cimgui_shim.h");
});

/// Write a polled InputBinding into the slot identified by `target` on the
/// given ControllerMapping. .none is a no-op (used as a sentinel for "no
/// binding in progress").
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

/// Render one bind button. If this target is the one currently being bound
/// (bind_target.* == target), show "Press..." and ignore clicks. Otherwise
/// show the current binding label and, when clicked, set bind_target.* = target
/// and arm a short cooldown so the same click doesn't immediately re-trigger.
pub fn bindButton(label: []const u8, target: mapper.BindingTarget, binding: mapper.InputBinding, bind_target: *mapper.BindingTarget, cooldown: *u32) void {
    var buf: [64]u8 = undefined;
    const bind_label = binding.label(&buf);

    if (bind_target.* == target) {
        // This button is currently being bound — show "Press input..."
        var btn_buf: [80]u8 = undefined;
        const btn_text = std.fmt.bufPrintZ(&btn_buf, "{s}: Press...", .{label}) catch label;
        _ = c.igButton(btn_text.ptr, .{ .x = 90, .y = 0 });
    } else {
        var btn_buf: [80]u8 = undefined;
        const btn_text = std.fmt.bufPrintZ(&btn_buf, "{s}: {s}", .{ label, bind_label }) catch label;
        if (c.igButton(btn_text.ptr, .{ .x = 90, .y = 0 })) {
            bind_target.* = target;
            cooldown.* = 15; // ~250ms at 60fps to avoid immediate re-bind
        }
    }
}

/// Classic grid layout for one player's controller mapping panel. Renders
/// device combo, FN/Start row, direction pad (2x2 grid), button grid (A/B/C
/// + D/E/A+B), SOCD radio, deadzone slider, Default + Clear buttons.
///
/// All state is mutated through the passed pointers — the panel is purely
/// a view over the caller's data.
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
    cooldown: *u32,
) void {
    _ = num_joy;

    // Build unique ID suffixes from player name to avoid ImGui ID conflicts
    var id_suffix_buf: [32]u8 = undefined;
    const id_suffix = std.fmt.bufPrintZ(&id_suffix_buf, "##{s}", .{name}) catch "##p";

    // Player label + device combo
    var name_buf: [32]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch name;
    c.igText("%s", @as([*:0]const u8, @ptrCast(name_z.ptr)));
    c.igSameLine(0, 16);

    var combo_label_buf: [48]u8 = undefined;
    const combo_label = std.fmt.bufPrintZ(&combo_label_buf, "##device_{s}", .{name}) catch "##device";
    _ = c.igCombo_Str_arr(combo_label.ptr, @ptrCast(device_sel), @ptrCast(dev_names), dev_count, 8);

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
    }

    c.igSpacing();

    // Push a unique ID stack for this player's widgets
    c.igPushID_Str(id_suffix.ptr);

    // Top row: FN1, Start, FN2
    c.igIndent(200);
    bindButton("FN1", .fn1, m.fn1, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("Start", .start, m.start, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("FN2", .fn2, m.fn2, bind_target, cooldown);
    c.igUnindent(200);

    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    // Two columns: Directions (left) + Buttons (right)
    // Reduced height by ~30px (one button row) to tighten the layout.
    _ = c.igBeginChild_Str("dir", .{ .x = 220, .y = 110 }, true, 0);

    c.igText("Directions");
    c.igSpacing();

    // Up (centered)
    c.igIndent(60);
    bindButton("Up", .up, m.up, bind_target, cooldown);
    c.igUnindent(60);

    // Left + Right
    bindButton("Left", .left, m.left, bind_target, cooldown);
    c.igSameLine(0, 8);
    c.igDummy(.{ .x = 30, .y = 0 });
    c.igSameLine(0, 8);
    bindButton("Right", .right, m.right, bind_target, cooldown);

    // Down (centered)
    c.igIndent(60);
    bindButton("Down", .down, m.down, bind_target, cooldown);
    c.igUnindent(60);

    c.igEndChild();

    c.igSameLine(0, 8);

    _ = c.igBeginChild_Str("btn", .{ .x = 310, .y = 110 }, true, 0);

    c.igText("Buttons");
    c.igSpacing();

    // Row 1: A, B, C
    bindButton("A", .a, m.a, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("B", .b, m.b, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("C", .c, m.c, bind_target, cooldown);

    c.igSpacing();

    // Row 2: D, E, AB
    bindButton("D", .d, m.d, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("E", .e, m.e, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("A+B", .ab, m.ab, bind_target, cooldown);

    c.igEndChild();

    c.igSpacing();

    // SOCD mode radio buttons — "Default" removed since the default is
    // already L+R neg (mode 1). Modes: 1=L+R neg, 2=U+D neg, 3=Both neg.
    c.igText("SOCD:");
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("L+R neg", m.socd_mode == 1)) m.socd_mode = 1;
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("U+D neg", m.socd_mode == 2)) m.socd_mode = 2;
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("Both neg", m.socd_mode == 3)) m.socd_mode = 3;
    // If the user had socd_mode == 0 (old "Default"), normalize to 1.
    if (m.socd_mode == 0) m.socd_mode = 1;

    c.igSpacing();

    // Air Dash Macro toggle. Per-player input option (see
    // docs/air-dash-macro-design.md). When enabled, pressing 9AB/7AB is
    // expanded into a 2-frame jump→air-dash sequence before the input reaches
    // the game / network. Off by default.
    _ = c.igCheckbox("Air Dash Macro (9AB/7AB)", &m.air_dash_macro);

    c.igSpacing();

    // Analog Deadzone as a 0.0-1.0 float slider.
    // Internally stored as u32 (0-32767, matching SDL axis range), but
    // displayed as a normalized float for user-friendliness.
    // Use PushItemWidth to make the slider a small field (120px) instead
    // of stretching to fill the available width.
    var dz_float: f32 = @as(f32, @floatFromInt(m.deadzone)) / 32767.0;
    c.igPushItemWidth(120.0);
    _ = c.igSliderFloat("Analog Deadzone", &dz_float, 0.0, 1.0, "%.2f", 0);
    c.igPopItemWidth();
    m.deadzone = @intFromFloat(dz_float * 32767.0);

    c.igSameLine(0, 16);

    if (c.igButton("Default Bindings", .{ .x = 130, .y = 0 })) {
        m.* = mapper.defaultXboxMapping();
        m.device_index = device_sel.* - 1;
    }
    c.igSameLine(0, 8);

    if (c.igButton("Clear", .{ .x = 60, .y = 0 })) {
        // Clear all bindings to .none (type=none, index=0). The struct
        // defaults pre-fill buttons with sdl_button indices, so m.* = .{}
        // does NOT actually clear — it resets to those defaults. We need
        // to explicitly set each binding to an empty InputBinding.
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
        // Keep device_index, stick axes, deadzone, socd_mode as-is.
    }

    c.igPopID();
}

/// List view panel — alternative to drawPlayerPanel. Renders the player's
/// bindings as a vertical list of rows, each row showing the in-game button
/// name on the left and the bind button on the right. Below the list: device
/// combo, SOCD, deadzone, default bindings, clear.
///
/// This is the "list view" toggled by the checkbox at the top of the
/// Controllers tab. Two of these panels sit side-by-side (P1 left, P2 right)
/// in equal-width child windows.
pub fn drawListPanel(
    name: []const u8,
    m: *mapper.ControllerMapping,
    bind_target: *mapper.BindingTarget,
    joy: *?*anyopaque,
    device_sel: *c_int,
    dev_names: *const [16][*:0]const u8,
    dev_count: c_int,
    log: *logging.Logger,
    cooldown: *u32,
) void {
    // Build unique ID suffix for ImGui ID stack
    var id_suffix_buf: [32]u8 = undefined;
    const id_suffix = std.fmt.bufPrintZ(&id_suffix_buf, "##list_{s}", .{name}) catch "##list_p";
    c.igPushID_Str(id_suffix.ptr);

    // Player name header
    var name_buf: [32]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch name;
    c.igText("%s", @as([*:0]const u8, @ptrCast(name_z.ptr)));
    c.igSpacing();

    // Device combo
    var combo_label_buf: [48]u8 = undefined;
    const combo_label = std.fmt.bufPrintZ(&combo_label_buf, "##device_{s}", .{name}) catch "##device";
    _ = c.igCombo_Str_arr(combo_label.ptr, @ptrCast(device_sel), @ptrCast(dev_names), dev_count, 8);

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
    }

    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    // Each row: [in-game button name (fixed width)] [bind button]
    // Use a table-like layout with align_text_to_frame_padding for clean
    // vertical alignment. The name column is 90px wide; the bind button
    // fills the rest.
    const rows = [_]struct { label: []const u8, target: mapper.BindingTarget, binding: mapper.InputBinding }{
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
        c.igAlignTextToFramePadding();
        var label_buf: [32]u8 = undefined;
        const label_z = std.fmt.bufPrintZ(&label_buf, "{s}", .{row.label}) catch row.label;
        c.igText("%s", @as([*:0]const u8, @ptrCast(label_z.ptr)));
        c.igSameLine(90, 8); // 90px name column + 8px spacing
        // Bind button (right column)
        bindButton(row.label, row.target, row.binding, bind_target, cooldown);
    }

    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    // SOCD mode radio buttons
    c.igText("SOCD:");
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("L+R neg", m.socd_mode == 1)) m.socd_mode = 1;
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("U+D neg", m.socd_mode == 2)) m.socd_mode = 2;
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("Both neg", m.socd_mode == 3)) m.socd_mode = 3;
    if (m.socd_mode == 0) m.socd_mode = 1;

    c.igSpacing();

    // Air Dash Macro toggle (per-player; see drawPlayerPanel for details).
    _ = c.igCheckbox("Air Dash Macro (9AB/7AB)", &m.air_dash_macro);

    c.igSpacing();

    // Analog Deadzone (0.0-1.0 float, small field)
    var dz_float: f32 = @as(f32, @floatFromInt(m.deadzone)) / 32767.0;
    c.igPushItemWidth(120.0);
    _ = c.igSliderFloat("Analog Deadzone", &dz_float, 0.0, 1.0, "%.2f", 0);
    c.igPopItemWidth();
    m.deadzone = @intFromFloat(dz_float * 32767.0);

    c.igSpacing();

    // Default Bindings + Clear buttons
    if (c.igButton("Default Bindings", .{ .x = 130, .y = 0 })) {
        m.* = mapper.defaultXboxMapping();
        m.device_index = device_sel.* - 1;
    }
    c.igSameLine(0, 8);
    if (c.igButton("Clear", .{ .x = 60, .y = 0 })) {
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
    }

    c.igPopID();
}

/// Build the device-name combo box array used by the Controllers tab.
/// Slot 0 is always "Keyboard"; slots 1..N are SDL joystick names (or
/// "Unknown Joystick" if SDL_JoystickNameForIndex returns null). The
/// returned `dev_names` array contains `dev_count` entries.
///
/// The `dev_names_buf` storage must outlive the ImGui calls that read
/// `dev_names` — both buffers are passed in by the caller and live on
/// the caller's stack.
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
                const n = @min(span.len, 63);
                @memcpy(dev_names_buf[@intCast(dev_count)][0..n], span[0..n]);
                dev_names_buf[@intCast(dev_count)][n] = 0;
                dev_names[@intCast(dev_count)] = @ptrCast(&dev_names_buf[@intCast(dev_count)]);
            } else {
                const fallback = "Unknown Joystick";
                @memcpy(dev_names_buf[@intCast(dev_count)][0..fallback.len], fallback);
                dev_names_buf[@intCast(dev_count)][fallback.len] = 0;
                dev_names[@intCast(dev_count)] = @ptrCast(&dev_names_buf[@intCast(dev_count)]);
            }
            dev_count += 1;
        }
    }
    return dev_count;
}
