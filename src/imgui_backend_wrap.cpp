// imgui_backend_wrap.cpp — C wrappers for ImGui SDL2/OpenGL3 backend functions.
// The backend functions in imgui_impl_sdl2.cpp/imgui_impl_opengl3.cpp are C++
// (name-mangled). We need C-linkage wrappers so Zig's @cImport shim can call them.
#include "imgui.h"
#include "imgui_impl_sdl2.h"
#include "imgui_impl_opengl3.h"
#include <SDL2/SDL.h>

extern "C" {

bool cccaster_imgui_sdl2_init(void* window, void* gl_context) {
    return ImGui_ImplSDL2_InitForOpenGL((SDL_Window*)window, gl_context);
}

void cccaster_imgui_sdl2_shutdown(void) {
    ImGui_ImplSDL2_Shutdown();
}

void cccaster_imgui_sdl2_newframe(void) {
    ImGui_ImplSDL2_NewFrame();
}

bool cccaster_imgui_sdl2_process_event(const void* event) {
    return ImGui_ImplSDL2_ProcessEvent((const SDL_Event*)event);
}

bool cccaster_imgui_opengl3_init(const char* glsl_version) {
    return ImGui_ImplOpenGL3_Init(glsl_version);
}

void cccaster_imgui_opengl3_shutdown(void) {
    ImGui_ImplOpenGL3_Shutdown();
}

void cccaster_imgui_opengl3_newframe(void) {
    ImGui_ImplOpenGL3_NewFrame();
}

void cccaster_imgui_opengl3_render(ImDrawData* draw_data) {
    ImGui_ImplOpenGL3_RenderDrawData(draw_data);
}

} // extern "C"
