// Root of the `dll` module imported by the launcher. Re-exports only the
// symbols external consumers need, so the launcher doesn't pull in the full
// DLL surface. Internal dll/ files use relative @import directly.
pub const controller_mapper = @import("controller_mapper.zig");
