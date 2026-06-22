// exports.zig — narrow cross-module export surface for the dll package.
//
// This file is the root of the `dll` module that the launcher imports
// (build.zig: dll_export_mod). It re-exports ONLY the symbols external
// consumers actually need, so the launcher doesn't pull in the entire DLL
// surface (dllmain, netplay_manager, rollback, asm_hacks, etc.).
//
// The launcher currently imports exactly one thing from dll: controller_mapper
// (the input-binding types + save/load helpers shared between the launcher's
// config UI and the DLL's runtime reader). If more dll types are needed by
// the launcher in the future, add them here explicitly — don't barrel-export
// the whole package.
//
// Internal dll/ files do NOT import through this file; they use relative
// @import("file.zig") directly.
pub const controller_mapper = @import("controller_mapper.zig");
