// cimgui_shim.h — Minimal C declarations for ImGui functions used by ui.zig.
// We can't @cImport cimgui.h directly because it contains C++ template
// typedefs that Zig's C parser can't handle. Instead, we declare just
// the functions and types we need here, and link against the compiled
// cimgui.cpp + imgui_impl_sdl2.cpp + imgui_impl_opengl3.cpp which provide
// the implementations.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Forward-declare ImGui types as opaque structs
typedef struct ImGuiContext ImGuiContext;
typedef struct ImGuiIO ImGuiIO;
typedef struct ImDrawData ImDrawData;
typedef struct ImDrawList ImDrawList;
typedef struct ImFont ImFont;
typedef struct ImFontBaked ImFontBaked;

// cimgui uses ImVec2_c for by-value parameters
typedef struct ImVec2_c { float x, y; } ImVec2_c;
typedef struct ImVec4_c { float x, y, z, w; } ImVec4_c;

// 32-bit packed RGBA color (8 bits per channel, R<<24 | G<<16 | B<<8 | A)
typedef uint32_t ImU32;

// ImGui window flags
typedef int ImGuiWindowFlags;
#define ImGuiWindowFlags_NoTitleBar 1
#define ImGuiWindowFlags_NoResize 2
#define ImGuiWindowFlags_NoMove 4
#define ImGuiWindowFlags_NoCollapse 16
#define ImGuiWindowFlags_NoBringToFrontOnFocus 8192
#define ImGuiWindowFlags_NoScrollbar 8
#define ImGuiWindowFlags_NoScrollWithMouse 32

// ImGui input text flags
typedef int ImGuiInputTextFlags;

// ImGui conditions
#define ImGuiCond_Always 1

// ImGui color indices — must match enum ImGuiCol_ in imgui.h
typedef int ImGuiCol;
#define ImGuiCol_Text 0
#define ImGuiCol_TextDisabled 1
#define ImGuiCol_WindowBg 2
#define ImGuiCol_ChildBg 3
#define ImGuiCol_PopupBg 4
#define ImGuiCol_Border 5
#define ImGuiCol_BorderShadow 6
#define ImGuiCol_FrameBg 7
#define ImGuiCol_FrameBgHovered 8
#define ImGuiCol_FrameBgActive 9
#define ImGuiCol_TitleBg 10
#define ImGuiCol_TitleBgActive 11
#define ImGuiCol_TitleBgCollapsed 12
#define ImGuiCol_MenuBarBg 13
#define ImGuiCol_ScrollbarBg 14
#define ImGuiCol_ScrollbarGrab 15
#define ImGuiCol_ScrollbarGrabHovered 16
#define ImGuiCol_ScrollbarGrabActive 17
#define ImGuiCol_CheckMark 18
#define ImGuiCol_CheckboxSelectedBg 19
#define ImGuiCol_SliderGrab 20
#define ImGuiCol_SliderGrabActive 21
#define ImGuiCol_Button 22
#define ImGuiCol_ButtonHovered 23
#define ImGuiCol_ButtonActive 24
#define ImGuiCol_Header 25
#define ImGuiCol_HeaderHovered 26
#define ImGuiCol_HeaderActive 27
#define ImGuiCol_Separator 28
#define ImGuiCol_SeparatorHovered 29
#define ImGuiCol_SeparatorActive 30
#define ImGuiCol_ResizeGrip 31
#define ImGuiCol_ResizeGripHovered 32
#define ImGuiCol_ResizeGripActive 33
#define ImGuiCol_InputTextCursor 34
#define ImGuiCol_TabHovered 35
#define ImGuiCol_Tab 36
#define ImGuiCol_TabSelected 37
#define ImGuiCol_TabSelectedOverline 38
#define ImGuiCol_TabDimmed 39
#define ImGuiCol_TabDimmedSelected 40
#define ImGuiCol_TabDimmedSelectedOverline 41
#define ImGuiCol_PlotLines 42
#define ImGuiCol_PlotLinesHovered 43
#define ImGuiCol_PlotHistogram 44
#define ImGuiCol_PlotHistogramHovered 45
#define ImGuiCol_TableHeaderBg 46
#define ImGuiCol_TableBorderStrong 47
#define ImGuiCol_TableBorderLight 48
#define ImGuiCol_TableRowBg 49
#define ImGuiCol_TableRowBgAlt 50
#define ImGuiCol_TextLink 51
#define ImGuiCol_TextSelectedBg 52
#define ImGuiCol_TreeLines 53
#define ImGuiCol_DragDropTarget 54
#define ImGuiCol_DragDropTargetBg 55
#define ImGuiCol_UnsavedMarker 56
#define ImGuiCol_NavCursor 57
#define ImGuiCol_NavWindowingHighlight 58
#define ImGuiCol_NavWindowingDimBg 59
#define ImGuiCol_ModalWindowDimBg 60

// ImGui style variable indices — must match enum ImGuiStyleVar_ in imgui.h
typedef int ImGuiStyleVar;
#define ImGuiStyleVar_Alpha 0
#define ImGuiStyleVar_DisabledAlpha 1
#define ImGuiStyleVar_WindowPadding 2
#define ImGuiStyleVar_WindowRounding 3
#define ImGuiStyleVar_WindowBorderSize 4
#define ImGuiStyleVar_WindowMinSize 5
#define ImGuiStyleVar_WindowTitleAlign 6
#define ImGuiStyleVar_ChildRounding 7
#define ImGuiStyleVar_ChildBorderSize 8
#define ImGuiStyleVar_PopupRounding 9
#define ImGuiStyleVar_PopupBorderSize 10
#define ImGuiStyleVar_FramePadding 11
#define ImGuiStyleVar_FrameRounding 12
#define ImGuiStyleVar_FrameBorderSize 13
#define ImGuiStyleVar_ItemSpacing 14
#define ImGuiStyleVar_ItemInnerSpacing 15
#define ImGuiStyleVar_IndentSpacing 16
#define ImGuiStyleVar_CellPadding 17
#define ImGuiStyleVar_ScrollbarSize 18
#define ImGuiStyleVar_ScrollbarRounding 19
#define ImGuiStyleVar_ScrollbarPadding 20
#define ImGuiStyleVar_GrabMinSize 21
#define ImGuiStyleVar_GrabRounding 22
#define ImGuiStyleVar_ImageRounding 23
#define ImGuiStyleVar_ImageBorderSize 24
#define ImGuiStyleVar_TabRounding 25
#define ImGuiStyleVar_TabBorderSize 26

// ImGui child window flags — must match enum ImGuiChildFlags_ in imgui.h
typedef int ImGuiChildFlags;
#define ImGuiChildFlags_None 0
#define ImGuiChildFlags_Borders 1
#define ImGuiChildFlags_AlwaysUseWindowPadding 2
#define ImGuiChildFlags_ResizeX 4
#define ImGuiChildFlags_ResizeY 8
#define ImGuiChildFlags_AutoResizeX 16
#define ImGuiChildFlags_AutoResizeY 32
#define ImGuiChildFlags_AlwaysAutoResize 64
#define ImGuiChildFlags_FrameStyle 128
#define ImGuiChildFlags_NavFlattened 256

// ImGui draw flags (subset)
typedef int ImDrawFlags;
#define ImDrawFlags_None 0
#define ImDrawFlags_RoundCornersTopLeft 1
#define ImDrawFlags_RoundCornersTopRight 2
#define ImDrawFlags_RoundCornersBottomLeft 4
#define ImDrawFlags_RoundCornersBottomRight 8
#define ImDrawFlags_RoundCornersAll 15
#define ImDrawFlags_RoundCornersNone 16

// Core functions (cimgui API — note igGetIO_Nil for the no-arg overload)
ImGuiContext* igCreateContext(void* shared_font_atlas);
void igDestroyContext(ImGuiContext* ctx);
ImGuiIO* igGetIO_Nil(void);
void igNewFrame(void);
void igRender(void);
ImDrawData* igGetDrawData(void);
void igStyleColorsDark(void* dst);

// Window/widget functions
bool igBegin(const char* name, bool* p_open, ImGuiWindowFlags flags);
void igEnd(void);
void igText(const char* fmt, ...);
void igTextColored(ImVec4_c col, const char* fmt, ...);
void igTextWrapped(const char* fmt, ...);
void igTextUnformatted(const char* text, const char* text_end);
void igBulletText(const char* fmt, ...);
bool igButton(const char* label, ImVec2_c size);
void igSameLine(float offset_from_start_x, float spacing);
bool igIsItemClicked(int mouse_button);
void igSpacing(void);
void igSeparator(void);
bool igInputText(const char* label, char* buf, size_t buf_size, ImGuiInputTextFlags flags, void* callback, void* user_data);
bool igSliderInt(const char* label, int* v, int v_min, int v_max, const char* format, int flags);
bool igSliderFloat(const char* label, float* v, float v_min, float v_max, const char* format, int flags);
void igPushItemWidth(float item_width);
void igPopItemWidth(void);
bool igSetNextWindowSize(ImVec2_c size, int cond);
void igSetNextWindowPos(ImVec2_c pos, int cond, ImVec2_c pivot);
void igSetNextWindowBgAlpha(float alpha);
void igSetClipboardText(const char* text);

// Child windows
bool igBeginChild_Str(const char* str_id, ImVec2_c size, ImGuiChildFlags child_flags, ImGuiWindowFlags window_flags);
void igEndChild(void);

// Selectable
bool igSelectable_Bool(const char* label, bool selected, int flags, ImVec2_c size);

// Radio buttons and combo boxes
bool igRadioButton_Bool(const char* label, bool active);
bool igCombo_Str_arr(const char* label, int* current_item, const char* const items[], int items_count, int popup_max_height_in_items);
bool igCheckbox(const char* label, bool* v);

// Layout helpers
void igDummy(ImVec2_c size);
void igIndent(float indent_w);
void igUnindent(float indent_w);
void igAlignTextToFramePadding(void);
void igPushTextWrapPos(float wrap_local_pos_x);
void igPopTextWrapPos(void);
ImVec2_c igGetContentRegionAvail(void);
ImVec2_c igGetCursorPos(void);
float igGetCursorPosX(void);
float igGetCursorPosY(void);
void igSetCursorPos(ImVec2_c local_pos);
void igSetCursorPosX(float local_x);
void igSetCursorPosY(float local_y);
float igGetTextLineHeight(void);
float igGetTextLineHeightWithSpacing(void);
float igGetFrameHeight(void);
float igGetFrameHeightWithSpacing(void);
ImVec2_c igGetWindowPos(void);
float igGetWindowWidth(void);
float igGetWindowHeight(void);
ImVec2_c igCalcTextSize(const char* text, const char* text_end, bool hide_text_after_double_hash, float wrap_width);

// Color and style stacks
void igPushStyleColor_U32(ImGuiCol idx, ImU32 col);
void igPushStyleColor_Vec4(ImGuiCol idx, ImVec4_c col);
void igPopStyleColor(int count);
void igPushStyleVar_Float(ImGuiStyleVar idx, float val);
void igPushStyleVar_Vec2(ImGuiStyleVar idx, ImVec2_c val);
void igPushStyleVarX(ImGuiStyleVar idx, float val_x);
void igPushStyleVarY(ImGuiStyleVar idx, float val_y);
void igPopStyleVar(int count);

// Color conversion
ImU32 igColorConvertFloat4ToU32(ImVec4_c in);
ImVec4_c igColorConvertU32ToFloat4(ImU32 in);

// Window draw list (for gradient background)
ImDrawList* igGetWindowDrawList(void);
ImDrawList* igGetBackgroundDrawList_Nil(void);
ImDrawList* igGetForegroundDrawList_Nil(void);

// ImDrawList primitive drawing
void ImDrawList_AddRectFilled(ImDrawList* self, ImVec2_c p_min, ImVec2_c p_max, ImU32 col, float rounding, ImDrawFlags flags);
void ImDrawList_AddRectFilledMultiColor(ImDrawList* self, ImVec2_c p_min, ImVec2_c p_max, ImU32 col_upr_left, ImU32 col_upr_right, ImU32 col_bot_right, ImU32 col_bot_left);
void ImDrawList_AddRect(ImDrawList* self, ImVec2_c p_min, ImVec2_c p_max, ImU32 col, float rounding, ImDrawFlags flags, float thickness);
void ImDrawList_AddLine(ImDrawList* self, ImVec2_c p1, ImVec2_c p2, ImU32 col, float thickness);
void ImDrawList_AddText_Vec2(ImDrawList* self, ImVec2_c pos, ImU32 col, const char* text_begin, const char* text_end);

// ID stack
void igPushID_Str(const char* str_id);
void igPopID(void);

// Backend functions — wrapped in imgui_backend_wrap.cpp with C linkage
// because the original ImGui backends are C++ (name-mangled).
bool cccaster_imgui_sdl2_init(void* window, void* gl_context);
void cccaster_imgui_sdl2_shutdown(void);
void cccaster_imgui_sdl2_newframe(void);
bool cccaster_imgui_sdl2_process_event(const void* event);

bool cccaster_imgui_opengl3_init(const char* glsl_version);
void cccaster_imgui_opengl3_shutdown(void);
void cccaster_imgui_opengl3_newframe(void);
void cccaster_imgui_opengl3_render(ImDrawData* draw_data);

#ifdef __cplusplus
}
#endif
