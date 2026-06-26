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

    // Default the 32-bit x86 build to the Haswell micro-architecture when the
    // user did NOT pass `-Dcpu=...`. This enables AVX2 / SSE4.2 code generation
    // in `@memcpy`, which the rollbacks hot path benefits from heavily. Users
    // can still opt out with `-Dcpu=baseline` for legacy x86 CPUs.
    //
    // Why Haswell (not Skylake / Zen3+): Haswell is the lowest-tier x86 with
    // AVX2 — every MBAACC player machine (Intel Haswell+, AMD Zen+) supports
    // it. Going higher (znver3, skylake) adds tuning hints that aren't worth
    // the risk of breaking on older CPUs (e.g. first-gen Zen / Broadwell-Iris).
    // Users on newer hardware can pass `-Dcpu=znver3` (or whatever) explicitly.
    //
    // See docs/dll-optimization-plan.md Strategy B + the experiment table there
    // for the SHA-256/size delta that confirms `-Dcpu=haswell` produces distinct
    // machine code.
    //
    // `user_target.query.cpu_model == .determined_by_arch_os` is the default
    // when the user did not pass `-Dcpu=...` (see standardTargetOptionsQueryOnly
    // and Target.Query.parse). We override only that case.
    var target_query = user_target.query;
    if (user_target.result.cpu.arch == .x86 and
        target_query.cpu_model == .determined_by_arch_os)
    {
        target_query.cpu_model = .{ .explicit = &std.Target.x86.cpu.haswell };
    }
    const target = b.resolveTargetQuery(target_query);

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

    // === Patch zgui's bundled imgui_impl_sdl2.cpp ===
    // The pinned zgui commit (bfbebed3) bundles an imgui_impl_sdl2.cpp that
    // redeclares `enum ImGui_ImplSDL2_GamepadMode` and re-specifies default
    // arguments on `ImGui_ImplSDL2_SetGamepadMode` — both already declared
    // in imgui_impl_sdl2.h (which the .cpp #includes at line 112). C++ forbids
    // both forms of redeclaration, producing 3 compile errors that block the
    // build. scripts/patch-zgui.sh strips the duplicate lines idempotently.
    // We run it as a build step that the imgui artifact depends on, so the
    // patch is applied before the .cpp is compiled.
    // Safe to remove once zgui is bumped to a fixed upstream commit.
    const patch_zgui = b.addSystemCommand(&.{ "bash", "scripts/patch-zgui.sh" });

    // ImGui + zgui
    const zgui_dep = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl2_opengl3,
    });
    // Run the patch before imgui is compiled (the .cpp is read by the
    // compiler at compile time, not at build.zig evaluation time, so
    // patching the file on disk between dependency resolution and the
    // compile step is sufficient).
    zgui_dep.artifact("imgui").step.dependOn(&patch_zgui.step);
    launcher_mod.addImport("zgui", zgui_dep.module("root"));
    launcher_mod.linkLibrary(zgui_dep.artifact("imgui"));

    if (sdl2_mingw_present) {
        const sdl2_inc = b.pathJoin(&.{ sdl2_arch_dir, "include/SDL2" });
        zgui_dep.artifact("imgui").root_module.addIncludePath(.{ .cwd_relative = sdl2_inc });
        const sdl2_inc_parent = b.pathJoin(&.{ sdl2_arch_dir, "include" });
        zgui_dep.artifact("imgui").root_module.addIncludePath(.{ .cwd_relative = sdl2_inc_parent });
    }
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

    // Net module tests — relay_protocol.zig and relay_config.zig have
    // pure-logic tests (wire format encode/decode, list parsing) with
    // no Win32 deps. We run them as separate test targets pointing at
    // the individual files, NOT at src/net/mod.zig — that would pull
    // in nat_probe.zig (which has `extern "ws2_32"` calls to
    // WSAStartup, a Windows-only symbol not in Linux libc) and
    // enet_transport.zig (which @cImports the enet C headers).
    //
    // nat_probe.zig's tests are logic-only (NAT type enum methods) but
    // the file's function bodies call WSAStartup. Rather than risk the
    // linker failing on undefined WSAStartup, we test the pure-logic
    // files individually. nat_probe.zig will be tested via the actual
    // launcher binary once Slice 3 integrates it.
    const net_protocol_test_mod = b.createModule(.{
        .root_source_file = b.path("src/net/relay_protocol.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const net_protocol_tests = b.addTest(.{
        .root_module = net_protocol_test_mod,
    });
    const run_net_protocol_tests = b.addRunArtifact(net_protocol_tests);

    const net_config_test_mod = b.createModule(.{
        .root_source_file = b.path("src/net/relay_config.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // relay_config.zig imports relay_protocol.zig via relative path
    // (@import("relay_protocol.zig")), which Zig resolves automatically
    // since both files are in src/net/. No addImport needed.
    const net_config_tests = b.addTest(.{
        .root_module = net_config_test_mod,
    });
    const run_net_config_tests = b.addRunArtifact(net_config_tests);

    // Integration tests for the full relay stack (protocol + config +
    // client non-network logic). Imports relay_client.zig for RelayError,
    // but only tests non-ws2_32 parts (room codes, wire format, parsing).
    const net_integration_test_mod = b.createModule(.{
        .root_source_file = b.path("src/net/relay_integration_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const net_integration_tests = b.addTest(.{
        .root_module = net_integration_test_mod,
    });
    const run_net_integration_tests = b.addRunArtifact(net_integration_tests);

    // Connection detector tests — pure logic, no Win32 deps
    const conn_detector_test_mod = b.createModule(.{
        .root_source_file = b.path("src/net/connection_detector.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const conn_detector_tests = b.addTest(.{
        .root_module = conn_detector_test_mod,
    });
    const run_conn_detector_tests = b.addRunArtifact(conn_detector_tests);

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

    // Standalone simulation tests (pure Zig, host-testable)
    const simulation_test_mod = b.createModule(.{
        .root_source_file = b.path("src/dll/test_simulation.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    simulation_test_mod.addImport("common", common_mod);
    const simulation_tests = b.addTest(.{
        .root_module = simulation_test_mod,
    });
    const run_simulation_tests = b.addRunArtifact(simulation_tests);

    const test_step = b.step("test", "Run unit tests (host)");
    test_step.dependOn(&run_common_tests.step);
    test_step.dependOn(&run_net_protocol_tests.step);
    test_step.dependOn(&run_net_config_tests.step);
    test_step.dependOn(&run_net_integration_tests.step);
    test_step.dependOn(&run_conn_detector_tests.step);
    test_step.dependOn(&run_air_dash_tests.step);
    test_step.dependOn(&run_simulation_tests.step);

    // Rollback micro-benchmark: measures save/load throughput for both
    // pre- and post-coalesced region layouts. Cross-compiled to the same
    // target as the DLL (x86-windows-gnu) so the numbers reflect the
    // 32-bit memcpy throughput that hook.dll will actually see, not the
    // host CPU's native 64-bit throughput. Run with:
    //   zig build bench
    //   zig build bench -Doptimize=ReleaseFast           # recommended
    //   zig build bench -Dcpu=baseline                    # no SIMD
    //   zig build bench -Dcpu=haswell                     # SIMD enabled
    //
    // Disabled for now — uncomment to re-enable building bench-rollback.exe.
    // const bench_exe = b.addExecutable(.{
    //     .name = "bench-rollback",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/dll/bench_rollback.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //         .link_libc = true,
    //     }),
    // });
    // b.installArtifact(bench_exe);
    // const run_bench = b.addRunArtifact(bench_exe);
    // const bench_step = b.step("bench", "Run rollback save/load micro-benchmark");
    // bench_step.dependOn(&run_bench.step);
}
