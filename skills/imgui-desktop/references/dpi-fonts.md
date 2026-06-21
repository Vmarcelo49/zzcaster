# DPI-aware fonts and theming

High-DPI displays (4K monitors at 150% scaling, Retina MacBooks at 200%) make UI tiny if
you don't account for them. This file covers Dear ImGui 1.92's DPI story, font loading,
and theming.

## Table of contents

1. [The DPI problem](#the-dpi-problem)
2. [1.92's DPI model](#192s-dpi-model)
3. [Loading fonts](#loading-fonts)
4. [Icon fonts](#icon-fonts)
5. [Custom glyph ranges (CJK)](#custom-glyph-ranges-cjk)
6. [Building the font atlas](#building-the-font-atlas)
7. [Themes](#themes)
8. [Custom themes](#custom-themes)
9. [Live theme editing](#live-theme-editing)

## The DPI problem

Without DPI awareness:
- A 16px font on a 4K display at 100% scaling looks normal.
- The same 16px font at 150% scaling looks tiny (because the OS is reporting logical
  pixels but the font is rendered at physical pixels).
- At 200% scaling, it's unreadable.

The fix is to scale font size by the display's DPI scale factor. ImGui 1.92 makes this
easier than ever with `FontSizeBase` and `FontScaleDpi`.

## 1.92's DPI model

Three related settings:

### `style.FontSizeBase`

The base font size, in points. Default: 13.0. Set this once at startup:

```zig
const style = zgui.getStyle();
style.font_size_base = 18.0;
```

### `style.FontScaleDpi`

The DPI scale multiplier. Default: 1.0. Set this to the display's scale:

```zig
const scale: f32 = window.getDisplayContentScale();   // 1.0, 1.5, 2.0, etc.
style.font_scale_dpi = scale;
```

### `ConfigFlags.DpiEnableScaleFonts`

Tells ImGui to automatically rebuild the font atlas at the right size when the DPI
changes (e.g. dragging a window between monitors at different DPIs):

```zig
zgui.io.setConfigFlags(.{
    .dpi_enable_scale_fonts = true,
});
```

Without this flag, you have to manually rebuild the atlas on DPI change.

### Putting it together

```zig
pub fn setupFontsAndDpi(window: *zsdl.video.Window) !void {
    const scale: f32 = window.getDisplayContentScale();

    const style = zgui.getStyle();
    style.font_size_base = 18.0;
    style.font_scale_dpi = scale;

    zgui.io.setConfigFlags(.{ .dpi_enable_scale_fonts = true });

    // Load a TTF — ImGui will bake it at the right size
    _ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", 18.0);
}
```

### Multi-monitor

When the user drags the window from a 100% monitor to a 150% monitor, SDL3 fires a
`window_display_changed` event. With `DpiEnableScaleFonts`, ImGui detects the change
and rebuilds the atlas automatically. You don't need to do anything.

If `DpiEnableScaleFonts` is off (or you're on a version that doesn't support it), you
have to handle it manually:

```zig
fn onDisplayChanged(window: *zsdl.video.Window) !void {
    const new_scale = window.getDisplayContentScale();
    if (new_scale != current_scale) {
        current_scale = new_scale;
        zgui.getStyle().font_scale_dpi = new_scale;
        zgui.io.fonts.build();   // rebuild atlas
        // Re-upload to GPU (the backend's NewFrame handles this automatically
        // when it detects the atlas has changed)
    }
}
```

## Loading fonts

### From a file

```zig
_ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", 18.0);
```

Returns a `*ImFont`. Use `pushFont` to switch to it temporarily:

```zig
const big_font = zgui.io.addFontFromFile("assets/Roboto-Bold.ttf", 32.0);
// ...
zgui.pushFont(big_font, 32.0);
defer zgui.popFont();
zgui.text("Big text!");
```

### From memory (embedded)

For single-binary distribution, embed the TTF with `@embedFile`:

```zig
const roboto_ttf = @embedFile("../assets/Roboto-Medium.ttf");

const config = zgui.io.FontConfig{
    .font_data = @constCast(roboto_ttf.ptr),
    .font_data_size = roboto_ttf.len,
    .size_pixels = 18.0,
};
_ = zgui.io.addFontFromMemory(&config);
```

Note: `addFontFromMemory` takes ownership of the buffer if `font_data_owned_by_atlas =
true`. For embedded fonts (which are static), set `font_data_owned_by_atlas = false`.

### With config

```zig
const config = zgui.io.FontConfig{
    .size_pixels = 18.0,
    .oversample_h = 2,
    .oversample_v = 1,
    .pixel_snap_h = false,
    .glyph_max_advance_x = -1.0,
    .glyph_ranges = null,   // use defaults
    .font_no = 0,
    .merge_mode = false,
};

_ = zgui.io.addFontFromFileWithConfig("assets/Roboto-Medium.ttf", 18.0, &config);
```

`oversample_h = 2` (default) gives smoother text at small sizes. `pixel_snap_h = true`
gives crisper text at integer sizes (good for pixel art editors).

### ProggyClean (the default)

If you don't load any font, ImGui uses `ProggyClean.ttf` (a built-in monospace bitmap
font). It's tiny and crisp at 13px, but looks dated. Use it only for quick prototypes.

## Icon fonts

For UI icons (save, open, settings, etc.), use FontAwesome or Material Icons. Merge them
into the default font:

```zig
// 1. Load the main font
_ = zgui.io.addFontFromFile("assets/Roboto-Medium.ttf", 18.0);

// 2. Merge FontAwesome into the just-loaded font
const fa_config = zgui.io.FontConfig{
    .merge_mode = true,   // <-- key
    .size_pixels = 18.0,
    .glyph_min_advance_x = 18.0,   // monospace the icons
    .glyph_ranges = &fa_ranges,    // see below
};

const fa_ranges = [_]u16{
    0xe005, 0xf8ff,    // FontAwesome solid range
    0,
};

_ = zgui.io.addFontFromFileWithConfig(
    "assets/fa-solid-900.ttf",
    18.0,
    &fa_config,
    &fa_ranges,
);
```

### Using icons in labels

FontAwesome icons are addressed by Unicode codepoint. Use them inline:

```zig
const FA_SAVE: []const u8 = "\xef\x80\x93";     // U+F013
const FA_OPEN: []const u8 = "\xef\x81\xbc";     // U+F07C
const FA_GEAR: []const u8 = "\xef\x82\x93";     // U+F013

if (zgui.button(FA_SAVE ++ " Save", .{})) saveFile();
if (zgui.button(FA_OPEN ++ " Open", .{})) openFile();
```

The `++` is Zig string concatenation at compile time. The result is a C string with the
icon character followed by the label text.

### Material Icons

Material Icons works the same way, just with different codepoints (e.g. U+E000-U+E900).
Material's ranges are larger; check the official font's CSS for the exact ranges you
need.

### Custom icon font

If you have your own icon set (e.g. game-specific icons), use
[fontcustom](https://github.com/FontCustom/fontcustom) or [Icomoon](https://icomoon.io/)
to build a TTF from SVGs. Then merge it like FontAwesome above.

## Custom glyph ranges (CJK)

For Chinese, Japanese, Korean text, the default glyph range doesn't include CJK
characters. You need to specify a CJK range:

```zig
// Simplified Chinese (most common 2500 characters)
const cjk_ranges = zgui.io.fonts.getGlyphRangesChineseSimplifiedCommon();

// Full Simplified Chinese
const cjk_full = zgui.io.fonts.getGlyphRangesChineseFull();

// Japanese
const jp_ranges = zgui.io.fonts.getGlyphRangesJapanese();

// Korean
const kr_ranges = zgui.io.fonts.getGlyphRangesKorean();

// All of the above + Cyrillic + Thai etc.
const all_ranges = zgui.io.fonts.getGlyphRangesDefault();

_ = zgui.io.addFontFromFileWithConfig(
    "assets/NotoSansSC.ttf",
    18.0,
    &zgui.io.FontConfig{ .glyph_ranges = cjk_ranges },
    null,
);
```

**Warning:** CJK font atlases are large. A full Chinese font atlas is ~10-20 MB of GPU
memory, vs ~512 KB for Latin-only. This affects:
- Startup time (font baking takes longer).
- GPU memory usage (especially on integrated graphics).
- First-frame hitch (the upload happens on first `NewFrame` after `build()`).

For shipping, use `getGlyphRangesChineseSimplifiedCommon()` (2500 chars, ~3 MB atlas)
rather than `getGlyphRangesChineseFull()` (~50k chars, ~80 MB atlas).

### Dynamic glyph loading (1.92)

If you can't predict which characters you'll need (e.g. user-entered text in any
language), 1.92 supports dynamic glyph loading:

```zig
zgui.io.setConfigFlags(.{ .font_allow_dynamic_glyphs = true });
// Now glyphs not in the atlas are loaded on demand.
```

This requires a more complex backend (the atlas can change mid-frame), but allows
arbitrary text without pre-baking every possible glyph.

## Building the font atlas

By default, ImGui builds the atlas on the first call to `NewFrame` after you've added
fonts. The backend uploads the resulting texture to the GPU.

If you want to build it manually (e.g. to inspect it):

```zig
zgui.io.fonts.build();
const tex_id = zgui.io.fonts.getTexDataAsRGBA32();   // returns texture ID
// Now you can inspect tex_id and verify the atlas looks right
```

### Inspecting the atlas

```zig
zgui.io.fonts.lock();   // prevents rebuild while we inspect
defer zgui.io.fonts.unlock();

const tex = zgui.io.fonts.getTexDataAsRGBA32();
io.out().print("Atlas size: {d}x{d} = {d} bytes\n", .{
    tex.width, tex.height, tex.width * tex.height * 4,
}) catch {};
```

### Rebuilding on DPI change

If `DpiEnableScaleFonts` is off (or you're on a version without it), you must rebuild
the atlas when the DPI changes:

```zig
fn rebuildAtlasForDpi(scale: f32) void {
    zgui.getStyle().font_scale_dpi = scale;
    zgui.io.fonts.build();
    // The backend will detect the atlas change on next NewFrame and re-upload.
}
```

## Themes

### Built-in themes

```zig
zgui.styleColorsDark(null);     // default — dark gray with subtle blues
zgui.styleColorsLight(null);    // macOS-like light gray
zgui.styleColorsClassic(null);  // the original 2014 ImGui look (high contrast)
```

### Style metrics

Beyond colors, `ImGuiStyle` controls all visual metrics:

```zig
const style = zgui.getStyle();

// Padding (inside windows and frames)
style.window_padding = .{ .x = 8, .y = 8 };
style.frame_padding = .{ .x = 4, .y = 3 };
style.popup_padding = .{ .x = 8, .y = 8 };

// Spacing (between widgets)
style.item_spacing = .{ .x = 8, .y = 4 };
style.item_inner_spacing = .{ .x = 4, .y = 4 };
style.indent_spacing = 20.0;
style.columns_min_spacing = 6.0;

// Scrollbar
style.scrollbar_size = 14.0;
style.scrollbar_rounding = 9.0;

// Borders
style.window_border_size = 1.0;
style.child_border_size = 1.0;
style.popup_border_size = 1.0;
style.frame_border_size = 0.0;
style.tab_border_size = 0.0;

// Rounding (corners)
style.window_rounding = 6.0;
style.child_rounding = 6.0;
style.popup_rounding = 4.0;
style.frame_rounding = 3.0;
style.tab_rounding = 4.0;
style.grab_rounding = 2.0;
style.log_slider_deadzone = 4.0;

// Grab min size (for sliders)
style.grab_min_size = 10.0;
```

### Scale all metrics at once

For HiDPI displays, scale everything:

```zig
const scale: f32 = 1.5;   // 150% scaling
zgui.getStyle().scaleAllSizes(scale);
```

This bumps every padding/spacing/rounding/size by `scale`. Call once at startup.

## Custom themes

Define your theme as a function:

```zig
fn applyMyTheme() void {
    const style = zgui.getStyle();
    const colors = style.colors;

    // Background colors
    colors[ImGuiCol_WindowBg] = .{ .x = 0.08, .y = 0.08, .z = 0.08, .w = 1.0 };
    colors[ImGuiCol_ChildBg] = .{ .x = 0.10, .y = 0.10, .z = 0.10, .w = 1.0 };
    colors[ImGuiCol_PopupBg] = .{ .x = 0.12, .y = 0.12, .z = 0.12, .w = 0.95 };

    // Borders
    colors[ImGuiCol_Border] = .{ .x = 0.20, .y = 0.20, .z = 0.20, .w = 1.0 };
    colors[ImGuiCol_BorderShadow] = .{ .x = 0, .y = 0, .z = 0, .w = 0 };

    // Text
    colors[ImGuiCol_Text] = .{ .x = 0.85, .y = 0.85, .z = 0.85, .w = 1.0 };
    colors[ImGuiCol_TextDisabled] = .{ .x = 0.50, .y = 0.50, .z = 0.50, .w = 1.0 };

    // Frames (input backgrounds)
    colors[ImGuiCol_FrameBg] = .{ .x = 0.15, .y = 0.15, .z = 0.15, .w = 1.0 };
    colors[ImGuiCol_FrameBgHovered] = .{ .x = 0.20, .y = 0.20, .z = 0.20, .w = 1.0 };
    colors[ImGuiCol_FrameBgActive] = .{ .x = 0.25, .y = 0.25, .z = 0.25, .w = 1.0 };

    // Buttons
    colors[ImGuiCol_Button] = .{ .x = 0.20, .y = 0.35, .z = 0.55, .w = 1.0 };
    colors[ImGuiCol_ButtonHovered] = .{ .x = 0.25, .y = 0.45, .z = 0.70, .w = 1.0 };
    colors[ImGuiCol_ButtonActive] = .{ .x = 0.15, .y = 0.30, .z = 0.50, .w = 1.0 };

    // Headers (selected items, tree node headers)
    colors[ImGuiCol_Header] = .{ .x = 0.20, .y = 0.35, .z = 0.55, .w = 1.0 };
    colors[ImGuiCol_HeaderHovered] = .{ .x = 0.25, .y = 0.45, .z = 0.70, .w = 1.0 };
    colors[ImGuiCol_HeaderActive] = .{ .x = 0.15, .y = 0.30, .z = 0.50, .w = 1.0 };

    // Sliders / grabs
    colors[ImGuiCol_SliderGrab] = .{ .x = 0.30, .y = 0.50, .z = 0.80, .w = 1.0 };
    colors[ImGuiCol_SliderGrabActive] = .{ .x = 0.40, .y = 0.60, .z = 0.90, .w = 1.0 };

    // Tabs
    colors[ImGuiCol_Tab] = .{ .x = 0.15, .y = 0.15, .z = 0.15, .w = 1.0 };
    colors[ImGuiCol_TabHovered] = .{ .x = 0.30, .y = 0.50, .z = 0.80, .w = 1.0 };
    colors[ImGuiCol_TabActive] = .{ .x = 0.20, .y = 0.35, .z = 0.55, .w = 1.0 };

    // Title bars
    colors[ImGuiCol_TitleBg] = .{ .x = 0.10, .y = 0.10, .z = 0.10, .w = 1.0 };
    colors[ImGuiCol_TitleBgActive] = .{ .x = 0.15, .y = 0.15, .z = 0.15, .w = 1.0 };
    colors[ImGuiCol_TitleBgCollapsed] = .{ .x = 0.05, .y = 0.05, .z = 0.05, .w = 1.0 };

    // Scrollbars
    colors[ImGuiCol_ScrollbarBg] = .{ .x = 0.05, .y = 0.05, .z = 0.05, .w = 1.0 };
    colors[ImGuiCol_ScrollbarGrab] = .{ .x = 0.20, .y = 0.20, .z = 0.20, .w = 1.0 };
    colors[ImGuiCol_ScrollbarGrabHovered] = .{ .x = 0.30, .y = 0.30, .z = 0.30, .w = 1.0 };
    colors[ImGuiCol_ScrollbarGrabActive] = .{ .x = 0.40, .y = 0.40, .z = 0.40, .w = 1.0 };

    // Metrics
    style.window_rounding = 4.0;
    style.frame_rounding = 3.0;
    style.grab_rounding = 2.0;
    style.window_border_size = 1.0;
    style.frame_border_size = 0.0;
}

// Call once at startup
applyMyTheme();
```

### Theme palettes

Use a palette generator for consistent colors. Popular options:

- [coolors.co](https://coolors.co/) — pick 5 colors, get the hex values.
- [material.io/design/color](https://material.io/design/color/) — Material Design
  palettes.
- [tailwindcss.com/docs/customizing-colors](https://tailwindcss.com/docs/customizing-colors) —
  Tailwind's default palette, easy to lift.

Pick:
- A primary accent (buttons, selected items).
- A background (window bg).
- A surface (child bg, popups).
- A text color.
- A "muted" text color (for disabled / secondary text).

That's enough for a clean theme.

## Live theme editing

Ship a theme editor in your debug builds:

```zig
if (zgui.begin("Style Editor", .{})) {
    zgui.showStyleEditor(null);
}
zgui.end();
```

This lets you tweak every color and metric live, then export the result as code:

1. Tweak until you like it.
2. Click "Export" in the style editor.
3. ImGui writes a C++ function that reproduces the current style.
4. Paste it into your Zig code (adjusting syntax).

Saves hours of guess-and-check on theme design.

## See also

- [fundamentals.md](fundamentals.md#style-and-colors) — Style overview
- [backends.md](backends.md#dpi-scaling) — Backend-side DPI handling
- [build-zig.md](build-zig.md#src-mainzig) — Where theme setup fits in the main loop
