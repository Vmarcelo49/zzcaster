const std = @import("std");
const config = @import("config.zig");
const logging = @import("logging.zig");
const launcher = @import("launcher.zig");
const ipc = @import("ipc.zig");
const mapper = @import("controller_mapper.zig");
const gamepad = @import("gamepad.zig");
const net = @import("net.zig");
const session = @import("session.zig");

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

const UiState = enum { idle, waiting_for_peer, in_game, error_state };
const MenuPage = enum { netplay, offline, game_config, controllers };

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
            try launchGame(allocator, io, cfg, log, true, false, port, pipe_name, true);
        },
        .versus => {
            stdout.interface.print("[cli] launching offline versus\n", .{}) catch {};
            stdout.interface.flush() catch {};
            try launchGame(allocator, io, cfg, log, false, false, port, pipe_name, true);
        },
        .host => {
            stdout.interface.print("[cli] hosting netplay on port {d}\n", .{port}) catch {};
            stdout.interface.flush() catch {};
            try runCliNetplay(allocator, io, cfg, log, port, null, false, pipe_name);
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
            try runCliNetplay(allocator, io, cfg, log, join_port, host_part, false, pipe_name);
        },
        .spectate => {
            const p = peer orelse {
                stdout.interface.print("[cli] --mode=spectate requires --peer=ip:port\n", .{}) catch {};
                stdout.interface.flush() catch {};
                std.process.exit(2);
            };
            stdout.interface.print("[cli] spectating {s}\n", .{p}) catch {};
            stdout.interface.flush() catch {};
            try launchNetplayPeerImpl(allocator, io, cfg, log, p, true, pipe_name);
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
    // Owned by the UI thread; the background session thread only reads/writes
    // fields on the NetplaySession itself (state, stats, etc.) which are
    // single-reader/single-writer between the two threads.
    var np_session: ?session.NetplaySession = null;
    var np_thread: ?std.Thread = null;
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
                // Title bar
                c.igText("ZZCaster v%s", @as([*:0]const u8, @ptrCast(config.version_string.ptr)));
                c.igSpacing();
                c.igSeparator();
                c.igSpacing();

                // Two-column layout: left sidebar + right content
                // Left sidebar (120px wide)
                _ = c.igBeginChild_Str("Sidebar", .{ .x = 140, .y = 0 }, true, 0);

                if (c.igSelectable_Bool("Netplay / Spectate", current_page == .netplay, 0, .{ .x = 0, .y = 0 })) {
                    current_page = .netplay;
                }
                if (c.igSelectable_Bool("Offline", current_page == .offline, 0, .{ .x = 0, .y = 0 })) {
                    current_page = .offline;
                }
                if (c.igSelectable_Bool("Game Config", current_page == .game_config, 0, .{ .x = 0, .y = 0 })) {
                    current_page = .game_config;
                }
                if (c.igSelectable_Bool("Controllers", current_page == .controllers, 0, .{ .x = 0, .y = 0 })) {
                    current_page = .controllers;
                }

                c.igSpacing();
                c.igSeparator();
                c.igSpacing();

                if (c.igButton("Quit", .{ .x = 120, .y = 30 })) {
                    quit = true;
                }

                c.igEndChild();

                // Right content area
                c.igSameLine(0, 4);
                _ = c.igBeginChild_Str("Content", .{ .x = 0, .y = 0 }, true, 0);

                switch (current_page) {
                    .netplay => {
                        c.igText("Netplay / Spectate");
                        c.igSpacing();

                        c.igText("IP:Port:");
                        c.igSameLine(0, 8);
                        _ = c.igInputText("##peer_addr", &peer_buf, peer_buf.len, 0, null, null);

                        c.igSpacing();

                        c.igText("Port (for host):");
                        c.igSameLine(0, 8);
                        _ = c.igInputText("##host_port", &port_buf, port_buf.len, 0, null, null);

                        c.igSpacing();
                        c.igSeparator();
                        c.igSpacing();

                        if (c.igButton("Host Game", .{ .x = 160, .y = 36 })) {
                            startHostSession(allocator, io, cfg, log, parsePort(&port_buf), &np_session, &np_thread);
                            if (np_session != null) {
                                host_start_clicked = false;
                                ui_state = .waiting_for_peer;
                            }
                        }
                        c.igSpacing();
                        if (c.igButton("Join Game", .{ .x = 160, .y = 36 })) {
                            startJoinSession(allocator, io, cfg, log, std.mem.sliceTo(@as([*:0]u8, @ptrCast(&peer_buf)), 0), pipe_name, &np_session, &np_thread);
                            if (np_session != null) {
                                ui_state = .waiting_for_peer;
                            }
                        }
                        c.igSpacing();
                        if (c.igButton("Spectate Match", .{ .x = 160, .y = 36 })) {
                            launchNetplayImpl(allocator, io, cfg, log, std.mem.sliceTo(@as([*:0]u8, @ptrCast(&peer_buf)), 0), true, pipe_name, &win_launcher, &game_pid, &ipc_server, &error_msg, &error_msg_len);
                            if (game_pid > 0) ui_state = .in_game else ui_state = .error_state;
                        }
                    },
                    .offline => {
                        c.igText("Offline Play");
                        c.igSpacing();
                        c.igSeparator();
                        c.igSpacing();

                        if (c.igButton("Training Mode", .{ .x = 200, .y = 40 })) {
                            launchGameImpl(allocator, io, cfg, log, true, false, config.default_port, pipe_name, &win_launcher, &game_pid, &ipc_server, &error_msg, &error_msg_len);
                            if (game_pid > 0) ui_state = .in_game else ui_state = .error_state;
                        }
                        c.igSpacing();
                        if (c.igButton("Versus Mode (P1 vs P2)", .{ .x = 200, .y = 40 })) {
                            launchGameImpl(allocator, io, cfg, log, false, false, config.default_port, pipe_name, &win_launcher, &game_pid, &ipc_server, &error_msg, &error_msg_len);
                            if (game_pid > 0) ui_state = .in_game else ui_state = .error_state;
                        }
                    },
                    .game_config => {
                        c.igText("Game Configuration");
                        c.igSpacing();
                        c.igSeparator();
                        c.igSpacing();

                        c.igText("Display Name:");
                        c.igSameLine(0, 8);
                        _ = c.igInputText("##displayname", &name_buf, name_buf.len, 0, null, null);
                        c.igSameLine(0, 8);
                        if (c.igButton("Apply##name", .{ .x = 60, .y = 0 })) {
                            const new_name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&name_buf)), 0);
                            if (cfg.display_name.len > 0) allocator.free(cfg.display_name);
                            cfg.display_name = allocator.dupe(u8, new_name) catch &.{};
                            config.saveConfig(cfg, io) catch {};
                            log.info("Display name set to '{s}'", .{new_name});
                        }

                        c.igSpacing();

                        c.igText("Versus Win Count:");
                        c.igSameLine(0, 8);
                        _ = c.igInputText("##wincount", &wincount_buf, wincount_buf.len, 0, null, null);
                        c.igSameLine(0, 8);
                        if (c.igButton("Apply", .{ .x = 60, .y = 0 })) {
                            const val = std.fmt.parseInt(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(&wincount_buf)), 0), 10) catch 2;
                            cfg.versus_win_count = val;
                            log.info("Win count set to {d}", .{val});
                        }

                        c.igSpacing();

                        c.igText("Rollback Frames:");
                        c.igSameLine(0, 8);
                        _ = c.igInputText("##rollback", &rollback_buf, rollback_buf.len, 0, null, null);
                        c.igSameLine(0, 8);
                        if (c.igButton("Apply##rb", .{ .x = 60, .y = 0 })) {
                            const val = std.fmt.parseInt(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(&rollback_buf)), 0), 10) catch 4;
                            cfg.default_rollback = val;
                            log.info("Rollback set to {d}", .{val});
                        }

                        c.igSpacing();
                        c.igSeparator();
                        c.igSpacing();

                        c.igText("Current: Win Count = %d, Rollback = %d", cfg.versus_win_count, cfg.default_rollback);
                        c.igText("Display Name = %s", @as([*:0]const u8, @ptrCast(&name_buf)));
                    },
                    .controllers => {
                        c.igText("Controller Mapper");
                        c.igSpacing();
                        c.igSeparator();
                        c.igSpacing();

                        // Decrement cooldown
                        if (bind_cooldown > 0) bind_cooldown -= 1;

                        // Poll for bind input if active
                        if (p1_bind_target != .none and bind_cooldown == 0) {
                            const dev_idx: c_int = p1_device_sel - 1;
                            if (mapper.pollForBindInput(p1_joystick, dev_idx)) |binding| {
                                applyBinding(&p1_mapping, p1_bind_target, binding);
                                p1_bind_target = .none;
                            }
                        }
                        if (p2_bind_target != .none and bind_cooldown == 0) {
                            const dev_idx: c_int = p2_device_sel - 1;
                            if (mapper.pollForBindInput(p2_joystick, dev_idx)) |binding| {
                                applyBinding(&p2_mapping, p2_bind_target, binding);
                                p2_bind_target = .none;
                            }
                        }

                        // Build device list for combo box
                        var dev_names_buf: [16][64]u8 = undefined;
                        var dev_names: [16][*:0]const u8 = undefined;
                        var dev_count: c_int = 1;
                        dev_names[0] = "Keyboard";
                        {
                            var j: c_int = 0;
                            while (j < num_joy and dev_count < 16) : (j += 1) {
                                const name = c.SDL_JoystickNameForIndex(j);
                                if (name != null) {
                                    const span = std.mem.span(name);
                                    const n = @min(span.len, 63);
                                    @memcpy(dev_names_buf[@intCast(dev_count)][0..n], span[0..n]);
                                    dev_names_buf[@intCast(dev_count)][n] = 0;
                                    dev_names[@intCast(dev_count)] = @ptrCast(&dev_names_buf[@intCast(dev_count)]);
                                } else {
                                    const fallback = "Unknown Joystick";
                                    @memcpy(dev_names_buf[@intCast(dev_count)][0..fallback.len], fallback);
                                    dev_names_buf[@intCast(dev_count)][fallback.len] = 0;
                                    dev_names[@intCast(dev_count)] = @ptrCast(&dev_names_buf[@intCast(dev_count)]);
                                }
                                dev_count += 1;
                            }
                        }

                        // Player 1 panel
                        drawPlayerPanel("Player 1", &p1_mapping, &p1_bind_target, &p1_joystick, &p1_device_sel, &dev_names, dev_count, num_joy, log, &bind_cooldown);

                        c.igSpacing();
                        c.igSeparator();
                        c.igSpacing();

                        // Player 2 panel
                        drawPlayerPanel("Player 2", &p2_mapping, &p2_bind_target, &p2_joystick, &p2_device_sel, &dev_names, dev_count, num_joy, log, &bind_cooldown);

                        c.igSpacing();
                        c.igSeparator();
                        c.igSpacing();

                        // Save button
                        if (c.igButton("Save Mapping", .{ .x = 160, .y = 30 })) {
                            p1_mapping.device_index = p1_device_sel - 1;
                            p2_mapping.device_index = p2_device_sel - 1;
                            mapper.saveMapping(p1_mapping, p2_mapping, mapping_path, io, log);
                        }
                        c.igSameLine(0, 8);
                        c.igText("(loaded by hook.dll on game start)");
                    },
                }

                c.igEndChild(); // Content
            },
            .waiting_for_peer => {
                drawWaitingForPeer(
                    allocator, io, cfg, log, pipe_name,
                    &np_session, &np_thread,
                    &win_launcher, &game_pid, &ipc_server,
                    &ui_state, &error_msg, &error_msg_len,
                    &host_start_clicked,
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
                            cleanupGame(&win_launcher, &game_pid, &ipc_server);
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
    cleanupSession(&np_session, &np_thread);
    cleanupGame(&win_launcher, &game_pid, &ipc_server);
}

fn parsePort(buf: [*]u8) u16 {
    const s = std.mem.sliceTo(@as([*:0]u8, @ptrCast(buf)), 0);
    return std.fmt.parseInt(u16, s, 10) catch config.default_port;
}

/// Clean up all game-related state: close IPC pipe, close process handles,
/// reset PID. Must be called before launching a new game so the named pipe
/// is released and can be re-created.
fn cleanupGame(
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
) void {
    if (ipc_server.*) |*srv| srv.close();
    ipc_server.* = null;
    if (win_launcher.*) |*wl| wl.terminate();
    win_launcher.* = null;
    game_pid.* = 0;
}

/// Tear down any in-progress netplay session (background thread + transport).
/// Called when leaving the waiting_for_peer screen (cancel, success, or quit).
fn cleanupSession(
    np_session: *?session.NetplaySession,
    np_thread: *?std.Thread,
) void {
    if (np_session.*) |*s| {
        s.cancel(); // signals the background thread + closes transport
    }
    if (np_thread.*) |t| {
        t.join();
        np_thread.* = null;
    }
    if (np_session.*) |*s| {
        s.deinit();
    }
    np_session.* = null;
}

// ============================================================================
// Controller Mapper UI helpers
// ============================================================================

fn applyBinding(m: *mapper.ControllerMapping, target: mapper.BindingTarget, binding: mapper.InputBinding) void {
    switch (target) {
        .a => m.a = binding,
        .b => m.b = binding,
        .c => m.c = binding,
        .d => m.d = binding,
        .e => m.e = binding,
        .ab => m.ab = binding,
        .start => m.start = binding,
        .fn1 => m.fn1 = binding,
        .fn2 => m.fn2 = binding,
        .up => m.up = binding,
        .down => m.down = binding,
        .left => m.left = binding,
        .right => m.right = binding,
        .none => {},
    }
}

fn bindButton(label: []const u8, target: mapper.BindingTarget, binding: mapper.InputBinding, bind_target: *mapper.BindingTarget, cooldown: *u32) void {
    var buf: [64]u8 = undefined;
    const bind_label = binding.label(&buf);

    if (bind_target.* == target) {
        // This button is currently being bound — show "Press input..."
        var btn_buf: [80]u8 = undefined;
        const btn_text = std.fmt.bufPrintZ(&btn_buf, "{s}: Press...", .{label}) catch label;
        _ = c.igButton(btn_text.ptr, .{ .x = 90, .y = 0 });
    } else {
        var btn_buf: [80]u8 = undefined;
        const btn_text = std.fmt.bufPrintZ(&btn_buf, "{s}: {s}", .{ label, bind_label }) catch label;
        if (c.igButton(btn_text.ptr, .{ .x = 90, .y = 0 })) {
            bind_target.* = target;
            cooldown.* = 15; // ~250ms at 60fps to avoid immediate re-bind
        }
    }
}

fn drawPlayerPanel(
    name: []const u8,
    m: *mapper.ControllerMapping,
    bind_target: *mapper.BindingTarget,
    joy: *?*anyopaque,
    device_sel: *c_int,
    dev_names: *const [16][*:0]const u8,
    dev_count: c_int,
    num_joy: c_int,
    log: *logging.Logger,
    cooldown: *u32,
) void {
    _ = num_joy;

    // Build unique ID suffixes from player name to avoid ImGui ID conflicts
    var id_suffix_buf: [32]u8 = undefined;
    const id_suffix = std.fmt.bufPrintZ(&id_suffix_buf, "##{s}", .{name}) catch "##p";

    // Player label + device combo
    var name_buf: [32]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&name_buf, "{s}", .{name}) catch name;
    c.igText("%s", @as([*:0]const u8, @ptrCast(name_z.ptr)));
    c.igSameLine(0, 16);

    var combo_label_buf: [48]u8 = undefined;
    const combo_label = std.fmt.bufPrintZ(&combo_label_buf, "##device_{s}", .{name}) catch "##device";
    _ = c.igCombo_Str_arr(combo_label.ptr, @ptrCast(device_sel), @ptrCast(dev_names), dev_count, 8);

    // Open/close joystick when device changes
    const new_dev: c_int = device_sel.* - 1;
    if (new_dev != m.device_index) {
        if (joy.*) |j| {
            c.SDL_JoystickClose(@ptrCast(j));
            joy.* = null;
        }
        if (new_dev >= 0) {
            joy.* = @ptrCast(c.SDL_JoystickOpen(new_dev));
            if (joy.* != null) {
                log.info("{s}: opened joystick {d}", .{ name, new_dev });
            }
        }
        m.device_index = new_dev;
    }

    c.igSpacing();

    // Push a unique ID stack for this player's widgets
    c.igPushID_Str(id_suffix.ptr);

    // Top row: FN1, Start, FN2
    c.igIndent(200);
    bindButton("FN1", .fn1, m.fn1, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("Start", .start, m.start, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("FN2", .fn2, m.fn2, bind_target, cooldown);
    c.igUnindent(200);

    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    // Two columns: Directions (left) + Buttons (right)
    _ = c.igBeginChild_Str("dir", .{ .x = 220, .y = 140 }, true, 0);

    c.igText("Directions");
    c.igSpacing();

    // Up (centered)
    c.igIndent(60);
    bindButton("Up", .up, m.up, bind_target, cooldown);
    c.igUnindent(60);

    // Left + Right
    bindButton("Left", .left, m.left, bind_target, cooldown);
    c.igSameLine(0, 8);
    c.igDummy(.{ .x = 30, .y = 0 });
    c.igSameLine(0, 8);
    bindButton("Right", .right, m.right, bind_target, cooldown);

    // Down (centered)
    c.igIndent(60);
    bindButton("Down", .down, m.down, bind_target, cooldown);
    c.igUnindent(60);

    c.igEndChild();

    c.igSameLine(0, 8);

    _ = c.igBeginChild_Str("btn", .{ .x = 310, .y = 140 }, true, 0);

    c.igText("Buttons");
    c.igSpacing();

    // Row 1: A, B, C
    bindButton("A", .a, m.a, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("B", .b, m.b, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("C", .c, m.c, bind_target, cooldown);

    c.igSpacing();

    // Row 2: D, E, AB
    bindButton("D", .d, m.d, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("E", .e, m.e, bind_target, cooldown);
    c.igSameLine(0, 8);
    bindButton("A+B", .ab, m.ab, bind_target, cooldown);

    c.igEndChild();

    c.igSpacing();

    // SOCD mode radio buttons
    c.igText("SOCD:");
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("Default", m.socd_mode == 0)) m.socd_mode = 0;
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("L+R neg", m.socd_mode == 1)) m.socd_mode = 1;
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("U+D neg", m.socd_mode == 2)) m.socd_mode = 2;
    c.igSameLine(0, 8);
    if (c.igRadioButton_Bool("Both neg", m.socd_mode == 3)) m.socd_mode = 3;

    c.igSpacing();

    // Deadzone slider + buttons on same line
    var dz: c_int = @intCast(m.deadzone);
    _ = c.igSliderInt("Analog Deadzone", @ptrCast(&dz), 0, 30000, "%d", 0);
    m.deadzone = @intCast(dz);

    c.igSameLine(0, 16);

    if (c.igButton("Default Bindings", .{ .x = 130, .y = 0 })) {
        m.* = mapper.defaultXboxMapping();
        m.device_index = device_sel.* - 1;
    }
    c.igSameLine(0, 8);

    if (c.igButton("Clear", .{ .x = 60, .y = 0 })) {
        m.* = .{};
        m.device_index = device_sel.* - 1;
    }

    c.igPopID();
}

fn launchGameImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    training: bool,
    is_netplay_host: bool,
    port: u16,
    pipe_name: []const u8,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    // Clean up any previous game state before launching a new one.
    cleanupGame(win_launcher, game_pid, ipc_server);

    const game_exe = std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate path");
        return;
    };
    defer allocator.free(game_exe);
    const dll_path = std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate dll path");
        return;
    };
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        setErr(error_msg, error_msg_len, "MBAA.exe not found");
        log.err("MBAA.exe not found: {s}", .{game_exe});
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        setErr(error_msg, error_msg_len, "hook.dll not found");
        log.err("hook.dll not found: {s}", .{dll_path});
        return;
    };

    ipc_server.* = ipc.IpcServer.listen(pipe_name) catch {
        setErr(error_msg, error_msg_len, "IPC listen failed");
        return;
    };

    win_launcher.* = launcher.WindowsLauncher{};
    const pid = win_launcher.*.?.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        setErr(error_msg, error_msg_len, "Failed to launch MBAA.exe");
        return;
    };
    game_pid.* = pid;
    log.info("Game launched (PID={d})", .{pid});

    if (ipc_server.*) |*srv| {
        srv.waitForConnection() catch {
            setErr(error_msg, error_msg_len, "IPC connection failed");
            return;
        };
    }
    log.info("DLL connected via IPC", .{});

    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0;
    if (training) config_buf[0] |= 0x01;
    if (is_netplay_host) config_buf[0] |= 0x02 | 0x04;
    config_buf[1] = cfg.default_rollback;
    config_buf[2] = cfg.default_rollback;
    config_buf[3] = cfg.versus_win_count;
    config_buf[4] = 1;
    std.mem.writeInt(u16, config_buf[5..7], port, .little);
    const msg_len = 7;

    if (ipc_server.*) |*srv| {
        _ = srv.send(config_buf[0..msg_len]);
    }
    log.info("Config sent (host={} training={} port={d})", .{ is_netplay_host, training, port });
}

fn launchNetplayImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    addr_str: []const u8,
    is_spectator: bool,
    pipe_name: []const u8,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    // Clean up any previous game state before launching a new one.
    cleanupGame(win_launcher, game_pid, ipc_server);

    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse {
        setErr(error_msg, error_msg_len, "Invalid format. Use IP:port");
        return;
    };
    const peer_addr = addr_str[0..colon];
    const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch config.default_port;

    const game_exe = std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate path");
        return;
    };
    defer allocator.free(game_exe);
    const dll_path = std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate dll path");
        return;
    };
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        setErr(error_msg, error_msg_len, "MBAA.exe not found");
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        setErr(error_msg, error_msg_len, "hook.dll not found");
        return;
    };

    ipc_server.* = ipc.IpcServer.listen(pipe_name) catch {
        setErr(error_msg, error_msg_len, "IPC listen failed");
        return;
    };

    win_launcher.* = launcher.WindowsLauncher{};
    const pid = win_launcher.*.?.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        setErr(error_msg, error_msg_len, "Failed to launch MBAA.exe");
        return;
    };
    game_pid.* = pid;
    log.info("Game launched (PID={d})", .{pid});

    if (ipc_server.*) |*srv| {
        srv.waitForConnection() catch {
            setErr(error_msg, error_msg_len, "IPC connection failed");
            return;
        };
    }

    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0x02 | (if (is_spectator) @as(u8, 0x08) else 0);
    config_buf[1] = if (is_spectator) 0 else cfg.default_rollback;
    config_buf[2] = if (is_spectator) 0 else cfg.default_rollback;
    config_buf[3] = cfg.versus_win_count;
    config_buf[4] = 1;
    std.mem.writeInt(u16, config_buf[5..7], port, .little);
    const addr_copy_len = @min(peer_addr.len, 248);
    @memcpy(config_buf[7..7 + addr_copy_len], peer_addr[0..addr_copy_len]);
    const msg_len = 7 + addr_copy_len;

    if (ipc_server.*) |*srv| {
        _ = srv.send(config_buf[0..msg_len]);
    }
    log.info("Config sent ({s} -> {s}:{d})", .{
        if (is_spectator) "spectator" else "client", peer_addr, port,
    });
}

// ============================================================================
// Netplay session (launcher-side handshake before the game opens)
// ============================================================================

const SessionThreadCtx = struct {
    s: *session.NetplaySession,
    port: u16,
    training: bool,
    is_host: bool,
    peer_addr: ?[]const u8 = null, // only for join
};

/// Background thread entry point: runs the blocking host()/join() call.
/// The NetplaySession's state field is the communication channel back to
/// the UI thread.
fn sessionThreadMain(ctx: SessionThreadCtx) void {
    if (ctx.is_host) {
        ctx.s.host(ctx.port, ctx.training) catch |err| {
            if (err != error.Cancelled) {
                ctx.s.log.warn("host() failed: {t}", .{err});
            }
        };
    } else {
        const addr = ctx.peer_addr orelse return;
        ctx.s.join(addr, ctx.port, ctx.training) catch |err| {
            if (err != error.Cancelled) {
                ctx.s.log.warn("join() failed: {t}", .{err});
            }
        };
    }
}

/// Start the host-side handshake session in a background thread.
fn startHostSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    port: u16,
    np_session: *?session.NetplaySession,
    np_thread: *?std.Thread,
) void {
    // Tear down any previous session first.
    cleanupSession(np_session, np_thread);

    var s = session.NetplaySession.init(allocator, io, log);
    s.config.rollback = cfg.default_rollback;
    s.config.win_count = cfg.versus_win_count;
    s.setLocalName(cfg.display_name);
    // Look up public + local IPs for the host display screen. Synchronous but
    // fast (wininet uses system timeout).
    s.lookupHostAddresses();
    np_session.* = s;

    const ctx = SessionThreadCtx{
        .s = &np_session.*.?,
        .port = port,
        .training = false,
        .is_host = true,
    };
    np_thread.* = std.Thread.spawn(.{}, sessionThreadMain, .{ctx}) catch null;
    log.info("Host session started on port {d} (pub={s} local={s} name='{s}')", .{
        port,
        s.publicIp() orelse "?",
        s.localIp() orelse "?",
        s.localName(),
    });
}

/// Start the client-side handshake session in a background thread.
fn startJoinSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    addr_str: []const u8,
    pipe_name: []const u8,
    np_session: *?session.NetplaySession,
    np_thread: *?std.Thread,
) void {
    _ = pipe_name;
    cleanupSession(np_session, np_thread);

    // Validate ip:port format up front.
    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse {
        log.err("Invalid address (no colon): {s}", .{addr_str});
        return;
    };
    const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch {
        log.err("Invalid port in: {s}", .{addr_str});
        return;
    };
    // Copy the host part into a stable buffer the thread can outlive the
    // stack frame that holds addr_str. The session also stores it in
    // config.peer_addr, but we need a separate owned slice for the thread ctx.
    const host_part = addr_str[0..colon];
    const host_owned = allocator.dupe(u8, host_part) catch {
        log.err("OOM duplicating host addr", .{});
        return;
    };

    var s = session.NetplaySession.init(allocator, io, log);
    s.config.rollback = cfg.default_rollback;
    s.config.win_count = cfg.versus_win_count;
    s.setLocalName(cfg.display_name);
    np_session.* = s;

    const ctx = SessionThreadCtx{
        .s = &np_session.*.?,
        .port = port,
        .training = false,
        .is_host = false,
        .peer_addr = host_owned,
    };
    np_thread.* = std.Thread.spawn(.{}, sessionThreadMain, .{ctx}) catch blk: {
        allocator.free(host_owned);
        break :blk null;
    };
    log.info("Join session started -> {s}:{d} (name='{s}')", .{ host_part, port, s.localName() });
}

/// Draw the waiting-for-peer screen. Polls the session state each frame and
/// either shows progress, a confirmation prompt, or transitions to the game.
fn drawWaitingForPeer(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    pipe_name: []const u8,
    np_session: *?session.NetplaySession,
    np_thread: *?std.Thread,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    ui_state: *UiState,
    error_msg: *[256]u8,
    error_msg_len: *usize,
    host_start_clicked: *bool,
) void {
    // Take a mutable pointer directly into the optional storage so we can
    // call mutating methods (hostConfirm) and read live state updated by the
    // background thread.
    if (np_session.* == null) {
        ui_state.* = .idle;
        return;
    }
    const s = &np_session.*.?;
    const is_host = s.config.is_host;

    c.igText("%s", @as([*:0]const u8, @ptrCast(if (is_host) "Hosting — waiting for opponent" else "Connecting to host")));
    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    switch (s.state) {
        .idle, .listening, .connecting, .handshaking, .ping_exchanging => {
            // In-progress: show address info + a spinner-ish message.
            if (is_host) {
                if (s.publicIp()) |pub_ip| {
                    var addr_buf: [80]u8 = undefined;
                    const addr_z = std.fmt.bufPrintZ(&addr_buf, "{s}:{d}", .{ pub_ip, s.config.peer_port }) catch "?:?";
                    c.igText("Give your opponent this address:");
                    c.igSameLine(0, 8);
                    c.igTextColored(.{ .x = 0.4, .y = 0.8, .z = 1.0, .w = 1.0 }, "%s", @as([*:0]const u8, @ptrCast(addr_z.ptr)));
                    c.igSameLine(0, 8);
                    if (c.igButton("Copy", .{ .x = 60, .y = 0 })) {
                        setClipboardZ(addr_z);
                    }
                } else {
                    c.igText("Looking up public IP...");
                }
                if (s.localIp()) |loc_ip| {
                    var addr_buf: [80]u8 = undefined;
                    const addr_z = std.fmt.bufPrintZ(&addr_buf, "Local IP: {s}:{d}", .{ loc_ip, s.config.peer_port }) catch "";
                    c.igText("%s", @as([*:0]const u8, @ptrCast(addr_z.ptr)));
                }
            } else {
                var addr_buf: [80]u8 = undefined;
                const peer_z = std.mem.sliceTo(&s.config.peer_addr, 0);
                const addr_z = std.fmt.bufPrintZ(&addr_buf, "{s}:{d}", .{ peer_z, s.config.peer_port }) catch "?:?";
                c.igText("Connecting to %s...", @as([*:0]const u8, @ptrCast(addr_z.ptr)));
            }
            c.igSpacing();
            c.igText("(make sure the port is open / forwarded on the host's router)");

            c.igSpacing();
            c.igSeparator();
            c.igSpacing();
            if (c.igButton("Cancel", .{ .x = 120, .y = 30 })) {
                cleanupSession(np_session, np_thread);
                ui_state.* = .idle;
            }
        },

        .waiting_confirmation => {
            // Host: handshake done, show ping + a Start button.
            const remote = s.remoteName();
            if (remote.len > 0) {
                c.igText("%.*s connected!", @as(c_int, @intCast(remote.len)), remote.ptr);
            } else {
                c.igText("Opponent connected!");
            }
            c.igSpacing();
            c.igText("Ping: avg=%.0fms  min=%.0fms  max=%.0fms", s.stats.avg_ms, s.stats.min_ms, s.stats.max_ms);
            c.igText("Auto input delay: %d", s.config.delay);
            c.igSpacing();
            c.igSeparator();
            c.igSpacing();
            if (c.igButton("Start Match", .{ .x = 160, .y = 36 })) {
                host_start_clicked.* = true;
                s.hostConfirm();
            }
            c.igSameLine(0, 16);
            if (c.igButton("Cancel", .{ .x = 120, .y = 36 })) {
                cleanupSession(np_session, np_thread);
                ui_state.* = .idle;
            }
        },

        .launching => {
            // Both sides agreed — open the game now.
            // For the host this is reached after hostConfirm(); for the
            // client it's reached right after waitForConfig().
            launchGameAfterHandshake(
                allocator, io, cfg, log, pipe_name,
                np_session, np_thread,
                win_launcher, game_pid, ipc_server,
                error_msg, error_msg_len,
            );
            if (game_pid.* > 0) {
                ui_state.* = .in_game;
            } else {
                ui_state.* = .error_state;
            }
        },

        .completed => {
            c.igText("Session completed.");
            c.igSpacing();
            if (c.igButton("OK", .{ .x = 120, .y = 30 })) {
                cleanupSession(np_session, np_thread);
                ui_state.* = .idle;
            }
        },

        .failed => {
            const msg = s.errorMessage();
            setErr(error_msg, error_msg_len, if (msg.len > 0) msg else "Connection failed");
            cleanupSession(np_session, np_thread);
            ui_state.* = .error_state;
        },

        .cancelled => {
            cleanupSession(np_session, np_thread);
            ui_state.* = .idle;
        },
    }
}

// Module-local references removed: the host-screen IP buffers are now passed
// through startHostSession → drawWaitingForPeer as explicit parameters.

fn setClipboardZ(text: []const u8) void {
    // Build a null-terminated copy on the stack and hand it to ImGui.
    var buf: [128]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    c.igSetClipboardText(@ptrCast(&buf));
}

/// Launch the game after the launcher-side handshake completed. Mirrors
/// MainApp.cpp:1263-1289: close the handshake socket, wait ~1s (so the OS
/// releases the UDP port — the legacy startTimer delay), then CreateProcess +
/// inject + send the negotiated config via IPC.
fn launchGameAfterHandshake(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    pipe_name: []const u8,
    np_session: *?session.NetplaySession,
    np_thread: *?std.Thread,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    // Snapshot the negotiated config BEFORE we tear down the session.
    const snap = blk: {
        if (np_session.*) |*s| break :blk s.config;
        setErr(error_msg, error_msg_len, "No session to launch from");
        return;
    };
    const is_host = snap.is_host;
    const peer_port = snap.peer_port;
    const delay = snap.delay;
    const rollback = snap.rollback;
    const win_count = snap.win_count;
    const host_player = snap.host_player;
    var peer_addr: [64]u8 = snap.peer_addr;

    // Join the session thread (it has finished its work by now — state is
    // .launching) and tear down the transport so the OS frees the UDP port.
    if (np_thread.*) |t| {
        t.join();
        np_thread.* = null;
    }
    if (np_session.*) |*s| {
        s.deinit();
    }
    np_session.* = null;

    log.info("Handshake done ({s}). Closing socket, waiting 1s before opening game...", .{
        if (is_host) "host" else "client",
    });
    // Mirror the legacy 1000ms startTimer delay (MainApp.cpp:933-934) so the
    // OS releases the port before the DLL rebinds it.
    std.Io.sleep(io, .{ .nanoseconds = 1 * std.time.ns_per_s }, .real) catch {};

    // Clean up any previous game state before launching a new one.
    cleanupGame(win_launcher, game_pid, ipc_server);

    const game_exe = std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate path");
        return;
    };
    defer allocator.free(game_exe);
    const dll_path = std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" }) catch {
        setErr(error_msg, error_msg_len, "Failed to allocate dll path");
        return;
    };
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        setErr(error_msg, error_msg_len, "MBAA.exe not found");
        log.err("MBAA.exe not found: {s}", .{game_exe});
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        setErr(error_msg, error_msg_len, "hook.dll not found");
        log.err("hook.dll not found: {s}", .{dll_path});
        return;
    };

    ipc_server.* = ipc.IpcServer.listen(pipe_name) catch {
        setErr(error_msg, error_msg_len, "IPC listen failed");
        return;
    };

    win_launcher.* = launcher.WindowsLauncher{};
    const pid = win_launcher.*.?.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        setErr(error_msg, error_msg_len, "Failed to launch MBAA.exe");
        return;
    };
    game_pid.* = pid;
    log.info("Game launched (PID={d})", .{pid});

    if (ipc_server.*) |*srv| {
        srv.waitForConnection() catch {
            setErr(error_msg, error_msg_len, "IPC connection failed");
            return;
        };
    }
    log.info("DLL connected via IPC", .{});

    // Build the config buffer using the SAME layout the DLL parses in
    // dllmain.zig:waitForConfig():
    //   [1 byte flags] [1 byte delay] [1 byte rollback] [1 byte win_count]
    //   [1 byte host_player] [2 bytes peer_port] [N bytes peer_addr]
    // flags bit0=training, bit1=netplay, bit2=host, bit3=spectator.
    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0x02 | (if (is_host) @as(u8, 0x04) else 0);
    config_buf[1] = delay;
    config_buf[2] = rollback;
    config_buf[3] = win_count;
    config_buf[4] = host_player;
    std.mem.writeInt(u16, config_buf[5..7], peer_port, .little);

    // Host does NOT send a peer address (it listens); client sends the host's
    // address so the DLL can connect outbound.
    var msg_len: usize = 7;
    if (!is_host) {
        const addr_slice = std.mem.sliceTo(&peer_addr, 0);
        const addr_copy_len = @min(addr_slice.len, 248);
        @memcpy(config_buf[7..7 + addr_copy_len], addr_slice[0..addr_copy_len]);
        msg_len = 7 + addr_copy_len;
    }

    if (ipc_server.*) |*srv| {
        _ = srv.send(config_buf[0..msg_len]);
    }
    log.info("Config sent to DLL (host={} delay={d} rollback={d} port={d})", .{
        is_host, delay, rollback, peer_port,
    });
}

fn setErr(msg: *[256]u8, len: *usize, text: []const u8) void {
    const n = @min(text.len, msg.len - 1);
    @memcpy(msg[0..n], text[0..n]);
    msg[n] = 0;
    len.* = n;
}

// Legacy CLI launch functions
fn launchGame(allocator: std.mem.Allocator, io: std.Io, cfg: *config.Config, log: *logging.Logger, training: bool, is_netplay_host: bool, port: u16, pipe_name: []const u8, non_interactive: bool) !void {
    _ = non_interactive;
    const game_exe = try std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" });
    defer allocator.free(game_exe);
    const dll_path = try std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" });
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        log.err("MBAA.exe not found: {s}", .{game_exe});
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        log.err("hook.dll not found: {s}", .{dll_path});
        return;
    };

    var ipc_server = try ipc.IpcServer.listen(pipe_name);
    defer ipc_server.close();
    log.info("IPC server listening", .{});

    var win_launcher = launcher.WindowsLauncher{};
    const pid = win_launcher.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        log.err("Failed to launch MBAA.exe", .{});
        return;
    };
    log.info("Game launched (PID={d})", .{pid});

    ipc_server.waitForConnection() catch {
        log.warn("IPC connection failed", .{});
        return;
    };
    log.info("DLL connected via IPC", .{});

    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0;
    if (training) config_buf[0] |= 0x01;
    if (is_netplay_host) config_buf[0] |= 0x02 | 0x04;
    config_buf[1] = cfg.default_rollback;
    config_buf[2] = cfg.default_rollback;
    config_buf[3] = cfg.versus_win_count;
    config_buf[4] = 1;
    std.mem.writeInt(u16, config_buf[5..7], port, .little);
    const msg_len = 7;

    _ = ipc_server.send(config_buf[0..msg_len]);
    log.info("Config sent to DLL (netplay={}, host={}, training={}, port={d})", .{
        is_netplay_host, is_netplay_host, training, port,
    });

    while (win_launcher.isAlive()) {
        // Zig 0.16: std.Thread.sleep is gone — use std.Io.sleep(io, dur, clock).
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {};
    }
    log.info("Game exited", .{});
}

fn launchNetplayPeerImpl(allocator: std.mem.Allocator, io: std.Io, cfg: *config.Config, log: *logging.Logger, addr_str: []const u8, is_spectator: bool, pipe_name: []const u8) !void {
    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return;
    const peer_addr = addr_str[0..colon];
    const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch config.default_port;

    const game_exe = try std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" });
    defer allocator.free(game_exe);
    const dll_path = try std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" });
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch return;
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch return;

    var ipc_server = try ipc.IpcServer.listen(pipe_name);
    defer ipc_server.close();

    var win_launcher = launcher.WindowsLauncher{};
    const pid = win_launcher.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch return;
    log.info("Game launched (PID={d})", .{pid});

    ipc_server.waitForConnection() catch {};
    log.info("DLL connected via IPC", .{});

    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0x02 | (if (is_spectator) @as(u8, 0x08) else 0);
    config_buf[1] = if (is_spectator) 0 else cfg.default_rollback;
    config_buf[2] = if (is_spectator) 0 else cfg.default_rollback;
    config_buf[3] = cfg.versus_win_count;
    config_buf[4] = 1;
    std.mem.writeInt(u16, config_buf[5..7], port, .little);
    const addr_copy_len = @min(peer_addr.len, 248);
    @memcpy(config_buf[7..7 + addr_copy_len], peer_addr[0..addr_copy_len]);
    const msg_len = 7 + addr_copy_len;

    _ = ipc_server.send(config_buf[0..msg_len]);
    log.info("Config sent ({s} -> {s}:{d})", .{
        if (is_spectator) "spectator" else "client", peer_addr, port,
    });

    while (win_launcher.isAlive()) {
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {};
    }
    log.info("Session ended", .{});
}

/// CLI netplay: run the launcher-side handshake session (blocking, no UI —
/// the host auto-confirms after the peer connects), then launch the game with
/// the negotiated config. Mirrors the GUI's startHostSession/Join +
/// launchGameAfterHandshake but single-threaded for the CLI path.
///
/// `peer_host` is null for host mode, "ip" for join mode.
fn runCliNetplay(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    port: u16,
    peer_host: ?[]const u8,
    is_spectator: bool,
    pipe_name: []const u8,
) !void {
    _ = is_spectator;
    var s = session.NetplaySession.init(allocator, io, log);
    defer s.deinit();
    s.config.rollback = cfg.default_rollback;
    s.config.win_count = cfg.versus_win_count;
    s.setLocalName(cfg.display_name);

    if (peer_host == null) {
        // Host: look up public IP, listen, handshake, then auto-confirm.
        s.lookupHostAddresses();
        try s.host(port, false);
        // host() leaves us in waiting_confirmation — auto-confirm like the
        // legacy --dummy path does.
        s.hostConfirm();
    } else {
        try s.join(peer_host.?, port, false);
    }

    if (s.state != .launching) {
        log.err("Handshake did not reach launching state (state={t})", .{s.state});
        return error.HandshakeFailed;
    }

    log.info("Handshake OK — launching game (delay={d} rollback={d})", .{
        s.config.delay, s.config.rollback,
    });

    // Snapshot config and tear down the handshake socket before opening the
    // game (matches launchGameAfterHandshake in the GUI path).
    const snap = s.config;
    s.deinit();

    // 1s delay so the OS frees the UDP port before the DLL rebinds it.
    std.Io.sleep(io, .{ .nanoseconds = 1 * std.time.ns_per_s }, .real) catch {};

    // Launch the game + inject + send config via IPC.
    const game_exe = try std.fs.path.join(allocator, &.{ cfg.app_dir, "MBAA.exe" });
    defer allocator.free(game_exe);
    const dll_path = try std.fs.path.join(allocator, &.{ cfg.app_dir, "zzcaster", "hook.dll" });
    defer allocator.free(dll_path);

    std.Io.Dir.cwd().access(io, game_exe, .{}) catch {
        log.err("MBAA.exe not found: {s}", .{game_exe});
        return;
    };
    std.Io.Dir.cwd().access(io, dll_path, .{}) catch {
        log.err("hook.dll not found: {s}", .{dll_path});
        return;
    };

    var ipc_server = try ipc.IpcServer.listen(pipe_name);
    defer ipc_server.close();
    log.info("IPC server listening", .{});

    var win_launcher = launcher.WindowsLauncher{};
    const pid = win_launcher.launch(.{
        .game_exe = game_exe,
        .dll_path = dll_path,
        .high_priority = cfg.high_cpu_priority,
    }, log) catch {
        log.err("Failed to launch MBAA.exe", .{});
        return;
    };
    log.info("Game launched (PID={d})", .{pid});

    ipc_server.waitForConnection() catch {
        log.warn("IPC connection failed", .{});
        return;
    };
    log.info("DLL connected via IPC", .{});

    // Build config buffer (same layout as launchGameAfterHandshake).
    var config_buf: [256]u8 = undefined;
    config_buf[0] = 0x02 | (if (snap.is_host) @as(u8, 0x04) else 0);
    config_buf[1] = snap.delay;
    config_buf[2] = snap.rollback;
    config_buf[3] = snap.win_count;
    config_buf[4] = snap.host_player;
    std.mem.writeInt(u16, config_buf[5..7], snap.peer_port, .little);

    var msg_len: usize = 7;
    if (!snap.is_host) {
        const addr_slice = std.mem.sliceTo(&snap.peer_addr, 0);
        const addr_copy_len = @min(addr_slice.len, 248);
        @memcpy(config_buf[7..7 + addr_copy_len], addr_slice[0..addr_copy_len]);
        msg_len = 7 + addr_copy_len;
    }

    _ = ipc_server.send(config_buf[0..msg_len]);
    log.info("Config sent to DLL (host={} delay={d} port={d})", .{
        snap.is_host, snap.delay, snap.peer_port,
    });

    while (win_launcher.isAlive()) {
        std.Io.sleep(io, .{ .nanoseconds = 100 * std.time.ns_per_ms }, .real) catch {};
    }
    log.info("Game exited", .{});
}