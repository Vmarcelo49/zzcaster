const std = @import("std");
const config = @import("common").config;
const logging = @import("common").logging;
const launcher = @import("launcher.zig");
const ipc = @import("common").ipc;
const mapper = @import("dll").controller_mapper;
const session = @import("session.zig");
const zgui = @import("zgui");

// Split-out modules — see file headers for what each one owns.
const ui_pages = @import("ui_pages.zig");
const ui_controller_mapper = @import("ui_controller_mapper.zig");
const ui_waiting_for_peer = @import("ui_waiting_for_peer.zig");
const game_launcher = @import("game_launcher.zig");
const ui_theme = @import("ui_theme.zig");

// Win32 Unicode helper — used to resolve mapping.ini relative to
// the exe's own directory, matching how the DLL resolves it relative to
// hook.dll. This ensures GUI and DLL agree on the file location.
const common_win32 = @import("common").win32;

fn resolveMappingPath(buf: []u8) []const u8 {
    const exe_path = common_win32.getModuleFileNameUtf8(null, buf) orelse return "zzcaster/mapping.ini";
    const len = exe_path.len;

    // Find last path separator
    var last_sep: usize = 0;
    for (buf[0..len], 0..) |ch, i| {
        if (ch == '\\' or ch == '/') last_sep = i;
    }
    if (last_sep == 0) return "zzcaster/mapping.ini";

    const exe_dir = buf[0 .. last_sep + 1]; // include trailing sep

    // Check if the exe directory itself is named "zzcaster" — if so,
    // mapping.ini is in the same directory (matching hook.dll's location).
    const dir_name = blk: {
        const name_end = last_sep; // position of last sep
        var name_start: usize = 0;
        var i: usize = name_end;
        while (i > 0) : (i -= 1) {
            if (buf[i - 1] == '\\' or buf[i - 1] == '/') {
                name_start = i;
                break;
            }
        }
        break :blk buf[name_start..name_end];
    };

    const filename = "mapping.ini";
    if (std.mem.eql(u8, dir_name, "zzcaster")) {
        // exe is in zzcaster/ subdir — mapping.ini is right here
        if (exe_dir.len + filename.len + 1 <= buf.len) {
            // exe_dir already in buf at the right offset, just append filename
            @memcpy(buf[exe_dir.len .. exe_dir.len + filename.len], filename);
            const total = exe_dir.len + filename.len;
            buf[total] = 0;
            return buf[0..total];
        }
    }

    // exe is in MBAACC root — mapping.ini is in zzcaster/ subdir
    const subdir = "zzcaster\\";
    if (exe_dir.len + subdir.len + filename.len + 1 <= buf.len) {
        // exe_dir already in buf, shift right content and append
        @memcpy(buf[exe_dir.len .. exe_dir.len + subdir.len], subdir);
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
});

pub const CliMode = @import("main.zig").CliMode;

// Re-exported so ui_pages.zig and ui_waiting_for_peer.zig can import the
// same enum values via `const UiState = @import("ui.zig").UiState;`.
pub const UiState = enum { idle, waiting_for_peer, in_game, error_state };
pub const MenuPage = enum { play, game_config, controllers };

/// Netplay connection mode — toggled on the Play page.
///   .direct_ip — existing behavior: paste ip:port, requires port forward
///   .relay     — relay-assisted hole-punch, no port forward needed.
///                For zzcaster relays: uses 4-letter room codes.
///                For cccaster relays: uses ip:port (same UX as direct,
///                  but relay-assisted hole-punching through live CCCaster
///                  relays).
pub const NetplayMode = enum { direct_ip, relay };

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

    zgui.init(allocator);
    defer zgui.deinit();

    // Load custom font from memory
    const font_ttf = @embedFile("font.ttf");
    const font = zgui.io.addFontFromMemory(font_ttf, 18.0);
    zgui.io.setDefaultFont(font);

    zgui.backend.initWithGlSlVersion(window, gl_ctx, "#version 130");
    defer zgui.backend.deinit();

    zgui.styleColorsDark(zgui.getStyle());
    ui_theme.applyModernTheme();
    defer ui_theme.popModernTheme();

    // State
    var ui_state: UiState = .idle;
    var current_page: MenuPage = .play;
    var error_msg: [256]u8 = undefined;
    var error_msg_len: usize = 0;

    // Input buffers — sentinel-terminated for ImGui InputText
    var port_buf = [_:0]u8{ '4', '6', '3', '1', '8' } ++ [_]u8{0} ** 10;
    var peer_buf = [_:0]u8{ '1', '2', '7', '.', '0', '.', '0', '.', '1', ':', '4', '6', '3', '1', '8' } ++ [_]u8{0} ** 112;

    // Netplay mode: direct IP (existing) or relay-assisted (new).
    // Defaults to direct_ip for backward compatibility — existing users
    // aren't surprised by a new flow. Can flip default to .relay in a
    // future release once the relay path is battle-tested.
    var netplay_mode: NetplayMode = .direct_ip;

    // Room code / host address input for relay mode.
    // For zzcaster relays: 4-letter room code (e.g., "ABCD").
    // For cccaster relays: host's ip:port (e.g., "203.0.113.10:46318").
    var room_code_buf = [_:0]u8{0} ** 32;

    // Text input buffers for config
    var wincount_buf = [_:0]u8{ '2' } ++ [_]u8{0} ** 6;
    var rollback_buf = [_:0]u8{ '4' } ++ [_]u8{0} ** 6;
    // Delay override buffer for the host confirmation screen
    var delay_buf = [_:0]u8{0} ** 3;
    var delay_override_active: bool = false;

    // Display name input buffer
    var name_buf = [_:0]u8{0} ** 39;
    {
        const dn = cfg.display_name;
        const n = @min(dn.len, name_buf.len);
        @memcpy(name_buf[0..n], dn[0..n]);
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
    var bind_cooldown_until_ms: i64 = 0; // wall-clock ms; 0 = no cooldown active
    // View mode toggle: false = classic grid layout, true = list layout.
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
            _ = zgui.backend.processEvent(&event);
            if (event.type == c.SDL_QUIT) quit = true;
        }

        zgui.backend.newFrame(1024, 768);

        // Main fullscreen window
        zgui.setNextWindowSize(.{ .w = 1024, .h = 768, .cond = .always });
        zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
        const window_flags = zgui.WindowFlags{
            .no_title_bar = true,
            .no_resize = true,
            .no_move = true,
            .no_collapse = true,
            .no_bring_to_front_on_focus = true,
            .no_scrollbar = true,
        };

        if (zgui.begin("ZZCaster", .{ .flags = window_flags })) {
            // Draw the vertical gradient background first, so every page sits
            // on top of the dark→mid gradient instead of a flat fill.
            ui_theme.drawGradientBackground();

            switch (ui_state) {
                .idle => {
                    ui_pages.drawIdlePage(
                        allocator,
                        io,
                        cfg,
                        log,
                        pipe_name,
                        &current_page,
                        peer_buf[0..],
                        port_buf[0..],
                        &netplay_mode,
                        room_code_buf[0..],
                        name_buf[0..],
                        wincount_buf[0..],
                        rollback_buf[0..],
                        &ui_state,
                        &np_session,
                        &host_start_clicked,
                        &win_launcher,
                        &game_pid,
                        &ipc_server,
                        &error_msg,
                        &error_msg_len,
                        &p1_mapping,
                        &p2_mapping,
                        &p1_bind_target,
                        &p2_bind_target,
                        &p1_joystick,
                        &p2_joystick,
                        &p1_device_sel,
                        &p2_device_sel,
                        &bind_cooldown_until_ms,
                        &list_view,
                        mapping_path,
                        num_joy,
                        &quit,
                    );
                },
                .waiting_for_peer => {
                    ui_waiting_for_peer.drawWaitingForPeer(
                        allocator,
                        io,
                        cfg,
                        log,
                        pipe_name,
                        &np_session,
                        &win_launcher,
                        &game_pid,
                        &ipc_server,
                        &ui_state,
                        &error_msg,
                        &error_msg_len,
                        &host_start_clicked,
                        delay_buf[0..],
                        &delay_override_active,
                    );
                },
                .in_game => {
                    // Centered card showing game status.
                    const cw: f32 = 420;
                    const ch: f32 = 220;
                    const cx = (1024 - cw) / 2;
                    const cy = (768 - ch) / 2;
                    zgui.setCursorPos(.{ cx, cy });
                    if (ui_theme.beginCard("##in_game_card", cw, ch, false)) {
                        ui_theme.cardTitle("GAME RUNNING");
                        zgui.text("PID: {d}", .{game_pid});
                        zgui.spacing();
                        if (win_launcher) |*wl| {
                            if (!wl.isAlive()) {
                                ui_theme.textColored(ui_theme.COL_MUTED, "Game exited.", .{});
                                zgui.spacing();
                                if (ui_theme.primaryButton("OK", 160, 36)) {
                                    game_launcher.cleanupGame(&win_launcher, &game_pid, &ipc_server);
                                    ui_state = .idle;
                                }
                            } else {
                                ui_theme.textColored(ui_theme.COL_MUTED, "Waiting for game to exit...", .{});
                                zgui.spacing();
                                if (ui_theme.secondaryButton("Force Kill", 160, 36)) {
                                    if (win_launcher) |*wl2| {
                                        wl2.terminate();
                                    }
                                }
                            }
                        }
                    }
                    ui_theme.endCard();
                },
                .error_state => {
                    // Centered error card with red border accent.
                    const cw: f32 = 480;
                    const ch: f32 = 200;
                    const cx = (1024 - cw) / 2;
                    const cy = (768 - ch) / 2;
                    zgui.setCursorPos(.{ cx, cy });
                    if (ui_theme.beginCard("##error_card", cw, ch, false)) {
                        ui_theme.pushStyleColor(.text, ui_theme.COL_RED);
                        zgui.text("ERROR", .{});
                        ui_theme.popStyleColor(1);
                        zgui.spacing();
                        zgui.separator();
                        zgui.spacing();
                        zgui.pushTextWrapPos(0.0);
                        zgui.text("{s}", .{std.mem.sliceTo(&error_msg, 0)});
                        zgui.popTextWrapPos();
                        zgui.spacing();
                        zgui.spacing();
                        if (ui_theme.primaryButton("OK", 160, 36)) {
                            ui_state = .idle;
                        }
                    }
                    ui_theme.endCard();
                },
            }
        }
        zgui.end();

        _ = c.glClearColor(0.1, 0.1, 0.1, 1.0);
        _ = c.glClear(c.GL_COLOR_BUFFER_BIT | c.GL_DEPTH_BUFFER_BIT);
        zgui.backend.draw();
        c.SDL_GL_SwapWindow(window);
    }

    // Cleanup on quit
    ui_waiting_for_peer.cleanupSession(&np_session);
    game_launcher.cleanupGame(&win_launcher, &game_pid, &ipc_server);
}
