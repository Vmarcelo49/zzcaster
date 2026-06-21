# C interop: `@cImport` deprecated, use `b.addTranslateC`

In Zig 0.16, `@cImport` is deprecated. It still works as a transition aid (now backed by
Aro, the new C parser, instead of libclang), but the supported path is `b.addTranslateC`
in `build.zig`. This compiles C headers to a Zig module at build time, with caching,
parallelism, and clean import boundaries.

## Table of contents

1. [Why `@cImport` is being retired](#why-cimport-is-being-retired)
2. [The new pattern: `b.addTranslateC`](#the-new-pattern-baddtranslatec)
3. [Consuming the translated module](#consuming-the-translated-module)
4. [Handling C standard library headers](#handling-c-standard-library-headers)
5. [Including vendor C libraries](#including-vendor-c-libraries)
6. [C++ wrappers: you still need a hand-written `extern "C"` shim](#c-wrappers-you-still-need-a-hand-written-extern-c-shim)
7. [Common pitfalls](#common-pitfalls)
8. [Migrating from `@cImport`](#migrating-from-cimport)

## Why `@cImport` is being retired

`@cImport` had three problems:

1. **Slow incremental builds.** It ran on every compile, even if the headers hadn't
   changed. The result wasn't cached.
2. **Tied to libclang.** Shipping libclang in the Zig distribution was a maintenance
   burden and a license concern.
3. **Polluted the import graph.** `@cImport` lived inline at the call site, so the C
   translation was re-evaluated per-file.

In 0.16, the new path is:

- **Aro** (Zig's own C parser) now backs `@cImport` as a transition aid.
- `b.addTranslateC` is the supported path — it produces a cached Zig module.
- The long-term plan is to remove `@cImport` entirely in 0.17.

## The new pattern: `b.addTranslateC`

Create a small "umbrella" C header that includes everything you need from C:

```c
// src/c_imports.h
#include <stdint.h>
#include <stdbool.h>

#include "vendor/foo.h"
#include "vendor/bar.h"
```

Then in `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = exe_mod,
    });

    // Translate the C umbrella header to a Zig module
    const c_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/c_imports.h"),
        .target = target,
        .optimize = optimize,
    });

    // Make it importable from Zig as `c`
    exe_mod.addImport("c", c_mod);

    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the app").dependOn(&run.step);
}
```

The translation runs once and is cached; subsequent builds skip it unless the headers
change.

## Consuming the translated module

```zig
// src/main.zig
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    const stdout = init.io.out();
    // Call a C function from vendor/foo.h
    const result = c.foo_add(3, 4);
    try stdout.print("3 + 4 = {d}\n", .{result});
}
```

The translated module exposes:
- C functions → Zig `extern fn` declarations
- C `#define` constants → Zig `pub const` of the appropriate type
- C `typedef`s → Zig `pub const T = ...;`
- C `struct`s → Zig `extern struct`s with matching layout
- C `enum`s → Zig `enum(c_int)` (with explicit backing type)
- C macros → only the simple ones (constant integer / string macros)

For macros that don't translate cleanly (function-like macros), you need to write a small
inline wrapper in C.

## Handling C standard library headers

Platform-specific headers (`<windows.h>`, `<sys/mman.h>`, `<mach/mach.h>`) require the
correct target to be set. `addTranslateC` inherits `target` from the build options.

```c
// src/c_imports.h
#if defined(__linux__)
#include <sys/mman.h>
#include <sys/socket.h>
#elif defined(__APPLE__)
#include <mach/mach.h>
#elif defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif
```

Translation errors are common with system headers — Aro is stricter than libclang in some
ways. If you hit a parse error, check the [Aro
docs](https://github.com/Vexu/arocc) for known incompatibilities, or include only the
specific headers you actually use.

## Including vendor C libraries

Two scenarios:

### A. The vendor library is just headers (header-only)

Put the headers somewhere `addTranslateC` can find them via `addIncludePath`:

```zig
const c_mod = b.addTranslateC(.{
    .root_source_file = b.path("src/c_imports.h"),
    .target = target,
    .optimize = optimize,
});
c_mod.addIncludePath(b.path("vendor/foo/include"));

exe_mod.addImport("c", c_mod);
```

```c
// src/c_imports.h
#include "foo.h"   // found via the addIncludePath above
```

### B. The vendor library is compiled C code

You need to compile the C source alongside the translation:

```zig
// Compile the vendor library as a static lib
const foo_lib = b.addStaticLibrary(.{
    .name = "foo",
    .target = target,
    .optimize = optimize,
});
foo_lib.addCSourceFile(.{
    .file = b.path("vendor/foo/foo.c"),
    .flags = &.{ "-std=c11", "-O2", "-fno-sanitize=undefined" },
});
foo_lib.addIncludePath(b.path("vendor/foo"));
foo_lib.linkLibC();

// Link it into the exe
exe.linkLibrary(foo_lib);

// Also translate its header for Zig to call into
const c_mod = b.addTranslateC(.{
    .root_source_file = b.path("src/c_imports.h"),
    .target = target,
    .optimize = optimize,
});
c_mod.addIncludePath(b.path("vendor/foo"));
exe_mod.addImport("c", c_mod);
```

You can compile multiple C files with `addCSourceFiles`:

```zig
foo_lib.addCSourceFiles(&.{
    "vendor/foo/foo.c",
    "vendor/foo/bar.c",
    "vendor/foo/baz.c",
}, &.{
    "-std=c11",
    "-O2",
});
```

## C++ wrappers: you still need a hand-written `extern "C"` shim

`b.addTranslateC` only handles C, not C++. If you're binding to a C++ library (like Dear
ImGui, which is C++), you need a small `extern "C"` wrapper:

```cpp
// vendor/imgui_shim.h
#pragma once
#include "imgui.h"

#ifdef __cplusplus
extern "C" {
#endif

void shim_imgui_begin(const char* name);
void shim_imgui_end(void);
int  shim_imgui_button(const char* label);
void shim_imgui_text(const char* fmt);

#ifdef __cplusplus
}
#endif
```

```cpp
// vendor/imgui_shim.cpp
#include "imgui_shim.h"

void shim_imgui_begin(const char* name) { ImGui::Begin(name); }
void shim_imgui_end(void) { ImGui::End(); }
int shim_imgui_button(const char* label) { return ImGui::Button(label) ? 1 : 0; }
void shim_imgui_text(const char* fmt) { ImGui::Text("%s", fmt); }
```

Compile the C++ source (note `link_libcpp = true`):

```zig
const imgui_lib = b.addStaticLibrary(.{
    .name = "imgui_shim",
    .target = target,
    .optimize = optimize,
});
imgui_lib.linkLibCpp();   // important: enables C++ compilation
imgui_lib.addCSourceFile(.{
    .file = b.path("vendor/imgui_shim.cpp"),
    .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" },
});
imgui_lib.addIncludePath(b.path("vendor/imgui"));
imgui_lib.addIncludePath(b.path("vendor/imgui/backends"));

exe.linkLibrary(imgui_lib);

const c_mod = b.addTranslateC(.{
    .root_source_file = b.path("src/c_imports.h"),
    .target = target,
    .optimize = optimize,
});
c_mod.addIncludePath(b.path("vendor"));
exe_mod.addImport("c", c_mod);
```

```c
// src/c_imports.h
#include "imgui_shim.h"
```

```zig
// src/main.zig
const c = @import("c");

fn drawUi() void {
    c.shim_imgui_begin("Hello");
    if (c.shim_imgui_button("Click") != 0) {
        c.shim_imgui_text("clicked!");
    }
    c.shim_imgui_end();
}
```

For a fully worked example with Dear ImGui, see the
[imgui-desktop skill](../../download/imgui-desktop/SKILL.md).

## Common pitfalls

### Variadic functions

C variadic functions (like `printf`) are awkward in Zig. Either:
1. Use `@cVaStart` / `@cVaArg` / `@cVaEnd` (still works in 0.16).
2. Write a non-variadic wrapper on the C side: `void shim_printf(const char* fmt)` and use
   a fixed format string.

The wrapper approach is usually cleaner.

### String lifetimes

If a C function returns a `const char*` that points to internal static memory, you must
copy it immediately:

```zig
const s = c.foo_get_string();
const owned = try arena.dupe(u8, std.mem.sliceTo(s, 0));
// s may be invalidated by the next call to foo_*
```

If the C function returns a `char*` that the caller must free, you need to call `c.free`
(or whatever the library's free function is) — `gpa.free` won't work because the memory
came from C's allocator.

### `InputText` and mutable buffers

```zig
var buf: [256]u8 = std.mem.zeroes([256]u8);
@memcpy(buf[0..5], "hello");
const changed = c.shim_imgui_input_text("name", &buf, buf.len);
```

The buffer must be mutable (`var`, not `const`) and NUL-terminated.

### Struct layout

`@cImport` and `b.addTranslateC` produce `extern struct` types — these have C-compatible
layout. Don't try to use them as regular Zig structs (no default values, no methods, no
comptime fields).

### Callbacks

C function pointers come through as `?*const fn (...) callconv(.c) ...`. To pass a Zig
function as a callback, it must be `callconv(.c)`:

```zig
fn myCallback(user_data: ?*anyopaque, event: c_int) callconv(.c) c_int {
    // ...
    return 0;
}

c.register_callback(@ptrCast(&myCallback), @ptrCast(&my_state));
```

The `callconv(.c)` is mandatory — Zig's default calling convention is not C.

### `#define` macros that don't translate

Function-like macros (`#define FOO(x) ((x) + 1)`) are not translated. Either:
1. Wrap in an inline C function: `static inline int foo(int x) { return FOO(x); }`
2. Replicate the macro in Zig directly: `fn foo(x: i32) i32 { return x + 1; }`

### Wide strings on Windows

`L"foo"` becomes `[*:0]const u16` in Zig. Use `std.unicode.wtf8ToWtf16Le` to convert.

## Migrating from `@cImport`

A mechanical migration:

### Before

```zig
const c = @cImport({
    @cInclude("foo.h");
    @cDefine("FOO_USE_FEATURE_X", "1");
});
```

### After

1. Create `src/c_imports.h`:

```c
#define FOO_USE_FEATURE_X 1
#include "foo.h"
```

2. Update `build.zig` to call `b.addTranslateC` and `addImport("c", c_mod)`.

3. Replace any per-file `@cImport` blocks with `@import("c")`.

4. Search your codebase for:
   - `@cInclude(` — should be gone
   - `@cDefine(` — moved into `c_imports.h`
   - `@cUndef(` — moved into `c_imports.h`

5. Run `zig build` and fix any errors caused by:
   - Missing includes (add to `c_imports.h`)
   - Macro expansion differences (Aro is stricter than libclang)
   - Type layout differences (rare; check `@sizeOf` and `@offsetOf` against C)

The migration is usually straightforward; plan on a half-day for a moderately sized
codebase.

## See also

- [build-system.md](build-system.md) — Build system reference
- The [imgui-desktop skill](../../download/imgui-desktop/SKILL.md) — Full worked example
  with `addTranslateC` and a C++ wrapper
