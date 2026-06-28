// Port of the rollback-relevant subset of CCCaster's `netplay/Constants.hpp`.
//
// Only constants that the rollback / state-save / input-container code touches
// are included here. Network / config / palette constants are intentionally
// omitted — this is a focused port of the rollback subsystem.
//
// The MBAACC memory addresses are 32-bit Windows virtual addresses inside
// MBAA.exe's address space. They are only dereferenced when this code is
// running inside the injected hook.dll on Windows; on the host (for tests)
// they are never dereferenced, only stored in region descriptors.

const std = @import("std");

// --- Rollback sizing -------------------------------------------------------

/// Number of input frames packed into a single PlayerInputs message.
/// Matches CCCaster `#define NUM_INPUTS ( 30 )` (Constants.hpp:10).
pub const num_inputs: u32 = 30;

/// Maximum allowed rollback frames. Matches `MAX_ROLLBACK` (Constants.hpp:13).
pub const max_rollback: u8 = 15;

/// Number of rollback states to allocate in the memory pool.
/// Matches `NUM_ROLLBACK_STATES` (Constants.hpp:16-20):
///   - 60 in RELEASE builds
///   - 256 in debug builds
/// The Zig port defaults to the debug value; the build can override.
pub const num_rollback_states: usize = 256;

// --- SFX (sound-effect dedup) ---------------------------------------------

/// Length of the SFX filter array. Matches `CC_SFX_ARRAY_LEN` (Constants.hpp:215).
pub const cc_sfx_array_len: usize = 1500;

// --- Intro / pre-game ------------------------------------------------------

/// Number of frames in the initial movement-only phase. Matches
/// `CC_PRE_GAME_INTRO_FRAMES` (Constants.hpp:222). During a rollback re-run
/// that advances past this frame, `CC_INTRO_STATE_ADDR` must be forced to 0.
pub const cc_pre_game_intro_frames: u32 = 224;

// --- MBAACC memory addresses (32-bit Windows virtual addrs) ----------------
//
// These mirror the `#define CC_*_ADDR` macros in Constants.hpp. They are
// stored as `usize` so they can be cast to `[*]u8` via `@ptrFromInt` when
// the code runs inside MBAA.exe on Windows. On a non-Windows host they are
// never dereferenced.

pub const cc_world_timer_addr: usize = 0x55D1D4;
pub const cc_skip_frames_addr: usize = 0x55D25C;
pub const cc_intro_state_addr: usize = 0x55D20B;
pub const cc_alive_flag_addr: usize = 0x76E650;
pub const cc_game_mode_addr: usize = 0x54EEE8;
pub const cc_game_state_addr: usize = 0x74D598;
pub const cc_reproll_tbl_endptr_addr: usize = 0x77BF9C;
pub const cc_sfx_array_addr: usize = 0x76E008;

pub const cc_rng_state0_addr: usize = 0x563778;
pub const cc_rng_state1_addr: usize = 0x56377C;
pub const cc_rng_state2_addr: usize = 0x564068;
pub const cc_rng_state3_addr: usize = 0x564070;
pub const cc_rng_state3_size: usize = 220;

// --- Game-mode codes (CC_GAME_MODE_*) -------------------------------------

pub const cc_game_mode_startup: u32 = 65535;
pub const cc_game_mode_opening: u32 = 3;
pub const cc_game_mode_title: u32 = 2;
pub const cc_game_mode_loading_demo: u32 = 13;
pub const cc_game_mode_high_scores: u32 = 11;
pub const cc_game_mode_main: u32 = 25;
pub const cc_game_mode_replay: u32 = 26;
pub const cc_game_mode_chara_select: u32 = 20;
pub const cc_game_mode_loading: u32 = 8;
pub const cc_game_mode_in_game: u32 = 1;
pub const cc_game_mode_retry: u32 = 5;

// --- Intermediate game-state codes (CC_GAME_STATE_*) ----------------------

pub const cc_game_state_chara_intro: u32 = 1;
pub const cc_game_state_intro_skip: u32 = 101;
pub const cc_game_state_intro_mid: u32 = 100;
pub const cc_game_state_intro_done: u32 = 99;
pub const cc_game_state_cintro_end: u32 = 12;
pub const cc_game_state_pregame_done: u32 = 2;

// --- Input button bits (CC_BUTTON_*) --------------------------------------
//
// Matches Constants.hpp:86-97. Inputs are u16; the high byte holds buttons,
// the low byte holds direction (numpad notation, 0 = neutral).

pub const cc_button_a: u16 = 0x0010;
pub const cc_button_b: u16 = 0x0020;
pub const cc_button_c: u16 = 0x0008;
pub const cc_button_d: u16 = 0x0004;
pub const cc_button_e: u16 = 0x0080;
pub const cc_button_ab: u16 = 0x0040;
pub const cc_button_start: u16 = 0x0001;
pub const cc_button_fn1: u16 = 0x0100;
pub const cc_button_fn2: u16 = 0x0200;
pub const cc_button_confirm: u16 = 0x0400;
pub const cc_button_cancel: u16 = 0x0800;
pub const cc_player_facing: u16 = 0x0002;

// --- NetplayConfig (rollback-relevant fields) -----------------------------
//
// Mirrors the subset of CCCaster's `NetplayConfig` that the rollback code
// reads. `delay` is the input delay used outside of rollback (chara-select,
// menus, training). `rollback_delay` is the input delay used DURING in_game
// when rollback is enabled. `rollback` is the max number of frames the
// simulation can rewind. See DllNetplayManager.hpp:118 (`getDelay()`).

pub const NetplayConfig = struct {
    delay: u8 = 0,
    rollback_delay: u8 = 0,
    rollback: u8 = 0,
    is_netplay: bool = false,
    is_host: bool = false,
    is_spectator: bool = false,
    is_offline: bool = false,
    is_training: bool = false,
    is_versus: bool = false,
};

test "constants match CCCaster" {
    try std.testing.expectEqual(@as(u32, 30), num_inputs);
    try std.testing.expectEqual(@as(u8, 15), max_rollback);
    try std.testing.expectEqual(@as(usize, 1500), cc_sfx_array_len);
    try std.testing.expectEqual(@as(u32, 224), cc_pre_game_intro_frames);
}
