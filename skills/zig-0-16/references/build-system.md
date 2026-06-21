# Build system in Zig 0.16: `build.zig` and `build.zig.zon`

The build system got incremental compilation, package forking, and a new zon format
requirement. This reference covers everything you need to write and debug a 0.16 build.

## Table of contents

1. [`build.zig.zon` changes](#buildzigzon-changes)
2. [Minimal `build.zig`](#minimal-buildzig)
3. [Modules, dependencies, and `addImport`](#modules-dependencies-and-addimport)
4. [Compiling C and C++](#compiling-c-and-c)
5. [Tests](#tests)
6. [Cross-compilation](#cross-compilation)
7. [`-fincremental --watch`](#-fincremental---watch)
8. [`--fork=<path>` for local package overrides](#--forkpath-for-local-package-overrides)
9. [Custom steps](#custom-steps)
10. [`fingerprint` generation](#fingerprint-generation)

## `build.zig.zon` changes

The package manifest got three breaking changes in 0.16:

### 1. `name` must be an enum-literal

```zig
// WRONG — 0.15 (string with hyphens)
.{
    .name = "my-package",
    .version = "0.1.0",
}

// CORRECT — 0.16 (enum literal, underscores only)
.{
    .name = .my_package,
    .version = "0.1.0",
}
```

The enum-literal form prevents typos and makes the name usable as an identifier in
`build.zig`.

### 2. `fingerprint` is required

```zig
.{
    .name = .my_package,
    .fingerprint = 0x9a3c1f8b7e2d4a01,   // u64, required
    .version = "0.1.0",
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}
```

The `fingerprint` is a u64 that uniquely identifies your package. It's used in the
dependency cache to disambiguate packages with the same name from different sources.
Generate one with `scripts/gen-fingerprint.sh` (in this skill) or with `openssl rand
-hex 8`.

### 3. Dependencies fetch into `./zig-pkg/`

Previously, dependencies were cached in `.zig-cache/dep/` (and before that, in
`.zig-cache/`). In 0.16 they live in `./zig-pkg/` at the project root. This separates
fetched source from compiler cache, making it easier to inspect or gitignore.

```gitignore
# .gitignore
.zig-cache/
.zig-out/
zig-pkg/
```

The hash format for `deps` is also updated; old hashes from 0.15 won't work. Re-fetch
with `zig build` to regenerate.

## Minimal `build.zig`

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
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
```

Note the shape that's been stable since 0.15: `b.createModule` → `b.addExecutable(.{
.root_module = mod })`. The old `root_source_file` field on `addExecutable` is gone.

## Modules, dependencies, and `addImport`

The unit of code organization is the **module**. Modules can import each other via
`addImport`.

### Adding a local module

```zig
const utils_mod = b.createModule(.{
    .root_source_file = b.path("src/utils.zig"),
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("utils", utils_mod);
```

```zig
// src/main.zig
const utils = @import("utils");
```

### Adding a dependency from zon

In `build.zig.zon`:

```zig
.{
    .name = .my_app,
    .fingerprint = 0x9a3c1f8b7e2d4a01,
    .version = "0.1.0",
    .dependencies = .{
        .zsdl = .{
            .url = "git+https://github.com/zig-gamedev/zsdl.git#v0.2.0",
            .hash = "1220e1b4c8f5e9c0d8a3b7e6c5d4e3f2a1b9c8d7e6f5a4b3c2d1e0f9a8b7c6d5e4",
        },
    },
}
```

Fetch:

```bash
zig fetch --save git+https://github.com/zig-gamedev/zsdl.git#v0.2.0
```

(This updates `build.zig.zon` automatically.)

In `build.zig`:

```zig
const zsdl_dep = b.dependency("zsdl", .{
    .target = target,
    .optimize = optimize,
});
const zsdl_mod = zsdl_dep.module("zsdl");
exe_mod.addImport("zsdl", zsdl_mod);
```

```zig
// src/main.zig
const zsdl = @import("zsdl");
```

### Multiple modules from one dependency

A package can expose multiple modules:

```zig
const dep = b.dependency("zgui", .{
    .target = target,
    .optimize = optimize,
    .backend = .sdl3_opengl3,
});
const zgui_mod = dep.module("zgui");
const zgui_backend_mod = dep.module("zgui-backend");
exe_mod.addImport("zgui", zgui_mod);
exe_mod.addImport("zgui-backend", zgui_backend_mod);
```

## Compiling C and C++

See [c-interop.md](c-interop.md) for the full story. Quick reference:

```zig
// Compile a C library
const foo_lib = b.addStaticLibrary(.{
    .name = "foo",
    .target = target,
    .optimize = optimize,
});
foo_lib.addCSourceFile(.{
    .file = b.path("vendor/foo.c"),
    .flags = &.{ "-std=c11", "-O2" },
});
foo_lib.linkLibC();

// Compile a C++ library
const bar_lib = b.addStaticLibrary(.{
    .name = "bar",
    .target = target,
    .optimize = optimize,
});
bar_lib.linkLibCpp();   // important
bar_lib.addCSourceFile(.{
    .file = b.path("vendor/bar.cpp"),
    .flags = &.{ "-std=c++17", "-fno-exceptions", "-fno-rtti" },
});

// Link into exe
exe.linkLibrary(foo_lib);
exe.linkLibrary(bar_lib);

// Translate C headers
const c_mod = b.addTranslateC(.{
    .root_source_file = b.path("src/c_imports.h"),
    .target = target,
    .optimize = optimize,
});
exe_mod.addImport("c", c_mod);
```

## Tests

```zig
const test_step = b.step("test", "Run unit tests");

const unit_tests = b.addTest(.{
    .root_module = exe_mod,
});
const run_unit_tests = b.addRunArtifact(unit_tests);
test_step.dependOn(&run_unit_tests.step);
```

Run with:

```bash
zig build test
zig build test --test-timeout=500ms        # surface hung tests
zig build test --test-filter "Parser"      # run only matching tests
zig build test --test-no-exec              # compile tests but don't run
```

### Testing with `std.testing.io`

Tests should use `std.testing.io` for deterministic I/O:

```zig
test "io test" {
    var io_state = std.testing.io;
    const io = &io_state.io;

    // ... do stuff with io ...

    try io_state.flush();
    // io_state.stdout_written contains the captured output
    try std.testing.expectEqualStrings("hello\n", io_state.stdout_written);
}
```

## Cross-compilation

```bash
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows-msvc
zig build -Dtarget=wasm32-wasi
```

Cross-compilation works for both the Zig code and any C/C++ you compile alongside it. The
Zig compiler bundles cross-compiled libc for musl, glibc, mingw, and WASI.

## `-fincremental --watch`

The big new workflow feature in 0.16: near-instant compile errors as you save.

```bash
zig build -fincremental --watch
```

This runs the build once, then watches your source files. When you save, it does an
incremental compile and shows errors in under a second (typically 200-500ms on a modern
machine). The LLVM backend is supported — you don't need to drop to the self-hosted
backend.

Incremental compilation is still off by default (it's marked experimental) but the 0.16
release notes call it "much more stable than 0.15" and recommend enabling it for
development.

To enable always:

```bash
# .zshrc / .bashrc
alias zb='zig build -fincremental --watch'
```

## `--fork=<path>` for local package overrides

Need to patch a dependency without forking it on GitHub? Use `--fork`:

```bash
zig build --fork=/home/me/zsdl-patches
```

This overrides the `zsdl` dependency across the entire dependency tree (including
transitive deps) with the local copy at `/home/me/zsdl-patches`. The local copy must have
a `build.zig.zon` with the same `name`.

Use cases:
- Debugging a dependency issue (add prints, rebuild).
- Trying a patch before upstreaming it.
- Pinning to a specific commit by URL without editing every `zon` in the tree.

## Custom steps

```zig
// A "fmt" step that runs zig fmt
const fmt_step = b.step("fmt", "Format source");
const fmt_cmd = b.addSystemCommand(&.{ "zig", "fmt", "src" });
fmt_step.dependOn(&fmt_cmd.step);

// A "lint" step that runs a custom linter
const lint_step = b.step("lint", "Run linter");
const lint_cmd = b.addSystemCommand(&.{ "python3", "scripts/lint.py" });
lint_step.dependOn(&lint_cmd.step);

// A "coverage" step that runs tests with coverage
const coverage_step = b.step("coverage", "Generate coverage");
const cov_cmd = b.addSystemCommand(&.{ "kcov", "--include-pattern=src/", "cov-out", "zig-out/bin/test" });
coverage_step.dependOn(&run_unit_tests.step);
coverage_step.dependOn(&cov_cmd.step);
```

## `fingerprint` generation

The `fingerprint` field in `build.zig.zon` must be a u64. Generate one:

```bash
# Method 1: openssl
openssl rand -hex 8

# Method 2: /dev/urandom
od -An -tu8 -N8 /dev/urandom | awk '{ print "0x" sprintf("%016x", $1) }'

# Method 3: this skill's helper script
bash /home/z/my-project/skills/zig-0-16/scripts/gen-fingerprint.sh
```

Paste the result into your `build.zig.zon`:

```zig
.{
    .name = .my_package,
    .fingerprint = 0x9a3c1f8b7e2d4a01,
    .version = "0.1.0",
    .paths = .{ "src", "build.zig", "build.zig.zon" },
}
```

If you forget, the error message tells you:

```
error: build.zig.zon is missing required field 'fingerprint'
```

## Common mistakes

### Using `root_source_file` instead of `root_module`

```zig
// WRONG
const exe = b.addExecutable(.{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),   // removed in 0.15
    .target = target,
    .optimize = optimize,
});

// CORRECT
const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = exe_mod,
});
```

### Forgetting `.linkLibC()` / `.linkLibCpp()`

If you compile C code with `addCSourceFile`, you must `linkLibC()` on the library or
executable, otherwise libc symbols won't resolve. Same for C++ and `linkLibCpp()`.

### Wrong `optimize` for tests

Tests default to `Debug`. If you want to test `ReleaseFast` behavior:

```bash
zig build test -Doptimize=ReleaseFast
```

### Not propagating `target` and `optimize` to dependencies

When you call `b.dependency("foo", .{ ... })`, you must pass `.target = target` and
`.optimize = optimize`. Otherwise the dependency builds with default options and may not
link cleanly.

## See also

- [c-interop.md](c-interop.md) — `b.addTranslateC` and C/C++ compilation
- [migration-015-016.md](migration-015-016.md) — End-to-end porting walkthrough
