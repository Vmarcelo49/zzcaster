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
const relay_config = @import("net").relay_config;
const connection_detector = @import("net").connection_detector;
const ui = @import("ui.zig");
const ui_theme = @import("ui_theme.zig");
const zgui = @import("zgui");

const UiState = ui.UiState;
const MenuPage = ui.MenuPage;

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
    peer_buf: [:0]u8,
    port_buf: [:0]u8,
    name_buf: [:0]u8,
    wincount_buf: [:0]u8,
    rollback_buf: [:0]u8,
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
    zgui.setCursorPos(.{ ui_theme.SIDEBAR_W, ui_theme.HEADER_H });
    // Padding inside the content area.
    zgui.setCursorPosX(zgui.getCursorPosX() + ui_theme.CONTENT_PAD);
    zgui.setCursorPosY(zgui.getCursorPosY() + ui_theme.CONTENT_PAD);
    // Use a child window so content can scroll if it overflows, without
    // affecting the header/sidebar.
    const content_w: f32 = 1024 - ui_theme.SIDEBAR_W - ui_theme.CONTENT_PAD * 2;
    const content_h: f32 = 768 - ui_theme.HEADER_H - ui_theme.CONTENT_PAD * 2;
    _ = zgui.beginChild("##content", .{
        .w = content_w,
        .h = content_h,
        .window_flags = .{ .no_scrollbar = true },
    });

    switch (current_page.*) {
        .play => drawPlayPage(
            allocator, io, cfg, log, pipe_name, peer_buf, port_buf, ui_state,
            np_session, host_start_clicked, win_launcher, game_pid, ipc_server,
            error_msg, error_msg_len
        ),
        .game_config => drawConfigPage(allocator, io, cfg, log, name_buf, wincount_buf, rollback_buf),
        .controllers => drawControllersPage(allocator, io, log, p1_mapping, p2_mapping, p1_bind_target, p2_bind_target, p1_joystick, p2_joystick, p1_device_sel, p2_device_sel, bind_cooldown_until_ms, list_view, mapping_path, num_joy),
    }

    zgui.endChild(); // ##content
}

// ---------------------------------------------------------------------------
// Header bar
// ---------------------------------------------------------------------------

fn drawHeaderBar() void {
    // Header is a child window: 1024 wide × 64 tall, fixed at (0, 0).
    // We use a child window so we can paint a distinct background color
    // and avoid touching the main window's gradient.
    zgui.setNextWindowPos(.{ .x = 0, .y = 0, .cond = .always });
    ui_theme.pushStyleColor(.child_bg, ui_theme.COL_HEADER_BAR);
    ui_theme.pushStyleColor(.border, ui_theme.COL_TRANSPARENT);
    ui_theme.pushStyleVarVec2(.window_padding, ui_theme.CONTENT_PAD, 0);
    ui_theme.pushStyleVarFloat(.child_border_size, 0.0);
    defer ui_theme.popStyleVar(2);
    defer ui_theme.popStyleColor(2);
    if (zgui.beginChild("##header", .{
        .w = 1024,
        .h = ui_theme.HEADER_H,
        .window_flags = .{ .no_scrollbar = true },
    })) {
        // Vertical-center the logo text inside the 64px bar. The default
        // font line height is ~13-15px; we offset cursor Y so the text
        // visually centers. CalcTextSize gives us the exact line height.
        const logo_h = zgui.getTextLineHeight();
        const logo_y = (ui_theme.HEADER_H - logo_h) / 2;
        zgui.setCursorPosY(logo_y);
        // Use the draw list of the header child so the logo is drawn
        // relative to its window position.
        const wp = zgui.getWindowPos();
        ui_theme.drawLogo(wp[0] + ui_theme.CONTENT_PAD, wp[1] + logo_y);
        // Reserve the line so subsequent items (if any) don't overlap.
        zgui.dummy(.{ .w = 0, .h = logo_h });
    }
    zgui.endChild();
}

// ---------------------------------------------------------------------------
// Sidebar
// ---------------------------------------------------------------------------

fn drawSidebar(current_page: *MenuPage, quit: *bool) void {
    // Sidebar sits below the header, on the left edge.
    zgui.setNextWindowPos(.{ .x = 0, .y = ui_theme.HEADER_H, .cond = .always });
    const sb_h = 768 - ui_theme.HEADER_H;
    ui_theme.pushStyleColor(.child_bg, ui_theme.COL_SIDEBAR);
    ui_theme.pushStyleColor(.border, ui_theme.COL_CARD_BRD);
    ui_theme.pushStyleVarVec2(.window_padding, 7, ui_theme.CONTENT_PAD);
    ui_theme.pushStyleVarFloat(.child_border_size, 1.0);
    ui_theme.pushStyleVarVec2(.item_spacing, 0, 8);
    defer ui_theme.popStyleVar(3);
    defer ui_theme.popStyleColor(2);

    if (zgui.beginChild("##sidebar", .{
        .w = ui_theme.SIDEBAR_W,
        .h = sb_h,
        .child_flags = .{
            .border = true,
            .always_use_window_padding = true,
        },
        .window_flags = .{
            .no_scrollbar = true,
        },
    })) {
        // Nav buttons. Each is a square ~SIDEBAR_W-14 px wide. Active page
        // gets the red accent via ui_theme.navButton.
        if (ui_theme.navButton("P", current_page.* == .play)) current_page.* = .play;
        if (ui_theme.navButton("C", current_page.* == .game_config)) current_page.* = .game_config;
        if (ui_theme.navButton("M", current_page.* == .controllers)) current_page.* = .controllers;

        // Quit button fixed at the bottom. We compute remaining vertical
        // space and add a dummy to push it to the bottom edge.
        const btn_h = ui_theme.SIDEBAR_W - 14;
        const used_h = 3 * (btn_h + 8); // 3 nav buttons + spacing
        const pad_top: f32 = ui_theme.CONTENT_PAD;
        const pad_bot: f32 = ui_theme.CONTENT_PAD;
        const avail = sb_h - used_h - pad_top - pad_bot;
        if (avail > 0) zgui.dummy(.{ .w = 0, .h = avail });

        if (ui_theme.navButton("Q", false)) quit.* = true;
    }
    zgui.endChild();
}

// ---------------------------------------------------------------------------
// Netplay page — two cards: Host Game + Join/Spectate
// ---------------------------------------------------------------------------

fn drawPlayPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    pipe_name: []const u8,
    peer_buf: [:0]u8,
    port_buf: [:0]u8,
    ui_state: *UiState,
    np_session: *?session.NetplaySession,
    host_start_clicked: *bool,
    win_launcher: *?launcher.WindowsLauncher,
    game_pid: *u32,
    ipc_server: *?ipc.IpcServer,
    error_msg: *[256]u8,
    error_msg_len: *usize,
) void {
    const avail = zgui.getContentRegionAvail();
    const col_w: f32 = (avail[0] - ui_theme.CONTENT_PAD) / 2;
    const col_h: f32 = avail[1];

    // ---- Left Card: Netplay ----
    if (ui_theme.beginCard("##netplay_card", col_w, col_h, false)) {
        ui_theme.cardTitle("NETPLAY");

        // --- Single unified input layout (Slice 5 redesign) ---
        // Two fields only:
        //   1. Host Port (used for hosting)
        //   2. IP:Port or Room Code (used for joining)
        //
        // Auto-detection: the Join button figures out what the user typed
        // and picks the right connection strategy. No mode toggle needed.
        zgui.text("Host Port", .{});
        zgui.pushItemWidth(120);
        _ = zgui.inputText("##host_port", .{ .buf = port_buf });
        zgui.popItemWidth();

        zgui.spacing();
        zgui.separator();
        zgui.spacing();

        zgui.text("Join: IP:Port or Room Code", .{});
        zgui.pushItemWidth(-1);
        _ = zgui.inputText("##peer_addr", .{ .buf = peer_buf });
        zgui.popItemWidth();

        zgui.spacing();
        ui_theme.textColored(ui_theme.COL_TEXT_DIM, "Room code: 4 letters (e.g., ABCD)", .{});
        ui_theme.textColored(ui_theme.COL_TEXT_DIM, "Direct: ip:port (e.g., 192.168.0.2:46318)", .{});

        // --- Bottom action buttons ---
        const card_inner_w = zgui.getContentRegionAvail()[0];
        const btn_w = (card_inner_w - ui_theme.CONTENT_PAD * 2) / 3;

        const btn_y = col_h - 32 - ui_theme.CARD_PAD;
        zgui.setCursorPosY(btn_y);

        // Host button — always tries relay first, falls back to direct
        if (ui_theme.primaryButton("Host", btn_w, 32)) {
            const relay_source = getRelaySource(cfg);
            ui_waiting_for_peer.startSmartHostSession(
                allocator, io, cfg, log,
                game_launcher.parsePort(port_buf.ptr),
                relay_source,
                np_session,
            );
            if (np_session.* != null) {
                host_start_clicked.* = false;
                ui_state.* = .waiting_for_peer;
            }
        }
        zgui.sameLine(.{ .spacing = ui_theme.CONTENT_PAD });

        // Join button — auto-detects input format
        if (ui_theme.primaryButton("Join", btn_w, 32)) {
            const input = std.mem.sliceTo(peer_buf, 0);
            const relay_source = getRelaySource(cfg);
            ui_waiting_for_peer.startSmartJoinSession(
                allocator, io, cfg, log,
                input,
                relay_source,
                np_session,
            );
            if (np_session.* != null) {
                ui_state.* = .waiting_for_peer;
            }
        }
        zgui.sameLine(.{ .spacing = ui_theme.CONTENT_PAD });

        // Spectate button — always uses direct IP (spectate via relay
        // is not yet implemented — would need spectator chain support
        // in the relay protocol).
        if (ui_theme.secondaryButton("Spectate", btn_w, 32)) {
            game_launcher.launchNetplayImpl(allocator, io, cfg, log, std.mem.sliceTo(peer_buf, 0), true, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
            if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
        }
    }
    ui_theme.endCard();

    zgui.sameLine(.{ .spacing = ui_theme.CONTENT_PAD });

    // ---- Right Card: Offline ----
    if (ui_theme.beginCard("##offline_card", col_w, col_h, false)) {
        ui_theme.cardTitle("OFFLINE");

        const card_inner_w = zgui.getContentRegionAvail()[0];
        const btn_w: f32 = 280.0;
        const btn_h: f32 = 44.0;

        // Centered stacked buttons inside card
        const cy = (col_h - ui_theme.CARD_PAD * 2 - (btn_h * 2 + 8)) / 2;
        const cx = (card_inner_w - btn_w) / 2;

        zgui.setCursorPos(.{ cx, cy });
        if (ui_theme.primaryButton("Training", btn_w, btn_h)) {
            game_launcher.launchGameImpl(allocator, io, cfg, log, true, false, config.default_port, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
            if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
        }

        zgui.setCursorPosX(cx);
        if (ui_theme.primaryButton("Versus Mode", btn_w, btn_h)) {
            game_launcher.launchGameImpl(allocator, io, cfg, log, false, false, config.default_port, pipe_name, win_launcher, game_pid, ipc_server, error_msg, error_msg_len);
            if (game_pid.* > 0) ui_state.* = .in_game else ui_state.* = .error_state;
        }
    }
    ui_theme.endCard();
}

/// Returns the relay source string — either from config.ini's
/// relayServers= field, or the hardcoded DEFAULT_RELAY_LIST.
///
/// The returned slice points to memory owned by `cfg` (if config has
/// relayServers) or to a compile-time constant (if using defaults).
/// Either way, the caller doesn't need to free it.
fn getRelaySource(cfg: *const config.Config) []const u8 {
    if (cfg.relay_servers.len > 0) return cfg.relay_servers;
    return relay_config.DEFAULT_RELAY_LIST;
}

// ---------------------------------------------------------------------------
// Config page — three independent cards: Profile / Match Rules / Network
// ---------------------------------------------------------------------------

fn drawConfigPage(
    allocator: std.mem.Allocator,
    io: std.Io,
    cfg: *config.Config,
    log: *logging.Logger,
    name_buf: [:0]u8,
    wincount_buf: [:0]u8,
    rollback_buf: [:0]u8,
) void {
    const avail = zgui.getContentRegionAvail();
    const card_w: f32 = avail[0];

    // ---- Card 1: Player Profile ----
    if (ui_theme.beginCard("##cfg_profile", card_w, 0, true)) {
        ui_theme.cardTitle("PLAYER PROFILE");
        ui_theme.textColored(ui_theme.COL_MUTED, "Shown to opponents during netplay handshake.", .{});
        zgui.spacing();

        zgui.alignTextToFramePadding();
        zgui.text("Display Name", .{});
        zgui.sameLine(.{ .spacing = ui_theme.CONTENT_PAD });
        zgui.pushItemWidth(250);
        _ = zgui.inputText("##displayname", .{ .buf = name_buf });
        zgui.popItemWidth();

        zgui.sameLine(.{ .spacing = 16 });
        if (ui_theme.primaryButton("Apply##profile", 100, 0)) {
            const new_name = std.mem.sliceTo(name_buf, 0);
            if (cfg.display_name.len > 0) allocator.free(cfg.display_name);
            cfg.display_name = allocator.dupe(u8, new_name) catch &.{};
            config.saveConfig(cfg, io) catch {};
            log.info("Display name set to '{s}'", .{new_name});
        }
    }
    ui_theme.endCard();

    zgui.dummy(.{ .w = 0, .h = ui_theme.CONTENT_PAD });

    // ---- Card 2: Match Rules ----
    if (ui_theme.beginCard("##cfg_rules", card_w, 0, true)) {
        ui_theme.cardTitle("MATCH RULES");
        ui_theme.textColored(ui_theme.COL_MUTED, "Number of rounds needed to win a versus match.", .{});
        zgui.spacing();

        zgui.alignTextToFramePadding();
        zgui.text("Win Count   ", .{});
        zgui.sameLine(.{ .spacing = ui_theme.CONTENT_PAD });
        zgui.pushItemWidth(100);
        _ = zgui.inputText("##wincount", .{ .buf = wincount_buf });
        zgui.popItemWidth();

        zgui.sameLine(.{ .spacing = 16 });
        if (ui_theme.primaryButton("Apply##rules", 100, 0)) {
            const val = std.fmt.parseInt(u8, std.mem.sliceTo(wincount_buf, 0), 10) catch 2;
            cfg.versus_win_count = val;
            config.saveConfig(cfg, io) catch {};
            log.info("Win count set to {d}", .{val});
        }
    }
    ui_theme.endCard();

    zgui.dummy(.{ .w = 0, .h = ui_theme.CONTENT_PAD });

    // ---- Card 3: Network Settings ----
    if (ui_theme.beginCard("##cfg_net", card_w, 0, true)) {
        ui_theme.cardTitle("NETWORK SETTINGS");
        ui_theme.textColored(ui_theme.COL_MUTED, "Rollback input delay (frames). Higher = more stable, less responsive.", .{});
        zgui.spacing();

        zgui.alignTextToFramePadding();
        zgui.text("Rollback Frames", .{});
        zgui.sameLine(.{ .spacing = ui_theme.CONTENT_PAD });
        zgui.pushItemWidth(100);
        _ = zgui.inputText("##rollback", .{ .buf = rollback_buf });
        zgui.popItemWidth();

        zgui.sameLine(.{ .spacing = 16 });
        if (ui_theme.primaryButton("Apply##net", 100, 0)) {
            const val = std.fmt.parseInt(u8, std.mem.sliceTo(rollback_buf, 0), 10) catch 4;
            cfg.default_rollback = val;
            config.saveConfig(cfg, io) catch {};
            log.info("Rollback set to {d}", .{val});
        }
    }
    ui_theme.endCard();
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
    zgui.text("Controller Mapper", .{});
    zgui.sameLine(.{ .spacing = ui_theme.CONTENT_PAD });
    ui_theme.pushStyleVarVec2(.frame_padding, 4, 1);
    _ = zgui.checkbox("List View", .{ .v = list_view });
    ui_theme.popStyleVar(1);
    zgui.spacing();
    zgui.setCursorPosY(zgui.getCursorPosY() - 5.0);

    // Poll for bind input if active.
    var binding_changed = false;
    const now_ms = std.Io.Clock.now(.real, io).toMilliseconds();
    const cooldown_done = bind_cooldown_until_ms.* == 0 or now_ms >= bind_cooldown_until_ms.*;
    if (bind_cooldown_until_ms.* != 0 and cooldown_done) {
        bind_cooldown_until_ms.* = 0;
    }

    if (p1_bind_target.* != .none and cooldown_done) {
        const dev_idx: c_int = p1_device_sel.* - 1;
        if (mapper.pollForBindInput(p1_joystick.*, dev_idx)) |binding| {
            ui_controller_mapper.applyBinding(p1_mapping, p1_bind_target.*, binding);
            p1_bind_target.* = .none;
            binding_changed = true;
        }
    }
    if (p2_bind_target.* != .none and cooldown_done) {
        const dev_idx: c_int = p2_device_sel.* - 1;
        if (mapper.pollForBindInput(p2_joystick.*, dev_idx)) |binding| {
            ui_controller_mapper.applyBinding(p2_mapping, p2_bind_target.*, binding);
            p2_bind_target.* = .none;
            binding_changed = true;
        }
    }

    // Build device list for combo box.
    var dev_names_buf: [16][64]u8 = undefined;
    var dev_names: [16][*:0]const u8 = undefined;
    const dev_count = ui_controller_mapper.buildDeviceList(&dev_names_buf, &dev_names, num_joy);

    var panel_changed = false;

    if (list_view.*) {
        // List view: two side-by-side cards (Player 1 / Player 2).
        const avail = zgui.getContentRegionAvail();
        const col_w: f32 = (avail[0] - ui_theme.CONTENT_PAD) / 2;
        const col_h: f32 = avail[1];

        if (ui_theme.beginCard("##p1_card", col_w, col_h, false)) {
            if (ui_controller_mapper.drawListPanel("Player 1", p1_mapping, p1_bind_target, p1_joystick, p1_device_sel, &dev_names, dev_count, log, io, bind_cooldown_until_ms))
                panel_changed = true;
        }
        ui_theme.endCard();
        zgui.sameLine(.{ .spacing = ui_theme.CONTENT_PAD });
        if (ui_theme.beginCard("##p2_card", col_w, col_h, false)) {
            if (ui_controller_mapper.drawListPanel("Player 2", p2_mapping, p2_bind_target, p2_joystick, p2_device_sel, &dev_names, dev_count, log, io, bind_cooldown_until_ms))
                panel_changed = true;
        }
        ui_theme.endCard();
    } else {
        // Grid view: two stacked cards.
        const avail = zgui.getContentRegionAvail();
        const card_w: f32 = avail[0];
        const card_h: f32 = (avail[1] - 3.0) / 2; // gap between cards is 3px

        if (ui_theme.beginCardWithFlags("##p1_grid", card_w, card_h, false, .{ .no_scrollbar = true })) {
            if (ui_controller_mapper.drawPlayerPanel("Player 1", p1_mapping, p1_bind_target, p1_joystick, p1_device_sel, &dev_names, dev_count, num_joy, log, io, bind_cooldown_until_ms))
                panel_changed = true;
        }
        ui_theme.endCard();
        zgui.setCursorPosY(zgui.getCursorPosY() + 3.0);
        if (ui_theme.beginCardWithFlags("##p2_grid", card_w, card_h, false, .{ .no_scrollbar = true })) {
            if (ui_controller_mapper.drawPlayerPanel("Player 2", p2_mapping, p2_bind_target, p2_joystick, p2_device_sel, &dev_names, dev_count, num_joy, log, io, bind_cooldown_until_ms))
                panel_changed = true;
        }
        ui_theme.endCard();
    }

    // Autosave: persist mapping whenever anything changes.
    if (binding_changed or panel_changed) {
        p1_mapping.device_index = p1_device_sel.* - 1;
        p2_mapping.device_index = p2_device_sel.* - 1;
        mapper.saveMapping(p1_mapping.*, p2_mapping.*, mapping_path, io, log);
    }
}
