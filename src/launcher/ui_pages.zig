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
const ui_theme = @import("ui_theme.zig");

const UiState = ui.UiState;
const MenuPage = ui.MenuPage;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
    @cInclude("SDL2/SDL_opengl.h");
    @cInclude("cimgui_shim.h");
});

/// Render the idle (main menu) page. Modern layout:
///   - Fixed header bar (64px) at the top with ZZ+CASTER logo
///   - Compact sidebar (56px) on the left with N/O/C/M nav buttons + Q (quit) at bottom
///   - Right content area with page-specific cards
///
/// All state is mutated through the passed pointers — the function is a
/// pure view over the caller's data. Logic / behavior is unchanged from
/// the original launcher; only presentation is modernized.
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
    // ---- Header bar (fixed at top, full width) ----
    drawHeaderBar();

    // ---- Sidebar (below header, left edge) ----
    drawSidebar(current_page, quit);

    // ---- Content area (right of sidebar, below header) ----
    c.igSetCursorPos(.{ .x = ui_theme.SIDEBAR_W, .y = ui_theme.HEADER_H });
    // Padding inside the content area.
    c.igSetCursorPosX(c.igGetCursorPosX() + ui_theme.CONTENT_PAD);
    c.igSetCursorPosY(c.igGetCursorPosY() + ui_theme.CONTENT_PAD);
    // Use a child window so content can scroll if it overflows, without
    // affecting the header/sidebar.
    const content_w: f32 = 1024 - ui_theme.SIDEBAR_W - ui_theme.CONTENT_PAD * 2;
    const content_h: f32 = 768 - ui_theme.HEADER_H - ui_theme.CONTENT_PAD * 2;
    _ = c.igBeginChild_Str(
        "##content",
        .{ .x = content_w, .y = content_h },
        c.ImGuiChildFlags_None,
        c.ImGuiWindowFlags_NoScrollbar,
    );

    switch (current_page.*) {
        .netplay => drawNetplayPage(allocator, io, cfg, log, pipe_name, peer_buf, port_buf, ui_state, np_session, host_start_clicked, win_launcher, game_pid, ipc_server, error_msg, error_msg_len),
        .offline => drawOfflinePage(allocator, io, cfg, log, pipe_name, ui_state, win_launcher, game_pid, ipc_server, error_msg, error_msg_len),
        .game_config => drawConfigPage(allocator, io, cfg, log, name_buf, wincount_buf, rollback_buf),
        .controllers => drawControllersPage(allocator, io, log, p1_mapping, p2_mapping, p1_bind_target, p2_bind_target, p1_joystick, p2_joystick, p1_device_sel, p2_device_sel, bind_cooldown_until_ms, list_view, mapping_path, num_joy),
    }

    c.igEndChild(); // ##content
}

// ---------------------------------------------------------------------------
// Header bar
// ---------------------------------------------------------------------------

fn drawHeaderBar() void {
    // Header is a child window: 1024 wide × 64 tall, fixed at (0, 0).
    // We use a child window so we can paint a distinct background color
    // and avoid touching the main window's gradient.
    c.igSetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    ui_theme.pushStyleColor(c.ImGuiCol_ChildBg, ui_theme.COL_HEADER_BAR);
    ui_theme.pushStyleColor(c.ImGuiCol_Border, ui_theme.COL_TRANSPARENT);
    ui_theme.pushStyleVarVec2(c.ImGuiStyleVar_WindowPadding, ui_theme.CONTENT_PAD, 0);
    ui_theme.pushStyleVarFloat(c.ImGuiStyleVar_ChildBorderSize, 0.0);
    defer ui_theme.popStyleVar(2);
    defer ui_theme.popStyleColor(2);
    if (c.igBeginChild_Str("##header", .{ .x = 1024, .y = ui_theme.HEADER_H }, c.ImGuiChildFlags_None, c.ImGuiWindowFlags_NoScrollbar)) {
        // Vertical-center the logo text inside the 64px bar. The default
        // font line height is ~13-15px; we offset cursor Y so the text
        // visually centers. CalcTextSize gives us the exact line height.
        const logo_h = c.igGetTextLineHeight();
        const logo_y = (ui_theme.HEADER_H - logo_h) / 2;
        c.igSetCursorPosY(logo_y);
        // Use the draw list of the header child so the logo is drawn
        // relative to its window position.
        const wp = c.igGetWindowPos();
        ui_theme.drawLogo(wp.x + ui_theme.CONTENT_PAD, wp.y + logo_y);
        // Reserve the line so subsequent items (if any) don't overlap.
        c.igDummy(.{ .x = 0, .y = logo_h });
    }
    c.igEndChild();
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

fn drawSidebar(current_page: *MenuPage, quit: *bool) void {
    // Sidebar sits below the header, on the left edge.
    c.igSetNextWindowPos(.{ .x = 0, .y = ui_theme.HEADER_H }, c.ImGuiCond_Always, .{ .x = 0, .y = 0 });
    const sb_h = 768 - ui_theme.HEADER_H;
    ui_theme.pushStyleColor(c.ImGuiCol_ChildBg, ui_theme.COL_SIDEBAR);
    ui_theme.pushStyleColor(c.ImGuiCol_Border, ui_theme.COL_CARD_BRD);
    ui_theme.pushStyleVarVec2(c.ImGuiStyleVar_WindowPadding, 7, 12);
    ui_theme.pushStyleVarFloat(c.ImGuiStyleVar_ChildBorderSize, 1.0);
    ui_theme.pushStyleVarVec2(c.ImGuiStyleVar_ItemSpacing, 0, 8);
    defer ui_theme.popStyleVar(3);
    defer ui_theme.popStyleColor(2);

    if (c.igBeginChild_Str("##sidebar", .{ .x = ui_theme.SIDEBAR_W, .y = sb_h }, c.ImGuiChildFlags_Borders | c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_NoScrollbar)) {
        // Nav buttons. Each is a square ~SIDEBAR_W-14 px wide. Active page
        // gets the red accent via ui_theme.navButton.
        if (ui_theme.navButton("N", current_page.* == .netplay)) current_page.* = .netplay;
        if (ui_theme.navButton("O", current_page.* == .offline)) current_page.* = .offline;
        if (ui_theme.navButton("C", current_page.* == .game_config)) current_page.* = .game_config;
        if (ui_theme.navButton("M", current_page.* == .controllers)) current_page.* = .controllers;

        // Quit button fixed at the bottom. We compute remaining vertical
        // space and add a dummy to push it to the bottom edge.
        const btn_h = ui_theme.SIDEBAR_W - 14;
        const used_h = 4 * (btn_h + 8); // 4 nav buttons + spacing
        const pad_top: f32 = 12; // matches WindowPadding.y above
        const pad_bot: f32 = 12;
        const avail = sb_h - used_h - pad_top - pad_bot;
        if (avail > 0) c.igDummy(.{ .x = 0, .y = avail });

        if (ui_theme.navButton("Q", false)) quit.* = true;
    }
    c.igEndChild();
}

// ---------------------------------------------------------------------------
// Netplay page — two cards: Host Game + Join/Spectate
// ---------------------------------------------------------------------------

fn drawNetplayPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    pipe_name: []const u8,
    peer_buf: *[128]u8,
    port_buf: *[16]u8,
    ui_state: *UiState,
    np_session: *?session.NetplaySession,
    host_start_clicked: *bool,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    const avail = c.igGetContentRegionAvail();
    const col_w: f32 = (avail.x - 16) / 2; // 16 = inter-card gap
    const col_h: f32 = avail.y;

    // ---- Card 1: Host Game ----
    if (ui_theme.beginCard("##net_host", col_w, col_h, false)) {
        ui_theme.cardTitle("HOST GAME");
        ui_theme.textColored(ui_theme.COL_MUTED, "Open a port on your router, then wait for an opponent to join.", .{});
        c.igSpacing();

        c.igText("Port");
        c.igPushItemWidth(-1);
        _ = c.igInputText("##host_port", port_buf, port_buf.len, 0, null, null);
        c.igPopItemWidth();
        c.igSpacing();
        c.igSpacing();

        if (ui_theme.primaryButton("Host Game", -1, 38)) {
            ui_waiting_for_peer.startHostSession(allocator, io, cfg, log, game_launcher.parsePort(port_buf), np_session);
            if (np_session.* != null) {
                host_start_clicked.* = false;
                ui_state.* = .waiting_for_peer;
            }
        }
        ui_theme.endCard();
    }

    c.igSameLine(0, 16);

    // ---- Card 2: Join / Spectate ----
    if (ui_theme.beginCard("##net_join", col_w, col_h, false)) {
        ui_theme.cardTitle("JOIN / SPECTATE");
        ui_theme.textColored(ui_theme.COL_MUTED, "Connect to a host's IP:port. Spectate watches an ongoing match.", .{});
        c.igSpacing();

        c.igText("IP : Port");
        c.igPushItemWidth(-1);
        _ = c.igInputText("##peer_addr", peer_buf, peer_buf.len, 0, null, null);
        c.igPopItemWidth();
        c.igSpacing();

        c.igText("Port (host side, optional)");
        c.igPushItemWidth(-1);
        _ = c.igInputText("##join_port", port_buf, port_buf.len, 0, null, null);
        c.igPopItemWidth();
        c.igSpacing();
        c.igSpacing();

        if (ui_theme.primaryButton("Join Game", -1, 38)) {
            ui_waiting_for_peer.startJoinSession(allocator, io, cfg, log, std.mem.sliceTo(@as([*:0]u8, @ptrCast(peer_buf)), 0), np_session);
            if (np_session.* != null) {
                ui_state.* = .waiting_for_peer;
            }
        }
        c.igSpacing();
        if (ui_theme.secondaryButton("Spectate Match", -1, 32)) {
            game_launcher.launchNetplayImpl(allocator, io, cfg, log, std.mem.sliceTo(@as([*:0]u8, @ptrCast(peer_buf)), 0), true, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
            if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
        }
        ui_theme.endCard();
    }
}

// ---------------------------------------------------------------------------
// Offline page — Training Mode + Versus Mode cards
// ---------------------------------------------------------------------------

fn drawOfflinePage(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    pipe_name: []const u8,
    ui_state: *UiState,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    const avail = c.igGetContentRegionAvail();
    const col_w: f32 = (avail.x - 16) / 2;
    const col_h: f32 = avail.y;

    // ---- Card 1: Training Mode ----
    if (ui_theme.beginCard("##off_training", col_w, col_h, false)) {
        ui_theme.cardTitle("TRAINING MODE");
        c.igPushTextWrapPos(0.0);
        c.igText("Solo practice with infinite health and dummy settings. Ideal for labbing combos and setups.");
        c.igPopTextWrapPos();
        c.igSpacing();
        c.igSpacing();
        // Push button to bottom of the card.
        const btn_y = col_h - 38 - 16 - ui_theme.CARD_PAD;
        c.igSetCursorPosY(btn_y);
        if (ui_theme.primaryButton("Launch", -1, 38)) {
            game_launcher.launchGameImpl(allocator, io, cfg, log, true, false, config.default_port, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
            if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
        }
        ui_theme.endCard();
    }

    c.igSameLine(0, 16);

    // ---- Card 2: Versus Mode ----
    if (ui_theme.beginCard("##off_versus", col_w, col_h, false)) {
        ui_theme.cardTitle("VERSUS MODE");
        c.igPushTextWrapPos(0.0);
        c.igText("Local 1v1 between Player 1 and Player 2. Uses your configured win count for the match.");
        c.igPopTextWrapPos();
        c.igSpacing();
        c.igSpacing();
        const btn_y = col_h - 38 - 16 - ui_theme.CARD_PAD;
        c.igSetCursorPosY(btn_y);
        if (ui_theme.primaryButton("Launch", -1, 38)) {
            game_launcher.launchGameImpl(allocator, io, cfg, log, false, false, config.default_port, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
            if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
        }
        ui_theme.endCard();
    }
}

// ---------------------------------------------------------------------------
// Config page — three independent cards: Profile / Match Rules / Network
// ---------------------------------------------------------------------------

fn drawConfigPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    name_buf: *[40]u8,
    wincount_buf: *[8]u8,
    rollback_buf: *[8]u8,
) void {
    const avail = c.igGetContentRegionAvail();
    const col_w: f32 = (avail.x - 32) / 3; // 2 gaps × 16px
    const col_h: f32 = avail.y;

    // ---- Card 1: Player Profile ----
    if (ui_theme.beginCard("##cfg_profile", col_w, col_h, false)) {
        ui_theme.cardTitle("PLAYER PROFILE");
        ui_theme.textColored(ui_theme.COL_MUTED, "Shown to opponents during netplay handshake.", .{});
        c.igSpacing();

        c.igText("Display Name");
        c.igPushItemWidth(-1);
        _ = c.igInputText("##displayname", name_buf, name_buf.len, 0, null, null);
        c.igPopItemWidth();
        c.igSpacing();

        const btn_y = col_h - 38 - 16 - ui_theme.CARD_PAD;
        c.igSetCursorPosY(btn_y);
        if (ui_theme.primaryButton("Apply", -1, 38)) {
            const new_name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(name_buf)), 0);
            if (cfg.display_name.len > 0) allocator.free(cfg.display_name);
            cfg.display_name = allocator.dupe(u8, new_name) catch &.{};
            config.saveConfig(cfg, io) catch {};
            log.info("Display name set to '{s}'", .{new_name});
        }
        ui_theme.endCard();
    }

    c.igSameLine(0, 16);

    // ---- Card 2: Match Rules ----
    if (ui_theme.beginCard("##cfg_rules", col_w, col_h, false)) {
        ui_theme.cardTitle("MATCH RULES");
        ui_theme.textColored(ui_theme.COL_MUTED, "Number of rounds needed to win a versus match.", .{});
        c.igSpacing();

        c.igText("Win Count");
        c.igPushItemWidth(-1);
        _ = c.igInputText("##wincount", wincount_buf, wincount_buf.len, 0, null, null);
        c.igPopItemWidth();
        c.igSpacing();

        const btn_y = col_h - 38 - 16 - ui_theme.CARD_PAD;
        c.igSetCursorPosY(btn_y);
        if (ui_theme.primaryButton("Apply", -1, 38)) {
            const val = std.fmt.parseInt(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(wincount_buf)), 0), 10) catch 2;
            cfg.versus_win_count = val;
            config.saveConfig(cfg, io) catch {};
            log.info("Win count set to {d}", .{val});
        }
        ui_theme.endCard();
    }

    c.igSameLine(0, 16);

    // ---- Card 3: Network Settings ----
    if (ui_theme.beginCard("##cfg_net", col_w, col_h, false)) {
        ui_theme.cardTitle("NETWORK SETTINGS");
        ui_theme.textColored(ui_theme.COL_MUTED, "Rollback input delay (frames). Higher = more stable, less responsive.", .{});
        c.igSpacing();

        c.igText("Rollback Frames");
        c.igPushItemWidth(-1);
        _ = c.igInputText("##rollback", rollback_buf, rollback_buf.len, 0, null, null);
        c.igPopItemWidth();
        c.igSpacing();

        const btn_y = col_h - 38 - 16 - ui_theme.CARD_PAD;
        c.igSetCursorPosY(btn_y);
        if (ui_theme.primaryButton("Apply", -1, 38)) {
            const val = std.fmt.parseInt(u8, std.mem.sliceTo(@as([*:0]u8, @ptrCast(rollback_buf)), 0), 10) catch 4;
            cfg.default_rollback = val;
            config.saveConfig(cfg, io) catch {};
            log.info("Rollback set to {d}", .{val});
        }
        ui_theme.endCard();
    }
}

// ---------------------------------------------------------------------------
// Controllers page — keep existing functionality, apply card styling
// ---------------------------------------------------------------------------

fn drawControllersPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    log: *logging.Logger,
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
) void {
    _ = allocator;
    // Header row: title + list view toggle.
    c.igText("Controller Mapper");
    c.igSameLine(0, 16);
    _ = c.igCheckbox("List View", list_view);
    c.igSpacing();

    // Bind cooldown handling — same logic as before.
    const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
    const cooldown_done = bind_cooldown_until_ms.* == 0 or now_ms >= bind_cooldown_until_ms.*;
    if (bind_cooldown_until_ms.* != 0 and cooldown_done) {
        bind_cooldown_until_ms.* = 0;
    }

    // Poll for bind input if active.
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

    // Build device list for combo box.
    var dev_names_buf: [16][64]u8 = undefined;
    var dev_names: [16][*:0]const u8 = undefined;
    const dev_count = ui_controller_mapper.buildDeviceList(&dev_names_buf, &dev_names, num_joy);

    if (list_view.*) {
        // List view: two side-by-side cards (Player 1 / Player 2).
        const avail = c.igGetContentRegionAvail();
        const col_w: f32 = (avail.x - 16) / 2;
        const col_h: f32 = avail.y - 48; // leave room for Save button

        if (ui_theme.beginCard("##p1_card", col_w, col_h, false)) {
            ui_controller_mapper.drawListPanel("Player 1", p1_mapping, p1_bind_target, p1_joystick, p1_device_sel, &dev_names, dev_count, log, io, bind_cooldown_until_ms);
            ui_theme.endCard();
        }
        c.igSameLine(0, 16);
        if (ui_theme.beginCard("##p2_card", col_w, col_h, false)) {
            ui_controller_mapper.drawListPanel("Player 2", p2_mapping, p2_bind_target, p2_joystick, p2_device_sel, &dev_names, dev_count, log, io, bind_cooldown_until_ms);
            ui_theme.endCard();
        }
    } else {
        // Grid view: two stacked cards.
        const avail = c.igGetContentRegionAvail();
        const card_w: f32 = avail.x;
        const card_h: f32 = (avail.y - 48 - 16) / 2; // 16 = inter-card gap

        if (ui_theme.beginCard("##p1_grid", card_w, card_h, false)) {
            ui_controller_mapper.drawPlayerPanel("Player 1", p1_mapping, p1_bind_target, p1_joystick, p1_device_sel, &dev_names, dev_count, num_joy, log, io, bind_cooldown_until_ms);
            ui_theme.endCard();
        }
        c.igSpacing();
        if (ui_theme.beginCard("##p2_grid", card_w, card_h, false)) {
            ui_controller_mapper.drawPlayerPanel("Player 2", p2_mapping, p2_bind_target, p2_joystick, p2_device_sel, &dev_names, dev_count, num_joy, log, io, bind_cooldown_until_ms);
            ui_theme.endCard();
        }
    }

    c.igSpacing();
    // Save button — primary CTA, full card-aligned.
    if (ui_theme.primaryButton("Save Mapping", 220, 36)) {
        p1_mapping.device_index = p1_device_sel.* - 1;
        p2_mapping.device_index = p2_device_sel.* - 1;
        mapper.saveMapping(p1_mapping.*, p2_mapping.*, mapping_path, io, log);
    }
    c.igSameLine(0, 12);
    ui_theme.textColored(ui_theme.COL_MUTED, "(loaded by hook.dll on game start)", .{});
}
