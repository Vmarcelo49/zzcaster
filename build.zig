const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Detect vendored SDL2 MinGW copy (created by scripts/fetch-deps.sh).
    // When present, use addIncludePath + addLibraryPath + linkObjectFile
    // instead of linkSystemLibrary("SDL2") — the latter uses pkg-config
    // which only finds the host's SDL2 dev package, not the MinGW copy.
    const sdl2_mingw_dir = b.pathFromRoot("libs/sdl2-mingw");
    // Zig 0.16: std.fs was rewritten into std.Io, and Dir methods now take an
    // explicit Io handle (exposed to build.zig as b.graph.io).
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const sdl2_mingw_present = blk: {
        var dir = cwd.openDir(io, sdl2_mingw_dir, .{}) catch break :blk false;
        dir.close(io);
        break :blk true;
    };

    // Pick the right SDL2 arch subdir based on target CPU arch.
    const sdl2_arch_subdir: []const u8 = switch (target.result.cpu.arch) {
        .x86 => "i686-w64-mingw32",
        .x86_64 => "x86_64-w64-mingw32",
        else => "i686-w64-mingw32", // fallback
    };

    const sdl2_arch_dir = if (sdl2_mingw_present)
        b.pathJoin(&.{ sdl2_mingw_dir, sdl2_arch_subdir })
    else
        "";

    // Helper: link SDL2 into a module using whichever strategy is appropriate.
    const sdl2_linker = struct {
        fn link(mod: *std.Build.Module, arch_dir: []const u8, present: bool, builder: *std.Build) void {
            if (present) {
                // Use the vendored MinGW copy.
                // Note: add the PARENT include dir (not .../include/SDL2) so
                // that @cImport(@cInclude("SDL2/SDL.h")) resolves correctly.
                const inc = builder.pathJoin(&.{ arch_dir, "include" });
                const lib = builder.pathJoin(&.{ arch_dir, "lib" });
                mod.addIncludePath(.{ .cwd_relative = inc });
                mod.addLibraryPath(.{ .cwd_relative = lib });
                mod.linkSystemLibrary("SDL2", .{});
                // SDL2 MinGW import lib transitively pulls in these Win32 APIs.
                // See libs/sdl2-mingw/<arch>/lib/pkgconfig/sdl2.pc for the full list.
                mod.linkSystemLibrary("mingw32", .{});
                mod.linkSystemLibrary("SDL2main", .{});
                mod.linkSystemLibrary("dinput8", .{});
                mod.linkSystemLibrary("dxguid", .{});
                mod.linkSystemLibrary("uuid", .{});
                mod.linkSystemLibrary("gdi32", .{});
                mod.linkSystemLibrary("ole32", .{});
                mod.linkSystemLibrary("oleaut32", .{});
                mod.linkSystemLibrary("shell32", .{});
                mod.linkSystemLibrary("winmm", .{});
                mod.linkSystemLibrary("imm32", .{});
                mod.linkSystemLibrary("setupapi", .{});
                mod.linkSystemLibrary("version", .{});
                mod.linkSystemLibrary("user32", .{});
                mod.linkSystemLibrary("kernel32", .{});
            } else {
                // Fall back to pkg-config / system library lookup.
                mod.linkSystemLibrary("SDL2", .{});
            }
        }
    };

    // === ENet (compile from source — it's pure C, ~2000 lines) ===
    const enet_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    enet_mod.addCSourceFiles(.{
        .files = &.{
            "libs/enet/callbacks.c",
            "libs/enet/compress.c",
            "libs/enet/host.c",
            "libs/enet/list.c",
            "libs/enet/packet.c",
            "libs/enet/peer.c",
            "libs/enet/protocol.c",
            "libs/enet/unix.c",
            "libs/enet/win32.c",
        },
        .flags = &.{"-DHAS_SOCKLEN_T=1"},
    });
    enet_mod.addIncludePath(b.path("libs/enet/include"));
    enet_mod.linkSystemLibrary("ws2_32", .{});

    const enet = b.addLibrary(.{
        .name = "enet",
        .root_module = enet_mod,
        .linkage = .static,
    });
    b.installArtifact(enet);

    // === cccaster.exe ===
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true, // ImGui is C++
    });
    exe_mod.linkSystemLibrary("ws2_32", .{});
    exe_mod.linkSystemLibrary("psapi", .{});
    exe_mod.linkSystemLibrary("user32", .{});
    exe_mod.linkSystemLibrary("gdi32", .{});
    exe_mod.linkSystemLibrary("shell32", .{});
    exe_mod.linkSystemLibrary("wininet", .{});
    exe_mod.linkSystemLibrary("advapi32", .{});
    exe_mod.linkSystemLibrary("kernel32", .{});
    // SDL2 MinGW import lib pulls in these Win32 APIs transitively.
    exe_mod.linkSystemLibrary("winmm", .{});
    exe_mod.linkSystemLibrary("setupapi", .{});
    exe_mod.linkSystemLibrary("imm32", .{});
    exe_mod.linkSystemLibrary("version", .{});
    exe_mod.linkSystemLibrary("ole32", .{});
    exe_mod.linkSystemLibrary("oleaut32", .{});
    sdl2_linker.link(exe_mod, sdl2_arch_dir, sdl2_mingw_present, b);
    // ENet
    exe_mod.addIncludePath(b.path("libs/enet/include"));
    exe_mod.linkLibrary(enet);

    // ImGui + cimgui (C API wrapper for Zig @cImport)
    exe_mod.addIncludePath(b.path("libs/imgui"));
    exe_mod.addIncludePath(b.path("libs/imgui/backends"));
    exe_mod.addIncludePath(b.path("libs/cimgui"));
    exe_mod.addIncludePath(b.path("src")); // for cimgui_shim.h
    // imgui_impl_sdl2.cpp includes <SDL.h> (not <SDL2/SDL.h>), so we need
    // the SDL2 subdirectory in the include path. Also needed for @cImport
    // of imgui_impl_sdl2.h in ui.zig.
    if (sdl2_mingw_present) {
        const sdl2_inc = b.pathJoin(&.{ sdl2_arch_dir, "include/SDL2" });
        exe_mod.addIncludePath(.{ .cwd_relative = sdl2_inc });
        // Also add the parent include dir so @cInclude("SDL2/SDL.h") works
        const sdl2_inc_parent = b.pathJoin(&.{ sdl2_arch_dir, "include" });
        exe_mod.addIncludePath(.{ .cwd_relative = sdl2_inc_parent });
    }
    exe_mod.addCSourceFiles(.{
        .files = &.{
            "libs/imgui/imgui.cpp",
            "libs/imgui/imgui_draw.cpp",
            "libs/imgui/imgui_tables.cpp",
            "libs/imgui/imgui_widgets.cpp",
            "libs/imgui/imgui_demo.cpp",
            "libs/cimgui/cimgui.cpp",
            "libs/imgui/backends/imgui_impl_sdl2.cpp",
            "libs/imgui/backends/imgui_impl_opengl3.cpp",
            "src/imgui_backend_wrap.cpp",
        },
        .flags = &.{
            "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS",
            "-I", "libs/imgui",
            "-I", "libs/cimgui",
        },
    });
    exe_mod.linkSystemLibrary("opengl32", .{});

    const exe = b.addExecutable(.{
        .name = "zzcaster",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // === hook.dll ===
    const hook_mod = b.createModule(.{
        .root_source_file = b.path("src/dllmain.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    hook_mod.linkSystemLibrary("ws2_32", .{});
    hook_mod.linkSystemLibrary("psapi", .{});
    hook_mod.linkSystemLibrary("user32", .{});
    hook_mod.linkSystemLibrary("winmm", .{});
    hook_mod.linkSystemLibrary("setupapi", .{});
    hook_mod.linkSystemLibrary("imm32", .{});
    hook_mod.linkSystemLibrary("cfgmgr32", .{});
    hook_mod.linkSystemLibrary("version", .{});
    hook_mod.linkSystemLibrary("kernel32", .{});
    // SDL2 MinGW import lib pulls in these Win32 APIs transitively.
    hook_mod.linkSystemLibrary("ole32", .{});
    hook_mod.linkSystemLibrary("oleaut32", .{});
    sdl2_linker.link(hook_mod, sdl2_arch_dir, sdl2_mingw_present, b);
    // ENet in the DLL too (for netplay)
    hook_mod.addIncludePath(b.path("libs/enet/include"));
    hook_mod.linkLibrary(enet);

    const hook = b.addLibrary(.{
        .name = "hook",
        .root_module = hook_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(hook);

    // Zig 0.16 mingw headers (any-windows-any/malloc.h) gate
    // _ALLOCA_S_MARKER_SIZE behind `defined(_X86_) && !defined(__x86_64)`.
    // Zig's clang front-end doesn't pre-define _X86_ on i686-windows-gnu
    // targets during @cImport parsing, so force it via each module's
    // c_macros (which propagate to both the C compile and the cimport
    // parser). (Same shim applies to winnt.h PCONTEXT — works once
    // _X86_ is set.) On x86_64-windows-gnu the macro isn't needed (mingw
    // defaults to the 64-bit arm/x86_64 branch of the #if).
    if (target.result.cpu.arch == .x86) {
        enet_mod.c_macros.append(b.allocator, "-D_X86_=1") catch @panic("OOM");
        exe_mod.c_macros.append(b.allocator, "-D_X86_=1") catch @panic("OOM");
        hook_mod.c_macros.append(b.allocator, "-D_X86_=1") catch @panic("OOM");
    }

    // === Run step ===
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run cccaster");
    run_step.dependOn(&run_cmd.step);
}
