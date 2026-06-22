// Minimal C glue for DLL exports that Zig's build system needs.
// This file ensures the DLL has proper exports for CreateRemoteThread(LoadLibraryA).

// The DllMain is defined in dllmain.zig and exported via `pub export`.
// This file is for any C-only glue that's easier to express in C.
