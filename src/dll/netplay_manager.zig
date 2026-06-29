const std = @import("std");
const logging = @import("common").logging;
const rollback = @import("rollback.zig");
const sfx_dedup = @import("sfx_dedup.zig");
const spectator_manager_mod = @import("spectator_manager.zig");
const net = @import("net").enet_transport;
const rollback_regions = @import("rollback_regions.zig");
const air_dash = @import("air_dash_macro.zig");
const asm_hacks = @import("asm_hacks.zig");
const builtin = @import("builtin");

/// Minimal Win32 surface for the rollback thread-priority boost (Strategy 2B
/// in docs/dll-optimization-plan.md). `SetThreadPriority` raises the calling
/// thread's base priority so the OS scheduler is less likely to preempt us
/// mid-rerun; we restore to `THREAD_PRIORITY_NORMAL` when the rerun completes.
const win32 = struct {
    extern "kernel32" fn GetCurrentThread() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn SetThreadPriority(
        hThread: ?*anyopaque,
        nPriority: i32,
    ) callconv(.winapi) i32;
    extern "kernel32" fn SetThreadPriorityBoost(
        hThread: ?*anyopaque,
        bDisablePriorityBoost: i32,
    ) callconv(.winapi) i32;

    const HWND = ?*anyopaque;
    const BOOL = i32;
    const LPARAM = usize;
    const WPARAM = usize;
    const UINT = u32;

    extern "user32" fn FlashWindow(hWnd: HWND, bInvert: BOOL) callconv(.winapi) BOOL;
    extern "user32" fn MessageBeep(uType: UINT) callconv(.winapi) BOOL;
    extern "user32" fn GetActiveWindow() callconv(.winapi) HWND;
    extern "user32" fn GetWindowThreadProcessId(hWnd: HWND, lpdwProcessId: ?*u32) callconv(.winapi) u32;
    extern "user32" fn EnumWindows(lpEnumFunc: *const fn (HWND, LPARAM) callconv(.winapi) BOOL, lParam: LPARAM) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

    const EnumState = struct {
        pid: u32,
        hwnd: HWND,
    };

    fn getWindowHandle() HWND {
        if (builtin.os.tag != .windows) return null;
        
        if (GetActiveWindow()) |hwnd| {
            return hwnd;
        }

        const target_pid = GetCurrentProcessId();
        var state = EnumState{
            .pid = target_pid,
            .hwnd = null,
        };

        const Helper = struct {
            fn enumProc(hwnd: HWND, lParam: LPARAM) callconv(.winapi) BOOL {
                var s: *EnumState = @ptrFromInt(lParam);
                var process_id: u32 = 0;
                _ = GetWindowThreadProcessId(hwnd, &process_id);
                if (process_id == s.pid) {
                    s.hwnd = hwnd;
                    return 0; // stop
                }
                return 1; // continue
            }
        };

        _ = EnumWindows(Helper.enumProc, @intFromPtr(&state));
        return state.hwnd;
    }

    // https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setthreadpriority
    const THREAD_PRIORITY_NORMAL: i32 = 0;
    const THREAD_PRIORITY_TIME_CRITICAL: i32 = 15;

    /// Boost the calling thread to time-critical priority. Called right
    /// before `loadStateForFrame` so the Windows scheduler doesn't preempt
    /// the rollback rerun. Safe to call multiple times — Win32 treats it
    /// as a "set base to value", not a relative bump.
    ///
    /// No-op on non-Windows targets (the host test runner). We guard with
    /// `builtin.os.tag == .windows` so cross-platform unit tests compile
    /// cleanly.
    fn boostForRerun() void {
        if (builtin.os.tag != .windows) return;
        const h = GetCurrentThread();
        _ = SetThreadPriorityBoost(h, 1); // 1 = disable dynamic priority boost
        _ = SetThreadPriority(h, THREAD_PRIORITY_TIME_CRITICAL);
    }

    /// Restore the calling thread to normal priority. Called from
    /// `finishedRerun` so we don't keep starving other threads between
    /// rollbacks. Idempotent.
    fn restoreAfterRerun() void {
        if (builtin.os.tag != .windows) return;
        const h = GetCurrentThread();
        _ = SetThreadPriority(h, THREAD_PRIORITY_NORMAL);
        _ = SetThreadPriorityBoost(h, 0); // 0 = re-enable dynamic priority boost
    }
};

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

// Match score (wins per player, in the current best-of-N match). Used by
// checkRoundOver to distinguish a round-over (continue to .skippable) from
// a match-over (transition to .retry_menu, where the player chooses
// rematch vs character-select with the full d-pad).
//
// Addresses match the rollback regions in rollback_regions.zig:32-33
// (CC_P1_WINS_ADDR / CC_P2_WINS_ADDR). u32: number of rounds won in the
// current match; resets to 0 when a new match starts (chara_select).
const p1_wins_addr: *u32 = @ptrFromInt(0x559550);
const p2_wins_addr: *u32 = @ptrFromInt(0x559580);

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

/// Minimum frame number before rollback can load a state. States at frames
/// 0-7 may differ between peers (both enter in_game at slightly different
/// absolute world_timer values). Rolling back to those frames loads a
/// divergent state → desync.
///
/// NOTE: This guard is a zzcaster addition — CCCaster has NO such guard
/// and will roll back to frame 0 if needed. The guard was originally added
/// to work around the intro-animation-timing race that caused frame-0 state
/// divergence. The race fix (commit 5a5c13c, hijackIntroState applied
/// before waitForConfig) should have eliminated that divergence.
///
/// DEFAULT: false (match CCCaster behavior — no guard, rollback corrects
/// early-frame mispredictions immediately).
///
/// If early-frame rollbacks cause the "state at frame 0 differs" desync to
/// return, set this to true and investigate the frame-0 divergence
/// separately. The log line "ROLLBACK to early frame" will indicate whether
/// early-frame rollbacks are happening.
const rollback_min_frame_delay: u32 = 8;
const enable_rollback_min_frame_delay_guard: bool = false;

// Protocol version for compatibility checking. Increment when the wire format
// or rollback state layout changes. Both peers must have the same version.
const protocol_version: u32 = 2;

// Game modes
const mode_startup: u32 = 65535;
const mode_opening: u32 = 3;
const mode_title: u32 = 2;
const mode_main: u32 = 25;
const mode_chara_select: u32 = 20;
const mode_loading: u32 = 8;
const mode_in_game: u32 = 1;
// CC_GAME_MODE_RETRY: the post-match "Rematch / Character Select" menu.
// CCCaster routes this directly to NetplayState::RetryMenu
// (DllMain.cpp:1162-1166), which lets getRetryMenuInput pass through the
// d-pad for cursor navigation. Without recognizing this mode, the FSM
// stays in .skippable (which only allows Confirm/Cancel) and the user
// can only confirm Rematch — moving the cursor down to Character Select
// is impossible.
const mode_retry: u32 = 5;

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
const heartbeat_timeout_ms: i64 = 120000; // 120s — no packet → peer is dead
const input_wait_timeout_ms: i64 = 10000; // 10s — no remote input → timed out

// RTT EMA time constant: ~10 seconds at 60fps (ported from ggpo-x).
// alpha = 2 / (N + 1) where N = 10000ms / 16.6ms ≈ 602 frames.
const rtt_ema_alpha: f64 = 2.0 / (1.0 + 10_000.0 / 16.6);

// Time-sync constants (ported from ggpo-x).
const max_frame_advantage: f32 = 30.0; // clamp for sleep recommendation
const min_frame_advantage: f32 = 3.0; // ignore drift below this (avoids micro-stutter)
const max_per_frame_sleep_ms: f32 = 4.0; // cap per-frame sleep at 4ms (~24% of 16.6ms frame)

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
    // Relay handoff: local UDP port used for NAT-traversal hole-punching.
    // 0 = direct connection (bind to any port, or to peer_port for host).
    // Non-zero = relay connection (bind ENet host to this exact port to
    // preserve the NAT mapping opened during hole-punching).
    local_udp_port: u16 = 0,
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
        // Compare health..seq (and conditionally seq_state). NOTE: this is
        // more permissive than the legacy operator==, whose memcmp covers
        // bytes 8..sizeof(CharaHash) and therefore also compares the
        // `chara` and `moon` selector fields — a divergence in those
        // would NOT be flagged here.
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
    ///   [4 camera_x][4 camera_y][2 × CharaHash (44 bytes data + 4 padding = 48-byte slot each)]
    /// Total = 8 + 16 + 16 + 96 = 136 bytes. (Legacy CharaHash is 44 bytes
    /// and its SyncHash wire total is 128; Zig reserves 48-byte slots.)
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
        // 44 bytes used; legacy CharaHash struct is 44 bytes (no padding —
        // uint16_t has 2-byte alignment, struct alignment is 4, 44 is already
        // a multiple of 4). The Zig wire format reserves a 48-byte slot per
        // CharaHash for 4-byte alignment of the next slot, so buf[44..48] is
        // unused scratch.
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

// Size of the RNG state body: 4 bytes index + 4+4+4 bytes rng0/rng1/rng2 +
// 220 bytes rng3 = 236 bytes. This is the payload that follows the 1-byte
// type tag in the 0x02 RNG packet, and what `getCachedRngState` writes into
// the caller's buffer.
const rng_body_size: usize = 4 + 4 + 4 + 4 + rng_state3_size;

// A cached RNG snapshot keyed by transition index. Used by the host to
// forward the same RNG state it sent to the client on to spectators.
// `valid` is false for unused slots.
const CachedRngState = struct {
    valid: bool = false,
    index: u32 = 0,
    body: [rng_body_size]u8 = [_]u8{0} ** rng_body_size,
};

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

    // RTT EMA for time-sync (ported from ggpo-x).
    rtt_ema_ms: f64 = 0,
    rtt_ema_initialized: bool = false,

    round_over_timer: i32 = -1,

    sfx_dedup: ?sfx_dedup.SfxDedup = null,

    air_dash_macro: air_dash.AirDashMacro = .{},

    spectators: ?spectator_manager_mod.SpectatorManager = null,

    // Defaults to false: armed by `onStateTransition` (on entering `.chara_select`
    // or `.in_game`) and by `checkIntroDone` (when `game_state == 99`, per-round
    // re-arm).
    //
    // CharaSelect arming is REQUIRED because MBAACC's character-select screen
    // consumes RNG (Random character pick, preview animations, stage-select
    // effects). The four RNG state words are global MBAACC memory, not
    // UI-scoped, so a Random pick is baked into the round's determinism root.
    // Without chara_select RNG sync, host and client diverge on the very first
    // Random pick. See `onStateTransition` for the full rationale.
    //
    // Determinism of the apply-frame is guaranteed by the `isRemoteInputReady`
    // gate (see that function): the client blocks in the lockstep wait loop
    // until `rng_synced` becomes true.
    should_sync_rng: bool = false,
    rng_synced: bool = false,
    // The transition index for which `rng_synced` was set. Used by
    // `applyRemoteRng` to decide whether a received RNG packet is a re-send
    // for the already-synced round (skip — idempotent) or a new round's RNG
    // (apply — even if `rng_synced` is still true from the prior round).
    // Without this, a spectator that synced index N and then receives
    // index N+1's RNG (because the host sent it before the spectator's
    // local state transition reset `rng_synced`) would wrongly skip the
    // new round's RNG and desync.
    rng_synced_index: u32 = 0,

    // RNG ack handshake: the host sends RNG state, but the peer must confirm
    // receipt before the host treats the sync as complete. The lazy-reconnect
    // design (ENet connection established inside frameStep, not in the
    // launcher) means the host's first RNG packet can be sent before the peer
    // has finished its ENet CONNECT — so the packet would be dropped and
    // the host would keep re-sending forever. The ack closes this race:
    // the host re-sends RNG every `rng_resend_period` frames until the
    // peer's ack arrives, then stops.
    //
    // Note: the host's `rng_synced` flag is NOT set when sending — it's
    // only set by `confirmRngAck` when the peer's ACK arrives. The
    // client's `rng_synced` flag is set by `applyRemoteRng` when it
    // actually writes the RNG to game memory. These are two separate
    // flags on two separate peers; don't conflate them.
    rng_acked: bool = false,
    rng_send_cooldown: u32 = 0, // frames until next resend attempt
    rng_send_count: u32 = 0, // diagnostic: how many times we sent

    intro_rng_enabled: bool = false,

    /// True after the first in_game entry of a match. Used by checkIntroDone
    /// to distinguish round 1 (where RNG is already synced at chara_select +
    /// in_game entry) from rounds 2+ (where intro_done RNG sync is needed).
    /// Without this, the intro_done RNG sync fires for round 1, causing the
    /// host to send advanced RNG that the client applies early → desync.
    /// Reset to false on new match chara_select.
    first_in_game_completed: bool = false,

    // Version handshake state
    version_confirmed: bool = false,
    version_mismatch: bool = false,

    // Host-side cache of the RNG state captured for each transition index.
    // Populated by `syncRngState` when the host captures+sends RNG to the
    // client. Looked up by `getCachedRngState` so the SpectatorManager can
    // forward the same RNG state to spectators. Mirrors CCCaster's
    // `NetplayManager::_rngStates` (DllNetplayManager.hpp:189), which is
    // populated by the host at DllMain.cpp:523
    // (`netMan.setRngState(msgRngState->getAs<RngState>())`) and read by
    // `SpectatorManager::frameStepSpectators` at
    // DllSpectatorManager.cpp:177 (`_netManPtr->getRngState(oldIndex)`).
    //
    // A small fixed-size ring is sufficient: the spectator is delayed by
    // at most a few seconds (NUM_INPUTS * a few broadcast intervals), and
    // the host's transition index advances slowly (once per round). We
    // keep the last 8 indices' RNG states; older entries are overwritten.
    cached_rng_states: [8]CachedRngState = [_]CachedRngState{.{}} ** 8,

    // Round-start detection: the detectRoundStart ASM hack (asm_hacks.zig)
    // increments a counter in DLL memory each time a round begins. We watch
    // it for changes to drive the Skippable → InGame transition (round 2+),
    // matching the legacy Variable::RoundStart change-monitor in
    // DllMain.cpp:1266-1270. last_round_start is the last-seen value.
    last_round_start: u32 = 0,
    round_start_waiting_logged: bool = false,

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

    // Retry-menu sync gate: true when we enter .retry_menu but the remote
    // remoto ainda não confirmou (via TransitionIndex) que também chegou lá.
    // While true, getNetplayInput suppresses all local inputs — the
    // player mais rápido não pode skipar a animação de vitória nem apertar
    // rematch antes do player mais lento chegar no menu. Impede a dessincronia
    // onde o player rápido avança para .loading enquanto o lento ainda vê a
    // tela de vitória.
    retry_menu_waiting_for_peer: bool = false,
    // Wall-clock ms when the retry-menu wait started (0 = not started yet).
    // iniciado). Usado para o timeout de segurança de 10s — se o peer
    // crashar ou o TransitionIndex se perder, os inputs são liberados
    // para não travar o jogo indefinidamente.
    retry_menu_wait_start_ms: i64 = 0,

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

    pub fn gracefulDisconnect(self: *NetplayManager) void {
        if (self.enet_peer != null) {
            self.log.info("Sending graceful disconnect to peer...", .{});
            enet.enet_peer_disconnect(self.enet_peer, 0);
            enet.enet_host_flush(self.enet_host);
        }
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
            // HOST: listen for inbound ENet CONNECT.
            //
            // For direct connections, peer_port is the host's listen port
            // (e.g., 46318) — enet_host_create binds to it.
            //
            // For relay connections, the launcher set peer_port =
            // local_udp_port (the port used for hole-punching) so the DLL
            // binds its ENet host to the SAME port, preserving the NAT
            // mapping. Without this, the peer's ENet CONNECT packets
            // would arrive at the (now-closed) launcher port and never
            // reach the DLL.
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
            // CLIENT (spectator OR player-2): connect outbound.
            //
            // For direct connections, local_udp_port is 0 — enet_host_create(null, ...)
            // binds to a random local port. This is fine because there's no
            // NAT mapping to preserve.
            //
            // For relay connections, local_udp_port is the port used for
            // hole-punching. We MUST bind the ENet host to this exact port
            // so the peer's return packets reach us (the NAT mapping
            // forwards traffic to this port). enet_host_create with a bind
            // address (instead of null) achieves this — it's the DLL-side
            // equivalent of the launcher's connectBound().
            if (self.config.local_udp_port != 0) {
                var bind_addr: enet.ENetAddress = undefined;
                bind_addr.host = enet.ENET_HOST_ANY;
                bind_addr.port = self.config.local_udp_port;
                self.enet_host = enet.enet_host_create(&bind_addr, 1, 3, 0, 0);
                self.log.info("DIAG: client host_create (bound to port {d}) returned {x}", .{
                    self.config.local_udp_port, @intFromPtr(self.enet_host),
                });
            } else {
                self.enet_host = enet.enet_host_create(null, 1, 3, 0, 0);
                self.log.info("DIAG: client host_create returned {x}", .{@intFromPtr(self.enet_host)});
            }
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
            // 0x5FEC is a ZZCaster-specific sentinel (does NOT match any
            // CCCaster mechanism — CCCaster uses TCP server sockets and
            // distinguishes spectators by connection context, not a
            // connect-data field). The value is arbitrary; it just needs
            // to be non-zero and distinct from the main peer's connect_data (0).
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
                    // by checking connect data (0x5FEC ZZCaster sentinel — see
                    // initEnet for why this doesn't match CCCaster).
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

                // Send the host's cached RNG state to the newly-activated
                // spectator, mirroring CCCaster's `SpectatorManager::pushSpectator`
                // (DllSpectatorManager.cpp:70-85). Without this, the spectator
                // would run without synchronized RNG until the next
                // `frameStepSpectators` broadcast tick (which only fires on
                // the broadcast pacing interval, not immediately).
                //
                // CCCaster selects the RNG index based on the host's current
                // netplay state:
                //   CharaSelect  →  spectator.pos.index          (the round they'll watch)
                //   InGame/etc   →  spectator.pos.index + 2     (skip the current finishing round)
                //   (training)   →  spectator.pos.index + 1     (training has no chara_intro round)
                // The +2 for non-training accounts for the fact that a
                // spectator joining mid-match is behind by ~1 index, and the
                // current round is about to end — they need the NEXT round's RNG.
                const rng_lookup_index: u32 = switch (self.state) {
                    .chara_select => start_index,
                    .loading, .chara_intro, .in_game, .skippable, .retry_menu => blk: {
                        const offset: u32 = if (self.config.is_training) 1 else 2;
                        break :blk start_index + offset;
                    },
                    .pre_initial, .initial => start_index,
                };

                var rng_buf: [1 + 4 + 4 + 4 + 4 + rng_state3_size]u8 = undefined;
                rng_buf[0] = 0x02; // RNG state
                if (self.getCachedRngState(rng_lookup_index, rng_buf[1..])) {
                    if (peer) |p| {
                        const pkt = enet.enet_packet_create(&rng_buf, rng_buf.len, enet.ENET_PACKET_FLAG_RELIABLE);
                        if (pkt != null) {
                            _ = enet.enet_peer_send(p, 0, pkt); // channel 0 = reliable
                            enet.enet_host_flush(self.enet_host);
                        }
                    }
                    self.log.info("Sent RNG state to new spectator at activation (index={d})", .{rng_lookup_index});
                } else {
                    // No cached RNG for this index yet — the spectator will
                    // pick it up via `frameStepSpectators` on the next
                    // broadcast tick once the host captures+sends RNG.
                    self.log.info("No cached RNG for spectator at activation (index={d}) — will send on next broadcast", .{rng_lookup_index});
                }
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
                if (peer_opt) |peer| {
                    // Increase ENet timeout for slow connections. The default
                    // 10s minimum is too short for online play with high latency
                    // or slow machines — during loading screens, a slow peer may
                    // not send packets for 10+ seconds, causing ENet to disconnect.
                    // 30s minimum, 120s maximum gives enough headroom.
                    enet.enet_peer_timeout(peer, 0, 30000, 120000);
                }
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

                // Send version config for compatibility check immediately
                // after connect. If versions don't match, we'll disconnect.
                if (self.enet_connected and !self.config.is_spectator) {
                    self.sendVersionConfig();
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
            0x07 => { // VersionConfig — version compatibility check
                if (msg.len >= 5) {
                    const remote_ver = std.mem.readInt(u32, msg[1..5], .little);
                    if (remote_ver != protocol_version) {
                        self.log.err("Protocol version mismatch: local={d} remote={d} — disconnecting", .{
                            protocol_version, remote_ver,
                        });
                        self.enet_connected = false;
                        self.version_mismatch = true;
                    } else {
                        self.log.info("Protocol version match: {d}", .{protocol_version});
                        self.version_confirmed = true;
                    }
                }
            },
            0x06 => { // ErrorMessage — peer reports an error before disconnect
                if (msg.len >= 2) {
                    const err_len = @min(msg.len - 1, 128);
                    self.log.err("Remote error: {s}", .{msg[1 .. 1 + err_len]});
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
                //
                // MUST set menu_confirm_state = 2 before returning the mash
                // — the menuConfirmState ASM hack (applyMenuConfirmHack)
                // gates the game's menu-confirm handler on this value:
                //   - >1: force the confirm through (LABEL_B path)
                //   - <=1: normal path (LABEL_A), which may NOT process
                //     the confirm if the game's own menu code drops it
                // Without setting this, the title-screen mash is silently
                // blocked by the hack and the game never advances past
                // game_mode=65535.
                //
                // Matches CCCaster getPreInitialInput (DllNetplayManager.cpp:93)
                // and getInitialInput (line 110), both of which set
                // AsmHacks::menuConfirmState = 2 before RETURN_MASH_INPUT.
                asm_hacks.menu_confirm_state = 2;
                if (self.indexed_frame.frame % 2 == 0) {
                    return button_confirm << 4;
                }
                return 0;
            },
            .chara_select => {
                var input = raw_input;

                // Conditionally mask Cancel (B button) — only when actively
                // selecting a CHARACTER (selector_mode == 0). This prevents
                // backing out of the character select screen entirely (which
                // would desync the state machine), while still allowing B to
                // work as "back" in the moon/color select sub-menus.
                // Matches CCCaster (DllNetplayManager.cpp:143-147).
                const p1_selector_mode: *u32 = @ptrFromInt(0x74D8EC);
                const p2_selector_mode: *u32 = @ptrFromInt(0x74D910);
                const selector_mode = if (self.config.local_player == 1)
                    p1_selector_mode.*
                else
                    p2_selector_mode.*;
                if (selector_mode == 0) { // CC_SELECT_CHARA
                    input &= ~@as(u16, 0x8000); // Cancel
                    input &= ~@as(u16, 0x0020); // B button
                }

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
                // ============================================================
                // Catch-up mash + getSkippableInput (matches CCCaster)
                // ============================================================
                // Ported from CCCaster DllNetplayManager.cpp:789-798. The
                // three states share the same input logic:
                //   1. If the remote is ahead by more than 1 index, mash
                //      Confirm to skip the animation faster (catch-up).
                //      This requires the menuConfirmState ASM hack
                //      (applyMenuConfirmHack, commit 9749937) to actually
                //      advance the game's menu/intro — without it, mashing
                //      Confirm does nothing.
                //   2. Otherwise, let the player's Confirm+Cancel inputs
                //      through (getSkippableInput). This lets players
                //      manually skip the intro/victory screen by pressing
                //      Confirm, matching CCCaster's UX.
                //
                // PREVIOUS BEHAVIOR (reverted by this commit): zzcaster
                // suppressed ALL inputs during these states (return 0) to
                // prevent "one peer skips, the other doesn't" desyncs. But
                // that created the §A chara_intro entry divergence freeze:
                // when one peer entered chara_intro 1 frame ahead (due to
                // loading-completion I/O variance), the behind peer couldn't
                // catch up (no mash), the per-frame lockstep forced
                // frame-by-frame advancement on divergent game states, and
                // round_start_counter fired asymmetrically → deadlock.
                //
                // CCCaster avoids this by NOT lockstepping these states
                // (commit 3/3 will remove the lockstep) and using mash to
                // catch up instead. The 1-frame entry drift is harmless
                // because the behind peer mashes and catches up within a
                // few frames.
                //
                // Spectators always mash Confirm to fast-forward (matches
                // CCCaster getSkippableInput line 160-161).

                // Spectator: always mash Confirm (fast-forward through
                // animations the spectator doesn't care about).
                if (self.config.is_spectator) {
                    asm_hacks.menu_confirm_state = 2;
                    if (self.indexed_frame.frame % 2 == 0) {
                        return button_confirm << 4;
                    }
                    return 0;
                }

                // Catch-up mash: remote is ahead by >1 index → mash Confirm
                // to skip the animation. The menuConfirmState hack makes
                // the game actually process the mashed confirm.
                if (self.shouldCatchUp()) {
                    asm_hacks.menu_confirm_state = 2;
                    if (self.indexed_frame.frame % 2 == 0) {
                        return button_confirm << 4;
                    }
                    return 0;
                }

                // Normal path: let Confirm+Cancel through (getSkippableInput).
                // Mask = COMBINE_INPUT(0, CC_BUTTON_CONFIRM | CC_BUTTON_CANCEL)
                //      = (0x0400 | 0x0800) << 4 = 0xC000.
                // This lets players manually skip the intro/victory screen.
                return raw_input & 0xC000;
            },
            .in_game, .retry_menu => {
                // Retry-menu sync gate: if in .retry_menu waiting for the remote to
                // reach our transition index, suppress all local inputs.
                // Prevents the faster player from skipping the victory
                // animation and pressing rematch before the slower player
                // reaches the menu — which would desync (.retry_menu → .loading
                // on one side while the other still sees victory).
                //
                //
                // 30s safety timeout: if the peer crashes or the
                // TransitionIndex is lost, unblock inputs to avoid
                // freezing the game indefinitely.
                if (self.state == .retry_menu and self.retry_menu_waiting_for_peer) {
                    const now = std.Io.Clock.now(.real, self.io).toMilliseconds();
                    if (self.retry_menu_wait_start_ms == 0) {
                        self.retry_menu_wait_start_ms = now;
                    }
                    if (now - self.retry_menu_wait_start_ms > 10_000) {
                        self.retry_menu_waiting_for_peer = false;
                        self.retry_menu_wait_start_ms = 0;
                        self.log.warn("Retry menu peer wait timed out (10s) — unblocking inputs", .{});
                    } else {
                        return 0; // suppress input
                    }
                }
                // Real input. In netplay, strip the Start button to prevent
                // pausing — pausing halts the game loop while the remote peer
                // keeps simulating, causing an instant desync. Matches CCCaster
                // (DllNetplayManager.cpp:240-265: input &= ~CC_BUTTON_START).
                if (self.config.is_netplay and !self.config.is_spectator) {
                    return raw_input & ~(button_start << 4); // strip Start
                }
                return raw_input;
            },
        }
    }

    pub fn setLocalInput(self: *NetplayManager, input: u16) void {
        // Use rollback_delay during re-runs, delay otherwise — matches
        // CCCaster's getDelay() (DllNetplayManager.hpp:118):
        //   return ( isInRollback() ? config.rollbackDelay : config.delay );
        // During a rollback re-run, we want minimal input lag so the
        // re-simulation catches up quickly. rollback_delay is typically 0
        // (re-run inputs are immediate), while delay is typically 1 (normal
        // play has 1 frame of input lag for network transit).
        const effective_delay: u8 = if (self.isRerunning())
            self.config.rollback_delay
        else
            self.config.delay;
        const frame = self.indexed_frame.frame + effective_delay;
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
        // CharaSelect and InGame block on remote input (lockstep).
        // All other states return true (run at own pace, catch-up mash handles lag).
        //
        // EXCEPTION: chara_intro blocks on remote reaching the same index.
        // Without this, a fast peer (who finished loading and entered
        // chara_intro first) would advance frames freely while the slow
        // peer is still in loading. The intro animation would play out
        // (or round_start_counter would increment) at different relative
        // frames for each peer → frame-0 state divergence → desync.
        //
        // By blocking during chara_intro until the remote reaches our
        // index, we pause the local game (lockstep wait freezes
        // frameStep, which freezes the game loop, which freezes
        // world_timer) until the remote is also in chara_intro. Both
        // peers then watch the intro from the same starting point and
        // reach "players can move" at the same relative frame.
        switch (self.state) {
            .pre_initial, .initial, .loading => return true,
            // chara_intro, skippable, retry_menu, chara_select, and in_game
            // all use the per-frame lockstep logic below (fall through to the
            // generic check that verifies remote has sent input for the
            // current frame).
            //
            // Originally tried index-based blocking for chara_intro/skippable
            // (commits 0e4760c, 0dc28ab, e4a8ba5), then per-frame lockstep
            // (commit d6a93b6), then reverted to index-based (commit d1899e8),
            // then reverted back to per-frame lockstep (this commit).
            //
            // The revert to index-based (d1899e8) was a mistake. Diagnostic
            // logs showed the remote was 30 frames ahead at the start of
            // chara_intro (remote_end_frame=30 while local frame=0). With
            // index-based blocking, the local peer advanced freely because
            // remote_end_index (4) > our_index (3), even though the remote
            // was 30 frames ahead in the animation. Both peers reached
            // "players can move" at different frames → massive divergence
            // (camera Δ19613, P1.x Δ45227, RNG mismatch).
            //
            // Per-frame lockstep (d6a93b6) had a minor regression: small
            // position drift over ~150 frames (camera Δ161, P1.x Δ250) with
            // RNG matching. This is MUCH better than the massive divergence
            // from index-based blocking. The small drift needs separate
            // investigation (possibly the cooperative sleep / RTT EMA
            // interacting with the lockstep during animation).
            //
            // The per-frame check (getEndFrame(our_index) > our_frame)
            // guarantees the remote has actually advanced to our frame, not
            // just reached our index. Both peers advance one frame at a time,
            // each waiting for the other's input before proceeding.
            .chara_intro, .skippable, .retry_menu, .chara_select, .in_game => {},
        }

        if (!self.config.is_netplay or self.config.is_spectator) return true;

        // Client blocks until host's RNG packet is applied (prevents RNG
        // advancement race). Not gated during chara_select (low-stakes,
        // cached RNG applied on in_game transition).
        if (self.state != .chara_select and
            self.should_sync_rng and !self.config.is_host and !self.rng_synced)
        {
            return false;
        }

        const our_index = self.indexed_frame.index;

        // No remote inputs at all yet — wait
        if (self.remote_inputs.getEndIndex() == 0) return false;

        const remote_end_index = self.remote_inputs.getEndIndex() - 1;

        // Remote is behind us — wait for them to catch up to our index
        if (remote_end_index < our_index) return false;

        // Remote is ahead of us OR at the same index — check if we have the
        // frame we need. Even if the remote is at a higher index (they've sent
        // TransitionIndex for a future state), they may not have sent actual
        // PlayerInputs for our current index yet. Without this check, we'd
        // predict remote input = 0 and run ahead, causing a large rollback
        // when the real inputs arrive — exactly the "huge rollback at Fight!"
        // symptom.
        //
        // If rollback is enabled, we can simulate up to `rollback` frames ahead.
        const max_frames_ahead = if (self.isInRollback()) self.config.rollback else 0;
        const needed = self.indexed_frame.frame;
        const end_frame = self.remote_inputs.getEndFrame(our_index);
        return (end_frame + max_frames_ahead) > needed;
    }

    // --- Send local inputs to peer ---

    pub fn sendLocalInputs(self: *NetplayManager) void {
        // Send the last num_inputs frames of local input, up to frame+delay.
        // Wire format (after sendInputs prepends 0x01 tag):
        //   [4 start_frame][4 index][N × 2 inputs]
        // Use rollback_delay during re-runs (matches setLocalInput).
        const effective_delay: u8 = if (self.isRerunning())
            self.config.rollback_delay
        else
            self.config.delay;
        const last_frame = self.indexed_frame.frame + effective_delay;
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
        // Host captures and sends RNG at 3 points: chara_select entry,
        // in_game entry (via onStateTransition), and intro_done for rounds
        // 2+ (via checkIntroDone). Client blocks via isRemoteInputReady
        // gate until the RNG packet arrives.
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

        // Cache the captured RNG body (bytes 1.., skipping the type tag) so
        // the SpectatorManager can forward it to spectators. Mirrors CCCaster
        // DllMain.cpp:523: `netMan.setRngState(msgRngState->getAs<RngState>())`
        // which caches in `_rngStates` for later lookup by the spectator
        // manager (DllSpectatorManager.cpp:177).
        self.cacheRngState(rng_buf[1..1 + rng_body_size]);

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
        //
        // For spectators we relax this to `rng_index <= current + 1` (i.e.
        // accept any RNG that isn't from the future). The spectator's
        // `indexed_frame.index` is driven by its own MBAACC state transitions,
        // which may lag behind the host's because the spectator receives
        // BothInputs at a delay. The host sends RNG keyed by the spectator's
        // playback index (see SpectatorManager.frameStepSpectators), so the
        // received `rng_index` will always be for an index the spectator is
        // at or has already passed — but it may be strictly less than
        // `self.indexed_frame.index` if the spectator has since advanced.
        // Rejecting it would leave the spectator's RNG unsynchronized for
        // that round. Mirrors CCCaster's spectator path, which looks up
        // `_netManPtr->getRngState(oldIndex)` (DllSpectatorManager.cpp:177)
        // and sends whatever is cached for that index without a forward-only
        // guard on the spectator side.
        if (self.config.is_spectator) {
            if (rng_index > self.indexed_frame.index + 1) {
                self.log.warn("Spectator: ignoring future RNG for index {d} (we're at {d})", .{
                    rng_index, self.indexed_frame.index,
                });
                return;
            }
        } else {
            if (rng_index != self.indexed_frame.index and rng_index != self.indexed_frame.index + 1) {
                self.log.warn("Ignoring RNG for index {d} (we're at {d})", .{ rng_index, self.indexed_frame.index });
                return;
            }
        }

        // Cache the RNG state in the local cached_rng_states buffer.
        self.cacheRngState(body);

        // If this RNG is for the next index, cache it but defer application
        // to game memory until onStateTransition transitions us to the new index.
        if (rng_index == self.indexed_frame.index + 1) {
            self.log.info("Cached future remote RNG state (index={d}, current={d})", .{rng_index, self.indexed_frame.index});
            if (!self.config.is_spectator) {
                self.sendRngAck(rng_index);
            }
            return;
        }

        // ----------------------------------------------------------------
        // Idempotent application: if we've already applied the host's RNG
        // for THIS round (same `rng_index`), do NOT overwrite the game's
        // RNG state again. The host re-sends every `rng_resend_period`
        // frames while waiting for our ACK (see `syncRngState`), and by
        // the time a re-send arrives our game has already advanced N
        // frames past S_F. Overwriting with the stale S_F would undo
        // those N advancements and silently diverge us from the host. We
        // just re-ACK so the host stops re-sending.
        //
        // If `rng_index` differs from `rng_synced_index`, this is a NEW
        // round's RNG (the host sent it before our local state transition
        // reset `rng_synced`). Fall through and apply it.
        // ----------------------------------------------------------------
        if (self.rng_synced and rng_index == self.rng_synced_index) {
            self.log.info("RNG already synced for index {d} — re-acking only", .{rng_index});
            // Spectators don't ACK (see comment below at the sendRngAck call).
            if (!self.config.is_spectator) {
                self.sendRngAck(rng_index);
            }
            return;
        }

        rng_state0_addr.* = std.mem.readInt(u32, body[4..8], .little);
        rng_state1_addr.* = std.mem.readInt(u32, body[8..12], .little);
        rng_state2_addr.* = std.mem.readInt(u32, body[12..16], .little);
        @memcpy(rng_state3_addr[0..rng_state3_size], body[16 .. 16 + rng_state3_size]);
        self.rng_synced = true;
        self.rng_synced_index = rng_index;
        self.log.info("Applied remote RNG state (index={d})", .{rng_index});

        // Acknowledge receipt so the host can stop re-sending. The host
        // may re-send several times before this arrives (see syncRngState);
        // replying to every received packet is fine — the host ignores
        // acks after the first (see `confirmRngAck`).
        //
        // Spectators do NOT send ACKs: the host's `confirmRngAck` sets
        // `rng_acked = true`, which tells the host the CLIENT has applied
        // the RNG. A spectator ACK would falsely signal client receipt,
        // causing the host to stop re-sending before the actual client
        // has applied the RNG. Spectators are passive receivers — they
        // just apply the RNG and continue.
        if (!self.config.is_spectator) {
            self.sendRngAck(rng_index);
        }
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

    /// Send our protocol version to the peer for compatibility checking.
    /// Called once when ENet connects. If versions don't match, disconnect.
    pub fn sendVersionConfig(self: *NetplayManager) void {
        if (self.enet_peer == null or !self.enet_connected) return;
        if (self.version_confirmed or self.version_mismatch) return; // already sent
        var buf: [5]u8 = undefined;
        buf[0] = 0x07; // VersionConfig
        std.mem.writeInt(u32, buf[1..5], protocol_version, .little);
        self.sendReliable(&buf);
        self.log.info("Sent VersionConfig (version={d})", .{protocol_version});
    }

    /// Send an error message to the peer before disconnecting, so the remote
    /// knows WHY we disconnected. Matches CCCaster's ErrorMessage (Messages.hpp).
    pub fn sendErrorMessage(self: *NetplayManager, message: []const u8) void {
        if (self.enet_peer == null or !self.enet_connected) return;
        var buf: [129]u8 = undefined;
        buf[0] = 0x06; // ErrorMessage
        const len = @min(message.len, 128);
        @memcpy(buf[1 .. 1 + len], message[0..len]);
        self.sendReliable(buf[0 .. 1 + len]);
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
        self.rng_synced_index = rng_index;
        self.log.info("RNG sync confirmed by peer ack (index={d}, after {d} send(s))", .{
            rng_index, self.rng_send_count,
        });
    }

    /// Host: cache a captured RNG state body so the SpectatorManager can
    /// forward it to spectators. `body` is the 236-byte payload
    /// [4 index][4 rng0][4 rng1][4 rng2][220 rng3] (i.e., the 0x02 packet
    /// body without the 1-byte type tag). Mirrors CCCaster's
    /// `NetplayManager::setRngState` (DllNetplayManager.cpp:1039-1052),
    /// which stores into `_rngStates[index - _startIndex]`.
    ///
    /// Uses a simple linear scan + overwrite-if-exists + overwrite-oldest
    /// strategy. The cache holds 8 entries — enough for ~8 rounds, which
    /// exceeds any realistic MBAACC match (best-of-3 = max 4 rounds per
    /// match including rematch).
    fn cacheRngState(self: *NetplayManager, body: []const u8) void {
        if (body.len < rng_body_size) return;
        const index = std.mem.readInt(u32, body[0..4], .little);

        // First pass: if we already have an entry for this index, update it
        // in place (the host may re-capture at the same index if it re-sends).
        for (&self.cached_rng_states) |*entry| {
            if (entry.valid and entry.index == index) {
                @memcpy(&entry.body, body[0..rng_body_size]);
                return;
            }
        }

        // Second pass: find the first invalid slot.
        for (&self.cached_rng_states) |*entry| {
            if (!entry.valid) {
                entry.valid = true;
                entry.index = index;
                @memcpy(&entry.body, body[0..rng_body_size]);
                return;
            }
        }

        // All slots full: overwrite the one with the smallest index (oldest).
        var oldest_idx: usize = 0;
        for (self.cached_rng_states, 0..) |entry, i| {
            if (entry.index < self.cached_rng_states[oldest_idx].index) {
                oldest_idx = i;
            }
        }
        self.cached_rng_states[oldest_idx].index = index;
        @memcpy(&self.cached_rng_states[oldest_idx].body, body[0..rng_body_size]);
    }

    /// Host: look up a cached RNG state by transition index. If found,
    /// copy the 236-byte body into `out` and return true. Used by the
    /// SpectatorManager to forward the host's authoritative RNG state to
    /// each spectator. Mirrors CCCaster's `NetplayManager::getRngState`
    /// (DllNetplayManager.cpp:1024-1037).
    pub fn getCachedRngState(self: *const NetplayManager, index: u32, out: []u8) bool {
        if (out.len < rng_body_size) return false;
        for (self.cached_rng_states) |entry| {
            if (entry.valid and entry.index == index) {
                @memcpy(out[0..rng_body_size], &entry.body);
                return true;
            }
        }
        return false;
    }

    // --- State transitions ---

    /// Validate state transitions. Diverges from CCCaster: no AutoCharaSelect
    /// or ReplayMenu states; pre_initial can go directly to any gameplay state;
    /// skippable → chara_select added for rematch flow.
    fn isValidNext(self: *const NetplayManager, new: NetplayState) bool {
        const old = self.state;
        const valid = switch (old) {
            .pre_initial => new == .initial or new == .chara_select or new == .loading or new == .chara_intro or new == .in_game,
            .initial => new == .chara_select or new == .in_game,
            .chara_select => new == .loading,
            .loading => new == .chara_intro or new == .in_game,
            .chara_intro => new == .in_game,
            .in_game => new == .skippable or new == .chara_select or new == .retry_menu,
            .skippable => new == .in_game or new == .retry_menu or new == .chara_select,
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
        } else if (new_mode == mode_retry) {
            // Post-match "Rematch / Character Select" menu. The game sets
            // game_mode = 5 when the deciding round ends; transitioning to
            // .retry_menu enables raw_input in getNetplayInput so the
            // player can navigate the cursor with the d-pad. Without this,
            // the FSM remains in .skippable (Confirm/Cancel only) and the
            // d-pad is ignored — the user can only confirm Rematch.
            //
            // Either routeRoundOver already sent us here (.in_game → .retry_menu),
            // or the game_mode change arrives first while we're still in
            // .in_game / .skippable (race with the round_over countdown).
            // isValidNext accepts .in_game → .retry_menu and
            // .skippable → .retry_menu.
            new_state = .retry_menu;
        } else if (new_mode == mode_in_game) {
            if (self.config.is_training or !self.config.is_netplay or self.config.is_spectator) {
                new_state = .in_game;
            } else {
                // Versus netplay: enter chara_intro first. The actual
                // chara_intro → in_game transition is driven by the intro
                // state flag (CC_INTRO_STATE_ADDR going to 0), watched in
                // checkIntroDone(). This DIVERGES from the legacy, which uses
                // the RoundStart variable watch (DllMain.cpp:1266-1270) for
                // both CharaIntro→InGame and Skippable→InGame; the Zig uses
                // intro_state for the former and round_start_counter for the latter.
                new_state = .chara_intro;
            }
        }

        if (new_state) |ns| {
            // Respect isValidNext: refuse to apply invalid transitions.
            // The previous implementation logged invalid transitions but
            // proceeded anyway, which could corrupt the FSM when the game
            // wrote an out-of-sequence mode (e.g. due to a desync or an
            // unhandled flow like Skippable → CharaSelect). Now we keep
            // the previous state and let the next frame's checkXxx
            // functions (checkIntroDone / checkRoundStart / checkRoundOver)
            // recover from there.
            //
            // isValidNext already logs the invalid transition as an error,
            // so we just bail here without an extra log line.
            if (!self.isValidNext(ns)) return;
            self.state = ns;
            self.onStateTransition(old_state, ns);
            if (new_mode == mode_in_game) self.onEnterInGame();
            self.log.info("NetplayState -> {s} (game_mode={d})", .{ @tagName(self.state), new_mode });

            // Reset SFX dedup on each state transition (legacy clears per round).
            if (self.sfx_dedup) |*sd| sd.clearPerFrame();
        }
    }

    pub fn checkIntroDone(self: *NetplayManager) void {
        // Arm RNG sync at intro_done (game_state==99) for rounds 2+ only.
        // For round 1, RNG is already synced at chara_select + in_game entry.
        // The chara_intro → in_game transition itself is handled by
        // checkRoundStart() via round_start_counter (fires at pre-game).
        if (!self.intro_rng_enabled and game_state_addr.* == game_state_intro_done and self.first_in_game_completed) {
            self.intro_rng_enabled = true;
            self.should_sync_rng = true;
            self.rng_synced = false;
            self.rng_acked = false;
            self.rng_send_cooldown = 0;
            self.rng_send_count = 0;
            self.log.info("Intro done (game_state=99) — RNG sync enabled (round 2+)", .{});
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
                    self.routeRoundOver();
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
            self.routeRoundOver();
        }
    }

    /// Decide where to send the FSM after a round ends.
    ///
    /// Round-over (`.skippable`): inter-round "Round X Winner" / "Continue?"
    ///   screen. Inputs are filtered to Confirm/Cancel only. The game
    ///   fires `round_start_counter` after a brief delay, and `checkRoundStart`
    ///   catches that to transition back to `.in_game` for the next round.
    ///
    /// Match-over (`.retry_menu`): post-match "Rematch" / "Character Select"
    ///   screen. Inputs are passed through (`getNetplayInput` returns
    ///   `raw_input`), so the player can move the cursor with the d-pad.
    ///   Confirm → either loads the next match (`.retry_menu → .loading`)
    ///   or returns to chara_select (`.retry_menu → .chara_select`); both
    ///   transitions are driven by the game's own `game_mode` changes via
    ///   `onGameModeChanged` (8 → loading, 20 → chara_select).
    ///
    /// We detect match-over by reading the per-player wins counters that
    /// the game itself maintains at CC_P1_WINS_ADDR / CC_P2_WINS_ADDR.
    /// When either player has at least `config.win_count` rounds won in
    /// the current match, the round that just ended was the deciding
    /// round. The legacy CCCaster implementation routes this same logic
    /// (DllMain.cpp:netplayStateChanged).
    ///
    /// Read AFTER the round-over countdown has decided to fire — by this
    /// point the game has already incremented the loser's no_input_flag
    /// (see playerRoundOver), and the per-round win counter has been
    /// updated. We don't need to wait or re-read; a single read here is
    /// the authoritative state.
    ///
    /// Note on rollback: this runs from the live frame loop path (not
    /// from a re-run), and the round_over_timer is gated on rollback
    /// spacing. If a rollback reverts to a frame before this transition
    /// fires, the timer is reset (round_over_timer = -1 in the
    /// `!is_over` branch above), and we'll re-evaluate on the next
    /// frame. The wins counter is also part of the rollback state pool
    /// (rollback_regions.zig:32-33), so a rollback reverts any premature
    /// win increments — safe to read here.
    fn routeRoundOver(self: *NetplayManager) void {
        const p1_wins: u32 = p1_wins_addr.*;
        const p2_wins: u32 = p2_wins_addr.*;
        const win_count: u32 = self.config.win_count;
        const match_over = (win_count > 0) and (p1_wins >= win_count or p2_wins >= win_count);
        if (match_over) {
            self.log.info("Match over (P1 wins={d}, P2 wins={d}, target={d}) — routing to RetryMenu", .{
                p1_wins, p2_wins, win_count,
            });
            self.transitionTo(.retry_menu);
        } else {
            self.log.info("Round over (P1 wins={d}, P2 wins={d}, target={d}) — routing to Skippable", .{
                p1_wins, p2_wins, win_count,
            });
            self.transitionTo(.skippable);
        }
    }

    /// Decrement the round-over countdown once per in-game frame. Mirrors
    /// the legacy decrement in frameStepNormal (DllMain.cpp:210-211). Called
    /// from frameStep before checkRoundOver so the timer can reach 0.
    pub fn tickRoundOverTimer(self: *NetplayManager) void {
        if (self.round_over_timer > 0) self.round_over_timer -= 1;
    }

    /// Watch round_start_counter for changes. Fires when players can move
    /// (intro_state==1, pre-game). Transitions chara_intro→in_game and
    /// skippable→in_game. Requires hijackIntroState ASM hack to be active.
    pub fn checkRoundStart(self: *NetplayManager) void {
        const current = asm_hacks.round_start_counter;
        if (current == self.last_round_start) return;

        if (self.state == .skippable or self.state == .chara_intro) {
            // For chara_intro→in_game, wait until the remote has reached
            // our transition index (prevents frame-0 state divergence).
            if (self.state == .chara_intro) {
                const remote_end_index = self.remote_inputs.getEndIndex();
                if (remote_end_index <= self.indexed_frame.index) {
                    if (!self.round_start_waiting_logged) {
                        self.round_start_waiting_logged = true;
                        self.log.info("Round start (counter {d} -> {d}) — chara_intro but remote behind (remote_end_index={d}, our_index={d}), waiting", .{
                            self.last_round_start, current, remote_end_index, self.indexed_frame.index,
                        });
                    }
                    return;
                }
            }
            self.round_start_waiting_logged = false;
            const prev = self.last_round_start;
            self.last_round_start = current;
            self.log.info("Round start (counter {d} -> {d}) — {s} -> InGame (frame={d}, world_timer={d})", .{
                prev, current, @tagName(self.state), self.indexed_frame.frame, world_timer_addr.*,
            });
            self.transitionTo(.in_game);
        } else {
            self.round_start_waiting_logged = false;
            const prev = self.last_round_start;
            self.last_round_start = current;
            self.log.info("Round start counter {d} -> {d} (state={s}, no transition)", .{
                prev, current, @tagName(self.state),
            });
        }
    }

    fn transitionTo(self: *NetplayManager, new: NetplayState) void {
        if (self.state == new) return;
        const old = self.state;
        _ = self.isValidNext(new);
        self.state = new;
        self.onStateTransition(old, new);
        self.round_over_timer = -1;
        self.log.info("{s} -> {s}", .{ @tagName(old), @tagName(new) });
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

        // DIAGNOSTIC: log absolute world_timer at each transition to identify
        // frame-level divergence between peers (especially on second match
        // after rematch). If both peers log the same world_timer at the same
        // transition, they're synchronized. If they differ, the intro/victory
        // animation started at different times.
        if (new == .chara_intro or new == .in_game or new == .skippable) {
            self.log.info("DIAG: transition to {s} at world_timer={d} (index={d})", .{
                @tagName(new), self.start_world_time, self.indexed_frame.index,
            });
        }

        // Arm RNG sync when entering `.in_game` (round 1 entry from
        // chara_intro, training mode direct entry) AND when entering
        // `.chara_select` (match start / character-select after retry menu).
        // Per-round re-arm for rounds 2+ is handled by `checkIntroDone`
        // when `game_state == 99`.
        //
        // CharaSelect arming is REQUIRED because MBAACC's character-select
        // screen consumes RNG (Random character pick, preview animations,
        // stage-select effects). The four RNG state words
        // (`rng_state0..3_addr`) are global MBAACC memory, NOT scoped to
        // UI state — a Random pick during chara_select is baked into the
        // determinism root for the round that follows. Without chara_select
        // RNG sync, host and client diverge on the very first Random pick.
        //
        // This matches the legacy CCCaster, which arms at all three points
        // (`DllMain.cpp:1075-1081`): CharaSelect, InGame, and INTRO_DONE.
        //
        // Determinism of the apply-frame is guaranteed by the
        // `isRemoteInputReady` gate (see that function): the client blocks
        // in the lockstep wait loop until `rng_synced` becomes true, so the
        // host's RNG snapshot is applied at the same logical frame on both
        // peers. This closes the original frame-149 desync race that
        // motivated disabling chara_select arming in commit 033de46.
        if (new == .in_game or new == .chara_select) {
            self.rng_synced = false;
            self.rng_acked = false;
            self.rng_send_cooldown = 0;
            self.rng_send_count = 0;
            self.should_sync_rng = true;
            // Re-enable the defense-in-depth gate in syncRngState so the
            // host actually sends (and the client accepts) the RNG state
            // for round 1. Without this, intro_rng_enabled stays false from
            // the prior chara_select transition (line below) and syncRngState
            // silently no-ops every frame. Rounds 2+ are handled separately
            // by checkIntroDone when game_state == 99.
            if (new == .chara_select or !self.first_in_game_completed) {
                self.intro_rng_enabled = true;
            }

            // Mark first in_game as completed so that checkIntroDone knows
            // to enable intro_done RNG sync for subsequent rounds (2+).
            if (new == .in_game) {
                self.first_in_game_completed = true;
            }

            // Reset first_in_game_completed when starting a new match at
            // chara_select. This allows the intro_done RNG sync guard to
            // correctly suppress for round 1 of the new match.
            if (new == .chara_select) {
                self.first_in_game_completed = false;
            }

            // Client/Spectator: apply the cached RNG state if we received and cached it early
            if (!self.config.is_host) {
                var cached_body: [rng_body_size]u8 = undefined;
                if (self.getCachedRngState(self.indexed_frame.index, &cached_body)) {
                    rng_state0_addr.* = std.mem.readInt(u32, cached_body[4..8], .little);
                    rng_state1_addr.* = std.mem.readInt(u32, cached_body[8..12], .little);
                    rng_state2_addr.* = std.mem.readInt(u32, cached_body[12..16], .little);
                    @memcpy(rng_state3_addr[0..rng_state3_size], cached_body[16 .. 16 + rng_state3_size]);
                    self.rng_synced = true;
                    self.rng_synced_index = self.indexed_frame.index;
                    self.log.info("Applied cached remote RNG state at transition (index={d})", .{self.indexed_frame.index});
                }
            }
        }

        // Loading and Skippable clear intro_rng_enabled so we don't want stale
        // RNG sync state lingering from a previous round/match.
        if (new == .loading or new == .skippable) {
            self.intro_rng_enabled = false;
        }

        // Retry-menu sync gate: when entering .retry_menu, check if
        // the remote has reached our transition index. If not, set
        // the flag that suppresses local inputs until the peer catches up
        // (confirmed via setRemoteIndex).
        //
        if (new == .retry_menu and self.config.is_netplay and !self.config.is_spectator) {
            const remote_end_index = if (self.remote_inputs.getEndIndex() > 0)
                self.remote_inputs.getEndIndex() - 1
            else
                0;
            if (remote_end_index < self.indexed_frame.index) {
                self.retry_menu_waiting_for_peer = true;
                self.retry_menu_wait_start_ms = 0; // set on first getNetplayInput call
                self.log.info("Retry menu: blocking inputs until peer catches up (remote_end_index={d}, our_index={d})", .{
                    remote_end_index, self.indexed_frame.index,
                });
            }
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
    /// Resizes the remote input container so getEndIndex() reflects the
    /// remote's new index. Matches CCCaster's setRemoteIndex.
    pub fn setRemoteIndex(self: *NetplayManager, remote_idx: u32) void {
        self.remote_index = remote_idx;
        self.remote_inputs.resizeOuter(remote_idx);
        // Unblock retry menu inputs if we were waiting for the peer.
        if (self.retry_menu_waiting_for_peer and remote_idx >= self.indexed_frame.index) {
            self.retry_menu_waiting_for_peer = false;
            self.retry_menu_wait_start_ms = 0;
            self.log.info("Peer reached retry_menu (index {d}) — inputs unblocked", .{remote_idx});
        }
        self.log.info("Remote transition index: {d} (remote_inputs.end_index now {d})", .{
            remote_idx, self.remote_inputs.getEndIndex(),
        });
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
        // Only meaningful during `.in_game`. Legacy CCCaster gates the hash
        // check on InGame because the RNG state is explicitly synced at the
        // `chara_intro → in_game` boundary; pre-in_game RNG draws are not
        // guaranteed to be deterministic across peers (cursor animation,
        // music selection, particle effects all touch RNG) and would
        // produce false-positive desyncs. Mirrors the legacy exclusion.
        if (self.state != .in_game) return;

        // CRITICAL: Do not capture/send a SyncHash until RNG is synced for
        // this round. Without this gate, the SyncHash fires at frame 0 of a
        // new index (because `frame % sync_send_period == 0` is true when
        // frame==0), which is BEFORE the client has received and applied the
        // host's RNG packet for that index. The result: the host captures
        // its authoritative RNG, the client captures its stale local RNG,
        // and checkSyncHashDesync immediately flags a "RNG hash mismatch"
        // desync — even though both sides will agree on RNG a few frames
        // later once the packet arrives.
        //
        // `rng_synced` is set:
        //   - On the client, by `applyRemoteRng` when the host's RNG packet
        //     is received and written to game memory.
        //   - On the host, by `confirmRngAck` when the client's RNG_ACK
        //     arrives (proving the client has applied the RNG).
        // Both sides reset `rng_synced = false` in `onStateTransition` and
        // `checkIntroDone`, so this gate correctly blocks SyncHash for the
        // first few frames of every round/index until the RNG exchange
        // completes. The missed frame-0 SyncHash is harmless — the next
        // one fires at frame 149 (or 300).
        if (self.should_sync_rng and !self.rng_synced) return;
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

    /// Append to a bounded ring; drop the oldest when full. The legacy
    /// code uses an unbounded std::list (DllMain.cpp:175) and never
    /// discards on full — the bounded ring is a Zig-specific defensive
    /// measure. In practice exchanges resolve within a handful of frames,
    /// so the ring never wraps.
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
        // Only meaningful during `.in_game` — matches the maybeSendSyncHash
        // gate. Without this, any hashes enqueued in chara_select (where the
        // RNG is not yet synced and not guaranteed deterministic) would
        // produce spurious desyncs at the first 150-frame check.
        if (self.state != .in_game) return;
        if (self.local_sync_count == 0 or self.remote_sync_count == 0) return;

        // Walk both queues in indexed_frame order, dropping entries that have
        // no counterpart on the other side (legacy pops the LOWER one first).
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

    // ================================================================
    // RTT tracking + time-sync (ported from ggpo-x).
    //
    // updateRttEma reads ENet's peer.roundTripTime and applies an EMA with
    // a 10-second time constant. The smoothed value feeds the remote-frame
    // estimate and per-frame sleep recommendation.
    //
    // recommendPerFrameSleepMs returns a small sleep (0-4ms) that the faster
    // peer applies each frame to slow down and let the slower peer catch up.
    // This is cooperative time-sync: sleeping delays the game's frame, which
    // slows world_timer, which slows indexed_frame.frame.
    // ================================================================

    pub fn updateRttEma(self: *NetplayManager) void {
        if (self.enet_peer == null or !self.enet_connected) return;
        const instant: f64 = @as(f64, @floatFromInt(self.enet_peer.?.roundTripTime));
        if (instant == 0) return;
        if (!self.rtt_ema_initialized) {
            self.rtt_ema_ms = instant;
            self.rtt_ema_initialized = true;
        } else {
            self.rtt_ema_ms = instant * rtt_ema_alpha + self.rtt_ema_ms * (1.0 - rtt_ema_alpha);
        }
    }

    pub fn rttMs(self: *const NetplayManager) f64 {
        return self.rtt_ema_ms;
    }

    pub fn remoteFrameEstimate(self: *const NetplayManager) f32 {
        if (self.remote_inputs.getEndIndex() == 0) return 0;
        const last_received: f32 = @as(f32, @floatFromInt(
            self.remote_inputs.getEndFrame(self.indexed_frame.index),
        ));
        const single_trip_ms = self.rtt_ema_ms / 2.0;
        const single_trip_frames = @as(f32, @floatCast(single_trip_ms * 60.0 / 1000.0));
        return last_received + single_trip_frames + 0.5;
    }

    pub fn localFrameAdvantage(self: *const NetplayManager) f32 {
        return self.remoteFrameEstimate() - @as(f32, @floatFromInt(self.indexed_frame.frame));
    }

    pub fn recommendPerFrameSleepMs(self: *const NetplayManager) u32 {
        if (!self.rtt_ema_initialized) return 0;
        const advantage = self.localFrameAdvantage();
        if (advantage >= -min_frame_advantage) return 0;
        const ahead = -advantage;
        const sleep_ms = @min(ahead * 1.0, max_per_frame_sleep_ms);
        if (sleep_ms < 1.0) return 0;
        return @intFromFloat(sleep_ms);
    }

    fn onEnterInGame(self: *NetplayManager) void {
        self.local_inputs.reset();
        self.remote_inputs.reset();

        // Defensive reset of the retry-menu sync gate.
        //
        //
        self.retry_menu_waiting_for_peer = false;
        self.retry_menu_wait_start_ms = 0;

        // Clear sync-hash desync detection queues and the desync flag.
        // Without this, leftover entries from a previous match cause a
        // false desync on the first .in_game frame of the new match —
        // checkSyncHashDesync compares old local/remote hashes that were
        // never matched/consumed when the previous match ended, flags a
        // mismatch, and force-exits the game.
        // Also reset fast_fwd_stop_frame in case a rollback rerun was
        // in-flight when the previous match ended.
        self.local_sync_count = 0;
        self.remote_sync_count = 0;
        self.desync_detected = false;
        self.desync_local = null;
        self.desync_remote = null;
        self.fast_fwd_stop_frame = 0;

        if (self.config.rollback > 0 and self.config.is_netplay and !self.config.is_spectator) {
            if (self.state_pool.pool.len == 0) {
                for (rollback_regions.all_regions) |r| {
                    self.state_pool.addRegion(r.addr, r.size) catch {};
                }
                self.log.info("Loaded {d} rollback memory regions ({d} bytes per state)", .{ rollback_regions.all_regions.len, self.state_pool.totalRegionSize() });

                self.state_pool.allocate(60, 0) catch {
                    self.log.warn("StatePool allocate failed — rollback disabled", .{});
                };
            } else {
                self.state_pool.reset();
                self.log.info("Resetting rollback StatePool for rematch", .{});
            }
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
        if (lcf_index != self.indexed_frame.index) {
            // Stale lcf from a previous transition index. Clear it so it
            // doesn't block future current-index changes from being detected.
            self.remote_inputs.clearLastChanged();
            return false;
        }
        if (lcf_frame >= self.indexed_frame.frame) return false;

        // Early-frame rollback guard (zzcaster addition, CCCaster has none).
        // See enable_rollback_min_frame_delay_guard documentation above.
        if (enable_rollback_min_frame_delay_guard and lcf_frame < rollback_min_frame_delay)
        {
            // Guard enabled: skip the rollback but keep lcf so it can be
            // corrected later (once we're past the delay window).
            self.log.warn("ROLLBACK SKIPPED (guard): lcf_frame={d} < min={d} (current frame={d})", .{
                lcf_frame, rollback_min_frame_delay, self.indexed_frame.frame,
            });
            return false;
        }

        // ============================================================
        // Frame-0 misprediction suppression (zzcaster addition)
        // ============================================================
        // CCCaster does NOT have this guard — it would roll back to frame 0
        // if lcf_frame == 0. However, CCCaster in RELEASE build does not
        // detect desyncs at all (SyncHash handler is #ifndef RELEASE), so
        // even if a frame-0 rollback caused divergence, CCCaster wouldn't
        // report it.
        //
        // WHY WE SUPPRESS FRAME-0 ROLLBACKS:
        //
        // The state at frame 0 of in_game is the state captured at the
        // chara_intro → in_game transition. Even with the race fix (commit
        // 5a5c13c, hijackIntroState applied before waitForConfig), the
        // absolute world_timer at the transition may differ slightly
        // between peers. The saved state for frame 0 may therefore carry
        // a slightly divergent state.
        //
        // Rolling back to frame 0 loads this potentially-divergent state
        // and re-simulates from it, which can cause RNG divergence (the
        // determinism root). This was observed in online testing:
        //   - Rollback to frame 0 → re-run → RNG hash mismatch at frame 149
        //   - Subsequent rollbacks fall back to frame 0 (state pool erosion)
        //   - Divergence accumulates with each frame-0 reload
        //
        // Additionally, frame-0 mispredictions are often FALSE POSITIVES
        // caused by InputBuffer.get's cross-index fallback: when the local
        // peer reads remote input for frame 0 of a new index, get() falls
        // back to last_inputs from the previous index (e.g. chara_intro
        // inputs). If the player was holding a button during chara_intro,
        // the stale fallback differs from the actual frame-0 remote input
        // (which is typically 0 or neutral), triggering a false misprediction.
        //
        // SUPPRESSION STRATEGY:
        //   - Clear lcf (so the false misprediction doesn't persist)
        //   - Apply the remote input (it's already stored in the buffer)
        //   - Do NOT rollback (avoid loading a potentially-divergent state)
        //   - Log for observability
        //
        // This is a targeted fix for the frame-0 case only. Rollbacks to
        // frame 1+ are allowed (they load states captured after the
        // transition, which should be deterministic).
        if (lcf_frame == 0) {
            self.log.info("ROLLBACK to frame 0 SUPPRESSED — clearing lcf (false misprediction or divergent state risk). current frame={d}", .{
                self.indexed_frame.frame,
            });
            self.remote_inputs.clearLastChanged();
            return false;
        }

        // Guard disabled (default, matches CCCaster): log early-frame
        // rollbacks so we can detect if the frame-0 state divergence
        // returns. If these log lines appear followed by a desync, the
        // intro-animation-timing fix didn't fully solve the frame-0 issue.
        if (lcf_frame < rollback_min_frame_delay) {
            self.log.info("ROLLBACK to early frame {d} (current={d}, lcf_index={d}) — guard disabled, proceeding", .{
                lcf_frame, self.indexed_frame.frame, lcf_index,
            });
        }

        const loaded = self.state_pool.loadStateForFrame(lcf_frame, lcf_index);
        if (loaded == null) {
            // Do NOT clear last changed frame! Let's keep it so it retries on subsequent frames.
            // Matches CCCaster: DllMain.cpp:620
            self.log.err("ROLLBACK FAILED: no saved state for frame {d} (rollback history exceeded, pool size is {d})", .{ lcf_frame, self.state_pool.num_states });
            return false;
        }

        // CRITICAL: Restore NetplayManager state to match CCCaster's loadState
        // (DllRollbackManager.cpp:147-149):
        //   netMan._state = it->netplayState;
        //   netMan._startWorldTime = it->startWorldTime;
        //   netMan._indexedFrame = it->indexedFrame;
        // Without restoring these, the re-run uses stale FSM state / wrong
        // frame counter base → wrong inputs → RNG diverges.
        self.state = @enumFromInt(loaded.?.netplay_state);
        self.start_world_time = loaded.?.start_world_time;

        // Strategy 2B (docs/dll-optimization-plan.md): raise the calling
        // thread to TIME_CRITICAL priority for the duration of the rerun.
        win32.boostForRerun();

        // Trigger rollback!
        const current_frame = self.indexed_frame.frame;
        self.fast_fwd_stop_frame = current_frame;
        self.log.info("ROLLBACK: frame {d} -> {d}", .{ current_frame, lcf_frame });

        // Apply SFX dedup filter: OR together snapshots between loaded and
        // current frame, then mark with 0x80 sentinel so the play-hook
        // knows to suppress them.
        if (self.sfx_dedup) |*sd| {
            sd.applyRollbackFilter(loaded.?.frame, current_frame);
        }

        self.indexed_frame.frame = loaded.?.frame;
        self.log.info("ROLLBACK: loaded state for frame {d}, re-running to {d}", .{ loaded.?.frame, current_frame });

        self.remote_inputs.clearLastChanged();
        self.rollback_timer = 0;
        return true;
    }

    pub fn isRerunning(self: *const NetplayManager) bool {
        return self.fast_fwd_stop_frame != 0;
    }

    /// Returns true when the FSM is in a "deterministic animation" state
    /// where inputs are suppressed and the game's progression is purely
    /// time-driven (chara_intro, skippable, retry_menu). In these states
    /// there is no input-prediction / rollback happening, and both peers
    /// are gated by the per-frame lockstep in isRemoteInputReady — so
    /// time-sync machinery (cooperative sleep, RTT EMA, frame limiter
    /// compensation) does not need to run, and running it adds timing
    /// variability that has been linked to the small-drift desync
    /// documented in docs/rollback-desync-investigation.md and
    /// docs/cccaster-vs-zzcaster-diffs.md.
    pub fn isInAnimationState(self: *const NetplayManager) bool {
        return switch (self.state) {
            .chara_intro, .skippable, .retry_menu => true,
            else => false,
        };
    }

    /// Force CC_INTRO_STATE_ADDR to 0 after the pre-game intro window.
    ///
    /// hijackIntroState (applied in all netplay modes) disables the game's
    /// natural intro_state 1→0 progression. Without this manual clear,
    /// intro_state stays at 1 forever → game stuck in pre-game (can move
    /// but cannot attack).
    ///
    /// In rollback mode, this also clears intro_state loaded from a saved
    /// state that was captured before the intro finished — re-running that
    /// state would re-trigger intro-only logic and desync.
    ///
    /// Runs in ALL netplay player modes (delay + rollback), because
    /// hijackIntroState is applied in all netplay player modes.
    pub fn clearIntroStateDuringRollback(self: *NetplayManager) void {
        if (!self.config.is_netplay or self.config.is_spectator) return;
        if (self.state != .in_game) return;
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
            // Strategy 2B: restore the calling thread to NORMAL priority
            // (we boosted to TIME_CRITICAL in `checkRollback` before the
            // load). Pairs with the boost so we don't keep starving other
            // threads between rollbacks.
            win32.restoreAfterRerun();
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
