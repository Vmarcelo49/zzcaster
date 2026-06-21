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

// cimgui uses ImVec2_c for by-value parameters
typedef struct ImVec2_c { float x, y; } ImVec2_c;
typedef struct ImVec4_c { float x, y, z, w; } ImVec4_c;

// ImGui window flags
typedef int ImGuiWindowFlags;
#define ImGuiWindowFlags_NoTitleBar 1
#define ImGuiWindowFlags_NoResize 2
#define ImGuiWindowFlags_NoMove 4
#define ImGuiWindowFlags_NoCollapse 16
#define ImGuiWindowFlags_NoBringToFrontOnFocus 8192

// ImGui input text flags
typedef int ImGuiInputTextFlags;

// ImGui conditions
#define ImGuiCond_Always 1

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
void igSetClipboardText(const char* text);

// Child windows
bool igBeginChild_Str(const char* str_id, ImVec2_c size, bool border, ImGuiWindowFlags flags);
void igEndChild(void);

// Selectable
bool igSelectable_Bool(const char* label, bool selected, int flags, ImVec2_c size);

// Radio buttons and combo boxes
bool igRadioButton_Bool(const char* label, bool active);
bool igCombo_Str_arr(const char* label, int* current_item, const char* const items[], int items_count, int popup_max_height_in_items);

// Layout helpers
void igDummy(ImVec2_c size);
void igIndent(float indent_w);
void igUnindent(float indent_w);

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
