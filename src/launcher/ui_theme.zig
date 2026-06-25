// ui_theme.zig — Modern dark UI theme for ZZCaster.
//
// This module owns the visual identity of the launcher:
//   - Color palette (dark theme with red accents)
//   - Style push/pop helpers (frame/child rounding, padding, spacing)
//   - Gradient background drawn via ImDrawList
//   - Card container helper (child window with consistent bg/border/rounding)
//   - Compact sidebar nav button + bottom-anchored quit button
//   - Header logo (ZZ + CASTER)
//   - Primary CTA button (red) + secondary flat button
//
// All functions here are pure visual helpers — they do NOT touch game,
// netplay, or session state. Logic lives in ui_pages.zig / ui.zig.

const std = @import("std");
const zgui = @import("zgui");

// ---------------------------------------------------------------------------
// Plain Zig color/vec types — safe to pass across modules
// ---------------------------------------------------------------------------

pub const Color = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

// ---------------------------------------------------------------------------
// Color palette
// ---------------------------------------------------------------------------

// Red brand accents
pub const COL_RED: Color = .{ .x = 0.75, .y = 0.22, .z = 0.17, .w = 1.0 };
pub const COL_RED_HOV: Color = .{ .x = 0.66, .y = 0.18, .z = 0.15, .w = 1.0 };
pub const COL_RED_ACT: Color = .{ .x = 0.55, .y = 0.14, .z = 0.12, .w = 1.0 };
pub const COL_RED_DIM: Color = .{ .x = 0.45, .y = 0.13, .z = 0.10, .w = 1.0 };

// Backgrounds (vertical gradient: top=dark, bottom=mid)
pub const COL_BG_DARK: Color = .{ .x = 0.10, .y = 0.10, .z = 0.11, .w = 1.0 };
pub const COL_BG_MID: Color = .{ .x = 0.16, .y = 0.16, .z = 0.18, .w = 1.0 };

// Card surface
pub const COL_CARD: Color = .{ .x = 0.10, .y = 0.10, .z = 0.11, .w = 0.92 };
pub const COL_CARD_BRD: Color = .{ .x = 0.27, .y = 0.27, .z = 0.30, .w = 1.0 };

// Sidebar surface (slightly darker than card)
pub const COL_SIDEBAR: Color = .{ .x = 0.07, .y = 0.07, .z = 0.08, .w = 0.95 };

// Frame (input fields, combos)
pub const COL_FRAME: Color = .{ .x = 0.18, .y = 0.18, .z = 0.20, .w = 1.0 };
pub const COL_FRAME_HOV: Color = .{ .x = 0.22, .y = 0.22, .z = 0.25, .w = 1.0 };
pub const COL_FRAME_ACT: Color = .{ .x = 0.26, .y = 0.26, .z = 0.30, .w = 1.0 };

// Header surface (very dark)
pub const COL_HEADER_BAR: Color = .{ .x = 0.05, .y = 0.05, .z = 0.06, .w = 0.95 };

// Text
pub const COL_TEXT: Color = .{ .x = 0.92, .y = 0.92, .z = 0.94, .w = 1.0 };
pub const COL_MUTED: Color = .{ .x = 0.50, .y = 0.50, .z = 0.55, .w = 1.0 };
pub const COL_TEXT_DIM: Color = .{ .x = 0.35, .y = 0.35, .z = 0.38, .w = 1.0 };

// Navigation button (sidebar)
pub const COL_NAV: Color = .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.0 };
pub const COL_NAV_HOV: Color = .{ .x = 0.20, .y = 0.20, .z = 0.22, .w = 0.6 };
pub const COL_NAV_ACTIVE: Color = .{ .x = 0.30, .y = 0.10, .z = 0.08, .w = 0.5 };

// Transparent color (used to clear window bg so gradient shows through)
pub const COL_TRANSPARENT: Color = .{ .x = 0, .y = 0, .z = 0, .w = 0 };

// Layout constants (in pixels)
pub const SIDEBAR_W: f32 = 56.0;
pub const HEADER_H: f32 = 64.0;
pub const CONTENT_PAD: f32 = 8.0;
pub const CARD_ROUND: f32 = 6.0;
pub const CARD_PAD: f32 = 8.0;

// ---------------------------------------------------------------------------
// Style/color stack wrappers
// ---------------------------------------------------------------------------

pub fn pushStyleColor(idx: zgui.StyleCol, col: Color) void {
    zgui.pushStyleColor4f(.{ .idx = idx, .c = .{ col.x, col.y, col.z, col.w } });
}

pub fn popStyleColor(count: c_int) void {
    zgui.popStyleColor(.{ .count = @intCast(count) });
}

pub fn pushStyleVarFloat(idx: zgui.StyleVar, val: f32) void {
    zgui.pushStyleVar1f(.{ .idx = idx, .v = val });
}

pub fn pushStyleVarVec2(idx: zgui.StyleVar, x: f32, y: f32) void {
    zgui.pushStyleVar2f(.{ .idx = idx, .v = .{ x, y } });
}

pub fn popStyleVar(count: c_int) void {
    zgui.popStyleVar(.{ .count = @intCast(count) });
}

// ---------------------------------------------------------------------------
// applyModernTheme — call once after zgui.styleColorsDark()
// ---------------------------------------------------------------------------

pub fn applyModernTheme() void {
    // Style vars (geometry)
    pushStyleVarVec2(.window_padding, 0, 0);
    pushStyleVarFloat(.window_rounding, 0.0);
    pushStyleVarFloat(.window_border_size, 0.0);
    pushStyleVarFloat(.child_rounding, CARD_ROUND);
    pushStyleVarFloat(.child_border_size, 1.0);
    pushStyleVarVec2(.frame_padding, 8, 5);
    pushStyleVarFloat(.frame_rounding, 6.0);
    pushStyleVarFloat(.frame_border_size, 0.0);
    pushStyleVarVec2(.item_spacing, 8, 8);
    pushStyleVarVec2(.item_inner_spacing, 6, 4);
    pushStyleVarFloat(.indent_spacing, 16.0);
    pushStyleVarFloat(.scrollbar_rounding, 8.0);
    pushStyleVarFloat(.grab_rounding, 4.0);
    pushStyleVarFloat(.tab_rounding, 4.0);

    // Style colors (palette)
    pushStyleColor(.window_bg, COL_TRANSPARENT);
    pushStyleColor(.child_bg, COL_CARD);
    pushStyleColor(.border, COL_CARD_BRD);
    pushStyleColor(.text, COL_TEXT);
    pushStyleColor(.text_disabled, COL_MUTED);
    pushStyleColor(.text_link, COL_RED);
    pushStyleColor(.frame_bg, COL_FRAME);
    pushStyleColor(.frame_bg_hovered, COL_FRAME_HOV);
    pushStyleColor(.frame_bg_active, COL_FRAME_ACT);
    pushStyleColor(.button, COL_RED);
    pushStyleColor(.button_hovered, COL_RED_HOV);
    pushStyleColor(.button_active, COL_RED_ACT);
    pushStyleColor(.header, COL_NAV_ACTIVE);
    pushStyleColor(.header_hovered, COL_NAV_HOV);
    pushStyleColor(.header_active, COL_NAV_ACTIVE);
    pushStyleColor(.check_mark, COL_RED);
    pushStyleColor(.separator, COL_CARD_BRD);
    pushStyleColor(.separator_hovered, COL_RED_DIM);
    pushStyleColor(.separator_active, COL_RED);
    pushStyleColor(.scrollbar_bg, COL_TRANSPARENT);
    pushStyleColor(.scrollbar_grab, COL_FRAME);
    pushStyleColor(.scrollbar_grab_hovered, COL_FRAME_HOV);
    pushStyleColor(.scrollbar_grab_active, COL_FRAME_ACT);
    pushStyleColor(.slider_grab, COL_RED);
    pushStyleColor(.slider_grab_active, COL_RED_HOV);
    pushStyleColor(.input_text_cursor, COL_RED);
    pushStyleColor(.tab, COL_FRAME);
    pushStyleColor(.tab_hovered, COL_RED_DIM);
    pushStyleColor(.tab_selected, COL_RED);
    pushStyleColor(.tab_selected_overline, COL_RED_HOV);
}

pub fn popModernTheme() void {
    popStyleColor(30);
    popStyleVar(14);
}

// ---------------------------------------------------------------------------
// drawGradientBackground — full-window vertical gradient via ImDrawList
// ---------------------------------------------------------------------------

pub fn drawGradientBackground() void {
    const dl = zgui.getWindowDrawList();
    const pos = zgui.getWindowPos();
    const w = zgui.getWindowWidth();
    const h = zgui.getWindowHeight();
    const top = colorU32(COL_BG_DARK);
    const bot = colorU32(COL_BG_MID);
    dl.addRectFilledMultiColor(.{
        .pmin = .{ pos[0], pos[1] },
        .pmax = .{ pos[0] + w, pos[1] + h },
        .col_upr_left = top,
        .col_upr_right = top,
        .col_bot_right = bot,
        .col_bot_left = bot,
    });
}

// ---------------------------------------------------------------------------
// Card container
// ---------------------------------------------------------------------------

pub fn beginCard(id: [*:0]const u8, w: f32, h: f32, auto_resize_y: bool) bool {
    return beginCardWithFlags(id, w, h, auto_resize_y, .{});
}

pub fn beginCardWithFlags(id: [*:0]const u8, w: f32, h: f32, auto_resize_y: bool, flags: zgui.WindowFlags) bool {
    pushStyleColor(.child_bg, COL_CARD);
    pushStyleColor(.border, COL_CARD_BRD);
    pushStyleVarVec2(.window_padding, CARD_PAD, CARD_PAD);
    defer popStyleVar(1);
    defer popStyleColor(2);
    return zgui.beginChild(std.mem.span(id), .{
        .w = w,
        .h = h,
        .child_flags = .{
            .border = true,
            .always_use_window_padding = true,
            .auto_resize_y = auto_resize_y,
        },
        .window_flags = flags,
    });
}

pub fn endCard() void {
    zgui.endChild();
}

// ---------------------------------------------------------------------------
// Card title — small uppercase muted label inside a card
// ---------------------------------------------------------------------------

pub fn cardTitle(text: [*:0]const u8) void {
    pushStyleColor(.text, COL_MUTED);
    zgui.text("{s}", .{std.mem.span(text)});
    popStyleColor(1);
    zgui.spacing();
}

// ---------------------------------------------------------------------------
// Sidebar nav button — single letter, square, transparent until hover/active
// ---------------------------------------------------------------------------

pub fn navButton(letter: [*:0]const u8, active: bool) bool {
    if (active) {
        pushStyleColor(.button, COL_NAV_ACTIVE);
        pushStyleColor(.button_hovered, COL_NAV_ACTIVE);
        pushStyleColor(.button_active, COL_RED_DIM);
        pushStyleColor(.text, COL_RED);
    } else {
        pushStyleColor(.button, COL_NAV);
        pushStyleColor(.button_hovered, COL_NAV_HOV);
        pushStyleColor(.button_active, COL_NAV_HOV);
        pushStyleColor(.text, COL_TEXT);
    }
    const sz_w: f32 = SIDEBAR_W - 14;
    const sz_h: f32 = SIDEBAR_W - 14;
    const clicked = zgui.button(std.mem.span(letter), .{ .w = sz_w, .h = sz_h });
    popStyleColor(4);
    return clicked;
}

// ---------------------------------------------------------------------------
// Primary CTA button — red, wider, framed
// ---------------------------------------------------------------------------

pub fn primaryButton(label: [*:0]const u8, w: f32, h: f32) bool {
    return zgui.button(std.mem.span(label), .{ .w = w, .h = h });
}

// ---------------------------------------------------------------------------
// Secondary button — flat dark, neutral
// ---------------------------------------------------------------------------

pub fn secondaryButton(label: [*:0]const u8, w: f32, h: f32) bool {
    pushStyleColor(.button, COL_FRAME);
    pushStyleColor(.button_hovered, COL_FRAME_HOV);
    pushStyleColor(.button_active, COL_FRAME_ACT);
    pushStyleColor(.text, COL_TEXT);
    defer popStyleColor(4);
    return zgui.button(std.mem.span(label), .{ .w = w, .h = h });
}

// ---------------------------------------------------------------------------
// Header logo — "ZZ" white + "CASTER" red, on the header bar
// ---------------------------------------------------------------------------

pub fn drawLogo(at_x: f32, at_y: f32) void {
    const dl = zgui.getWindowDrawList();
    const zz_col = colorU32(COL_TEXT);
    const caster_col = colorU32(COL_RED);
    const zz_str = "ZZ";
    const caster_str = "CASTER";
    const zz_size = zgui.calcTextSize(zz_str, .{});
    dl.addTextUnformatted(.{ at_x, at_y }, zz_col, zz_str);
    dl.addTextUnformatted(.{ at_x + zz_size[0] + 8, at_y }, caster_col, caster_str);
}

// ---------------------------------------------------------------------------
// Text helpers — colored text via the theme palette
// ---------------------------------------------------------------------------

pub fn textColored(col: Color, comptime fmt: []const u8, args: anytype) void {
    zgui.textColored(.{ col.x, col.y, col.z, col.w }, fmt, args);
}

pub fn textWrapped(col: Color, comptime fmt: []const u8, args: anytype) void {
    pushStyleColor(.text, col);
    defer popStyleColor(1);
    zgui.textWrapped(fmt, args);
}

// ---------------------------------------------------------------------------
// Small inline helpers for layout
// ---------------------------------------------------------------------------

pub fn hspace(w: f32) void {
    zgui.dummy(.{ .w = w, .h = 0 });
}

pub fn vspace(h: f32) void {
    zgui.dummy(.{ .w = 0, .h = h });
}

// ---------------------------------------------------------------------------
// Internal color conversion
// ---------------------------------------------------------------------------

fn colorU32(col: Color) u32 {
    return zgui.colorConvertFloat4ToU32(.{ col.x, col.y, col.z, col.w });
}
