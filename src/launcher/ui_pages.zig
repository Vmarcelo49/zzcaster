const std = @import("std");
const config = @import("common").config;
const logging = @import("common").logging;
const launcher = @import("launcher.zig");
const ipc = @import("common").ipc;
const mapper = @import("dll").controller_mapper;
const session = @import("session.zig");
const game_launcher = @import("game_launcher.zig");
const ui_controller_mapper = @import("ui_controller_mapper.zig");
const ui_waiting_for_peer = @import("ui_waiting_for_peer.zig");
const ui = @import("ui.zig");

const UiState = ui.UiState;
const MenuPage = ui.MenuPage;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_opengl.h");
    @cInclude("cimgui_shim.h");
});

/// Render the idle (main menu) page. Includes the sidebar with the four
/// page tabs (Netplay / Offline / Game Config / Controllers) and the
/// corresponding content area on the right.
///
/// All state is mutated through the passed pointers — the function is a
/// pure view over the caller's data.
pub fn drawIdlePage(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    pipe_name: []const u8,
    current_page: *MenuPage,
    peer_buf: *[128]u8,
    port_buf: *[16]u8,
    name_buf: *[40]u8,
    wincount_buf: *[8]u8,
    rollback_buf: *[8]u8,
    ui_state: *UiState,
    np_session: *?session.NetplaySession,
    host_start_clicked: *bool,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
    p1_mapping: *mapper.ControllerMapping,
    p2_mapping: *mapper.ControllerMapping,
    p1_bind_target: *mapper.BindingTarget,
    p2_bind_target: *mapper.BindingTarget,
    p1_joystick: *?*anyopaque,
    p2_joystick: *?*anyopaque,
    p1_device_sel: *c_int,
    p2_device_sel: *c_int,
    bind_cooldown_until_ms: *i64,
    list_view: *bool,
    mapping_path: []const u8,
    num_joy: c_int,
    quit: *bool,
) void {
    // Title bar
    c.igText("ZZCaster v%s", @as([*:0]const u8, @ptrCast(config.version_string.ptr)));
    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    // Two-column layout: left sidebar + right content
    // Left sidebar (120px wide)
    _ = c.igBeginChild_Str("Sidebar", .{ .x = 140, .y = 0 }, true, 0);

    if (c.igSelectable_Bool("Netplay / Spectate", current_page.* == .netplay, 0, .{ .x = 0, .y = 0 })) {
        current_page.* = .netplay;
    }
    if (c.igSelectable_Bool("Offline", current_page.* == .offline, 0, .{ .x = 0, .y = 0 })) {
        current_page.* = .offline;
    }
    if (c.igSelectable_Bool("Game Config", current_page.* == .game_config, 0, .{ .x = 0, .y = 0 })) {
        current_page.* = .game_config;
    }
    if (c.igSelectable_Bool("Controllers", current_page.* == .controllers, 0, .{ .x = 0, .y = 0 })) {
        current_page.* = .controllers;
    }

    c.igSpacing();
    c.igSeparator();
    c.igSpacing();

    if (c.igButton("Quit", .{ .x = 120, .y = 30 })) {
        quit.* = true;
    }

    c.igEndChild();

    // Right content area
    c.igSameLine(0, 4);
    _ = c.igBeginChild_Str("Content", .{ .x = 0, .y = 0 }, true, 0);

    switch (current_page.*) {
        .netplay => {
            c.igText("Netplay / Spectate");
            c.igSpacing();

            c.igText("IP:Port:");
            c.igSameLine(0, 8);
            _ = c.igInputText("##peer_addr", peer_buf, peer_buf.len, 0, null, null);

            c.igSpacing();

            c.igText("Port (for host):");
            c.igSameLine(0, 8);
            _ = c.igInputText("##host_port", port_buf, port_buf.len, 0, null, null);

            c.igSpacing();
            c.igSeparator();
            c.igSpacing();

            if (c.igButton("Host Game", .{ .x = 160, .y = 36 })) {
                ui_waiting_for_peer.startHostSession(allocator, io, cfg, log, game_launcher.parsePort(port_buf), np_session);
                if (np_session.* != null) {
                    host_start_clicked.* = false;
                    ui_state.* = .waiting_for_peer;
                }
            }
            c.igSpacing();
            if (c.igButton("Join Game", .{ .x = 160, .y = 36 })) {
                ui_waiting_for_peer.startJoinSession(allocator, io, cfg, log, std.mem.sliceTo(@as([*:0]u8, @ptrCast(peer_buf)), 0), np_session);
                if (np_session.* != null) {
                    ui_state.* = .waiting_for_peer;
                }
            }
            c.igSpacing();
            if (c.igButton("Spectate Match", .{ .x = 160, .y = 36 })) {
                game_launcher.launchNetplayImpl(allocator, io, cfg, log, std.mem.sliceTo(@as([*:0]u8, @ptrCast(peer_buf)), 0), true, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
                if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
            }
        },
        .offline => {
            c.igText("Offline Play");
            c.igSpacing();
            c.igSeparator();
            c.igSpacing();

            if (c.igButton("Training Mode", .{ .x = 200, .y = 40 })) {
                game_launcher.launchGameImpl(allocator, io, cfg, log, true, false, config.default_port, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
                if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
            }
            c.igSpacing();
            if (c.igButton("Versus Mode (P1 vs P2)", .{ .x = 200, .y = 40 })) {
                game_launcher.launchGameImpl(allocator, io, cfg, log, false, false, config.default_port, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
                if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
            }
        },
        .game_config => {
            c.igText("Game Configuration");
            c.igSpacing();
            c.igSeparator();
            c.igSpacing();

            c.igText("Display Name:");
            c.igSameLine(0, 8);
            _ = c.igInputText("##displayname", name_buf, name_buf.len, 0, null, null);
            c.igSameLine(0, 8);
            if (c.igButton("Apply##name", .{ .x = 60, .y = 0 })) {
                const new_name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(name_buf)), 0);
                if (cfg.display_name.len > 0) allocator.free(cfg.display_name);
                cfg.display_name = allocator.dupe(u8, new_name) catch &.{};
                config.saveConfig(cfg, io) catch {};
                log.info("Display name set to '{s}'", .{new_name});
            }

            c.igSpacing();

            c.igText("Versus Win Count:");
            c.igSameLine(0, 8);
            _ = c.igInputText("##wincount", wincount_buf, wincount_buf.len, 0, null, null);
            c.igSameLine(0, 8);
            if (c.igButton("Apply", .{ .x = 60, .y = 0 })) {
                const val = std.fmt.parseInt(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(wincount_buf)), 0), 10) catch 2;
                cfg.versus_win_count = val;
                log.info("Win count set to {d}", .{val});
            }

            c.igSpacing();

            c.igText("Rollback Frames:");
            c.igSameLine(0, 8);
            _ = c.igInputText("##rollback", rollback_buf, rollback_buf.len, 0, null, null);
            c.igSameLine(0, 8);
            if (c.igButton("Apply##rb", .{ .x = 60, .y = 0 })) {
                const val = std.fmt.parseInt(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(rollback_buf)), 0), 10) catch 4;
                cfg.default_rollback = val;
                log.info("Rollback set to {d}", .{val});
            }

            c.igSpacing();
            c.igSeparator();
            c.igSpacing();

            c.igText("Current: Win Count = %d, Rollback = %d", cfg.versus_win_count, cfg.default_rollback);
            c.igText("Display Name = %s", @as([*:0]const u8, @ptrCast(name_buf)));
        },
        .controllers => {
            c.igText("Controller Mapper");
            c.igSameLine(0, 16);
            _ = c.igCheckbox("List View", list_view);
            c.igSpacing();
            c.igSeparator();
            c.igSpacing();

            // Check bind cooldown using wall-clock ms so it runs at real-time
            // speed regardless of the UI's frame rate. The cooldown prevents
            // the same click that triggered "press to bind" from being read
            // back as the binding itself.
            const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
            const cooldown_done = bind_cooldown_until_ms.* == 0 or now_ms >= bind_cooldown_until_ms.*;
            if (bind_cooldown_until_ms.* != 0 and cooldown_done) {
                bind_cooldown_until_ms.* = 0;
            }

            // Poll for bind input if active
            if (p1_bind_target.* != .none and cooldown_done) {
                const dev_idx: c_int = p1_device_sel.* - 1;
                if (mapper.pollForBindInput(p1_joystick.*, dev_idx)) |binding| {
                    ui_controller_mapper.applyBinding(p1_mapping, p1_bind_target.*, binding);
                    p1_bind_target.* = .none;
                }
            }
            if (p2_bind_target.* != .none and cooldown_done) {
                const dev_idx: c_int = p2_device_sel.* - 1;
                if (mapper.pollForBindInput(p2_joystick.*, dev_idx)) |binding| {
                    ui_controller_mapper.applyBinding(p2_mapping, p2_bind_target.*, binding);
                    p2_bind_target.* = .none;
                }
            }

            // Build device list for combo box
            var dev_names_buf: [16][64]u8 = undefined;
            var dev_names: [16][*:0]const u8 = undefined;
            const dev_count = ui_controller_mapper.buildDeviceList(&dev_names_buf, &dev_names, num_joy);

            if (list_view.*) {
                // === LIST VIEW ===
                // Two side-by-side columns: Player 1 (left) and
                // Player 2 (right). Each column has a device
                // combo, then a vertical list of bind rows:
                //   [in-game button name] [bind button]
                // Below both columns: shared controls (deadzone,
                // default bindings, clear, save).

                // Left column: Player 1
                _ = c.igBeginChild_Str("P1List", .{ .x = 0, .y = 0 }, true, 0);
                ui_controller_mapper.drawListPanel("Player 1", p1_mapping, p1_bind_target, p1_joystick, p1_device_sel, &dev_names, dev_count, log, io, bind_cooldown_until_ms);
                c.igEndChild();

                c.igSameLine(0, 8);

                // Right column: Player 2
                _ = c.igBeginChild_Str("P2List", .{ .x = 0, .y = 0 }, true, 0);
                ui_controller_mapper.drawListPanel("Player 2", p2_mapping, p2_bind_target, p2_joystick, p2_device_sel, &dev_names, dev_count, log, io, bind_cooldown_until_ms);
                c.igEndChild();
            } else {
                // === GRID VIEW (classic layout) ===
                ui_controller_mapper.drawPlayerPanel("Player 1", p1_mapping, p1_bind_target, p1_joystick, p1_device_sel, &dev_names, dev_count, num_joy, log, io, bind_cooldown_until_ms);

                c.igSpacing();
                c.igSeparator();
                c.igSpacing();

                ui_controller_mapper.drawPlayerPanel("Player 2", p2_mapping, p2_bind_target, p2_joystick, p2_device_sel, &dev_names, dev_count, num_joy, log, io, bind_cooldown_until_ms);
            }

            c.igSpacing();
            c.igSeparator();
            c.igSpacing();

            // Save button (shared between both views)
            if (c.igButton("Save Mapping", .{ .x = 160, .y = 30 })) {
                p1_mapping.device_index = p1_device_sel.* - 1;
                p2_mapping.device_index = p2_device_sel.* - 1;
                mapper.saveMapping(p1_mapping.*, p2_mapping.*, mapping_path, io, log);
            }
            c.igSameLine(0, 8);
            c.igText("(loaded by hook.dll on game start)");
        },
    }

    c.igEndChild(); // Content
}
