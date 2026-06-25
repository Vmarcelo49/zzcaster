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
//
// Type strategy: this module declares a plain Zig `Color` struct (no cimport
// dependency) so that color constants can be passed across module boundaries
// (ui.zig, ui_pages.zig, ui_waiting_for_peer.zig all have their own
// @cImport of cimgui_shim.h, which generates distinct ImVec4_c types per
// file). The internal `c` module is only used inside ui_theme.zig itself.

const std = @import("std");
const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_opengl.h");
    @cInclude("cimgui_shim.h");
});

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
pub const CONTENT_PAD: f32 = 16.0;
pub const CARD_ROUND: f32 = 8.0;
pub const CARD_PAD: f32 = 16.0;

// ---------------------------------------------------------------------------
// Style/color stack wrappers — these call into c directly, using anonymous
// struct literals to coerce to ImVec4_c / ImVec2_c at the call site.
// ---------------------------------------------------------------------------

pub fn pushStyleColor(idx: c_int, col: Color) void {
    c.igPushStyleColor_Vec4(idx, .{ .x = col.x, .y = col.y, .z = col.z, .w = col.w });
}

pub fn popStyleColor(count: c_int) void {
    c.igPopStyleColor(count);
}

pub fn pushStyleVarFloat(idx: c_int, val: f32) void {
    c.igPushStyleVar_Float(idx, val);
}

pub fn pushStyleVarVec2(idx: c_int, x: f32, y: f32) void {
    c.igPushStyleVar_Vec2(idx, .{ .x = x, .y = y });
}

pub fn popStyleVar(count: c_int) void {
    c.igPopStyleVar(count);
}

// ---------------------------------------------------------------------------
// applyModernTheme — call once after igStyleColorsDark()
// ---------------------------------------------------------------------------

/// Pushes the global style/colors. The matching pop is done by the caller
/// before igEnd() of the main window. We push style vars + style colors
/// here; they apply to everything inside the main window.
///
/// Counts pushed:
///   - style var: 14 (pop with popStyleVar(14))
///   - style color: 30 (pop with popStyleColor(30))
pub fn applyModernTheme() void {
    // Style vars (geometry)
    pushStyleVarVec2(c.ImGuiStyleVar_WindowPadding, 0, 0);
    pushStyleVarFloat(c.ImGuiStyleVar_WindowRounding, 0.0);
    pushStyleVarFloat(c.ImGuiStyleVar_WindowBorderSize, 0.0);
    pushStyleVarFloat(c.ImGuiStyleVar_ChildRounding, CARD_ROUND);
    pushStyleVarFloat(c.ImGuiStyleVar_ChildBorderSize, 1.0);
    pushStyleVarVec2(c.ImGuiStyleVar_FramePadding, 10, 6);
    pushStyleVarFloat(c.ImGuiStyleVar_FrameRounding, 6.0);
    pushStyleVarFloat(c.ImGuiStyleVar_FrameBorderSize, 0.0);
    pushStyleVarVec2(c.ImGuiStyleVar_ItemSpacing, 10, 10);
    pushStyleVarVec2(c.ImGuiStyleVar_ItemInnerSpacing, 8, 6);
    pushStyleVarFloat(c.ImGuiStyleVar_IndentSpacing, 16.0);
    pushStyleVarFloat(c.ImGuiStyleVar_ScrollbarRounding, 8.0);
    pushStyleVarFloat(c.ImGuiStyleVar_GrabRounding, 4.0);
    pushStyleVarFloat(c.ImGuiStyleVar_TabRounding, 4.0);

    // Style colors (palette)
    pushStyleColor(c.ImGuiCol_WindowBg, COL_TRANSPARENT);
    pushStyleColor(c.ImGuiCol_ChildBg, COL_CARD);
    pushStyleColor(c.ImGuiCol_Border, COL_CARD_BRD);
    pushStyleColor(c.ImGuiCol_Text, COL_TEXT);
    pushStyleColor(c.ImGuiCol_TextDisabled, COL_MUTED);
    pushStyleColor(c.ImGuiCol_TextLink, COL_RED);
    pushStyleColor(c.ImGuiCol_FrameBg, COL_FRAME);
    pushStyleColor(c.ImGuiCol_FrameBgHovered, COL_FRAME_HOV);
    pushStyleColor(c.ImGuiCol_FrameBgActive, COL_FRAME_ACT);
    pushStyleColor(c.ImGuiCol_Button, COL_RED);
    pushStyleColor(c.ImGuiCol_ButtonHovered, COL_RED_HOV);
    pushStyleColor(c.ImGuiCol_ButtonActive, COL_RED_ACT);
    pushStyleColor(c.ImGuiCol_Header, COL_NAV_ACTIVE);
    pushStyleColor(c.ImGuiCol_HeaderHovered, COL_NAV_HOV);
    pushStyleColor(c.ImGuiCol_HeaderActive, COL_NAV_ACTIVE);
    pushStyleColor(c.ImGuiCol_CheckMark, COL_RED);
    pushStyleColor(c.ImGuiCol_Separator, COL_CARD_BRD);
    pushStyleColor(c.ImGuiCol_SeparatorHovered, COL_RED_DIM);
    pushStyleColor(c.ImGuiCol_SeparatorActive, COL_RED);
    pushStyleColor(c.ImGuiCol_ScrollbarBg, COL_TRANSPARENT);
    pushStyleColor(c.ImGuiCol_ScrollbarGrab, COL_FRAME);
    pushStyleColor(c.ImGuiCol_ScrollbarGrabHovered, COL_FRAME_HOV);
    pushStyleColor(c.ImGuiCol_ScrollbarGrabActive, COL_FRAME_ACT);
    pushStyleColor(c.ImGuiCol_SliderGrab, COL_RED);
    pushStyleColor(c.ImGuiCol_SliderGrabActive, COL_RED_HOV);
    pushStyleColor(c.ImGuiCol_InputTextCursor, COL_RED);
    pushStyleColor(c.ImGuiCol_Tab, COL_FRAME);
    pushStyleColor(c.ImGuiCol_TabHovered, COL_RED_DIM);
    pushStyleColor(c.ImGuiCol_TabSelected, COL_RED);
    pushStyleColor(c.ImGuiCol_TabSelectedOverline, COL_RED_HOV);
}

/// Pop the styles pushed by applyModernTheme(). Must be called after igEnd()
/// of the main window to keep the style stack balanced.
pub fn popModernTheme() void {
    popStyleColor(30);
    popStyleVar(14);
}

// ---------------------------------------------------------------------------
// drawGradientBackground — full-window vertical gradient via ImDrawList
// ---------------------------------------------------------------------------

/// Draws a vertical gradient (COL_BG_DARK → COL_BG_MID) covering the entire
/// main window. Must be called right after igBegin() of the main window,
/// before any other widgets, so the gradient sits at the bottom of the
/// draw stack inside that window.
pub fn drawGradientBackground() void {
    const dl = c.igGetWindowDrawList() orelse return;
    const pos = c.igGetWindowPos();
    const w = c.igGetWindowWidth();
    const h = c.igGetWindowHeight();
    const top = colorU32(COL_BG_DARK);
    const bot = colorU32(COL_BG_MID);
    // Vertical gradient: same color across left/right at each Y level.
    c.ImDrawList_AddRectFilledMultiColor(
        dl,
        .{ .x = pos.x, .y = pos.y },
        .{ .x = pos.x + w, .y = pos.y + h },
        top,
        top,
        bot,
        bot,
    );
}

// ---------------------------------------------------------------------------
// Card container
// ---------------------------------------------------------------------------

/// Begin a card (child window) at the current cursor position with the
/// given width/height. Use 0 for width to fill available space. Pass
/// `auto_resize_y = true` to size the card to its contents.
///
/// Internally pushes ChildBg = COL_CARD, Border = COL_CARD_BRD, WindowPadding
/// = CARD_PAD. Caller must call endCard() afterwards.
pub fn beginCard(id: [*:0]const u8, w: f32, h: f32, auto_resize_y: bool) bool {
    pushStyleColor(c.ImGuiCol_ChildBg, COL_CARD);
    pushStyleColor(c.ImGuiCol_Border, COL_CARD_BRD);
    pushStyleVarVec2(c.ImGuiStyleVar_WindowPadding, CARD_PAD, CARD_PAD);
    var flags: c.ImGuiChildFlags = c.ImGuiChildFlags_Borders | c.ImGuiChildFlags_AlwaysUseWindowPadding;
    if (auto_resize_y) flags |= c.ImGuiChildFlags_AutoResizeY;
    defer popStyleVar(1);
    defer popStyleColor(2);
    return c.igBeginChild_Str(id, .{ .x = w, .y = h }, flags, 0);
}

pub fn endCard() void {
    c.igEndChild();
}

// ---------------------------------------------------------------------------
// Card title — small uppercase muted label inside a card
// ---------------------------------------------------------------------------

pub fn cardTitle(text: [*:0]const u8) void {
    pushStyleColor(c.ImGuiCol_Text, COL_MUTED);
    c.igText("%s", text);
    popStyleColor(1);
    c.igSpacing();
}

// ---------------------------------------------------------------------------
// Sidebar nav button — single letter, square, transparent until hover/active
// ---------------------------------------------------------------------------

/// Returns true if the button was clicked.
/// `active` controls the highlight state (active page).
/// `letter` is the single-character label (e.g. "N").
pub fn navButton(letter: [*:0]const u8, active: bool) bool {
    // Push button background: transparent normally, red-tinted when active,
    // dark when hovered. ImGui Button uses ButtonHovered/ButtonActive from
    // the global palette for those states, so we only override Button when
    // active to give it the red tint.
    if (active) {
        pushStyleColor(c.ImGuiCol_Button, COL_NAV_ACTIVE);
        pushStyleColor(c.ImGuiCol_ButtonHovered, COL_NAV_ACTIVE);
        pushStyleColor(c.ImGuiCol_ButtonActive, COL_RED_DIM);
        pushStyleColor(c.ImGuiCol_Text, COL_RED);
    } else {
        pushStyleColor(c.ImGuiCol_Button, COL_NAV);
        pushStyleColor(c.ImGuiCol_ButtonHovered, COL_NAV_HOV);
        pushStyleColor(c.ImGuiCol_ButtonActive, COL_NAV_HOV);
        pushStyleColor(c.ImGuiCol_Text, COL_TEXT);
    }
    const sz_w: f32 = SIDEBAR_W - 14;
    const sz_h: f32 = SIDEBAR_W - 14;
    const clicked = c.igButton(letter, .{ .x = sz_w, .y = sz_h });
    popStyleColor(4);
    return clicked;
}

// ---------------------------------------------------------------------------
// Primary CTA button — red, wider, framed
// ---------------------------------------------------------------------------

/// Returns true if clicked. Uses the global red button colors (already pushed
/// in applyModernTheme), but ensures consistent height/rounding.
pub fn primaryButton(label: [*:0]const u8, w: f32, h: f32) bool {
    return c.igButton(label, .{ .x = w, .y = h });
}

// ---------------------------------------------------------------------------
// Secondary button — flat dark, neutral
// ---------------------------------------------------------------------------

/// Returns true if clicked. Flat dark button (for Cancel / OK secondary actions).
pub fn secondaryButton(label: [*:0]const u8, w: f32, h: f32) bool {
    pushStyleColor(c.ImGuiCol_Button, COL_FRAME);
    pushStyleColor(c.ImGuiCol_ButtonHovered, COL_FRAME_HOV);
    pushStyleColor(c.ImGuiCol_ButtonActive, COL_FRAME_ACT);
    pushStyleColor(c.ImGuiCol_Text, COL_TEXT);
    defer popStyleColor(4);
    return c.igButton(label, .{ .x = w, .y = h });
}

// ---------------------------------------------------------------------------
// Header logo — "ZZ" white + "CASTER" red, on the header bar
// ---------------------------------------------------------------------------

/// Draws the ZZ CASTER logo at the given absolute screen coordinates.
/// The text is rendered in two pieces via ImDrawList_AddText so we can
/// color them independently.
pub fn drawLogo(at_x: f32, at_y: f32) void {
    const dl = c.igGetWindowDrawList() orelse return;
    // "ZZ" in white, then "CASTER" in red, baseline-aligned. We add a small
    // gap between them for visual breathing room.
    const zz_col = colorU32(COL_TEXT);
    const caster_col = colorU32(COL_RED);
    const zz_str: [*:0]const u8 = "ZZ";
    const caster_str: [*:0]const u8 = "CASTER";
    // Measure "ZZ" width so "CASTER" starts right after with a gap.
    const zz_size = c.igCalcTextSize(zz_str, null, false, 0.0);
    c.ImDrawList_AddText_Vec2(dl, .{ .x = at_x, .y = at_y }, zz_col, zz_str, null);
    c.ImDrawList_AddText_Vec2(dl, .{ .x = at_x + zz_size.x + 8, .y = at_y }, caster_col, caster_str, null);
}

// ---------------------------------------------------------------------------
// Text helpers — colored text via the theme palette
// ---------------------------------------------------------------------------

/// Render text in a given theme color. Builds a null-terminated buffer on
/// the stack because c.igTextColored is variadic and Zig can't pass args
/// directly to a C variadic; we format locally and call with "%s".
pub fn textColored(col: Color, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const formatted = std.fmt.bufPrintZ(&buf, fmt, args) catch {
        // Buffer too small — fall back to format string itself.
        c.igTextColored(.{ .x = col.x, .y = col.y, .z = col.z, .w = col.w }, "%s", fmt.ptr);
        return;
    };
    c.igTextColored(.{ .x = col.x, .y = col.y, .z = col.z, .w = col.w }, "%s", formatted.ptr);
}

/// Wrapped variant — text wraps at the right edge of the container.
pub fn textWrapped(col: Color, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const formatted = std.fmt.bufPrintZ(&buf, fmt, args) catch {
        c.igPushTextWrapPos(0.0);
        c.igTextColored(.{ .x = col.x, .y = col.y, .z = col.z, .w = col.w }, "%s", fmt.ptr);
        c.igPopTextWrapPos();
        return;
    };
    c.igPushTextWrapPos(0.0);
    c.igTextColored(.{ .x = col.x, .y = col.y, .z = col.z, .w = col.w }, "%s", formatted.ptr);
    c.igPopTextWrapPos();
}

// ---------------------------------------------------------------------------
// Small inline helpers for layout
// ---------------------------------------------------------------------------

/// Fills a horizontal gap with an invisible dummy of given width.
pub fn hspace(w: f32) void {
    c.igDummy(.{ .x = w, .y = 0 });
}

/// Vertical spacer (in pixels).
pub fn vspace(h: f32) void {
    c.igDummy(.{ .x = 0, .y = h });
}

// ---------------------------------------------------------------------------
// Internal color conversion
// ---------------------------------------------------------------------------

fn colorU32(col: Color) c.ImU32 {
    return c.igColorConvertFloat4ToU32(.{ .x = col.x, .y = col.y, .z = col.z, .w = col.w });
}
