const std = @import("std");
const logging = @import("common").logging;
const rollback = @import("rollback.zig");
const sfx_dedup = @import("sfx_dedup.zig");
const spectator_manager_mod = @import("spectator_manager.zig");
const net = @import("net").enet_transport;
const rollback_regions = @import("rollback_regions.zig");
const air_dash = @import("air_dash_macro.zig");

const Md5 = std.crypto.hash.Md5;

// Use the shared ENet cimport from enet_transport.zig so all files see the
// same `cimport.struct__ENetPeer` / `cimport.struct__ENetHost` types.
const enet = net.enet;

// Game memory addresses
const game_mode_addr: *u32 = @ptrFromInt(0x54EEE8);
const world_timer_addr: *u32 = @ptrFromInt(0x55D1D4);
const skip_frames_addr: *u32 = @ptrFromInt(0x55D25C);
const alive_flag_addr: *u8 = @ptrFromInt(0x76E650);
const damage_level_addr: *u32 = @ptrFromInt(0x553FCC);
const timer_speed_addr: *u32 = @ptrFromInt(0x553FD0);
const win_count_vs_addr: *u32 = @ptrFromInt(0x553FDC);
const ptr_to_write_input_addr: [*]u8 = @ptrFromInt(0x76E6AC);
const p1_offset_direction: u32 = 0x18;
const p1_offset_buttons: u32 = 0x24;
const p2_offset_direction: u32 = 0x2C;
const p2_offset_buttons: u32 = 0x38;

// RNG state addresses
const rng_state0_addr: *u32 = @ptrFromInt(0x563778);
const rng_state1_addr: *u32 = @ptrFromInt(0x56377C);
const rng_state2_addr: *u32 = @ptrFromInt(0x564068);
const rng_state3_addr: [*]u8 = @ptrFromInt(0x564070);
const rng_state3_size: u32 = 220;

// Sync-relevant addresses (ported from netplay/Constants.hpp).
// Used by the SyncHash desync detector and the intro→in-game transition.
const game_state_addr: *u32 = @ptrFromInt(0x74D598); // CC_GAME_STATE_ADDR (99 = intro done)
const intro_state_addr: *u8 = @ptrFromInt(0x55D20B); // CC_INTRO_STATE_ADDR (2=chara intro, 1=pre-game, 0=in-game)
const round_timer_addr: *u32 = @ptrFromInt(0x562A3C); // CC_ROUND_TIMER_ADDR
const real_timer_addr: *u32 = @ptrFromInt(0x562A40); // CC_REAL_TIMER_ADDR
const camera_x_addr: *i32 = @ptrFromInt(0x564B14); // CC_CAMERA_X_ADDR
const camera_y_addr: *i32 = @ptrFromInt(0x564B18); // CC_CAMERA_Y_ADDR

// Player struct layout (CC_PLR_STRUCT_SIZE = 0xAFC). P1 base = 0x555130.
const player_struct_size: u32 = 0xAFC;
const p1_base: u32 = 0x555130;
const p2_base: u32 = 0x555130 + player_struct_size;
const p3_base: u32 = 0x555130 + 2 * player_struct_size; // P1 puppet
const p4_base: u32 = 0x555130 + 3 * player_struct_size; // P2 puppet
// Offsets within a player struct (relative to base).
const off_enabled: u32 = 0x000; // u8
const off_sequence: u32 = 0x010; // u32
const off_seq_state: u32 = 0x014; // u32
const off_health: u32 = 0x0BC; // u32
const off_red_health: u32 = 0x0C0; // u32
const off_guard_bar: u32 = 0x0C4; // f32
const off_guard_quality: u32 = 0x0D8; // f32
const off_meter: u32 = 0x0E0; // u32
const off_heat: u32 = 0x0E4; // u32
const off_x: u32 = 0x108; // i32
const off_y: u32 = 0x10C; // i32
const off_no_input_flag: u32 = 0x177; // u8
const off_puppet_state: u32 = 0x178; // u8

// Character select selectors (only valid in chara-select state).
const p1_character_addr: *u32 = @ptrFromInt(0x74D8FC);
const p2_character_addr: *u32 = @ptrFromInt(0x74D920);
const p1_moon_addr: *u32 = @ptrFromInt(0x74D900);
const p2_moon_addr: *u32 = @ptrFromInt(0x74D924);

// Game-state values (CC_GAME_STATE_*).
const game_state_intro_done: u32 = 99; // CC_GAME_STATE_INTRO_DONE

// Number of frames in the initial movement-only (pre-game) intro phase.
// Matches CC_PRE_GAME_INTRO_FRAMES in Constants.hpp. During a rollback
// re-run that advances past this frame, CC_INTRO_STATE_ADDR must be forced
// to 0 so the re-run doesn't re-trigger intro logic.
const pre_game_intro_frames: u32 = 224;

// Game modes
const mode_startup: u32 = 65535;
const mode_opening: u32 = 3;
const mode_title: u32 = 2;
const mode_main: u32 = 25;
const mode_chara_select: u32 = 20;
const mode_loading: u32 = 8;
const mode_in_game: u32 = 1;

// Buttons
pub const button_confirm: u16 = 0x0400;
pub const button_a: u16 = 0x0010;
pub const button_b: u16 = 0x0020;
pub const button_c: u16 = 0x0008;
pub const button_d: u16 = 0x0004;
pub const button_e: u16 = 0x0080;
pub const button_start: u16 = 0x0001;

// ASM addresses
const loop_start_addr: u32 = 0x40D330;
const hook_call1_addr: u32 = 0x40D032;
const hook_call2_addr: u32 = 0x40D411;
const multiple_melty_addr: *u8 = @ptrFromInt(0x40D25A);
const force_goto_addr: *u8 = @ptrFromInt(0x42B475);
const keyboard_config_offset: u32 = 0x14D2C0;

const num_inputs: u32 = 30;
const max_rollback: u8 = 15;

// Health-check timeouts (ported from CCCaster's GoBackN keepalive + input-wait)
const heartbeat_timeout_ms: i64 = 20000; // 20s — no packet → peer is dead
const input_wait_timeout_ms: i64 = 10000; // 10s — no remote input → timed out

pub const NetplayState = enum {
    pre_initial,
    initial,
    chara_select,
    loading,
    chara_intro,
    skippable,
    in_game,
    retry_menu,
};

pub const NetplayConfig = struct {
    is_host: bool = false,
    is_training: bool = false,
    is_spectator: bool = false, // spectator client mode (no local input → host)
    delay: u8 = 0,
    rollback: u8 = 0,
    rollback_delay: u8 = 0,
    win_count: u8 = 2,
    host_player: u8 = 1,
    local_player: u8 = 1,
    remote_player: u8 = 2,
    peer_addr: [64]u8 = [_]u8{0} ** 64,
    peer_port: u16 = 0,
    is_netplay: bool = false,
    spectator_listen_port: u16 = 0, // host: port to also-listen on for spectators (== peer_port)
};

const md5_digest_size: usize = 16;

const CharaHash = extern struct {
    seq: u32 = 0,
    seq_state: u32 = 0,
    health: u32 = 0,
    red_health: u32 = 0,
    meter: u32 = 0,
    heat: u32 = 0,
    guard_bar: f32 = 0,
    guard_quality: f32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    chara: u16 = 0,
    moon: u16 = 0,
};

const SyncHash = struct {
    // indexed_frame packed as u64 (frame | (index << 32)) — matches legacy
    // IndexedFrame.value and makes ordering/comparison trivial.
    indexed_frame: u64 = 0,
    hash: [md5_digest_size]u8 = [_]u8{0} ** md5_digest_size,
    round_timer: u32 = 0,
    real_timer: u32 = 0,
    camera_x: i32 = 0,
    camera_y: i32 = 0,
    chara: [2]CharaHash = .{ .{}, .{} },

    /// Snapshot the current game state into a SyncHash. Mirrors the legacy
    /// SyncHash constructor in DllHacks.cpp. When not in-game, only the
    /// character/moon selectors are captured (matching legacy's early return).
    fn capture(indexed_frame: u64) SyncHash {
        var sh: SyncHash = .{ .indexed_frame = indexed_frame };

        // MD5 over RNG state (3 × u32 + 220 bytes), exactly as legacy does.
        var rng_buf: [12 + rng_state3_size]u8 = undefined;
        std.mem.writeInt(u32, rng_buf[0..4], rng_state0_addr.*, .little);
        std.mem.writeInt(u32, rng_buf[4..8], rng_state1_addr.*, .little);
        std.mem.writeInt(u32, rng_buf[8..12], rng_state2_addr.*, .little);
        @memcpy(rng_buf[12..][0..rng_state3_size], rng_state3_addr[0..rng_state3_size]);
        Md5.hash(&rng_buf, &sh.hash, .{});

        if (game_mode_addr.* != mode_in_game) {
            // Pre-game: only chara/moon selectors are meaningful.
            sh.chara[0].chara = @truncate(p1_character_addr.*);
            sh.chara[0].moon = @truncate(p1_moon_addr.*);
            sh.chara[1].chara = @truncate(p2_character_addr.*);
            sh.chara[1].moon = @truncate(p2_moon_addr.*);
            return sh;
        }

        sh.round_timer = round_timer_addr.*;
        sh.real_timer = real_timer_addr.*;
        sh.camera_x = camera_x_addr.*;
        sh.camera_y = camera_y_addr.*;

        sh.chara[0] = readCharaHash(p1_base);
        sh.chara[1] = readCharaHash(p2_base);
        // chara/moon come from the chara-select selector addresses even in-game
        // (legacy SAVE_CHARA reads CC_Pn_CHARACTER_ADDR / CC_Pn_MOON_SELECTOR_ADDR).
        sh.chara[0].chara = @truncate(p1_character_addr.*);
        sh.chara[0].moon = @truncate(p1_moon_addr.*);
        sh.chara[1].chara = @truncate(p2_character_addr.*);
        sh.chara[1].moon = @truncate(p2_moon_addr.*);
        return sh;
    }

    /// Compare two hashes. Returns true if they match (legacy operator==,
    /// including the seq==0 seqState exception). The indexed_frame is NOT
    /// compared here — callers pair entries by indexed_frame before invoking.
    fn matches(self: SyncHash, other: SyncHash) bool {
        if (!std.mem.eql(u8, &self.hash, &other.hash)) return false;
        if (self.round_timer != other.round_timer) return false;
        if (self.real_timer != other.real_timer) return false;
        if (self.camera_x != other.camera_x) return false;
        if (self.camera_y != other.camera_y) return false;
        return charaMatches(self.chara[0], other.chara[0]) and
            charaMatches(self.chara[1], other.chara[1]);
    }

    fn charaMatches(a: CharaHash, b: CharaHash) bool {
        // Compare everything except the two seq fields first (legacy compares
        // the byte block from offset 8 onward, i.e. health..moon).
        if (a.health != b.health) return false;
        if (a.red_health != b.red_health) return false;
        if (a.meter != b.meter) return false;
        if (a.heat != b.heat) return false;
        if (a.guard_bar != b.guard_bar) return false;
        if (a.guard_quality != b.guard_quality) return false;
        if (a.x != b.x) return false;
        if (a.y != b.y) return false;
        if (a.seq != b.seq) return false;
        // Special case: seq 0 (the neutral sequence) is allowed to differ in
        // seqState — legacy quirk preserved for hash compatibility.
        if (a.seq != 0 and a.seq_state != b.seq_state) return false;
        return true;
    }

    /// Serialize into a flat byte buffer for the wire. Format:
    ///   [8 indexed_frame][16 md5][4 round_timer][4 real_timer]
    ///   [4 camera_x][4 camera_y][2 × CharaHash (48 bytes each)]
    /// Total = 8 + 16 + 16 + 96 = 136 bytes.
    fn serialize(self: SyncHash, buf: []u8) usize {
        std.mem.writeInt(u64, buf[0..8], self.indexed_frame, .little);
        @memcpy(buf[8..24], &self.hash);
        std.mem.writeInt(u32, buf[24..28], self.round_timer, .little);
        std.mem.writeInt(u32, buf[28..32], self.real_timer, .little);
        std.mem.writeInt(i32, buf[32..36], self.camera_x, .little);
        std.mem.writeInt(i32, buf[36..40], self.camera_y, .little);
        writeCharaHash(buf[40..88], self.chara[0]);
        writeCharaHash(buf[88..136], self.chara[1]);
        return 136;
    }

    fn deserialize(data: []const u8) ?SyncHash {
        if (data.len < 136) return null;
        var sh: SyncHash = .{};
        sh.indexed_frame = std.mem.readInt(u64, data[0..8], .little);
        @memcpy(&sh.hash, data[8..24]);
        sh.round_timer = std.mem.readInt(u32, data[24..28], .little);
        sh.real_timer = std.mem.readInt(u32, data[28..32], .little);
        sh.camera_x = std.mem.readInt(i32, data[32..36], .little);
        sh.camera_y = std.mem.readInt(i32, data[36..40], .little);
        sh.chara[0] = readCharaHashBuf(data[40..88]);
        sh.chara[1] = readCharaHashBuf(data[88..136]);
        return sh;
    }

    fn writeCharaHash(buf: []u8, c: CharaHash) void {
        std.mem.writeInt(u32, buf[0..4], c.seq, .little);
        std.mem.writeInt(u32, buf[4..8], c.seq_state, .little);
        std.mem.writeInt(u32, buf[8..12], c.health, .little);
        std.mem.writeInt(u32, buf[12..16], c.red_health, .little);
        std.mem.writeInt(u32, buf[16..20], c.meter, .little);
        std.mem.writeInt(u32, buf[20..24], c.heat, .little);
        std.mem.writeInt(u32, buf[24..28], @bitCast(c.guard_bar), .little);
        std.mem.writeInt(u32, buf[28..32], @bitCast(c.guard_quality), .little);
        std.mem.writeInt(i32, buf[32..36], c.x, .little);
        std.mem.writeInt(i32, buf[36..40], c.y, .little);
        std.mem.writeInt(u16, buf[40..42], c.chara, .little);
        std.mem.writeInt(u16, buf[42..44], c.moon, .little);
        // 44 bytes used; legacy CharaHash struct has padding to 48 (the 16-bit
        // chara/moon fields force alignment). We pack tightly here and the
        // 4 trailing bytes are unused — buf[44..48] is scratch.
    }

    fn readCharaHashBuf(buf: []const u8) CharaHash {
        return .{
            .seq = std.mem.readInt(u32, buf[0..4], .little),
            .seq_state = std.mem.readInt(u32, buf[4..8], .little),
            .health = std.mem.readInt(u32, buf[8..12], .little),
            .red_health = std.mem.readInt(u32, buf[12..16], .little),
            .meter = std.mem.readInt(u32, buf[16..20], .little),
            .heat = std.mem.readInt(u32, buf[20..24], .little),
            .guard_bar = @bitCast(std.mem.readInt(u32, buf[24..28], .little)),
            .guard_quality = @bitCast(std.mem.readInt(u32, buf[28..32], .little)),
            .x = std.mem.readInt(i32, buf[32..36], .little),
            .y = std.mem.readInt(i32, buf[36..40], .little),
            .chara = std.mem.readInt(u16, buf[40..42], .little),
            .moon = std.mem.readInt(u16, buf[42..44], .little),
        };
    }
};

/// Read a CharaHash from a player struct base address. Mirrors SAVE_CHARA in
/// DllHacks.cpp, including the guardBar=0-during-intro rule.
fn readCharaHash(base_addr: u32) CharaHash {
    const base: [*]u8 = @ptrFromInt(base_addr);
    return .{
        .seq = readU32At(base + off_sequence),
        .seq_state = readU32At(base + off_seq_state),
        .health = readU32At(base + off_health),
        .red_health = readU32At(base + off_red_health),
        .meter = readU32At(base + off_meter),
        .heat = readU32At(base + off_heat),
        // Legacy zeroes guardBar while CC_INTRO_STATE_ADDR != 0 — the bar is
        // not meaningful during the intro. Preserve that for hash parity.
        .guard_bar = if (intro_state_addr.* != 0) 0.0 else @bitCast(readU32At(base + off_guard_bar)),
        .guard_quality = @bitCast(readU32At(base + off_guard_quality)),
        .x = @bitCast(readU32At(base + off_x)),
        .y = @bitCast(readU32At(base + off_y)),
        // chara/moon come from the chara-select selectors, not the player
        // struct. Filled by the caller for in-game too.
        .chara = 0,
        .moon = 0,
    };
}

fn readU32At(p: [*]u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}

// SyncHash cadence/queue sizing. Placed at file scope because Zig disallows
// declarations between struct fields. Ported from the legacy SyncHash exchange
// (DllMain.cpp:775-789): send every 5s and at frame 149 of each 150-cycle.
const sync_send_period: u32 = 5 * 60; // 5 seconds at 60fps
const sync_queue_len: u8 = 16;

// Host re-sends the RNG state this many frames apart while waiting for the
// peer's RNG_ACK. ~0.5s at 60fps is slow enough not to flood, fast enough to
// recover within the chara-select phase well before the first SyncHash check
// at frame 149.
const rng_resend_period: u32 = 30;

// Round-over: extra frames to wait before committing the InGame→Skippable
// transition when rollback is enabled. Matches ROLLBACK_ROUND_OVER_DELAY in
// DllMain.cpp:38.
const rollback_round_over_delay: i32 = 5;

pub const NetplayManager = struct {
    allocator: std.mem.Allocator,

    io: std.Io,
    log: *logging.Logger,
    config: NetplayConfig = .{},
    state: NetplayState = .pre_initial,

    enet_host: ?*enet.ENetHost = null,
    enet_peer: ?*enet.ENetPeer = null,
    enet_connected: bool = false,

    local_inputs: rollback.InputBuffer,
    remote_inputs: rollback.InputBuffer,

    indexed_frame: struct { frame: u32 = 0, index: u32 = 0 } = .{},
    start_world_time: u32 = 0,

    state_pool: rollback.StatePool,
    rollback_timer: u8 = 0,
    min_rollback_spacing: u8 = 2,
    fast_fwd_stop_frame: u32 = 0,

    round_over_timer: i32 = -1,

    sfx_dedup: ?sfx_dedup.SfxDedup = null,

    air_dash_macro: air_dash.AirDashMacro = .{},

    spectators: ?spectator_manager_mod.SpectatorManager = null,

    should_sync_rng: bool = true,
    rng_synced: bool = false,

    // RNG ack handshake: the host sends RNG state, but the peer must confirm
    // receipt before the host treats the sync as complete. The lazy-reconnect
    // design (ENet connection established inside frameStep, not in the
    // launcher) means the host's first RNG packet can be sent before the peer
    // has finished its ENet CONNECT — so the packet would be dropped and the
    // host would run with `rng_synced=true` while the peer still has its own
    // seed. That diverged the RNG hash and triggered a false desync at
    // frame 149. The ack closes this race: the host re-sends RNG until the
    // peer's ack arrives, and only then flips `rng_synced`.
    rng_acked: bool = false,
    rng_send_cooldown: u32 = 0, // frames until next resend attempt
    rng_send_count: u32 = 0, // diagnostic: how many times we sent

    intro_rng_enabled: bool = false,

    // Round-start detection: the detectRoundStart ASM hack (asm_hacks.zig)
    // increments a counter in DLL memory each time a round begins. We watch
    // it for changes to drive the Skippable → InGame transition (round 2+),
    // matching the legacy Variable::RoundStart change-monitor in
    // DllMain.cpp:1266-1270. last_round_start is the last-seen value.
    last_round_start: u32 = 0,

    // Input resend
    resend_timer_active: bool = false,
    wait_ticks: u32 = 0,

    connect_attempts: u32 = 0,
    connect_attempts_exhausted: bool = false,

    was_connected: bool = false,

    diag_connect_disconnects: u32 = 0,
    diag_connect_receives: u32 = 0,

    remote_index: u32 = 0,

    last_packet_ms: i64 = 0,

    local_sync: [sync_queue_len]SyncHash = [_]SyncHash{.{}} ** sync_queue_len,
    remote_sync: [sync_queue_len]SyncHash = [_]SyncHash{.{}} ** sync_queue_len,
    local_sync_count: u8 = 0, // entries valid from index 0
    remote_sync_count: u8 = 0,
    desync_detected: bool = false,
    desync_local: ?SyncHash = null,
    desync_remote: ?SyncHash = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, log: *logging.Logger) !NetplayManager {
        return .{
            .allocator = allocator,
            .io = io,
            .log = log,
            .local_inputs = rollback.InputBuffer.init(allocator),
            .remote_inputs = rollback.InputBuffer.init(allocator),
            .state_pool = rollback.StatePool.init(allocator),
            .sfx_dedup = try sfx_dedup.SfxDedup.init(allocator),
            .spectators = spectator_manager_mod.SpectatorManager.init(allocator, io, log),
        };
    }

    pub fn deinit(self: *NetplayManager) void {
        self.local_inputs.deinit();
        self.remote_inputs.deinit();
        self.state_pool.deinit();
        if (self.sfx_dedup) |*sd| sd.deinit();
        if (self.spectators) |*sm| sm.deinit();
        if (self.enet_peer != null) {
            enet.enet_peer_disconnect(self.enet_peer, 0);
            enet.enet_host_flush(self.enet_host);
        }
        if (self.enet_host != null) {
            enet.enet_host_destroy(self.enet_host);
        }
        enet.enet_deinitialize();
    }

    pub fn configure(self: *NetplayManager, cfg: NetplayConfig) void {
        self.config = cfg;
        self.min_rollback_spacing = if (cfg.rollback > 0) @max(@min(cfg.rollback, 4), 2) else 2;
        self.rollback_timer = self.min_rollback_spacing;
        if (self.sfx_dedup) |*sd| sd.setLogger(self.log);
        self.log.info("NetplayManager: delay={d} rollback={d} host={} spectator={}", .{
            cfg.delay, cfg.rollback, cfg.is_host, cfg.is_spectator,
        });
    }

    pub fn initEnet(self: *NetplayManager) !void {
        if (enet.enet_initialize() != 0) {
            self.log.err("ENet init failed", .{});
            return error.EnetInitFailed;
        }

        if (self.config.is_host) {
            var addr: enet.ENetAddress = undefined;
            addr.host = enet.ENET_HOST_ANY;
            addr.port = self.config.peer_port;
            // 1 main peer + 15 spectators = 16 total peers; 3 channels (0=reliable, 1=inputs, 2=spectator).
            self.enet_host = enet.enet_host_create(&addr, 16, 3, 0, 0);
            // Stage-0 diag: log the host_create return so we can tell bind
            // success from bind failure in the DLL log.
            self.log.info("DIAG: host_create returned {x} on port {d}", .{
                @intFromPtr(self.enet_host), self.config.peer_port,
            });
            if (self.enet_host == null) {
                self.log.err("ENet host_create failed on port {d}", .{self.config.peer_port});
                return error.HostCreateFailed;
            }
            // Hook spectator manager to this host.
            if (self.spectators) |*sm| sm.setEnetHost(self.enet_host);
            self.log.info("ENet listening on port {d} (1 player + up to 15 spectators)", .{self.config.peer_port});
        } else {
            // Spectator OR player-2 client — both connect outbound.
            self.enet_host = enet.enet_host_create(null, 1, 3, 0, 0);
            // Stage-0 diag: log the client host_create return too.
            self.log.info("DIAG: client host_create returned {x}", .{@intFromPtr(self.enet_host)});
            if (self.enet_host == null) return error.HostCreateFailed;

            var addr: enet.ENetAddress = undefined;
            const addr_z = std.mem.sliceTo(&self.config.peer_addr, 0);
            var addr_buf: [64]u8 = undefined;
            const addr_z_copy = std.fmt.bufPrintZ(&addr_buf, "{s}", .{addr_z}) catch return error.AddrTooLong;
            if (enet.enet_address_set_host(&addr, addr_z_copy.ptr) != 0) {
                self.log.err("DIAG: enet_address_set_host failed for {s}", .{addr_z});
                return error.BadAddr;
            }
            addr.port = self.config.peer_port;

            // Stage-0 diag: log the resolved address (host is network byte
            // order) so we can confirm 127.0.0.1 actually resolved. Format
            // the 4 bytes as dotted-quad for readability.
            const h = std.mem.bigToNative(u32, addr.host);
            self.log.info("DIAG: resolved peer = {d}.{d}.{d}.{d}:{d}", .{
                (h >> 24) & 0xff, (h >> 16) & 0xff, (h >> 8) & 0xff, h & 0xff,
                addr.port,
            });

            // For spectators, use a non-zero connect data so the host can
            // immediately distinguish them from the main player peer.
            // 0x5FEC == "SPEC" sentinel (visual mnemonic).
            const connect_data: u32 = if (self.config.is_spectator) 0x5FEC else 0;
            self.enet_peer = enet.enet_host_connect(self.enet_host, &addr, 3, connect_data);
            // Stage-0 diag: log the host_connect return — a null here means
            // the connect call itself failed (not the same as a timeout).
            self.log.info("DIAG: host_connect returned {x} (spectator={})", .{
                @intFromPtr(self.enet_peer), self.config.is_spectator,
            });
            if (self.enet_peer == null) return error.ConnectFailed;
            self.log.info("ENet connecting to {s}:{d} (spectator={})", .{
                addr_z, self.config.peer_port, self.config.is_spectator,
            });
        }
    }

    // The previous `pub fn waitForEnetConnect(self, timeout_ms) !void` was
    // REMOVED — it was dead code per docs/netcode-test-plan.md (status:
    // Proposed) and had no callers in the codebase. The frame loop in
    // frame_step.zig handles ENet connect events via `drainSpectatorEvents()`
    // and the regular `enet_host_service` poll path. Keeping this stub
    // created two mental models of the same connect flow.

    /// After the main peer is connected, the host should call this each
    /// frame to accept/deny any incoming spectator connections.
    pub fn drainSpectatorEvents(self: *NetplayManager) void {
        if (self.enet_host == null) return;
        if (!self.config.is_host) return;
        if (self.spectators == null) return;

        var event: enet.ENetEvent = undefined;
        while (enet.enet_host_service(self.enet_host, &event, 0) > 0) {
            const peer_opt: ?*enet.ENetPeer = if (event.peer != null) event.peer else null;
            switch (event.type) {
                enet.ENET_EVENT_TYPE_CONNECT => {
                    // Distinguish main peer (already connected) from spectator
                    // by checking connect data (0x5FEC == "SPEC" sentinel).
                    if (peer_opt) |p| {
                        if (p.data != null) {
                            const cd: *u32 = @ptrCast(@alignCast(p.data.?));
                            if (cd.* == 0x5FEC) {
                                self.spectators.?.onNewPeer(peer_opt, std.Io.Clock.now(.real, self.io).toMilliseconds());
                                continue;
                            }
                        }
                    }
                    // Default: treat as spectator (no connect data set).
                    self.spectators.?.onNewPeer(peer_opt, std.Io.Clock.now(.real, self.io).toMilliseconds());
                },
                enet.ENET_EVENT_TYPE_DISCONNECT => {
                    self.spectators.?.onPeerDisconnect(peer_opt);
                },
                enet.ENET_EVENT_TYPE_RECEIVE => {
                    // Route by channel: 2 = spectator control messages.
                    // Non-channel-2 messages are regular gameplay packets
                    // (inputs, RNG, TransitionIndex) that arrived while the
                    // host was also draining spectator events — dispatch them
                    // via handleMessage so they're not lost.
                    if (event.packet != null) {
                        const pkt = event.packet;
                        const data_ptr = pkt.*.data;
                        const data_len = pkt.*.dataLength;
                        if (event.channelID == 2) {
                            self.handleSpectatorMessage(peer_opt, data_ptr[0..data_len]);
                        } else {
                            const copy_len = @min(data_len, recv_buf.len);
                            @memcpy(recv_buf[0..copy_len], data_ptr[0..copy_len]);
                            self.handleMessage(recv_buf[0..copy_len]);
                        }
                        enet.enet_packet_destroy(event.packet);
                    }
                },
                else => {},
            }
        }

        // Check pending timeouts.
        self.spectators.?.checkPendingTimeouts(std.Io.Clock.now(.real, self.io).toMilliseconds());
    }

    fn handleSpectatorMessage(self: *NetplayManager, peer: ?*enet.ENetPeer, data: []const u8) void {
        if (peer == null or data.len == 0) return;
        const msg_type = data[0];
        switch (msg_type) {
            0x01 => {
                // HELLO from spectator — promote to active.
                const start_index: u32 = if (data.len >= 5) std.mem.readInt(u32, data[1..5], .little) else 0;
                self.spectators.?.activateSpectator(peer, start_index);
            },
            else => {
                self.log.warn("Unknown spectator message type: 0x{x}", .{msg_type});
            },
        }
    }

    pub fn pollEnet(self: *NetplayManager, timeout_ms: u32) ?[]const u8 {
        if (self.enet_host == null) return null;
        var event: enet.ENetEvent = undefined;
        if (enet.enet_host_service(self.enet_host, &event, timeout_ms) <= 0) return null;

        const peer_opt: ?*enet.ENetPeer = if (event.peer != null) event.peer else null;

        switch (event.type) {
            enet.ENET_EVENT_TYPE_RECEIVE => {
                if (!self.enet_connected) self.diag_connect_receives += 1;
                // Heartbeat: record when we last heard from the peer.
                self.last_packet_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
                const pkt = event.packet;
                const data = pkt.*.data;
                const len = pkt.*.dataLength;
                const copy_len = @min(len, recv_buf.len);
                @memcpy(recv_buf[0..copy_len], data[0..copy_len]);
                enet.enet_packet_destroy(event.packet);
                return recv_buf[0..copy_len];
            },
            enet.ENET_EVENT_TYPE_DISCONNECT => {
                if (!self.enet_connected) {
                    self.diag_connect_disconnects += 1;
                    self.log.warn("DIAG: DISCONNECT during connect phase (peer refused/timed out) count={d}", .{
                        self.diag_connect_disconnects,
                    });
                }
                // Host: if this was a spectator, route to SpectatorManager.
                if (self.config.is_host and self.spectators != null) {
                    self.spectators.?.onPeerDisconnect(peer_opt);
                    if (peer_opt == self.enet_peer) {
                        self.enet_connected = false;
                        self.log.warn("Main peer disconnected", .{});
                    }
                    return null;
                }
                self.enet_connected = false;
                self.was_connected = true; // don't tear down on first poll
                self.log.warn("ENet peer disconnected", .{});
                return null;
            },
            enet.ENET_EVENT_TYPE_CONNECT => {
                // Mark the main peer connected. For host the first CONNECT
                // is the player-2 peer; subsequent ones are spectators.
                self.log.info("DIAG: ENET_EVENT_TYPE_CONNECT received host={} connected_before={}", .{
                    self.config.is_host,
                    self.enet_connected,
                });
                // Heartbeat: start the heartbeat clock from the CONNECT event.
                self.last_packet_ms = std.Io.Clock.now(.real, self.io).toMilliseconds();
                if (self.config.is_host and !self.enet_connected) {
                    self.enet_peer = event.peer;
                    self.enet_connected = true;
                    self.was_connected = true;
                    self.log.info("Main peer connected", .{});
                } else if (!self.config.is_host) {
                    self.enet_peer = event.peer;
                    self.enet_connected = true;
                    self.was_connected = true;
                    self.log.info("ENet peer connected!", .{});
                } else if (self.spectators != null) {
                    self.spectators.?.onNewPeer(peer_opt, std.Io.Clock.now(.real, self.io).toMilliseconds());
                }
                return null;
            },
            else => return null,
        }
    }

    /// Dispatch a received message to the appropriate handler based on the
    /// 1-byte type tag. Called by pollAndDispatch for each received packet.
    fn handleMessage(self: *NetplayManager, msg: []const u8) void {
        if (msg.len < 1) return;
        switch (msg[0]) {
            0x01 => { // Player inputs
                if (msg.len >= 8) self.setRemoteInputs(msg[1..]);
            },
            0x02 => { // RNG state
                self.applyRemoteRng(msg);
            },
            0x03 => { // TransitionIndex
                if (msg.len >= 5) {
                    const idx = std.mem.readInt(u32, msg[1..5], .little);
                    self.setRemoteIndex(idx);
                }
            },
            0x04 => { // SyncHash (desync detection)
                self.applyRemoteSyncHash(msg[1..]);
            },
            0x05 => { // RNG_ACK (peer confirms it applied the host's RNG state)
                if (msg.len >= 5) {
                    const idx = std.mem.readInt(u32, msg[1..5], .little);
                    self.confirmRngAck(idx);
                }
            },
            0x20 => { // BothInputs (spectator broadcast from host)
                if (self.config.is_spectator) {
                    self.applyBothInputsPacket(msg[1..]);
                }
            },
            else => {
                self.log.warn("Unknown message type: 0x{x}", .{msg[0]});
            },
        }
    }

    /// Poll ENet for events and dispatch any received messages. Call this
    /// once per frame to process incoming network traffic. The first poll
    /// uses the given timeout; subsequent polls use 0 to drain all pending.
    pub fn pollAndDispatch(self: *NetplayManager, timeout_ms: u32) void {
        if (self.pollEnet(timeout_ms)) |msg| {
            self.handleMessage(msg);
        }
        while (self.pollEnet(0)) |msg| {
            self.handleMessage(msg);
        }
    }

    var recv_buf: [4096]u8 = undefined;

    pub fn applyBothInputsPacket(self: *NetplayManager, data: []const u8) void {
        if (data.len < 8) return;
        const start_frame = std.mem.readInt(u32, data[0..4], .little);
        const start_index = std.mem.readInt(u32, data[4..8], .little);
        const num = (data.len - 8) / 4;
        var i: u32 = 0;
        while (i < num) : (i += 1) {
            const p1 = std.mem.readInt(u16, data[8 + i * 4 .. 10 + i * 4][0..2], .little);
            const p2 = std.mem.readInt(u16, data[10 + i * 4 .. 12 + i * 4][0..2], .little);
            self.local_inputs.set(start_index, start_frame + i, p1);
            self.remote_inputs.set(start_index, start_frame + i, p2);
        }
    }

    /// Spectator: get both inputs for the current frame.
    pub fn getSpectatorInputs(self: *const NetplayManager) struct { p1: u16, p2: u16 } {
        return .{
            .p1 = self.local_inputs.get(self.indexed_frame.index, self.indexed_frame.frame),
            .p2 = self.remote_inputs.get(self.indexed_frame.index, self.indexed_frame.frame),
        };
    }

    pub fn sendInputs(self: *NetplayManager, inputs: []const u8) void {
        if (self.enet_peer == null or !self.enet_connected) return;

        var tagged: [1 + 128]u8 = .{0x01} ++ .{0} ** 128;
        const copy_len = @min(inputs.len, tagged.len - 1);
        @memcpy(tagged[1..][0..copy_len], inputs[0..copy_len]);
        const packet = enet.enet_packet_create(&tagged, 1 + copy_len, 0); // unreliable
        if (packet != null) {
            _ = enet.enet_peer_send(self.enet_peer, 1, packet);
            enet.enet_host_flush(self.enet_host);
        }
    }

    var dbg_send_inputs: u32 = 0;
    var dbg_send_reliable: u32 = 0;

    pub fn sendReliable(self: *NetplayManager, data: []const u8) void {
        if (self.enet_peer == null or !self.enet_connected) return;
        const packet = enet.enet_packet_create(data.ptr, data.len, enet.ENET_PACKET_FLAG_RELIABLE);
        if (packet != null) {
            _ = enet.enet_peer_send(self.enet_peer, 0, packet);
            enet.enet_host_flush(self.enet_host);
        }
    }

    pub fn updateFrame(self: *NetplayManager) void {
        const world_timer = world_timer_addr.*;
        self.indexed_frame.frame = world_timer - self.start_world_time;
    }

    pub fn isPreGame(_: *const NetplayManager) bool {
        const mode = game_mode_addr.*;
        return mode == mode_startup or mode == mode_opening or
            mode == mode_title or mode == mode_main;
    }

    pub fn isInGame(self: *const NetplayManager) bool {
        return self.state == .in_game;
    }

    pub fn isInRollback(self: *const NetplayManager) bool {
        // Spectators never trigger rollback — they just replay both players'
        // inputs as delivered by the host.
        if (self.config.is_spectator) return false;
        return self.isInGame() and self.config.rollback > 0 and self.config.is_netplay;
    }

    pub fn shouldCatchUp(self: *const NetplayManager) bool {
        if (self.remote_inputs.getEndIndex() == 0) return false;
        const remote_end_index = self.remote_inputs.getEndIndex() - 1;
        return remote_end_index > self.indexed_frame.index + 1;
    }

    pub fn getNetplayInput(self: *NetplayManager, raw_input: u16) u16 {
        switch (self.state) {
            .pre_initial, .initial => {
                // Mash Confirm every other frame to auto-advance through
                // the title screen and menus.
                if (self.indexed_frame.frame % 2 == 0) {
                    return button_confirm << 4;
                }
                return 0;
            },
            .chara_select => {
                var input = raw_input;

                // Mask Cancel so neither player can back out of chara-select
                // and desync the state machine (legacy getCharaSelectInput).
                input &= ~@as(u16, 0x8000);

                // Moon-selector desync guard (legacy DllNetplayManager.cpp:138):
                // for the first 150 frames of chara-select, mask A + Confirm.
                // The moon (Crescent/Full/Half) selector hasn't settled
                // identically on both sides yet; confirming too early can
                // lock the two clients into different moon styles and desync
                // at round start. 150f ≈ 2.5s at 60fps.
                if (self.config.is_netplay and self.indexed_frame.frame < 150) {
                    input &= ~@as(u16, 0x0100); // A
                    input &= ~@as(u16, 0x4000); // Confirm
                }
                return input;
            },
            .loading, .chara_intro, .skippable => {
                // If remote is ahead, mash Confirm to catch up.
                if (self.shouldCatchUp()) {
                    if (self.indexed_frame.frame % 2 == 0) {
                        return button_confirm << 4;
                    }
                    return 0;
                }
                // Otherwise, only allow Confirm/Cancel through — suppress
                // all direction and action buttons so the player can't
                // accidentally affect game state during loading/intro.
                // Confirm = 0x0400 in btns = 0x4000 in combined.
                // Cancel  = 0x0800 in btns = 0x8000 in combined.
                return raw_input & 0xC000; // keep only Confirm + Cancel bits
            },
            .in_game, .retry_menu => {
                // Real input — game logic handles filtering.
                return raw_input;
            },
        }
    }

    pub fn setLocalInput(self: *NetplayManager, input: u16) void {
        const frame = self.indexed_frame.frame + self.config.delay;
        self.local_inputs.set(self.indexed_frame.index, frame, input);
    }

    pub fn getLocalInput(self: *const NetplayManager) u16 {
        return self.local_inputs.get(self.indexed_frame.index, self.indexed_frame.frame);
    }

    pub fn setRemoteInputs(self: *NetplayManager, data: []const u8) void {
        // Parse input packet: [4 bytes start_frame][4 bytes index][N × 2 bytes inputs]
        if (data.len < 8) return;
        const start_frame = std.mem.readInt(u32, data[0..4], .little);
        const index = std.mem.readInt(u32, data[4..8], .little);
        const num = (data.len - 8) / 2;
        if (num == 0) return;

        // Only keep remote inputs at most 1 transition index old (legacy guard)
        if (index + 1 < self.indexed_frame.index) return;

        var inputs_buf: [num_inputs]u16 = undefined;
        const n = @min(num, inputs_buf.len);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            inputs_buf[i] = std.mem.readInt(u16, data[8 + i * 2 ..][0..2], .little);
        }

        // check_changes=true so last_changed_frame is updated on misprediction
        // (needed for rollback to trigger; harmless for delay-based since
        // checkRollback returns false when rollback=0).
        self.remote_inputs.setRemote(index, start_frame, inputs_buf[0..n], true);
    }

    pub fn getRemoteInput(self: *const NetplayManager) u16 {
        return self.remote_inputs.get(self.indexed_frame.index, self.indexed_frame.frame);
    }

    /// Check if the peer has been silent for too long. Returns true if the
    /// heartbeat has expired (no packet received in HEARTBEAT_TIMEOUT_MS).
    /// Called from frameStep to detect dead peers that crashed without
    /// sending a DISCONNECT event.
    pub fn checkHeartbeat(self: *const NetplayManager) bool {
        if (!self.enet_connected or self.last_packet_ms == 0) return false;
        const now = std.Io.Clock.now(.real, self.io).toMilliseconds();
        return (now - self.last_packet_ms) > heartbeat_timeout_ms;
    }

    pub fn isRemoteInputReady(self: *const NetplayManager) bool {
        // In CharaSelect and InGame, the frame loop MUST block until the
        // remote peer has caught up to our transition index AND has sent
        // input for the current frame. This is the lock-step gate that
        // keeps both sides synchronized — without it, one side can race
        // ahead (e.g. start the match while the other is still loading).
        //
        // Loading / CharaIntro / Skippable / RetryMenu do NOT block:
        // each side runs at its own pace, and the catch-up mash logic
        // in getNetplayInput() ensures the lagging side auto-skips.
        switch (self.state) {
            .pre_initial, .initial, .loading, .chara_intro, .skippable, .retry_menu => return true,
            .chara_select, .in_game => {},
        }

        // Offline / spectator: always ready
        if (!self.config.is_netplay or self.config.is_spectator) return true;

        const our_index = self.indexed_frame.index;

        // No remote inputs at all yet — wait
        if (self.remote_inputs.getEndIndex() == 0) return false;

        const remote_end_index = self.remote_inputs.getEndIndex() - 1;

        // Remote is behind us — wait for them to catch up to our index
        if (remote_end_index < our_index) return false;

        // Remote is ahead of us — use prediction, don't wait
        if (remote_end_index > our_index) return true;

        // Same index — check if we have the frame we need
        const needed = self.indexed_frame.frame + self.config.delay;
        const end_frame = self.remote_inputs.getEndFrame(our_index);
        return end_frame > needed;
    }

    // --- Send local inputs to peer ---

    pub fn sendLocalInputs(self: *NetplayManager) void {
        // Send the last num_inputs frames of local input, up to frame+delay.
        // Wire format (after sendInputs prepends 0x01 tag):
        //   [4 start_frame][4 index][N × 2 inputs]
        const last_frame = self.indexed_frame.frame + self.config.delay;
        const start_frame: u32 = if (last_frame + 1 < num_inputs)
            0
        else
            last_frame + 1 - num_inputs;

        var buf: [4 + 4 + num_inputs * 2]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], start_frame, .little);
        std.mem.writeInt(u32, buf[4..8], self.indexed_frame.index, .little);
        var i: u32 = 0;
        while (i < num_inputs) : (i += 1) {
            const input = self.local_inputs.get(self.indexed_frame.index, start_frame + i);
            std.mem.writeInt(u16, buf[8 + i * 2 ..][0..2], input, .little);
        }
        self.sendInputs(buf[0 .. 8 + num_inputs * 2]);
    }

    // --- RNG sync ---

    pub fn syncRngState(self: *NetplayManager) void {
        if (!self.should_sync_rng or self.rng_acked) return;
        if (!self.config.is_host) return;
        // Lazy-reconnect: only send once the ENet peer has actually connected.
        // The peer's CONNECT event may not have arrived yet on the first
        // frames of chara-select; sending before that silently drops the
        // packet (sendReliable bails when !enet_connected), so we must not
        // burn a send attempt or mark anything done in that window.
        if (self.enet_peer == null or !self.enet_connected) return;

        // Throttle resends so we don't flood the peer every frame while the
        // ack is in flight. Send immediately on the first attempt, then wait
        // rng_resend_period frames between retries.
        if (self.rng_send_count > 0 and self.rng_send_cooldown > 0) {
            self.rng_send_cooldown -= 1;
            return;
        }

        // Host sends RNG state to client. Format:
        //   [1 byte type=0x02][4 bytes index][4+4+4+220 bytes RNG state]
        const payload_len: usize = 1 + 4 + 4 + 4 + 4 + rng_state3_size;
        var rng_buf: [1 + 4 + 4 + 4 + 4 + rng_state3_size]u8 = undefined;
        rng_buf[0] = 0x02;
        std.mem.writeInt(u32, rng_buf[1..5], self.indexed_frame.index, .little);
        std.mem.writeInt(u32, rng_buf[5..9], rng_state0_addr.*, .little);
        std.mem.writeInt(u32, rng_buf[9..13], rng_state1_addr.*, .little);
        std.mem.writeInt(u32, rng_buf[13..17], rng_state2_addr.*, .little);
        @memcpy(rng_buf[17..][0..rng_state3_size], rng_state3_addr[0..rng_state3_size]);
        self.sendReliable(rng_buf[0..payload_len]);

        self.rng_send_count += 1;
        self.rng_send_cooldown = rng_resend_period;
        // NOTE: rng_synced / rng_acked are NOT set here. The host only treats
        // the sync as complete once the peer's RNG_ACK arrives. This closes
        // the race where the first send was dropped before the peer finished
        // connecting.
        self.log.info("RNG state sent (index={d}, attempt={d})", .{ self.indexed_frame.index, self.rng_send_count });
    }

    pub fn applyRemoteRng(self: *NetplayManager, data: []const u8) void {
        // Skip the 1-byte type tag added by syncRngState.
        // Format: [1 type=0x02][4 index][4 rng0][4 rng1][4 rng2][220 rng3]
        if (data.len < 1 + 16 + rng_state3_size) return;
        const body = data[1..];
        const rng_index = std.mem.readInt(u32, body[0..4], .little);

        // Only accept RNG for our current index or the one we're about to
        // enter. This prevents stale RNG from a previous round overwriting
        // the current round's state.
        if (rng_index != self.indexed_frame.index and rng_index != self.indexed_frame.index + 1) {
            self.log.warn("Ignoring RNG for index {d} (we're at {d})", .{ rng_index, self.indexed_frame.index });
            return;
        }

        rng_state0_addr.* = std.mem.readInt(u32, body[4..8], .little);
        rng_state1_addr.* = std.mem.readInt(u32, body[8..12], .little);
        rng_state2_addr.* = std.mem.readInt(u32, body[12..16], .little);
        @memcpy(rng_state3_addr[0..rng_state3_size], body[16 .. 16 + rng_state3_size]);
        self.rng_synced = true;
        self.log.info("Applied remote RNG state (index={d})", .{rng_index});

        // Acknowledge receipt so the host can stop re-sending and flip its
        // rng_synced flag. The host may re-send several times before this
        // arrives (see syncRngState); replying to every received packet is
        // fine — the host ignores acks after the first.
        self.sendRngAck(rng_index);
    }

    /// Peer → host: confirm the RNG state for `rng_index` was applied.
    /// Format: [1 byte type=0x05][4 bytes index]
    fn sendRngAck(self: *NetplayManager, rng_index: u32) void {
        if (self.enet_peer == null or !self.enet_connected) return;
        var buf: [5]u8 = undefined;
        buf[0] = 0x05; // RNG_ACK
        std.mem.writeInt(u32, buf[1..5], rng_index, .little);
        self.sendReliable(&buf);
        self.log.info("Sent RNG_ACK (index={d})", .{rng_index});
    }

    /// Host: peer confirmed receipt of the RNG state. Flip rng_synced/rng_acked
    /// so the host stops re-sending and treats the RNG as authoritative.
    pub fn confirmRngAck(self: *NetplayManager, rng_index: u32) void {
        if (!self.config.is_host) return;
        // Ignore stale acks for an index we've moved past.
        if (rng_index != self.indexed_frame.index and rng_index != self.indexed_frame.index + 1) {
            return;
        }
        if (self.rng_acked) return; // already confirmed for this round
        self.rng_acked = true;
        self.rng_synced = true;
        self.log.info("RNG sync confirmed by peer ack (index={d}, after {d} send(s))", .{
            rng_index, self.rng_send_count,
        });
    }

    // --- State transitions ---

    /// Validate that a state transition is allowed. CCCaster uses an explicit
    /// white-list; invalid transitions indicate a desync and should be logged.
    /// Returns true if the transition is valid, false otherwise.
    ///
    /// Valid transitions (from CCCaster's isValidNext):
    ///   pre_initial → initial
    ///   initial → chara_select (netplay) | in_game (training)
    ///   chara_select → loading
    ///   loading → chara_intro (versus) | in_game (training)
    ///   chara_intro → in_game
    ///   in_game → skippable
    ///   skippable → in_game (next round) | retry_menu
    ///   retry_menu → loading (rematch) | chara_select
    fn isValidNext(self: *const NetplayManager, new: NetplayState) bool {
        const old = self.state;
        const valid = switch (old) {
            .pre_initial => new == .initial,
            .initial => new == .chara_select or new == .in_game,
            .chara_select => new == .loading,
            .loading => new == .chara_intro or new == .in_game,
            .chara_intro => new == .in_game,
            .in_game => new == .skippable or new == .chara_select,
            .skippable => new == .in_game or new == .retry_menu,
            .retry_menu => new == .loading or new == .chara_select,
        };
        if (!valid) {
            self.log.err("Invalid state transition: {s} -> {s} (potential desync)", .{
                @tagName(old), @tagName(new),
            });
        }
        return valid;
    }

    pub fn onGameModeChanged(self: *NetplayManager, new_mode: u32) void {
        const old_state = self.state;
        var new_state: ?NetplayState = null;

        if (new_mode == mode_chara_select) {
            new_state = .chara_select;
        } else if (new_mode == mode_loading) {
            new_state = .loading;
        } else if (new_mode == mode_in_game) {
            if (self.config.is_training or !self.config.is_netplay or self.config.is_spectator) {
                new_state = .in_game;
            } else {
                // Versus netplay: enter chara_intro first. The actual
                // chara_intro → in_game transition is driven by the intro
                // state flag (CC_INTRO_STATE_ADDR going to 0), watched in
                // checkIntroDone() — matching the legacy RoundStart variable
                // watch in DllMain.cpp:1266-1269.
                new_state = .chara_intro;
            }
        }

        if (new_state) |ns| {
            // Validate the transition — log invalid ones but proceed anyway
            // (the game already wrote the new mode, we can't stop it).
            _ = self.isValidNext(ns);
            self.state = ns;
            self.onStateTransition(old_state, ns);
            if (new_mode == mode_in_game) self.onEnterInGame();
        }
        self.log.info("NetplayState -> {s} (game_mode={d})", .{ @tagName(self.state), new_mode });

        // Reset SFX dedup on each state transition (legacy clears per round).
        if (self.sfx_dedup) |*sd| sd.clearPerFrame();
    }

    pub fn checkIntroDone(self: *NetplayManager) void {
        // Track the intro-done edge so we enable RNG exactly once per round.
        // (game_state_addr isn't a simple monotonic flag — it cycles through
        // several values — so we watch for the 99 value with a one-shot.)
        if (!self.intro_rng_enabled and game_state_addr.* == game_state_intro_done) {
            self.intro_rng_enabled = true;
            self.should_sync_rng = true;
            self.rng_synced = false;
            self.rng_acked = false;
            self.rng_send_cooldown = 0;
            self.rng_send_count = 0;
            self.log.info("Intro done (game_state=99) — RNG sync enabled", .{});
        }

        // chara_intro → in_game: CC_INTRO_STATE_ADDR drops to 0 when players
        // can move. Only transition out of chara_intro — if we're already
        // in_game this is a no-op.
        if (self.state == .chara_intro and intro_state_addr.* == 0) {
            const old = self.state;
            _ = self.isValidNext(.in_game);
            self.state = .in_game;
            self.onStateTransition(old, .in_game);
            self.log.info("CharaIntro -> InGame (intro_state=0, players can move)", .{});
            if (self.sfx_dedup) |*sd| sd.clearPerFrame();
        }
    }

    pub fn checkRoundOver(self: *NetplayManager) void {
        // Only meaningful while actively in-game.
        if (self.state != .in_game) {
            self.round_over_timer = -1;
            return;
        }

        const p1_over = playerRoundOver(p1_base, p3_base);
        const p2_over = playerRoundOver(p2_base, p4_base);
        const is_over = p1_over and p2_over;

        if (self.config.rollback > 0 and self.config.is_netplay and !self.config.is_spectator) {
            // Rollback path: count down before committing.
            if (is_over) {
                if (self.round_over_timer == 0) {
                    // Countdown reached zero while still over — fire.
                    self.round_over_timer = -1;
                    self.transitionTo(.skippable);
                } else if (self.round_over_timer < 0) {
                    // First frame we've seen is_over — arm the countdown.
                    self.round_over_timer = @as(i32, self.config.rollback) + rollback_round_over_delay;
                }
            } else {
                // Not over (or not anymore) — re-arm.
                self.round_over_timer = -1;
            }
        } else if (is_over and !self.config.is_training) {
            // Non-rollback path: immediate transition. Legacy also skips
            // replay mode, but ZZCaster has no replay playback path.
            self.transitionTo(.skippable);
        }
    }

    /// Decrement the round-over countdown once per in-game frame. Mirrors
    /// the legacy decrement in frameStepNormal (DllMain.cpp:210-211). Called
    /// from frameStep before checkRoundOver so the timer can reach 0.
    pub fn tickRoundOverTimer(self: *NetplayManager) void {
        if (self.round_over_timer > 0) self.round_over_timer -= 1;
    }

    fn transitionTo(self: *NetplayManager, new: NetplayState) void {
        if (self.state == new) return;
        const old = self.state;
        _ = self.isValidNext(new);
        self.state = new;
        self.onStateTransition(old, new);
        self.round_over_timer = -1; // leaving in-game re-arms the timer
        self.log.info("Round over -> {s}", .{@tagName(new)});
        if (self.sfx_dedup) |*sd| sd.clearPerFrame();
    }

    /// Read a player's round-over flag, accounting for the puppet wrinkle.
    /// `main_base` is P1/P2, `puppet_base` is P3/P4. When the main struct's
    /// puppet_state != 0, the active body is the puppet and its no_input_flag
    /// is authoritative.
    fn playerRoundOver(main_base: u32, puppet_base: u32) bool {
        const main: [*]u8 = @ptrFromInt(main_base);
        const puppet_state = main[off_puppet_state];
        if (puppet_state == 0) {
            return main[off_no_input_flag] != 0;
        }
        const puppet: [*]u8 = @ptrFromInt(puppet_base);
        return puppet[off_no_input_flag] != 0;
    }

    /// Called on every state transition to a gameplay-relevant state
    /// (CharaSelect or higher). Increments the transition index, resets the
    /// frame counter, re-enables RNG sync, and sends a TransitionIndex
    /// message to the peer so they know which round we're on.
    ///
    /// This is the core of the legacy sync algorithm: each round gets a
    /// unique (index, frame) coordinate so inputs from different rounds
    /// don't collide in the InputBuffer.
    fn onStateTransition(self: *NetplayManager, old: NetplayState, new: NetplayState) void {
        // Only track transitions to CharaSelect or higher (skip startup/title)
        const new_val = @intFromEnum(new);
        const chara_select_val = @intFromEnum(NetplayState.chara_select);
        if (new_val < chara_select_val) return;

        self.indexed_frame.index += 1;
        self.start_world_time = world_timer_addr.*;
        self.indexed_frame.frame = 0;

        if (new == .in_game or new == .chara_select) {
            self.rng_synced = false;
            self.rng_acked = false;
            self.rng_send_cooldown = 0;
            self.rng_send_count = 0;
            self.should_sync_rng = true;
        }

        if (new == .loading or new == .chara_select) {
            self.intro_rng_enabled = false;
        }

        if (self.enet_connected and !self.config.is_spectator and self.config.is_netplay) {
            var buf: [5]u8 = undefined;
            buf[0] = 0x03; // TransitionIndex
            std.mem.writeInt(u32, buf[1..5], self.indexed_frame.index, .little);
            self.sendReliable(&buf);
        }

        if (new == .in_game) self.air_dash_macro.reset();

        self.log.info("State transition: {s} -> {s}, index={d}", .{
            @tagName(old), @tagName(new), self.indexed_frame.index,
        });
    }

    /// Called when we receive a TransitionIndex message from the remote peer.
    /// Records their current transition index so isRemoteInputReady can
    /// decide whether to wait or predict.
    pub fn setRemoteIndex(self: *NetplayManager, remote_idx: u32) void {
        self.remote_index = remote_idx;
        self.log.info("Remote transition index: {d}", .{remote_idx});
    }

    fn packedIndexedFrame(self: *const NetplayManager) u64 {
        return @as(u64, self.indexed_frame.frame) |
            (@as(u64, self.indexed_frame.index) << 32);
    }

    /// Snapshot game state and send a SyncHash to the peer. Called every
    /// sync_send_period frames and at frame 149 of each 150-cycle. Mirrors
    /// the legacy condition in DllMain.cpp:775-789 (excluding the states the
    /// legacy excludes: Loading, CharaIntro, Skippable, RetryMenu).
    pub fn maybeSendSyncHash(self: *NetplayManager) void {
        if (!self.enet_connected) return;
        if (self.config.is_spectator) return; // spectators don't initiate sync
        // Only meaningful from CharaSelect onward.
        const state_val = @intFromEnum(self.state);
        if (state_val < @intFromEnum(NetplayState.chara_select)) return;
        // Legacy excludes these states: no stable state to hash there.
        if (self.state == .loading or self.state == .chara_intro or
            self.state == .skippable or self.state == .retry_menu) return;

        const frame = self.indexed_frame.frame;
        const due_period = (frame % sync_send_period == 0);
        const due_149 = (frame % 150 == 149);
        if (!due_period and !due_149) return;

        if (self.isRerunning()) return;

        const sh = SyncHash.capture(self.packedIndexedFrame());

        // Wire format: [1 type=0x04][136 SyncHash body].
        var buf: [1 + 136]u8 = undefined;
        buf[0] = 0x04; // SyncHash
        _ = sh.serialize(buf[1..137]);
        self.sendReliable(buf[0..137]);

        self.pushLocalSync(sh);
    }

    /// Store a SyncHash received from the peer. Called from handleMessage for
    /// message type 0x04.
    pub fn applyRemoteSyncHash(self: *NetplayManager, data: []const u8) void {
        if (SyncHash.deserialize(data)) |sh| {
            self.pushRemoteSync(sh);
        }
    }

    fn pushLocalSync(self: *NetplayManager, sh: SyncHash) void {
        self.pushSync(&self.local_sync, &self.local_sync_count, sh);
    }

    fn pushRemoteSync(self: *NetplayManager, sh: SyncHash) void {
        self.pushSync(&self.remote_sync, &self.remote_sync_count, sh);
    }

    /// Append to a bounded ring; drop the oldest when full. Matches the
    /// legacy std::list semantics (front-pop on full) closely enough — since
    /// exchanges resolve within a handful of frames, the ring never wraps in
    /// practice.
    fn pushSync(_: *NetplayManager, buf: *[sync_queue_len]SyncHash, count: *u8, sh: SyncHash) void {
        if (count.* < sync_queue_len) {
            buf[count.*] = sh;
            count.* += 1;
        } else {
            // Shift left by one and append (oldest discarded).
            std.mem.copyForwards(SyncHash, buf[0 .. sync_queue_len - 1], buf[1..sync_queue_len]);
            buf[sync_queue_len - 1] = sh;
        }
    }

    /// Compare paired local/remote hashes. On the first mismatch, record the
    /// divergent pair and set desync_detected so the frame loop can abort.
    /// Called once per frame; safe to call when queues are empty.
    pub fn checkSyncHashDesync(self: *NetplayManager) void {
        if (self.desync_detected) return; // already flagged
        if (self.local_sync_count == 0 or self.remote_sync_count == 0) return;

        // Walk both queues in indexed_frame order, dropping entries that have
        // no counterpart on the other side (legacy pops the higher one first).
        var li: usize = 0;
        var ri: usize = 0;
        while (li < self.local_sync_count and ri < self.remote_sync_count) {
            const l = self.local_sync[li];
            const r = self.remote_sync[ri];
            if (l.indexed_frame > r.indexed_frame) {
                // Remote is behind — drop the remote entry (legacy pops remote).
                ri += 1;
                continue;
            }
            if (r.indexed_frame > l.indexed_frame) {
                // Local is behind — drop the local entry.
                li += 1;
                continue;
            }
            // Paired. Compare.
            if (!l.matches(r)) {
                self.desync_detected = true;
                self.desync_local = l;
                self.desync_remote = r;
                self.logDesync(l, r);
                return;
            }
            // Match — consume both.
            li += 1;
            ri += 1;
        }

        // Compact the queues: drop matched/stale entries from the front.
        if (li > 0) self.dropFrontLocal(li);
        if (ri > 0) self.dropFrontRemote(ri);
    }

    fn dropFrontLocal(self: *NetplayManager, n: usize) void {
        const keep = self.local_sync_count - @as(u8, @intCast(n));
        std.mem.copyForwards(SyncHash, self.local_sync[0..keep], self.local_sync[n..self.local_sync_count]);
        self.local_sync_count = keep;
    }

    fn dropFrontRemote(self: *NetplayManager, n: usize) void {
        const keep = self.remote_sync_count - @as(u8, @intCast(n));
        std.mem.copyForwards(SyncHash, self.remote_sync[0..keep], self.remote_sync[n..self.remote_sync_count]);
        self.remote_sync_count = keep;
    }

    fn logDesync(self: *NetplayManager, l: SyncHash, r: SyncHash) void {
        self.log.err("DESYNC detected at indexed_frame=0x{x:0>16}", .{l.indexed_frame});
        // Identify which field diverged — this is the diagnostic payoff.
        if (!std.mem.eql(u8, &l.hash, &r.hash)) {
            self.log.err("  RNG hash mismatch (determinism root diverged)", .{});
        }
        if (l.round_timer != r.round_timer) self.log.err("  round_timer: {d} vs {d}", .{ l.round_timer, r.round_timer });
        if (l.real_timer != r.real_timer) self.log.err("  real_timer: {d} vs {d}", .{ l.real_timer, r.real_timer });
        if (l.camera_x != r.camera_x) self.log.err("  camera_x: {d} vs {d}", .{ l.camera_x, r.camera_x });
        if (l.camera_y != r.camera_y) self.log.err("  camera_y: {d} vs {d}", .{ l.camera_y, r.camera_y });
        logCharaDiff(self.log, "P1", l.chara[0], r.chara[0]);
        logCharaDiff(self.log, "P2", l.chara[1], r.chara[1]);
    }

    fn logCharaDiff(log: *logging.Logger, label: []const u8, a: CharaHash, b: CharaHash) void {
        if (a.health != b.health) log.err("  {s} health: {d} vs {d}", .{ label, a.health, b.health });
        if (a.red_health != b.red_health) log.err("  {s} red_health: {d} vs {d}", .{ label, a.red_health, b.red_health });
        if (a.meter != b.meter) log.err("  {s} meter: {d} vs {d}", .{ label, a.meter, b.meter });
        if (a.heat != b.heat) log.err("  {s} heat: {d} vs {d}", .{ label, a.heat, b.heat });
        if (a.guard_bar != b.guard_bar) log.err("  {s} guard_bar: {d} vs {d}", .{ label, a.guard_bar, b.guard_bar });
        if (a.guard_quality != b.guard_quality) log.err("  {s} guard_quality: {d} vs {d}", .{ label, a.guard_quality, b.guard_quality });
        if (a.x != b.x) log.err("  {s} x: {d} vs {d}", .{ label, a.x, b.x });
        if (a.y != b.y) log.err("  {s} y: {d} vs {d}", .{ label, a.y, b.y });
        if (a.seq != b.seq) log.err("  {s} seq: {d} vs {d}", .{ label, a.seq, b.seq });
        if (a.seq != 0 and a.seq_state != b.seq_state)
            log.err("  {s} seq_state: {d} vs {d}", .{ label, a.seq_state, b.seq_state });
        if (a.chara != b.chara) log.err("  {s} chara: {d} vs {d}", .{ label, a.chara, b.chara });
        if (a.moon != b.moon) log.err("  {s} moon: {d} vs {d}", .{ label, a.moon, b.moon });
    }

    fn onEnterInGame(self: *NetplayManager) void {
        if (self.config.rollback > 0 and self.config.is_netplay and !self.config.is_spectator) {
            for (rollback_regions.all_regions) |r| {
                self.state_pool.addRegion(r.addr, r.size) catch {};
            }
            self.log.info("Loaded {d} rollback memory regions ({d} bytes per state)", .{ rollback_regions.all_regions.len, self.state_pool.totalRegionSize() });

            self.state_pool.allocate(60, 0) catch {
                self.log.warn("StatePool allocate failed — rollback disabled", .{});
            };
        }
        self.rollback_timer = self.min_rollback_spacing;

        // Reset SFX dedup at round start.
        if (self.sfx_dedup) |*sd| sd.reset();

        self.air_dash_macro.reset();
    }

    // --- Rollback ---

    pub fn checkRollback(self: *NetplayManager) bool {
        if (!self.isInRollback()) return false;
        if (self.rollback_timer < self.min_rollback_spacing) return false;

        const lcf = self.remote_inputs.last_changed_frame;
        if (lcf == null) return false;

        const lcf_frame = @as(u32, @intCast(lcf.? & 0xFFFFFFFF));
        const lcf_index = @as(u32, @intCast(lcf.? >> 32));
        if (lcf_index != self.indexed_frame.index) return false;
        if (lcf_frame >= self.indexed_frame.frame) return false;

        // Trigger rollback!
        const current_frame = self.indexed_frame.frame;
        self.fast_fwd_stop_frame = current_frame;
        self.log.info("ROLLBACK: frame {d} -> {d}", .{ current_frame, lcf_frame });

        // Apply SFX dedup filter: OR together snapshots between loaded and
        // current frame, then mark with 0x80 sentinel so the play-hook
        // knows to suppress them.
        if (self.sfx_dedup) |*sd| {
            sd.applyRollbackFilter(lcf_frame, current_frame);
        }

        if (self.state_pool.loadStateForFrame(lcf_frame, lcf_index)) |loaded_frame| {
            self.indexed_frame.frame = loaded_frame;
            self.log.info("ROLLBACK: loaded state for frame {d}, re-running to {d}", .{ loaded_frame, current_frame });
        } else {
            self.indexed_frame.frame = lcf_frame;
            self.log.warn("ROLLBACK: no saved state for frame {d}", .{lcf_frame});
        }

        self.remote_inputs.clearLastChanged();
        self.rollback_timer = 0;
        return true;
    }

    pub fn isRerunning(self: *const NetplayManager) bool {
        return self.fast_fwd_stop_frame != 0;
    }

    /// Force CC_INTRO_STATE_ADDR to 0 during a rollback re-run that has
    /// advanced past the pre-game intro window (CC_PRE_GAME_INTRO_FRAMES).
    /// Ported from DllMain.cpp:975-976:
    ///   if ( isInRollback() && getFrame() > CC_PRE_GAME_INTRO_FRAMES
    ///                            && *CC_INTRO_STATE_ADDR )
    ///       *CC_INTRO_STATE_ADDR = 0;
    ///
    /// A loaded state from before the intro finished may carry a non-zero
    /// intro flag; re-running that state would re-trigger intro-only logic
    /// (e.g. the guard-bar masking in readCharaHash) and desync the re-run.
    /// Clearing it once we're past frame 224 keeps the re-run on the
    /// gameplay path.
    pub fn clearIntroStateDuringRollback(self: *NetplayManager) void {
        if (!self.isInRollback()) return;
        if (self.indexed_frame.frame <= pre_game_intro_frames) return;
        if (intro_state_addr.* == 0) return;
        intro_state_addr.* = 0;
    }

    pub fn checkRerunComplete(self: *NetplayManager) bool {
        if (self.fast_fwd_stop_frame == 0) return false;

        // While re-running, snapshot SFX per-frame so finishedRerun knows
        // which sounds actually re-fired.
        if (self.sfx_dedup) |*sd| sd.saveRerunSounds(self.indexed_frame.frame);

        if (self.indexed_frame.frame >= self.fast_fwd_stop_frame) {
            self.fast_fwd_stop_frame = 0;
            skip_frames_addr.* = 0; // restore rendering
            // Re-run finished — cancel any SFX that was queued pre-rollback
            // but didn't actually re-fire during the re-run.
            if (self.sfx_dedup) |*sd| sd.finishedRerun();
            return true;
        }
        skip_frames_addr.* = 1; // keep skipping
        return false;
    }

    // --- Write game inputs ---

    pub fn writeGameInputs(self: *NetplayManager) void {
        if (self.config.is_spectator) {
            // Spectator: both inputs come from the host's BothInputs packet.
            const both = self.getSpectatorInputs();
            writeGameInput(1, both.p1);
            writeGameInput(2, both.p2);
        } else {
            const local = self.getLocalInput();
            const remote = self.getRemoteInput();
            writeGameInput(self.config.local_player, local);
            writeGameInput(self.config.remote_player, remote);
        }
    }

    /// Host: build a BothInputs packet for spectator broadcast. Returns
    /// the number of bytes written into `out`.
    /// Format: [1 type=0x20][4 start_frame][4 start_index][N × 4 (P1:u16, P2:u16)]
    pub fn fillBothInputsForBroadcast(self: *NetplayManager, index: u32, frame: u32, out: []u8) usize {
        if (out.len < 1 + 8 + num_inputs * 4) return 0;
        out[0] = 0x20;
        std.mem.writeInt(u32, out[1..5], frame, .little);
        std.mem.writeInt(u32, out[5..9], index, .little);
        var i: u32 = 0;
        while (i < num_inputs) : (i += 1) {
            const p1 = self.local_inputs.get(index, frame + i);
            const p2 = self.remote_inputs.get(index, frame + i);
            std.mem.writeInt(u16, out[9 + i * 4 .. 11 + i * 4][0..2], p1, .little);
            std.mem.writeInt(u16, out[11 + i * 4 .. 13 + i * 4][0..2], p2, .little);
        }
        return 1 + 8 + num_inputs * 4;
    }
};

fn writeGameInput(player: u8, input: u16) void {
    // See dllmain.zig writeInput — same alignment trick for 64-bit.
    const base_ptr = @as(usize, @bitCast(ptr_to_write_input_addr[0..@sizeOf(usize)].*));
    if (base_ptr == 0) return;
    const base: [*]u8 = @ptrFromInt(base_ptr);
    const dir_off: u32 = if (player == 1) p1_offset_direction else p2_offset_direction;
    const btn_off: u32 = if (player == 1) p1_offset_buttons else p2_offset_buttons;

    const dir_ptr: *u16 = @ptrCast(@alignCast(base + dir_off));
    const btn_ptr: *u16 = @ptrCast(@alignCast(base + btn_off));
    dir_ptr.* = input & 0x0F;
    btn_ptr.* = (input >> 4) & 0x0FFF;
}
