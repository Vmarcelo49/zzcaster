# ImGui Remake Plan — v3

Replace the fragile cimgui C-shim layer with **zgui**, a pure-Zig binding
for Dear ImGui.  This document captures the dependency source, API mapping,
and staged migration strategy.

## Revision history

| Version | Date       | Change                                                       |
|--------|------------|--------------------------------------------------------------|
| v1     | 2025-06-01 | Initial plan using zig-gamedev/zgui trunk.                  |
| v2     | 2025-06-15 | Updated for Zig 0.16; assumed zig-gamedev/zgui PR #103.     |
| v3     | 2025-06-21 | Switched to **cyberegoorg/zgui** fork (`upgrade_to_zig_16`) |
|        |            | — the only publicly available zgui build with 0.16 support.  |

## Dependency source

We depend on a **third-party fork** of zig-gamedev/zgui rather than the
upstream main branch, because the upstream has not yet merged official
Zig 0.16 support at the time of writing.

- **Repo:** `cyberegoorg/zgui`
- **Branch:** `upgrade_to_zig_16`
- **Version:** `0.6.0-dev`
- **Minimum Zig:** `0.16.0`
- **URL:** `https://github.com/cyberegoorg/zgui/tree/upgrade_to_zig_16`

### Adding the dependency

```bash
zig fetch --save \
  "git+https://github.com/cyberegoorg/zgui.git#upgrade_to_zig_16"
```

### build.zig.zon snippet

```zig
.@"zgui" = .{
    .url = "https://github.com/cyberegoorg/zgui/archive/refs/heads/upgrade_to_zig_16.tar.gz",
    .hash = "0xe78160e64acbef8",
},
```

> **Fork governance note:** This is a temporary measure.  If zig-gamedev/zgui
> merges official 0.16 support in the future, we should evaluate switching
> back to the upstream package.  The fork's API surface is identical to
> upstream zgui, so the migration cost would be minimal (update URL + hash,
> re-run `zig fetch`).

## Backend selection

ZZCaster uses SDL2 with OpenGL 3 renderer.  The fork provides the following
backends via its `Backend` enum:

| Backend enum value       | Description               |
|------------------------|---------------------------|
| `sdl2`                 | SDL2 (software)           |
| `sdl2_opengl`          | SDL2 + OpenGL 3           |
| `sdl2_renderer`        | SDL2 + SDL_Renderer       |
| `glfw`                 | GLFW                      |
| `glfw_opengl`          | GLFW + OpenGL 3           |
| `sdl3`                 | SDL3                      |
| `sdl3_opengl`          | SDL3 + OpenGL 3           |

**Our target: `sdl2_opengl`.** This matches ZZCaster's current SDL2+GL3
setup exactly.  The relevant backend source in the fork is
`backend_sdl2_opengl.zig`.

## API mapping (cimgui → zgui)

The mapping below covers every cimgui call used in `src/ui.zig`.  The fork
preserves the same public API as upstream zgui, so these mappings are stable
regardless of which package source we use.

| Current (cimgui C import)                | zgui equivalent                      | Notes                              |
|------------------------------------------|--------------------------------------|------------------------------------|
| `igCreateContext(nullptr)`                | `zgui.init()`                        | Returns `!void` instead of pointer  |
| `igDestroyContext(ctx)`                   | `zgui.deinit()`                      |                                     |
| `igSetCurrentContext(ctx)`                | (implicit, context is global)        | Not needed                          |
| `igGetIO()`                              | `zgui.io()`                          | Returns pointer to `Io` struct      |
| `igNewFrame()`                            | `zgui.newFrame()`                    |                                     |
| `igRender()`                             | `zgui.render()`                      |                                     |
| `igGetDrawData()`                         | `zgui.getDrawData()`                 |                                     |
| `igBegin(label, p_open, flags)`          | `zgui.begin(label, flags)`           | Optional `.p_open` arg              |
| `igEnd()`                                 | `zgui.end()`                          |                                     |
| `igBeginChild(id, size, border, flags)`  | `zgui.beginChild(id, size, flags)`    |                                     |
| `igEndChild()`                            | `zgui.endChild()`                     |                                     |
| `igSetNextWindowPos(pos, cond, pivot)`   | `zgui.setNextWindowPos(pos, cond)`   |                                     |
| `igSetNextWindowSize(size, cond)`        | `zgui.setNextWindowSize(size, cond)`  |                                     |
| `igSetNextWindowSizeConstraints(...)`    | `zgui.setNextWindowSizeConstraints()`|                                     |
| `igPushStyleVar(idx, val)`                | `zgui.pushStyleVar(idx, val)`         |                                     |
| `igPopStyleVar(count)`                    | `zgui.popStyleVar(count)`             |                                     |
| `igPushStyleColor(idx, col)`              | `zgui.pushStyleColor(idx, col)`       |                                     |
| `igPopStyleColor(count)`                  | `zgui.popStyleColor(count)`           |                                     |
| `igGetStyle()`                            | `zgui.getStyle()`                     |                                     |
| `igGetFont()`                             | `zgui.getFont()`                      |                                     |
| `igText(fmt, ...)`                        | `zgui.text(fmt, ...)`                |                                     |
| `igTextWrapped(fmt, ...)`                 | `zgui.textWrapped(fmt, ...)`         |                                     |
| `igBulletText(fmt, ...)`                  | `zgui.bulletText(fmt, ...)`           |                                     |
| `igSeparator()`                           | `zgui.separator()`                    |                                     |
| `igSameLine(offset, spacing)`             | `zgui.sameLine(offset, spacing)`      |                                     |
| `igDummy(size)`                           | `zgui.dummy(size)`                    |                                     |
| `igSpacing()`                             | `zgui.spacing()`                      |                                     |
| `igIndent(indent)`                        | `zgui.indent(indent)`                 |                                     |
| `igUnindent(indent)`                      | `zgui.unindent(indent)`               |                                     |
| `igButton(label, size)`                   | `zgui.button(label, size)`            | Returns `bool`                      |
| `igSmallButton(label)`                    | `zgui.smallButton(label)`             |                                     |
| `igInvisibleButton(id, size, flags)`      | `zgui.invisibleButton(id, size)`      |                                     |
| `igArrowButton(id, dir)`                  | `zgui.arrowButton(id, dir)`           |                                     |
| `igCheckbox(label, v)`                    | `zgui.checkbox(label, v)`             |                                     |
| `igRadioButton(label, active)`            | `zgui.radioButton(label, active)`      |                                     |
| `igProgressBar(fraction, size_ovl, overlay)` | `zgui.progressBar(frac, size, overlay)` | |
| `igCombo(label, current_item, items_separated_by_zeros)` | `zgui.combo(label, current, items)` | |
| `igBeginCombo(label, preview_value, flags)` | `zgui.beginCombo(label, preview)`     | |
| `igEndCombo()`                            | `zgui.endCombo()`                     |                                     |
| `igInputText(label, buf, sz, flags, cb, ud)` | `zgui.inputText(label, buf, flags)`   | |
| `igInputTextMultiline(label, buf, sz, size, flags, cb, ud)` | `zgui.inputTextMultiline(...)` | |
| `igInputInt(label, v, step, step_fast, flags)` | `zgui.inputInt(label, v, flags)`     | |
| `igInputFloat(label, v, step, step_fast, fmt, flags)` | `zgui.inputFloat(label, v, ...)` | |
| `igInputScalar(...)`                     | `zgui.inputScalar(...)`               |                                     |
| `igSliderFloat(label, v, min, max, fmt, flags)` | `zgui.sliderFloat(label, v, min, max)` | |
| `igSliderInt(label, v, min, max, fmt, flags)`   | `zgui.sliderInt(label, v, min, max)`   | |
| `igSliderAngle(label, v_rad, min_deg, max_deg, fmt, flags)` | `zgui.sliderAngle(label, v, ...)` | |
| `igVSliderFloat(label, size, v, min, max, fmt, flags)` | `zgui.vSliderFloat(...)` | |
| `igDragFloat(label, v, speed, min, max, fmt, flags)` | `zgui.dragFloat(label, v, ...)` | |
| `igDragInt(label, v, speed, min, max, fmt, flags)`   | `zgui.dragInt(label, v, ...)`   | |
| `igDragFloatRange2(label, v_min, v_max, speed, min, max, fmt, fmt_max, flags)` | `zgui.dragFloatRange2(...)` | |
| `igColorEdit3(label, col, flags)`        | `zgui.colorEdit3(label, col, flags)`   |                                     |
| `igColorEdit4(label, col, flags)`        | `zgui.colorEdit4(label, col, flags)`   |                                     |
| `igColorButton(desc_id, col, flags, size)` | `zgui.colorButton(id, col, flags, size)` | |
| `igTreeNode(label)`                       | `zgui.treeNode(label)`                |                                     |
| `igTreeNodeStrStr(str_id, fmt, ...)`     | `zgui.treeNodeEx(id, flags)`          |                                     |
| `igTreePop()`                             | `zgui.treePop()`                       |                                     |
| `igTreePush(str_id)`                     | `zgui.treePush(id)`                    |                                     |
| `igCollapsingHeader(label, flags)`       | `zgui.collapsingHeader(label, flags)`  |                                     |
| `igSelectable(label, p_selected, flags, size)` | `zgui.selectable(label, selected, flags, size)` | |
| `igListBox(label, current_item, items, items_count, height_in_items)` | `zgui.listBox(label, current, items)` | |
| `igBeginMenuBar()`                        | `zgui.beginMenuBar()`                  |                                     |
| `igEndMenuBar()`                          | `zgui.endMenuBar()`                    |                                     |
| `igBeginMainMenuBar()`                    | `zgui.beginMainMenuBar()`              |                                     |
| `igEndMainMenuBar()`                      | `zgui.endMainMenuBar()`                |                                     |
| `igBeginMenu(label, enabled)`             | `zgui.beginMenu(label, enabled)`       |                                     |
| `igEndMenu()`                             | `zgui.endMenu()`                       |                                     |
| `igMenuItem(label, shortcut, selected, enabled)` | `zgui.menuItem(label, shortcut, selected, enabled)` | |
| `igTooltip(fmt, ...)`                     | `zgui.setTooltip(fmt, ...)`            |                                     |
| `igBeginTooltip()`                        | `zgui.beginTooltip()`                  |                                     |
| `igEndTooltip()`                          | `zgui.endTooltip()`                    |                                     |
| `igOpenPopup(str_id, flags)`             | `zgui.openPopup(id, flags)`            |                                     |
| `igBeginPopup(str_id, flags)`            | `zgui.beginPopup(id, flags)`           |                                     |
| `igBeginPopupModal(name, p_open, flags)` | `zgui.beginPopupModal(name, flags)`    |                                     |
| `igEndPopup()`                            | `zgui.endPopup()`                      |                                     |
| `igCloseCurrentPopup()`                   | `zgui.closeCurrentPopup()`             |                                     |
| `igIsPopupOpen(str_id, flags)`           | `zgui.isPopupOpen(id, flags)`          |                                     |
| `igColumns(count, id, border)`           | `zgui.columns(count, id, border)`      |                                     |
| `igNextColumn()`                           | `zgui.nextColumn()`                    |                                     |
| `igGetColumnIndex()`                      | `zgui.getColumnIndex()`                |                                     |
| `igGetColumnWidth(idx)`                   | `zgui.getColumnWidth(idx)`             |                                     |
| `igSetColumnWidth(idx, width)`           | `zgui.setColumnWidth(idx, width)`      |                                     |
| `igGetColumnOffset(idx)`                  | `zgui.getColumnOffset(idx)`           |                                     |
| `igSetColumnOffset(idx, offset)`         | `zgui.setColumnOffset(idx, offset)`    |                                     |
| `igTabBar(id, flags)`                     | `zgui.beginTabBar(id, flags)`          | Returns `bool` (acts as begin)       |
| `igEndTabBar()`                           | `zgui.endTabBar()`                     |                                     |
| `igBeginTabItem(label, p_open, flags)`   | `zgui.beginTabItem(label, flags)`      |                                     |
| `igEndTabItem()`                          | `zgui.endTabItem()`                    |                                     |
| `igSetTabItemClosed(tab_or_docked_window_tab_id)` | `zgui.setTabItemClosed(id)` | |
| `igScrollbar(axis)`                       | `zgui.scrollbar(axis)`                  |                                     |
| `igGetScrollY()`                          | `zgui.getScrollY()`                     |                                     |
| `igSetScrollY(scroll_y)`                  | `zgui.setScrollY(scroll_y)`            |                                     |
| `igGetScrollMaxY()`                       | `zgui.getScrollMaxY()`                  |                                     |
| `igIsItemHovered(flags)`                  | `zgui.isItemHovered(flags)`            |                                     |
| `igIsItemClicked(flags)`                  | `zgui.isItemClicked(flags)`            |                                     |
| `igIsItemActive()`                        | `zgui.isItemActive()`                  |                                     |
| `igIsItemEdited()`                        | `zgui.isItemEdited()`                  |                                     |
| `igIsWindowFocused(flags)`                | `zgui.isWindowFocused(flags)`           |                                     |
| `igIsWindowHovered(flags)`               | `zgui.isWindowHovered(flags)`          |                                     |
| `igGetMousePos()`                         | `zgui.getMousePos()`                   |                                     |
| `igGetMouseDragDelta(idx, lock_threshold)` | `zgui.getMouseDragDelta(idx)`          |                                     |
| `igIsMouseDown(button)`                   | `zgui.isMouseDown(button)`             |                                     |
| `igIsMouseClicked(button, repeat)`       | `zgui.isMouseClicked(button, repeat)` |                                     |
| `igIsMouseDoubleClicked(button)`          | `zgui.isMouseDoubleClicked(button)`     |                                     |
| `igGetCursorPos()`                        | `zgui.getCursorPos()`                  |                                     |
| `igSetCursorPos(local_pos)`               | `zgui.setCursorPos(local_pos)`          |                                     |
| `igGetContentRegionAvail()`              | `zgui.getContentRegionAvail()`        |                                     |
| `igGetWindowContentRegionMax()`          | `zgui.getWindowContentRegionMax()`    |                                     |
| `igGetWindowWidth()`                      | `zgui.getWindowWidth()`                |                                     |
| `igGetWindowHeight()`                     | `zgui.getWindowHeight()`               |                                     |
| `igGetWindowPos()`                        | `zgui.getWindowPos()`                  |                                     |
| `igGetWindowSize()`                       | `zgui.getWindowSize()`                 |                                     |
| `igGetFrameCount()`                       | `zgui.getFrameCount()`                 |                                     |
| `igGetTime()`                             | `zgui.getTime()`                       |                                     |
| `igGetBackgroundDrawList()`               | `zgui.getBackgroundDrawList()`          |                                     |
| `igGetForegroundDrawList()`              | `zgui.getForegroundDrawList()`          |                                     |
| `igImDrawList_AddRect(p_list, ...)`      | `drawlist.addRect(...)`                | Method on DrawList                    |
| `igImDrawList_AddRectFilled(p_list, ...)`| `drawlist.addRectFilled(...)`          | Method on DrawList                    |
| `igImDrawList_AddLine(p_list, ...)`      | `drawlist.addLine(...)`                | Method on DrawList                    |
| `igImDrawList_AddText(p_list, ...)`      | `drawlist.addText(...)`                | Method on DrawList                    |
| `igImDrawList_AddCircleFilled(...)`       | `drawlist.addCircleFilled(...)`         |                                     |
| `igImDrawList_AddTriangleFilled(...)`    | `drawlist.addTriangleFilled(...)`      |                                     |
| `igImDrawList_AddBezierCubic(...)`       | `drawlist.addBezierCubic(...)`         |                                     |
| `igImDrawList_PushClipRect(...)`         | `drawlist.pushClipRect(...)`            |                                     |
| `igImDrawList_PopClipRect()`             | `drawlist.popClipRect()`               |                                     |
| `igImDrawList_AddImage(...)`             | `drawlist.addImage(...)`                |                                     |
| `ImVec2(...)`                             | `zgui.math.Vec2` or just `[2]f32`      |                                     |
| `ImVec4(...)`                             | `zgui.math.Vec4` or `[4]f32`           |                                     |
| `ImColor(...)`                            | `zgui.math.Vec4` + helper             |                                     |
| `ImGuiWindowFlags_None`                   | `zgui.WindowFlags{}`                   |                                     |
| `ImGuiWindowFlags_NoTitleBar`             | `.{.no_title_bar = true}`              | Bitfield struct                      |
| `ImGuiWindowFlags_NoScrollbar`            | `.{.no_scrollbar = true}`              |                                     |
| `ImGuiWindowFlags_NoMove`                 | `.{.no_move = true}`                   |                                     |
| `ImGuiWindowFlags_NoResize`              | `.{.no_resize = true}`                 |                                     |
| `ImGuiWindowFlags_NoCollapse`             | `.{.no_collapse = true}`               |                                     |
| `ImGuiWindowFlags_AlwaysAutoResize`       | `.{.always_auto_resize = true}`        |                                     |
| `ImGuiCond_Once`                          | `.once`                                | Enum value                            |
| `ImGuiCond_FirstUseEver`                  | `.first_use_ever`                      |                                     |
| `ImGuiCond_Appearing`                     | `.appearing`                           |                                     |
| `ImGuiCol_Text`                           | `.text`                                | Enum value on Style                  |
| `ImGuiCol_WindowBg`                       | `.window_bg`                           |                                     |
| `ImGuiCol_Button`                         | `.button`                              |                                     |
| `ImGuiCol_ButtonHovered`                  | `.button_hovered`                      |                                     |
| `ImGuiCol_ButtonActive`                   | `.button_active`                       |                                     |
| `ImGuiCol_CheckMark`                      | `.check_mark`                          |                                     |
| `ImGuiCol_FrameBg`                        | `.frame_bg`                            |                                     |
| `ImGuiCol_FrameBgHovered`                 | `.frame_bg_hovered`                    |                                     |
| `ImGuiCol_FrameBgActive`                  | `.frame_bg_active`                     |                                     |
| `ImGuiCol_Tab`                            | `.tab`                                 |                                     |
| `ImGuiCol_TabActive`                      | `.tab_active`                          |                                     |
| `ImGuiCol_TabHovered`                     | `.tab_hovered`                         |                                     |
| `ImGuiCol_TitleBg`                        | `.title_bg`                            |                                     |
| `ImGuiCol_TitleBgActive`                 | `.title_bg_active`                     |                                     |
| `ImGuiCol_PopupBg`                        | `.popup_bg`                            |                                     |
| `ImGuiCol_Border`                         | `.border`                              |                                     |
| `ImGuiCol_Separator`                      | `.separator`                            |                                     |
| `ImGuiCol_ScrollbarBg`                    | `.scrollbar_bg`                        |                                     |
| `ImGuiCol_ScrollbarGrab`                  | `.scrollbar_grab`                      |                                     |
| `ImGuiCol_Header`                         | `.header`                              |                                     |
| `ImGuiCol_HeaderHovered`                  | `.header_hovered`                      |                                     |
| `ImGuiCol_HeaderActive`                   | `.header_active`                       |                                     |
| `ImGuiCol_TextSelectedBg`                 | `.text_selected_bg`                    |                                     |
| `ImGuiStyleVar_WindowPadding`            | `.window_padding`                      |                                     |
| `ImGuiStyleVar_FrameRounding`             | `.frame_rounding`                      |                                     |
| `ImGuiStyleVar_WindowRounding`           | `.window_rounding`                     |                                     |
| `ImGuiStyleVar_ItemSpacing`               | `.item_spacing`                        |                                     |
| `ImGuiStyleVar_FramePadding`              | `.frame_padding`                       |                                     |
| `ImGuiStyleVar_TabRounding`              | `.tab_rounding`                        |                                     |
| `ImGuiMouseButton_Left`                   | `.left`                                |                                     |
| `ImGuiMouseButton_Right`                  | `.right`                               |                                     |
| `ImGuiMouseButton_Middle`                  | `.middle`                              |                                     |
| `ImGuiDir_None`                           | `.none`                                |                                     |
| `ImGuiDir_Left`                           | `.left`                                |                                     |
| `ImGuiDir_Right`                          | `.right`                               |                                     |
| `ImGuiDir_Up`                             | `.up`                                  |                                     |
| `ImGuiDir_Down`                           | `.down`                                |                                     |
| `ImGuiKey_*`                              | `zgui.Key` enum                        | Key mapping may differ                |

## Migration strategy — 4 stages

### Stage 1: Pre-flight verification

1. **Clone and build the fork locally:**
   ```bash
   git clone --branch upgrade_to_zig_16 \
     https://github.com/cyberegoorg/zgui.git \
     /tmp/zgui-fork
   cd /tmp/zgui-fork
   zig build
   ```

2. **Verify the `sdl2_opengl` backend compiles** with our Zig version
   (`0.16.0`).

3. **Add the dependency** to ZZCaster's `build.zig.zon` using the
   `zig fetch --save` command from above.

4. **Wire it into `build.zig`:**
   ```zig
   const zgui = b.dependency("zgui", .{
       .backend = .sdl2_opengl,
   });
   exe.root_module.addImport("zgui", zgui.module("root"));
   ```

5. **Confirm a minimal smoke test compiles** — a hello-window that calls
   `zgui.init()`, creates one window, renders a frame, calls `zgui.deinit()`.

### Stage 2: Parallel bring-up

1. **Create `src/ui_new.zig`** alongside the existing `src/ui.zig`.  Port
   each function one at a time.

2. **Start with the render loop scaffolding:**
   ```zig
   const zgui = @import("zgui");

   pub fn init(allocator: std.mem.Allocator) !void {
       zgui.init(allocator) catch |err| {
           std.log.err("zgui.init failed: {}", .{err});
           return err;
       };
       zgui.backend.init();
   }

   pub fn deinit() void {
       zgui.backend.deinit();
       zgui.deinit();
   }
   ```

3. **Port helper functions first** (wrappers around vectors, colors,
   style helpers) since they have no side effects and can be unit-tested
   conceptually.

4. **Switch `main.zig` to import `ui_new`** once the render loop works.
   Keep `src/ui.zig` in the tree but unused.

### Stage 3: Page-by-page migration

Port each UI page from `src/ui.zig` into separate modules under
`src/ui/`:

| New file                  | Contents from `ui.zig`              |
|--------------------------|--------------------------------------|
| `src/ui/root.zig`        | Main menu, tab bar, window layout    |
| `src/ui/host_tab.zig`    | Host game page (IP, port, delay)     |
| `src/ui/lobby_tab.zig`   | Lobby / spectate UI                  |
| `src/ui/replay_tab.zig`  | Replay browser / player              |
| `src/ui/settings_tab.zig`| Settings page (keys, video, audio)  |
| `src/ui/log_tab.zig`      | Netplay log / console               |
| `src/ui/style.zig`       | Theme, colors, fonts                 |
| `src/ui/helpers.zig`     | Small reusable widgets              |

### Stage 4: Cleanup

1. **Delete** `cimgui_shim.h`, `imgui_backend_wrap.cpp`, `libs/cimgui/`,
   `libs/imgui/`.

2. **Remove** the C++ compile step from `build.zig` (no more
   `.cpp_sources`, no more `linkSystemLibrary("c++")` on Windows).

3. **Delete** the old `src/ui.zig`.

4. **Update `context.md`** and this plan to reflect the completed migration.

## File-by-file change list

### Delete

| File                              | Reason                                   |
|-----------------------------------|------------------------------------------|
| `cimgui_shim.h`                   | Replaced by zgui's pure-Zig API           |
| `imgui_backend_wrap.cpp`          | Replaced by `backend_sdl2_opengl.zig`     |
| `libs/cimgui/`                    | Entire vendored directory                 |
| `libs/imgui/`                     | Entire vendored directory                 |

### Create

| File                          | Purpose                                    |
|-------------------------------|--------------------------------------------|
| `src/ui/root.zig`             | Main window + tab bar                       |
| `src/ui/host_tab.zig`         | Host game page                             |
| `src/ui/lobby_tab.zig`        | Lobby / spectate                           |
| `src/ui/replay_tab.zig`       | Replay browser                             |
| `src/ui/settings_tab.zig`     | Settings page                              |
| `src/ui/log_tab.zig`           | Netplay log                                |
| `src/ui/style.zig`            | Theme / colors / fonts                     |
| `src/ui/helpers.zig`          | Shared widget helpers                      |

### Modify

| File        | Change                                              |
|-------------|-----------------------------------------------------|
| `build.zig` | Remove C++ compile step; add `zgui` dependency wire-up |
| `build.zig.zon` | Add zgui dependency URL + hash                    |

## Risk table

| Risk                                 | Likelihood | Impact | Mitigation                                          |
|--------------------------------------|------------|--------|-----------------------------------------------------|
| Fork may go stale or diverge from zig-gamedev/zgui | Medium | Medium | Monitor upstream; fork's API is identical so switching back is low-cost |
| zgui API surface missing an `ig*` call we need | Low     | Low    | Hand-wrap missing calls via `@cImport` temporarily   |
| Font loading API differs from cimgui  | Low       | Low    | Port font config 1:1; zgui supports `.ttf` loading   |
| `backend_sdl2_opengl` glitches       | Low       | Medium | Test on Windows (primary target) before full switch   |
| Zig 0.16 patch bumps break zgui hash | Medium    | Low    | Pin exact Zig version in build.zig.zon `minimum_zig` |
| Upstream merges 0.16 support → fork redundant | High (eventual) | None | Positive outcome — migrate URL back to upstream      |
