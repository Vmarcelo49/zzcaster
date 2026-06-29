// ASM-level patches installed into the running MBAA.exe process.
const std = @import("std");
const sfx_dedup = @import("sfx_dedup.zig");
const state = @import("dll_state.zig");

const loop_start_addr: u32 = 0x40D330;
const hook_call1_addr: u32 = 0x40D032;
const hook_call2_addr: u32 = 0x40D411;
const multiple_melty_addr: *u8 = @ptrFromInt(0x40D25A);

// Counter incremented by the detectRoundStart ASM hack every time a round
// begins (when players can move). Lives in the DLL's memory, not the game's.
// Ported from legacy DllAsmHacks.cpp:48 (roundStartCounter). The game code,
// patched at 0x440CC5 → 0x440D16 → code cave 0x441002, does:
//   mov ecx, &round_start_counter   ; load the ADDRESS (B9 = mov ecx, imm32)
//   mov esi, [ecx]                  ; read current value
//   inc esi                         ; increment
//   mov [ecx], esi                  ; store back
// NetplayManager watches this counter for changes to drive the
// Skippable → InGame transition (round 2+ start), matching the legacy
// Variable::RoundStart change-monitor in DllMain.cpp:1266-1270.
pub var round_start_counter: u32 = 0;

pub fn applyPreLoadHacks() void {
    if (state.log == null) return;
    state.log.?.info("Applying pre-load ASM hacks...", .{});
    applyHookMainLoop();
    var multi_melty: [1]u8 = .{0xEB};
    writeBytes(@intFromPtr(multiple_melty_addr), &multi_melty);
    applyHijackControls();
    applyDetectRoundStart();

    applySfxAsmHacks();
    state.log.?.info("Pre-load hacks applied", .{});
}

// hijackIntroState — NOPs 7 bytes at 0x45C1F2, disabling the game's natural
// intro_state 1→0 progression ("Fight!" announcement). This lets us manually
// control the chara_intro → in_game transition timing via checkRoundStart,
// ensuring both peers enter in_game at the same frame.
//
// Ported from CCCaster's DllAsmHacks.hpp:502-503:
//   static const Asm hijackIntroState = { ( void * ) 0x45C1F2, INLINE_NOP_SEVEN_TIMES };
//
// CRITICAL: This hack MUST be applied before the game reaches chara_intro.
// If applied after, the game's intro_state has already progressed naturally
// (1→0) at a non-deterministic frame, and both peers enter in_game at
// different points in the intro animation → characters start at different
// positions → constant position offset → desync detected ~150 frames later.
//
// To eliminate the race between config arrival (network handshake) and the
// game reaching chara_intro, this hack is pre-applied in lazyInit BEFORE
// waitForConfig(). If the session turns out to be offline/spectator,
// revertHijackIntroState() restores the original bytes in applyPostLoadHacks.
const hijack_intro_state_addr: u32 = 0x45C1F2;

var original_intro_state_bytes: [7]u8 = undefined;
var intro_state_saved: bool = false;

pub fn applyHijackIntroState() void {
    if (state.log == null) return;
    // Save original bytes before NOPing (for potential revert in post-load)
    if (!intro_state_saved) {
        const ptr: [*]u8 = @ptrFromInt(hijack_intro_state_addr);
        @memcpy(&original_intro_state_bytes, ptr[0..7]);
        intro_state_saved = true;
    }
    const nops = [_]u8{0x90} ** 7;
    writeBytes(hijack_intro_state_addr, &nops);
    state.log.?.info("hijackIntroState applied (NOP 7 bytes @0x{x:0>8}) — intro_state progression disabled", .{hijack_intro_state_addr});
}

/// Restore the original 7 bytes at hijack_intro_state_addr. Used to revert
/// the hack in applyPostLoadHacks when the session is offline or spectator.
/// No-op if applyHijackIntroState was never called.
pub fn revertHijackIntroState() void {
    if (state.log == null) return;
    if (!intro_state_saved) return;
    writeBytes(hijack_intro_state_addr, &original_intro_state_bytes);
    state.log.?.info("hijackIntroState reverted — original 7 bytes restored @0x{x:0>8}", .{hijack_intro_state_addr});
}

// ============================================================================
// FPS limiter hacks (ported from CCCaster's DllAsmHacks.hpp:227-231).
//
// MBAACC has a built-in FPS limiter that uses QueryPerformanceFrequency
// (stored at CC_PERF_FREQ_ADDR = 0x774A80). The game divides this frequency
// by a target value to calculate how long to wait between frames.
//
// On high-refresh-rate monitors (144Hz, 180Hz, 240Hz), the game's vsync or
// limiter can run faster than 60fps, causing world_timer to increment faster
// than 60fps. This breaks netplay — one peer advances frames faster, causing
// constant lockstep waits, stutter, and desyncs.
//
// CCCaster disables the game's limiter by writing 1 to CC_PERF_FREQ_ADDR
// (making the game think the performance frequency is 1, so its wait
// calculation produces ~0ms wait), then applies its OWN frame limiter using
// QueryPerformanceCounter to enforce exactly 60fps.
//
// We do the same: disable the game's limiter, then enforce 60fps in
// frameStep using QueryPerformanceCounter.
// ============================================================================

const perf_freq_addr: *u64 = @ptrFromInt(0x774A80);
const fps_counter_nop_addr: u32 = 0x41FD43;

pub fn applyDisableFpsLimit() void {
    if (state.log == null) return;

    // Disable the game's FPS limiter by setting CC_PERF_FREQ_ADDR to 1.
    // The game uses QueryPerformanceFrequency / target_fps to calculate
    // frame wait. Setting it to 1 makes the wait ~0ms, effectively
    // disabling the game's limiter. We enforce 60fps ourselves in frameStep.
    perf_freq_addr.* = 1;

    // Disable the FPS counter display update code (NOP 3 bytes at 0x41FD43).
    // The game updates CC_FPS_COUNTER_ADDR (0x774A70) based on its own
    // (now broken) timing. NOP'ing this prevents a wrong FPS display.
    const nops = [_]u8{ 0x90, 0x90, 0x90 };
    writeBytes(fps_counter_nop_addr, &nops);

    state.log.?.info("disableFpsLimit applied — game FPS limiter disabled, zzcaster will enforce 60fps", .{});
}

pub fn applyHookMainLoop() void {
    const callback_addr: u32 = @intCast(@intFromPtr(&state.zzcasterFrameCallback));

    // Patch 1: call zzcasterFrameCallback, then jmp to patch 2.
    var p1: [10]u8 = undefined;
    p1[0] = 0xE8;
    std.mem.writeInt(u32, p1[1..5], rel32(callback_addr, hook_call1_addr + 0, 5), .little);
    p1[5] = 0xE9;
    // The E9 sits at hook_call1_addr + 5. next_ip = hook_call1_addr + 10.
    std.mem.writeInt(u32, p1[6..10], rel32(hook_call2_addr, hook_call1_addr + 5, 5), .little);
    writeBytes(hook_call1_addr, &p1);

    // Patch 2: push args then jmp loop_start+6 (past the patch 3 site;
    // landing on loop_start itself would loop through patch 3 and overflow).
    var p2: [11]u8 = .{ 0x6A, 0x01, 0x6A, 0x00, 0x6A, 0x00, 0xE9, 0, 0, 0, 0 };

    std.mem.writeInt(u32, p2[7..11], rel32(loop_start_addr + 6, hook_call2_addr + 6, 5), .little);
    writeBytes(hook_call2_addr, &p2);
    state.log.?.info("hookCall2 bytes: {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
        p2[0], p2[1], p2[2], p2[3], p2[4], p2[5], p2[6], p2[7], p2[8], p2[9], p2[10],
    });
    // Patch 3: jmp back to patch 1.
    var p3: [6]u8 = .{ 0xE9, 0, 0, 0, 0, 0x90 };

    std.mem.writeInt(u32, p3[1..5], rel32(hook_call1_addr, loop_start_addr + 0, 5), .little);
    writeBytes(loop_start_addr, &p3);

    state.log.?.info("hookMainLoop applied (callback=0x{x:0>8})", .{callback_addr});
}

pub fn applyHijackControls() void {
    const nops = [_]struct { addr: u32, len: u32 }{
        .{ .addr = 0x41F098, .len = 2 }, .{ .addr = 0x41F0A0, .len = 3 },
        .{ .addr = 0x4A024E, .len = 2 }, .{ .addr = 0x4A027F, .len = 3 },
        .{ .addr = 0x4A0291, .len = 3 }, .{ .addr = 0x4A02A2, .len = 3 },
        .{ .addr = 0x4A02B4, .len = 3 }, .{ .addr = 0x4A02E9, .len = 2 },
        .{ .addr = 0x4A02F2, .len = 3 },
    };
    for (nops) |n| {
        var buf: [3]u8 = .{ 0x90, 0x90, 0x90 };
        writeBytes(n.addr, buf[0..n.len]);
    }
    var zeros: [20]u8 = [_]u8{0} ** 20;
    writeBytes(0x54D2C0, &zeros);
}

// detectRoundStart — three patches that increment round_start_counter each
// time a round begins (when players can move). Ported from legacy
// DllAsmHacks.hpp:322-340. The patches redirect the game's round-start
// code path through a small code cave at 0x441002 that bumps the counter,
// letting NetplayManager detect round transitions via a change-monitor
// (legacy DllMain.cpp:1266-1270, Variable::RoundStart).
//
// Patch order matters: the entry redirect at 0x440CC5 is written LAST so the
// patched code at 0x440D16 and its code cave at 0x441002 are in place before
// execution can reach them (legacy comment: "Write this last due to
// dependencies").
pub fn applyDetectRoundStart() void {
    const counter_addr: u32 = @intCast(@intFromPtr(&round_start_counter));

    // Patch 1 @ 0x440D16 (10 bytes): load the counter's address into ecx and
    // jump to the code cave. Layout:
    //   B9 <imm32>   ; mov ecx, &round_start_counter   (5 bytes)
    //   E9 <rel32>   ; jmp 0x441002                     (5 bytes)
    // B9 = mov ecx, imm32 (loads the ADDRESS, not the value — the legacy
    // comment "mov ecx,[&counter]" is misleading).
    var p1: [10]u8 = undefined;
    p1[0] = 0xB9; // mov ecx, imm32
    std.mem.writeInt(u32, p1[1..5], counter_addr, .little);
    p1[5] = 0xE9; // jmp rel32 -> 0x441002
    std.mem.writeInt(u32, p1[6..10], rel32(0x441002, 0x440D16 + 5, 5), .little);
    writeBytes(0x440D16, &p1);

    // Patch 2 @ 0x441002 (8 bytes): code cave. Read/increment/store the
    // counter, then pop esi/ecx (restoring registers saved by the containing
    // function's prologue) and ret — this short-circuits the rest of the
    // function that 0x440CC5 lives in, returning early to its caller.
    //   8B 31    ; mov esi, [ecx]   (2 bytes)
    //   46       ; inc esi          (1 byte)
    //   89 31    ; mov [ecx], esi   (2 bytes)
    //   5E       ; pop esi          (1 byte)
    //   59       ; pop ecx          (1 byte)
    //   C3       ; ret              (1 byte)
    // Total = 8 bytes.
    const p2: [8]u8 = .{
        0x8B, 0x31, // mov esi, [ecx]
        0x46, // inc esi
        0x89, 0x31, // mov [ecx], esi
        0x5E, // pop esi
        0x59, // pop ecx
        0xC3, // ret
    };
    writeBytes(0x441002, &p2);

    // Patch 3 @ 0x440CC5 (2 bytes): entry redirect. A short jmp to patch 1.
    // EB 4F = jmp rel8 to 0x440CC5 + 2 + 0x4F = 0x440D16.
    const p3: [2]u8 = .{ 0xEB, 0x4F };
    writeBytes(0x440CC5, &p3);

    state.log.?.info("detectRoundStart applied (round_start_counter @0x{x:0>8})", .{counter_addr});
}

// SFX dedup hooks. filterRepeatedSfx suppresses repeated/muted playbacks;
// muteSpecificSfx overrides volume when a mute flag is set. Together they let
// us cancel a stale queued SFX by setting sfxMuteArray[i]=1 (plays muted).
pub fn applySfxAsmHacks() void {
    if (state.log == null) return;
    const filter_arr = @intFromPtr(&sfx_dedup.sfx_filter_array);
    const mute_arr = @intFromPtr(&sfx_dedup.sfx_mute_array);
    const sfx_len = sfx_dedup.sfx_array_len;
    const muted_vol = sfx_dedup.dx_muted_volume;

    // --- filterRepeatedSfx (7 patches, applied in order) ---
    var p0: [7]u8 = undefined;
    p0[0] = 0xB8; // mov eax, imm32
    std.mem.writeInt(u32, p0[1..5], @intCast(mute_arr), .little);
    p0[5] = 0xEB; // jmp rel8
    p0[6] = 0x79;
    writeBytes(0x4DD836, &p0);

    var p1: [9]u8 = .{ 0x80, 0x3C, 0x30, 0x00, 0xE9, 0, 0, 0, 0 };
    std.mem.writeInt(u32, p1[5..9], 0x4DDB73 -% 0x4DD8BF, .little);
    writeBytes(0x4DD8B6, &p1);

    var p2: [12]u8 = .{0} ** 12;
    p2[0] = 0x0F;
    p2[1] = 0x84; // je rel32
    std.mem.writeInt(u32, p2[2..6], 0x4DDEB3 -% 0x4DDB79, .little);
    p2[6] = 0x58; // pop eax
    p2[7] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p2[8..12], 0x4DDFA4 -% 0x4DDB7F, .little);
    writeBytes(0x4DDB73, &p2);

    var p3: [11]u8 = undefined;
    p3[0] = 0xB8; // mov eax, imm32
    std.mem.writeInt(u32, p3[1..5], @intCast(filter_arr), .little);
    p3[5] = 0x80;
    p3[6] = 0x04;
    p3[7] = 0x30;
    p3[8] = 0x01; // add byte ptr [eax+esi], 1
    p3[9] = 0xEB; // jmp rel8
    p3[10] = 0x74;
    writeBytes(0x4DDEB3, &p3);

    var p4: [13]u8 = .{0} ** 13;
    p4[0] = 0x80;
    p4[1] = 0x3C;
    p4[2] = 0x30;
    p4[3] = 0x01; // cmp byte ptr [eax+esi], 1
    p4[4] = 0x58; // pop eax
    p4[5] = 0x0F;
    p4[6] = 0x87; // ja rel32
    std.mem.writeInt(u32, p4[7..11], 0x4DE223 -% 0x4DDF3D, .little);
    p4[11] = 0xEB; // jmp rel8
    p4[12] = 0x65;
    writeBytes(0x4DDF32, &p4);

    var p5: [12]u8 = undefined;
    p5[0] = 0x8B;
    p5[1] = 0x3C;
    p5[2] = 0xB5; // mov edi, [esi*4 + imm32]
    std.mem.writeInt(u32, p5[3..7], 0x76C6F8, .little);
    p5[7] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p5[8..12], 0x4DE217 -% 0x4DDFB0, .little);
    writeBytes(0x4DDFA4, &p5);

    var p6: [6]u8 = .{0} ** 6;
    p6[0] = 0x50; // push eax
    p6[1] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p6[2..6], @as(u32, 0x4DD836) -% (@as(u32, 0x4DE210) + 6), .little);
    writeBytes(0x4DE210, &p6);

    var m0: [14]u8 = undefined;
    m0[0] = 0x8B;
    m0[1] = 0x14;
    m0[2] = 0x24; // mov edx, [esp]
    m0[3] = 0x81;
    m0[4] = 0xFA; // cmp edx, imm32
    std.mem.writeInt(u32, m0[5..9], @intCast(sfx_len), .little);
    m0[9] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m0[10..14], @as(u32, 0x40F1D1) -% (@as(u32, 0x40EEA1) + 14), .little);
    writeBytes(0x40EEA1, &m0);

    var m1: [11]u8 = .{0} ** 11;
    m1[0] = 0x0F;
    m1[1] = 0x8D; // jnl rel32
    std.mem.writeInt(u32, m1[2..6], @as(u32, 0x40F398) -% (@as(u32, 0x40F1D1) + 6), .little);
    m1[6] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m1[7..11], @as(u32, 0x40F392) -% (@as(u32, 0x40F1D1) + 11), .little);
    writeBytes(0x40F1D1, &m1);

    var m2: [13]u8 = .{0} ** 13;
    m2[0] = 0x0F;
    m2[1] = 0x85; // jne rel32
    std.mem.writeInt(u32, m2[2..6], @as(u32, 0x40F462) -% (@as(u32, 0x40F392) + 6), .little);
    m2[6] = 0x8B;
    m2[7] = 0x50;
    m2[8] = 0x3C; // mov edx, [eax+3C]
    m2[9] = 0x51; // push ecx
    m2[10] = 0x56; // push esi
    m2[11] = 0xEB; // jmp rel8
    m2[12] = 0x3B; // legacy value — jumps to 0x40F3DA (past the 0x40F3D5 patch)
    writeBytes(0x40F392, &m2);

    var m3: [11]u8 = undefined;
    m3[0] = 0x8D;
    m3[1] = 0x92; // lea edx, [edx + imm32]
    std.mem.writeInt(u32, m3[2..6], @intCast(mute_arr), .little);
    m3[6] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m3[7..11], @as(u32, 0x40FAE5) -% (@as(u32, 0x40F462) + 11), .little);
    writeBytes(0x40F462, &m3);

    var m4: [8]u8 = .{0} ** 8;
    m4[0] = 0x80;
    m4[1] = 0x3A;
    m4[2] = 0x00; // cmp byte ptr [edx], 0
    m4[3] = 0xC6;
    m4[4] = 0x02;
    m4[5] = 0x00; // mov byte ptr [edx], 0
    m4[6] = 0xEB;
    m4[7] = 0x14; // jmp rel8
    writeBytes(0x40FAE5, &m4);

    var m5: [12]u8 = .{0} ** 12;
    m5[0] = 0x74;
    m5[1] = 0x05; // je +5 (DONE_MUTE, just past the mov ecx)
    m5[2] = 0xB9; // mov ecx, imm32
    std.mem.writeInt(u32, m5[3..7], muted_vol, .little);
    m5[7] = 0xE9; // jmp rel32 to AFTER label (0x40F398)
    std.mem.writeInt(u32, m5[8..12], @as(u32, 0x40F398) -% (@as(u32, 0x40FB01) + 12), .little);
    writeBytes(0x40FB01, &m5);

    var m6: [5]u8 = undefined;
    m6[0] = 0xE9;
    std.mem.writeInt(u32, m6[1..5], @as(u32, 0x40EEA1) -% (@as(u32, 0x40F3D5) + 5), .little);
    writeBytes(0x40F3D5, &m6);

    state.log.?.info("SFX dedup ASM hooks applied (filter_array=0x{x:0>8} mute_array=0x{x:0>8})", .{
        filter_arr, mute_arr,
    });
}

pub fn writeBytes(addr: u32, data: []const u8) void {
    const ptr: [*]u8 = @ptrFromInt(addr);
    var old: u32 = 0;
    const k32 = struct {
        extern "kernel32" fn VirtualProtect(lpAddress: ?*anyopaque, dwSize: usize, flNewProtect: u32, lpflOldProtect: *u32) callconv(.winapi) i32;
        extern "kernel32" fn FlushInstructionCache(hProcess: ?*anyopaque, lpBaseAddress: ?*const anyopaque, dwSize: usize) callconv(.winapi) i32;
    };
    _ = k32.VirtualProtect(ptr, data.len, 0x40, &old);
    @memcpy(ptr[0..data.len], data);
    _ = k32.VirtualProtect(ptr, data.len, old, &old);
    _ = k32.FlushInstructionCache(null, ptr, data.len);
}

// rel32(target, source, instr_len) returns the rel32 displacement for a
// `jmp`/`call` instruction at `source` whose next_ip (source + instr_len)
// should land on `target`. Result is bitcast to u32 for use with writeInt.
// Handles wraparound for backward jumps.
pub fn rel32(target: u32, source: u32, instr_len: u32) u32 {
    const t: i64 = @intCast(target);
    const s: i64 = @intCast(source);
    const l: i64 = @intCast(instr_len);
    return @bitCast(@as(i32, @intCast(t - (s + l))));
}
