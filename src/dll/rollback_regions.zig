const std = @import("std");

// ============================================================================
// Rollback memory regions — ported from legacy_unused/Generator.cpp.
//
// These are the game memory addresses that must be saved/restored on each
// rollback. Without saving these, a rollback would rewind the input history
// but the game state (positions, health, effects, camera, etc.) would stay
// at the current frame, causing an instant desync.
//
// The list is organized as:
//   1. miscAddrs  — global game state (timers, RNG, camera, effects, HUD)
//   2. playerAddrs — per-player struct (health, position, velocity, input
//      history, etc.) — repeated 4× for P1, P2, Puppet1, Puppet2 with
//      CC_PLR_STRUCT_SIZE (0xAFC) offset between each.
//   3. effects array — 1000 graphical effect elements.
//
// NOTE: The legacy code also has pointer-following MemDumpPtr entries that
// follow pointers within saved memory to save/restore heap-allocated sub-
// structures. Those are mostly commented out in Generator.cpp except for
// the effects array (which follows a 3-level pointer chain at offset 0x320
// in each effect element). We skip pointer-following for now — the flat
// regions cover ~95% of the state needed for correct rollback. Visual
// glitches in pointed-to effect sub-structures are possible but won't
// affect game logic.
// ============================================================================

pub const Region = struct { addr: usize, size: usize };

const CC_PLR_STRUCT_SIZE = 0xAFC;

// --- Misc global state ---
const misc_addrs = [_]Region{
    .{ .addr = 0x562A3C, .size = 4 },    // CC_ROUND_TIMER_ADDR
    .{ .addr = 0x562A40, .size = 4 },    // CC_REAL_TIMER_ADDR
    .{ .addr = 0x55D1D4, .size = 4 },    // CC_WORLD_TIMER_ADDR
    .{ .addr = 0x562A6C, .size = 2 },    // CC_SLOW_TIMER_INIT_ADDR
    .{ .addr = 0x55D208, .size = 2 },    // CC_SLOW_TIMER_ADDR
    .{ .addr = 0x55D20B, .size = 1 },    // CC_INTRO_STATE_ADDR
    .{ .addr = 0x562A6F, .size = 1 },    // CC_INPUT_STATE_ADDR
    .{ .addr = 0x74D99C, .size = 4 },    // CC_SKIPPABLE_FLAG_ADDR
    .{ .addr = 0x563778, .size = 4 },    // CC_RNG_STATE0_ADDR
    .{ .addr = 0x56377C, .size = 4 },    // CC_RNG_STATE1_ADDR
    .{ .addr = 0x564068, .size = 4 },    // CC_RNG_STATE2_ADDR
    .{ .addr = 0x564070, .size = 220 },  // CC_RNG_STATE3_ADDR + SIZE
    .{ .addr = 0x563864, .size = 4 },    // unknown state
    .{ .addr = 0x56414C, .size = 4 },    // unknown state
    .{ .addr = 0x61E170, .size = 4000 * 0x60 }, // CC_GRAPHICS_ARRAY
    .{ .addr = 0x67BD78, .size = 4 },    // CC_GRAPHICS_COUNTER
    .{ .addr = 0x5595B4, .size = 4 },    // CC_SUPER_FLASH_PAUSE_ADDR
    .{ .addr = 0x562A48, .size = 4 },    // CC_SUPER_FLASH_TIMER_ADDR
    .{ .addr = 0x558608, .size = 5 * 0x30C }, // CC_SUPER_STATE_ARRAY
    .{ .addr = 0x557DB8, .size = 0x20C }, // CC_P1_EXTRA_STRUCT
    .{ .addr = 0x557FC4, .size = 0x20C }, // CC_P2_EXTRA_STRUCT
    .{ .addr = 0x559550, .size = 4 },    // CC_P1_WINS_ADDR
    .{ .addr = 0x559580, .size = 4 },    // CC_P2_WINS_ADDR
    .{ .addr = 0x559548, .size = 4 },    // CC_P1_GAME_POINT_FLAG
    .{ .addr = 0x55954C, .size = 4 },    // CC_P2_GAME_POINT_FLAG
    .{ .addr = 0x7717D8, .size = 4 },    // CC_METER_ANIMATION_ADDR
    .{ .addr = 0x5641A4, .size = 4 },    // CC_P1_SPELL_CIRCLE_ADDR
    .{ .addr = 0x564200, .size = 4 },    // CC_P2_SPELL_CIRCLE_ADDR
    .{ .addr = 0x563580, .size = 0x60 }, // CC_P1_STATUS_MSG_ARRAY
    .{ .addr = 0x5635F4, .size = 0x60 }, // CC_P2_STATUS_MSG_ARRAY
    // Intro/outro graphics
    .{ .addr = 0x74D9D0, .size = 4 },
    .{ .addr = 0x74E4E4, .size = 4 },
    .{ .addr = 0x74E4E8, .size = 4 },
    .{ .addr = 0x74D598, .size = 4 },
    .{ .addr = 0x74E5B0, .size = 4 },
    .{ .addr = 0x74E768, .size = 4 },
    .{ .addr = 0x74E770, .size = 0x14 },
    .{ .addr = 0x74E78C, .size = 0x0C },
    .{ .addr = 0x74E79C, .size = 0x0C },
    .{ .addr = 0x74E7AC, .size = 0x14 },
    .{ .addr = 0x74E7C8, .size = 0x10 },
    .{ .addr = 0x74E7DC, .size = 4 },
    .{ .addr = 0x74E7E4, .size = 0x10 },
    .{ .addr = 0x74E7F8, .size = 0x10 },
    .{ .addr = 0x74E80C, .size = 4 },
    .{ .addr = 0x74E814, .size = 0x14 },
    .{ .addr = 0x74E82C, .size = 8 },
    .{ .addr = 0x74E838, .size = 0x14 },
    .{ .addr = 0x74E850, .size = 8 },
    .{ .addr = 0x74E85C, .size = 0x10 },
    .{ .addr = 0x76E780, .size = 0x0C },
    // Camera position state
    .{ .addr = 0x555124, .size = 4 },
    .{ .addr = 0x555128, .size = 4 },
    .{ .addr = 0x5585E8, .size = 0x0C },
    .{ .addr = 0x55DEC4, .size = 0x0C },
    .{ .addr = 0x55DEDC, .size = 0x0C },
    .{ .addr = 0x564B14, .size = 0x0C },
    .{ .addr = 0x564B10, .size = 2 },
    .{ .addr = 0x563750, .size = 4 },
    .{ .addr = 0x557DB0, .size = 4 },
    .{ .addr = 0x557DB4, .size = 4 },
    .{ .addr = 0x557D2B, .size = 1 },
    .{ .addr = 0x557DAC, .size = 2 },
    .{ .addr = 0x559546, .size = 2 },
    .{ .addr = 0x564B00, .size = 2 },
    .{ .addr = 0x76E6F8, .size = 4 },
    .{ .addr = 0x76E6FC, .size = 4 },
    .{ .addr = 0x7B1D2C, .size = 4 },
    // Camera scaling state
    .{ .addr = 0x55D204, .size = 4 },
    .{ .addr = 0x56357C, .size = 4 },
    .{ .addr = 0x55DEE8, .size = 4 },
    .{ .addr = 0x564B0C, .size = 4 },
    .{ .addr = 0x564AF8, .size = 4 },
    .{ .addr = 0x564B24, .size = 4 },
    .{ .addr = 0x76E6F4, .size = 4 },
    .{ .addr = 0x54EB70, .size = 4 },    // CC_CAMERA_SCALE_1
    .{ .addr = 0x54EB74, .size = 4 },    // CC_CAMERA_SCALE_2
    .{ .addr = 0x54EB78, .size = 4 },    // CC_CAMERA_SCALE_3
};

// --- Per-player struct (repeated 4× for P1, P2, Puppet1, Puppet2) ---
// Ported from Generator.cpp playerAddrs. Each entry is {start, end} in the
// legacy code; we convert to {addr, size = end - start}.
const player_addrs = [_]Region{
    .{ .addr = 0x555130, .size = 0x10 },  // 0x555130..0x555140
    .{ .addr = 0x555140, .size = 0x20 },
    .{ .addr = 0x555160, .size = 0x20 },
    .{ .addr = 0x555180, .size = 0x08 },
    .{ .addr = 0x555188, .size = 0x08 },
    .{ .addr = 0x555190, .size = 0xB0 },  // 0x555190..0x555240
    .{ .addr = 0x555240, .size = 0x04 },
    .{ .addr = 0x555244, .size = 0x40 },  // 0x555244..0x555284
    .{ .addr = 0x555284, .size = 0x04 },
    .{ .addr = 0x555288, .size = 0x64 },  // 0x555288..0x5552EC
    .{ .addr = 0x5552EC, .size = 0x04 },
    .{ .addr = 0x5552F0, .size = 0x04 },
    .{ .addr = 0x5552F4, .size = 0x1C },  // 0x5552F4..0x555310
    .{ .addr = 0x555310, .size = 0x1C },  // 0x555310..0x55532C
    .{ .addr = 0x55532C, .size = 0x04 },
    .{ .addr = 0x555330, .size = 0x1C },  // 0x555330..0x55534C
    .{ .addr = 0x55534C, .size = 0x10 },
    .{ .addr = 0x55535C, .size = 0x70 },  // 0x55535C..0x5553CC
    .{ .addr = 0x5553CC, .size = 0x04 },
    .{ .addr = 0x5553D0, .size = 0x1C },  // 0x5553D0..0x5553EC
    .{ .addr = 0x5553EC, .size = 0x04 },
    .{ .addr = 0x5553F0, .size = 0x04 },
    .{ .addr = 0x5553F4, .size = 0x08 },  // 0x5553F4..0x5553FC
    .{ .addr = 0x5553FC, .size = 0x04 },
    .{ .addr = 0x555400, .size = 0x04 },
    .{ .addr = 0x555404, .size = 0x0C },  // 0x555404..0x555410
    .{ .addr = 0x555410, .size = 0x1C },
    .{ .addr = 0x55542C, .size = 0x04 },
    .{ .addr = 0x555430, .size = 0x1C },  // 0x555430..0x55544C
    .{ .addr = 0x55544C, .size = 0x04 },
    .{ .addr = 0x555450, .size = 0x04 },
    .{ .addr = 0x555454, .size = 0x04 },
    .{ .addr = 0x555458, .size = 0x04 },
    .{ .addr = 0x55545C, .size = 0x04 },  // 0x55545C..0x555460
    .{ .addr = 0x555460, .size = 0x04 },
    .{ .addr = 0x555464, .size = 0x08 },  // 0x555464..0x55546C
    .{ .addr = 0x55546C, .size = 0x04 },
    .{ .addr = 0x555470, .size = 0x9C },  // 0x555470..0x55550C
    .{ .addr = 0x55550C, .size = 0x04 },
    .{ .addr = 0x555510, .size = 0x08 },  // 0x555510..0x555518
    .{ .addr = 0x555518, .size = 0x102 }, // input history (directions)
    .{ .addr = 0x55561A, .size = 0x102 }, // input history (A)
    .{ .addr = 0x55571C, .size = 0x102 }, // input history (B)
    .{ .addr = 0x55581E, .size = 0x102 }, // input history (C)
    .{ .addr = 0x555920, .size = 0x102 }, // input history (D)
    .{ .addr = 0x555A22, .size = 0x102 }, // input history (E)
    .{ .addr = 0x555B24, .size = 0x08 },  // 0x555B24..0x555B2C
    .{ .addr = 0x555B2C, .size = 0x100 }, // 0x555B2C..0x555C2C
};

// --- Effects array: 1000 elements × 0x33C bytes each ---
// The 1000 effect elements are contiguous in memory, so we save them as
// a single large region rather than 1000 individual ones. This is both
// faster (one memcpy instead of 1000) and avoids comptime branch limits.
const CC_EFFECTS_ARRAY_ADDR = 0x67BDE8;
const CC_EFFECTS_ARRAY_COUNT = 1000;
const CC_EFFECT_ELEMENT_SIZE = 0x33C;

/// All memory regions to save/restore during rollback.
/// Built at comptime by concatenating misc + 4× player + effects.
fn computeRegions() [misc_addrs.len + player_addrs.len * 4 + 1]Region {
    const total = misc_addrs.len + player_addrs.len * 4 + 1;
    var regions: [total]Region = undefined;
    var i: usize = 0;

    // Misc
    for (misc_addrs) |r| {
        regions[i] = r;
        i += 1;
    }

    // 4× player structs (P1, P2, Puppet1, Puppet2)
    var p: u32 = 0;
    while (p < 4) : (p += 1) {
        const offset = @as(usize, p) * CC_PLR_STRUCT_SIZE;
        for (player_addrs) |r| {
            regions[i] = .{ .addr = r.addr + offset, .size = r.size };
            i += 1;
        }
    }

    // Effects array as a single contiguous region
    regions[i] = .{
        .addr = CC_EFFECTS_ARRAY_ADDR,
        .size = CC_EFFECTS_ARRAY_COUNT * CC_EFFECT_ELEMENT_SIZE,
    };

    return regions;
}

pub const all_regions = computeRegions();
