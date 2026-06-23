const std = @import("std");

pub fn build(b: *std.Build) void {
    // both zzcaster and hook.dll are 32 bit applications, so we force the build to be x86
    const user_target = b.standardTargetOptions(.{});
    if (user_target.result.os.tag == .windows and user_target.result.cpu.arch != .x86) {
        std.debug.panic(
            "zzcaster requires -Dtarget=x86-windows-gnu on Windows (got {s}-windows). " ++
                "hook.dll must be 32-bit to inject into MBAA.exe (also 32-bit).",
            .{@tagName(user_target.result.cpu.arch)},
        );
    }
    const target = user_target;
    const optimize = b.standardOptimizeOption(.{});

    // Detect vendored SDL2 MinGW copy (created by scripts/fetch-deps.sh).
    const sdl2_mingw_dir = b.pathFromRoot("libs/sdl2-mingw");
    const io = b.graph.io;
    const cwd = std.Io.Dir.cwd();
    const sdl2_mingw_present = blk: {
        var dir = cwd.openDir(io, sdl2_mingw_dir, .{}) catch break :blk false;
        dir.close(io);
        break :blk true;
    };

    const sdl2_arch_subdir: []const u8 = switch (target.result.cpu.arch) {
        .x86 => "i686-w64-mingw32",
        .x86_64 => "x86_64-w64-mingw32",
        else => "i686-w64-mingw32",
    };

    const sdl2_arch_dir = if (sdl2_mingw_present)
        b.pathJoin(&.{ sdl2_mingw_dir, sdl2_arch_subdir })
    else
        "";

    // Helper: link SDL2 into a module.
    const sdl2_linker = struct {
        fn link(mod: *std.Build.Module, arch_dir: []const u8, present: bool, builder: *std.Build) void {
            if (present) {
                const inc = builder.pathJoin(&.{ arch_dir, "include" });
                const lib = builder.pathJoin(&.{ arch_dir, "lib" });
                mod.addIncludePath(.{ .cwd_relative = inc });
                mod.addLibraryPath(.{ .cwd_relative = lib });
                mod.linkSystemLibrary("SDL2", .{});
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
                mod.linkSystemLibrary("SDL2", .{});
            }
        }
    };

    // === ENet (compile from source) ===
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

    // ====================================================================
    // Named modules — allow cross-directory @import via module names.
    //
    // Module hierarchy:
    //   common  — logging, config, ipc (shared by launcher + dll)
    //   net     — enet_transport, ip_discovery (shared by launcher + dll)
    //   dll     — hook.dll code (imports common + net)
    //   launcher — zzcaster.exe code (imports common + net + dll)
    //
    // In source code, use @import("common").logging, @import("net").enet, etc.
    // Files within the same module use relative @import("file.zig").
    // ====================================================================

    // --- common module ---
    const common_mod = b.createModule(.{
        .root_source_file = b.path("src/common/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // --- net module (imports common for logging) ---
    const net_mod = b.createModule(.{
        .root_source_file = b.path("src/net/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    net_mod.addImport("common", common_mod);
    net_mod.linkSystemLibrary("ws2_32", .{});
    net_mod.linkSystemLibrary("wininet", .{});
    net_mod.addIncludePath(b.path("libs/enet/include"));

    // --- dll module for hook.dll build (root = dllmain.zig, the DLL entry) ---
    const dll_mod = b.createModule(.{
        .root_source_file = b.path("src/dll/dllmain.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dll_mod.addImport("common", common_mod);
    dll_mod.addImport("net", net_mod);
    dll_mod.linkSystemLibrary("ws2_32", .{});
    dll_mod.linkSystemLibrary("psapi", .{});
    dll_mod.linkSystemLibrary("user32", .{});
    dll_mod.linkSystemLibrary("winmm", .{});
    dll_mod.linkSystemLibrary("setupapi", .{});
    dll_mod.linkSystemLibrary("imm32", .{});
    dll_mod.linkSystemLibrary("cfgmgr32", .{});
    dll_mod.linkSystemLibrary("version", .{});
    dll_mod.linkSystemLibrary("kernel32", .{});
    dll_mod.linkSystemLibrary("ole32", .{});
    dll_mod.linkSystemLibrary("oleaut32", .{});
    sdl2_linker.link(dll_mod, sdl2_arch_dir, sdl2_mingw_present, b);
    dll_mod.addIncludePath(b.path("libs/enet/include"));
    dll_mod.linkLibrary(enet);

    // --- dll export module (root = exports.zig, re-exports only the symbols
    // external consumers need) ---
    // Used by the launcher to import dll types (currently just
    // controller_mapper) without pulling in dllmain.zig (which has the
    // DLL-specific DllMain export) or the full DLL surface. Keeping this
    // narrow avoids recompiling netplay_manager/rollback/etc. into the
    // launcher when they're dead code there.
    const dll_export_mod = b.createModule(.{
        .root_source_file = b.path("src/dll/exports.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dll_export_mod.addImport("common", common_mod);
    dll_export_mod.addImport("net", net_mod);
    dll_export_mod.addIncludePath(b.path("libs/enet/include"));
    sdl2_linker.link(dll_export_mod, sdl2_arch_dir, sdl2_mingw_present, b);

    // --- launcher module (imports common + net + dll) ---
    const launcher_mod = b.createModule(.{
        .root_source_file = b.path("src/launcher/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    launcher_mod.addImport("common", common_mod);
    launcher_mod.addImport("net", net_mod);
    launcher_mod.addImport("dll", dll_export_mod);
    launcher_mod.linkSystemLibrary("ws2_32", .{});
    launcher_mod.linkSystemLibrary("psapi", .{});
    launcher_mod.linkSystemLibrary("user32", .{});
    launcher_mod.linkSystemLibrary("gdi32", .{});
    launcher_mod.linkSystemLibrary("shell32", .{});
    launcher_mod.linkSystemLibrary("wininet", .{});
    launcher_mod.linkSystemLibrary("advapi32", .{});
    launcher_mod.linkSystemLibrary("kernel32", .{});
    launcher_mod.linkSystemLibrary("iphlpapi", .{});
    launcher_mod.linkSystemLibrary("winmm", .{});
    launcher_mod.linkSystemLibrary("setupapi", .{});
    launcher_mod.linkSystemLibrary("imm32", .{});
    launcher_mod.linkSystemLibrary("version", .{});
    launcher_mod.linkSystemLibrary("ole32", .{});
    launcher_mod.linkSystemLibrary("oleaut32", .{});
    sdl2_linker.link(launcher_mod, sdl2_arch_dir, sdl2_mingw_present, b);
    launcher_mod.addIncludePath(b.path("libs/enet/include"));
    launcher_mod.linkLibrary(enet);

    // ImGui + cimgui
    launcher_mod.addIncludePath(b.path("libs/imgui"));
    launcher_mod.addIncludePath(b.path("libs/imgui/backends"));
    launcher_mod.addIncludePath(b.path("libs/cimgui"));
    launcher_mod.addIncludePath(b.path("src")); // for cimgui_shim.h
    if (sdl2_mingw_present) {
        const sdl2_inc = b.pathJoin(&.{ sdl2_arch_dir, "include/SDL2" });
        launcher_mod.addIncludePath(.{ .cwd_relative = sdl2_inc });
        const sdl2_inc_parent = b.pathJoin(&.{ sdl2_arch_dir, "include" });
        launcher_mod.addIncludePath(.{ .cwd_relative = sdl2_inc_parent });
    }
    launcher_mod.addCSourceFiles(.{
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
            "-I",
            "libs/imgui",
            "-I",
            "libs/cimgui",
        },
    });
    launcher_mod.linkSystemLibrary("opengl32", .{});

    // === zzcaster.exe ===
    const exe = b.addExecutable(.{
        .name = "zzcaster",
        .root_module = launcher_mod,
    });
    b.installArtifact(exe);

    // === Embed Windows icon (assets/icon.rc → .res via Zig's built-in
    // Win32 resource compiler, then linked into zzcaster.exe) ===
    if (target.result.os.tag == .windows) {
        launcher_mod.addWin32ResourceFile(.{
            .file = b.path("assets/icon.rc"),
            // windres wants the .ico to be findable; pass the assets
            // directory as an include path so the relative
            // `ICON "icon.ico"` reference inside icon.rc resolves
            // even when windres is invoked from the build cache.
            .include_paths = &.{b.path("assets")},
        });
    }

    // === hook.dll ===
    const hook = b.addLibrary(.{
        .name = "hook",
        .root_module = dll_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(hook);

    // _X86_ macro for 32-bit targets (needed by mingw headers in @cImport)
    if (target.result.cpu.arch == .x86) {
        enet_mod.c_macros.append(b.allocator, "-D_X86_=1") catch @panic("OOM");
        net_mod.c_macros.append(b.allocator, "-D_X86_=1") catch @panic("OOM");
        launcher_mod.c_macros.append(b.allocator, "-D_X86_=1") catch @panic("OOM");
        dll_mod.c_macros.append(b.allocator, "-D_X86_=1") catch @panic("OOM");
        dll_export_mod.c_macros.append(b.allocator, "-D_X86_=1") catch @panic("OOM");
    }

    // === Run step ===
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zzcaster");
    run_step.dependOn(&run_cmd.step);

    const common_test_mod = b.createModule(.{
        .root_source_file = b.path("src/common/mod.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const common_tests = b.addTest(.{
        .root_module = common_test_mod,
    });
    const run_common_tests = b.addRunArtifact(common_tests);

    // air_dash_macro.zig is pure std (no Win32/SDL/game-memory deps), so like
    // the common module it host-tests cleanly. Build a fresh test module
    // rather than reusing the cross-compiled dll module.
    const air_dash_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dll/air_dash_macro.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const air_dash_tests = b.addTest(.{
        .root_module = air_dash_test_mod,
    });
    const run_air_dash_tests = b.addRunArtifact(air_dash_tests);

    const test_step = b.step("test", "Run unit tests (host)");
    test_step.dependOn(&run_common_tests.step);
    test_step.dependOn(&run_air_dash_tests.step);
}
