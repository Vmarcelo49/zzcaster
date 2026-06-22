// ui.zig — Top-level UI entry points + main ImGui/SDL2 event loop.
//
// This file is the "shell" of the launcher UI. It owns:
//   - the SDL2 + OpenGL + ImGui init/teardown sequence
//   - the UiState / MenuPage enums (re-exported for use by ui_pages.zig and
//     ui_waiting_for_peer.zig)
//   - the per-frame state variables (input buffers, controller mapping,
//     netplay session, game launcher handles) that are threaded through
//     the page renderers
//   - the main loop's switch on UiState (idle / waiting_for_peer / in_game /
//     error_state), delegating the heavy rendering to ui_pages.zig and
//     ui_waiting_for_peer.zig
//   - runCli(), the non-interactive CLI entry point (delegates all real
//     work to game_launcher.zig)
//
// All page rendering, controller-mapper widgets, and game-launch logic
// live in sibling files — see the imports below.

const std = @import("std");
const config = @import("common").config;
const logging = @import("common").logging;
const launcher = @import("launcher.zig");
const ipc = @import("common").ipc;
const mapper = @import("dll").controller_mapper;
const session = @import("session.zig");

// Split-out modules — see file headers for what each one owns.
const ui_pages = @import("ui_pages.zig");
const ui_controller_mapper = @import("ui_controller_mapper.zig");
const ui_waiting_for_peer = @import("ui_waiting_for_peer.zig");
const game_launcher = @import("game_launcher.zig");

// Win32 for GetModuleFileNameA — used to resolve mapping.ini relative to
// the exe's own directory, matching how the DLL resolves it relative to
// hook.dll. This ensures GUI and DLL agree on the file location.
const win32 = struct {
    extern "kernel32" fn GetModuleFileNameA(hModule: ?*anyopaque, lpFilename: [*]u8, nSize: u32) callconv(.winapi) u32;
};

/// Resolve the path to mapping.ini relative to the exe's own directory.
/// zzcaster.exe is typically at `<MBAACC>/zzcaster.exe` or
/// `<MBAACC>/zzcaster/zzcaster.exe`. The mapping.ini file should be in
/// the same directory as hook.dll — i.e. `<MBAACC>/zzcaster/mapping.ini`.
///
/// To match the DLL's path resolution (which uses hook.dll's directory),
/// we check two locations:
///   1. `<exe_dir>/mapping.ini` (if exe is in zzcaster/ subdir)
///   2. `<exe_dir>/zzcaster/mapping.ini` (if exe is in MBAACC root)
///
/// Returns a slice into the provided buffer.
fn resolveMappingPath(buf: []u8) []const u8 {
    var exe_path: [512]u8 = undefined;
    const len = win32.GetModuleFileNameA(null, &exe_path, exe_path.len);
    if (len == 0) return "zzcaster/mapping.ini";

    // Find last path separator
    var last_sep: usize = 0;
    for (exe_path[0..len], 0..) |ch, i| {
        if (ch == '\\' or ch == '/') last_sep = i;
    }
    if (last_sep == 0) return "zzcaster/mapping.ini";

    const exe_dir = exe_path[0 .. last_sep + 1]; // include trailing sep

    // Check if the exe directory itself is named "zzcaster" — if so,
    // mapping.ini is in the same directory (matching hook.dll's location).
    const dir_name = blk: {
        const name_end = last_sep; // position of last sep
        var name_start: usize = 0;
        var i: usize = name_end;
        while (i > 0) : (i -= 1) {
            if (exe_path[i - 1] == '\\' or exe_path[i - 1] == '/') {
                name_start = i;
                break;
            }
        }
        break :blk exe_path[name_start..name_end];
    };

    const filename = "mapping.ini";
    if (std.mem.eql(u8, dir_name, "zzcaster")) {
        // exe is in zzcaster/ subdir — mapping.ini is right here
        if (exe_dir.len + filename.len + 1 <= buf.len) {
            @memcpy(buf[0..exe_dir.len], exe_dir);
            @memcpy(buf[exe_dir.len..exe_dir.len + filename.len], filename);
            const total = exe_dir.len + filename.len;
            buf[total] = 0;
            return buf[0..total];
        }
    }

    // exe is in MBAACC root — mapping.ini is in zzcaster/ subdir
    const subdir = "zzcaster\\";
    if (exe_dir.len + subdir.len + filename.len + 1 <= buf.len) {
        @memcpy(buf[0..exe_dir.len], exe_dir);
        @memcpy(buf[exe_dir.len..exe_dir.len + subdir.len], subdir);
        @memcpy(buf[exe_dir.len + subdir.len .. exe_dir.len + subdir.len + filename.len], filename);
        const total = exe_dir.len + subdir.len + filename.len;
        buf[total] = 0;
        return buf[0..total];
    }

    return "zzcaster/mapping.ini";
}

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_opengl.h");
    @cInclude("cimgui_shim.h");
});

pub const CliMode = @import("main.zig").CliMode;

// Re-exported so ui_pages.zig and ui_waiting_for_peer.zig can import the
// same enum values via `const UiState = @import("ui.zig").UiState;`.
pub const UiState = enum { idle, waiting_for_peer, in_game, error_state };
pub const MenuPage = enum { netplay, offline, game_config, controllers };

pub fn runCli(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    mode: CliMode,
    port: u16,
    peer: ?[]const u8,
    pipe_name: []const u8,
) !void {
    var stdout_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buf);
    switch (mode) {
        .menu => unreachable,
        .training => {
            stdout.interface.print("[cli] launching offline training\n", .{}) catch {};
            stdout.interface.flush() catch {};
            try game_launcher.launchGame(allocator, io, cfg, log, true, false, port, pipe_name, true);
        },
        .versus => {
            stdout.interface.print("[cli] launching offline versus\n", .{}) catch {};
            stdout.interface.flush() catch {};
            try game_launcher.launchGame(allocator, io, cfg, log, false, false, port, pipe_name, true);
        },
        .host => {
            stdout.interface.print("[cli] hosting netplay on port {d}\n", .{port}) catch {};
            stdout.interface.flush() catch {};
            try game_launcher.runCliNetplay(allocator, io, cfg, log, port, null, false, pipe_name);
        },
        .join => {
            const p = peer orelse {
                stdout.interface.print("[cli] --mode=join requires --peer=ip:port\n", .{}) catch {};
                stdout.interface.flush() catch {};
                std.process.exit(2);
            };
            stdout.interface.print("[cli] joining netplay peer {s}\n", .{p}) catch {};
            stdout.interface.flush() catch {};
            // Parse host:port out of --peer for the handshake session.
            const colon = std.mem.lastIndexOfScalar(u8, p, ':') orelse {
                stdout.interface.print("[cli] --peer must be ip:port\n", .{}) catch {};
                stdout.interface.flush() catch {};
                std.process.exit(2);
            };
            const host_part = p[0..colon];
            const join_port = std.fmt.parseInt(u16, p[colon + 1 ..], 10) catch config.default_port;
            try game_launcher.runCliNetplay(allocator, io, cfg, log, join_port, host_part, false, pipe_name);
        },
        .spectate => {
            const p = peer orelse {
                stdout.interface.print("[cli] --mode=spectate requires --peer=ip:port\n", .{}) catch {};
                stdout.interface.flush() catch {};
                std.process.exit(2);
            };
            stdout.interface.print("[cli] spectating {s}\n", .{p}) catch {};
            stdout.interface.flush() catch {};
            try game_launcher.launchNetplayPeerImpl(allocator, io, cfg, log, p, true, pipe_name);
        },
    }
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, cfg: *config.Config, log: *logging.Logger, pipe_name: []const u8) !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_GAMECONTROLLER | c.SDL_INIT_JOYSTICK) != 0) {
        log.err("SDL_Init failed: {s}", .{c.SDL_GetError()});
        return error.SdlInitFailed;
    }
    defer c.SDL_Quit();

    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_CONTEXT_MINOR_VERSION, 0);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DOUBLEBUFFER, 1);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_DEPTH_SIZE, 24);
    _ = c.SDL_GL_SetAttribute(c.SDL_GL_STENCIL_SIZE, 8);

    const window = c.SDL_CreateWindow(
        "ZZCaster",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        1024,
        768,
        c.SDL_WINDOW_OPENGL,
    ) orelse {
        log.err("SDL_CreateWindow failed: {s}", .{c.SDL_GetError()});
        return error.WindowCreateFailed;
    };
    defer c.SDL_DestroyWindow(window);

    const gl_ctx = c.SDL_GL_CreateContext(window) orelse {
        log.err("SDL_GL_CreateContext failed: {s}", .{c.SDL_GetError()});
        return error.GlContextFailed;
    };
    defer c.SDL_GL_DeleteContext(gl_ctx);

    _ = c.SDL_GL_SetSwapInterval(1);

    const ctx = c.igCreateContext(null);
    defer c.igDestroyContext(ctx);

    _ = c.cccaster_imgui_sdl2_init(window, gl_ctx);
    defer c.cccaster_imgui_sdl2_shutdown();

    _ = c.cccaster_imgui_opengl3_init("#version 130");
    defer c.cccaster_imgui_opengl3_shutdown();

    c.igStyleColorsDark(null);

    // State
    var ui_state: UiState = .idle;
    var current_page: MenuPage = .netplay;
    var error_msg: [256]u8 = undefined;
    var error_msg_len: usize = 0;

    // Input buffers — sentinel-terminated for ImGui InputText
    var port_buf: [16]u8 = "46318\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*;
    var peer_buf: [128]u8 = "127.0.0.1:46318\x00".* ++ [_]u8{0} ** 112;

    // Text input buffers for config (ImGui InputInt requires int* but we use
    // InputText with manual parse so the user can type freely)
    var wincount_buf: [8]u8 = "2\x00\x00\x00\x00\x00\x00\x00".*;
    var rollback_buf: [8]u8 = "4\x00\x00\x00\x00\x00\x00\x00".*;
    // Delay override buffer for the host confirmation screen. Initialized
    // empty — when the host reaches waiting_confirmation, the auto-computed
    // delay is loaded into this buffer so the host can edit it.
    var delay_buf: [4]u8 = [_]u8{0} ** 4;
    var delay_override_active: bool = false;

    // Display name input buffer (sentinel-terminated for ImGui). Initialized
    // from cfg.display_name on startup; saved back when the user clicks Apply.
    var name_buf: [40]u8 = [_]u8{0} ** 40;
    {
        const dn = cfg.display_name;
        const n = @min(dn.len, name_buf.len - 1);
        @memcpy(name_buf[0..n], dn[0..n]);
        name_buf[n] = 0;
    }

    // Game tracking
    var win_launcher: ?launcher.WindowsLauncher = null;
    var game_pid: u32 = 0;
    var ipc_server: ?ipc.IpcServer = null;

    // Netplay session (launcher-side handshake before the game opens).
    // Runs entirely on the main thread — the UI calls session.step() each
    // frame to drive the handshake forward. No background thread.
    var np_session: ?session.NetplaySession = null;
    // Host-mode wait screen: has the user clicked "Start"?
    var host_start_clicked: bool = false;

    // Controller mapper state
    var p1_mapping: mapper.ControllerMapping = .{};
    var p2_mapping: mapper.ControllerMapping = .{};
    var p1_bind_target: mapper.BindingTarget = .none;
    var p2_bind_target: mapper.BindingTarget = .none;
    var p1_joystick: ?*anyopaque = null;
    var p2_joystick: ?*anyopaque = null;
    var p1_device_sel: c_int = 0; // 0=keyboard, 1+=joystick index+1
    var p2_device_sel: c_int = 0;
    var bind_cooldown: u32 = 0; // frames to skip before polling (avoids click re-bind)
    // View mode toggle: false = classic grid layout, true = list layout.
    // List layout shows both players side-by-side, each as a vertical list
    // of (in-game button name | bind button) rows. Easier to scan when
    // the user has many bindings to review at a glance.
    var list_view: bool = false;

    // Resolve mapping.ini path relative to the exe's own directory, so
    // the GUI and DLL agree on the file location regardless of CWD.
    var mapping_path_buf: [600]u8 = undefined;
    const mapping_path = resolveMappingPath(&mapping_path_buf);
    log.info("Mapping path: {s}", .{mapping_path});

    // Load existing mapping; default to Xbox layout on first run
    if (mapper.loadMapping(mapping_path, io, log)) |mappings| {
        p1_mapping = mappings.p1;
        p2_mapping = mappings.p2;
        p1_device_sel = if (mappings.p1.device_index >= 0) mappings.p1.device_index + 1 else 0;
        p2_device_sel = if (mappings.p2.device_index >= 0) mappings.p2.device_index + 1 else 0;
    } else {
        // No saved mapping — default both players to Xbox layout.
        // Leave device_index at -1 (keyboard) so the drawPlayerPanel
        // detects a mismatch when SDL_NumJoysticks > 0 and auto-opens
        // joystick 0 on first frame. Setting device_index = 0 here
        // would match the default device_sel=0 (keyboard) and skip
        // the open, leaving p1_joystick null and breaking the bind
        // poll.
        p1_mapping = mapper.defaultXboxMapping();
        p2_mapping = mapper.defaultXboxMapping();
        p1_mapping.device_index = -1;
        p2_mapping.device_index = -1;
        if (c.SDL_NumJoysticks() > 0) {
            p1_device_sel = 1;
            p2_device_sel = 1;
        }
    }

    // Gamepad list
    const num_joy = c.SDL_NumJoysticks();

    var quit = false;
    while (!quit) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            _ = c.cccaster_imgui_sdl2_process_event(&event);
            if (event.type == c.SDL_QUIT) quit = true;
        }

        _ = c.cccaster_imgui_opengl3_newframe();
        _ = c.cccaster_imgui_sdl2_newframe();
        c.igNewFrame();

        // Main fullscreen window
        _ = c.igSetNextWindowSize(.{ .x = 1024, .y = 768 }, c.ImGuiCond_Always);
        _ = c.igSetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always, .{ .x = 0, .y = 0 });
        const window_flags = c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize |
            c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoCollapse |
            c.ImGuiWindowFlags_NoBringToFrontOnFocus;

        _ = c.igBegin("ZZCaster", null, window_flags);

        switch (ui_state) {
            .idle => {
                ui_pages.drawIdlePage(
                    allocator, io, cfg, log, pipe_name,
                    &current_page,
                    &peer_buf, &port_buf,
                    &name_buf, &wincount_buf, &rollback_buf,
                    &ui_state,
                    &np_session, &host_start_clicked,
                    &win_launcher, &game_pid, &ipc_server,
                    &error_msg, &error_msg_len,
                    &p1_mapping, &p2_mapping,
                    &p1_bind_target, &p2_bind_target,
                    &p1_joystick, &p2_joystick,
                    &p1_device_sel, &p2_device_sel,
                    &bind_cooldown, &list_view,
                    mapping_path, num_joy,
                    &quit,
                );
            },
            .waiting_for_peer => {
                ui_waiting_for_peer.drawWaitingForPeer(
                    allocator, io, cfg, log, pipe_name,
                    &np_session,
                    &win_launcher, &game_pid, &ipc_server,
                    &ui_state, &error_msg, &error_msg_len,
                    &host_start_clicked,
                    &delay_buf, &delay_override_active,
                );
            },
            .in_game => {
                c.igText("Game running (PID: %d)", game_pid);
                c.igSpacing();

                if (win_launcher) |*wl| {
                    if (!wl.isAlive()) {
                        c.igText("Game exited.");
                        c.igSpacing();
                        if (c.igButton("OK", .{ .x = 120, .y = 30 })) {
                            game_launcher.cleanupGame(&win_launcher, &game_pid, &ipc_server);
                            ui_state = .idle;
                        }
                    } else {
                        c.igText("Waiting for game to exit...");
                        c.igSpacing();
                        if (c.igButton("Force Kill", .{ .x = 120, .y = 30 })) {
                            if (win_launcher) |*wl2| {
                                wl2.terminate();
                            }
                        }
                    }
                }
            },
            .error_state => {
                c.igText("Error:");
                c.igSpacing();
                c.igText("%s", @as([*]const u8, @ptrCast(&error_msg)));
                c.igSpacing();
                if (c.igButton("OK", .{ .x = 120, .y = 30 })) {
                    ui_state = .idle;
                }
            },
        }

        c.igEnd();

        c.igRender();
        _ = c.glClearColor(0.1, 0.1, 0.1, 1.0);
        _ = c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
        _ = c.cccaster_imgui_opengl3_render(c.igGetDrawData());
        c.SDL_GL_SwapWindow(window);
    }

    // Cleanup on quit
    ui_waiting_for_peer.cleanupSession(&np_session);
    game_launcher.cleanupGame(&win_launcher, &game_pid, &ipc_server);
}
