// asm_hacks.zig — ASM-level patches installed into the running MBAA.exe
// process.
//
// Functions:
//   - applyPreLoadHacks:  top-level installer; wires the main loop, disables
//                         the game's input poller, and installs the SFX dedup
//                         hooks. Called from lazyInit on the worker thread
//                         before the game's main loop starts calling us.
//   - applyHookMainLoop:  patches the game's main loop so each iteration
//                         calls zzcasterFrameCallback (which routes to
//                         dllmain.frameStep).
//   - applyHijackControls: NOPs out the game's own input-polling code so our
//                         writeInput calls are the only source of input.
//   - applySfxAsmHacks:   installs the SFX filter/mute hooks used by rollback
//                         re-runs (prevents stale queued sounds replaying).
//   - writeBytes:         VirtualProtect-protected memcpy into game memory.
//   - rel32:              computes the rel32 displacement for jmp/call
//                         instructions (handles wraparound for back-branches).
//
// Extracted from dllmain.zig (task 2b) to keep the DLL entry-point file
// focused on init / frame-loop control. The shared `log` logger and the
// `zzcasterFrameCallback` trampoline live in dllmain.zig and are reached via
// `@import("dllmain.zig")` — Zig resolves circular imports at compile time,
// so the back-reference is safe.
const std = @import("std");
const sfx_dedup = @import("sfx_dedup.zig");
const dm = @import("dllmain.zig");

// ASM patch addresses — used only by the installers in this file.
const loop_start_addr: u32 = 0x40D330;
const hook_call1_addr: u32 = 0x40D032;
const hook_call2_addr: u32 = 0x40D411;
const multiple_melty_addr: *u8 = @ptrFromInt(0x40D25A);

pub fn applyPreLoadHacks() void {
    if (dm.log == null) return;
    dm.log.?.info("Applying pre-load ASM hacks...", .{});
    applyHookMainLoop();
    var multi_melty: [1]u8 = .{0xEB};
    writeBytes(@intFromPtr(multiple_melty_addr), &multi_melty);
    applyHijackControls();
    // Apply SFX dedup ASM hooks (filter repeated SFX + cancel muted SFX).
    // These wire the game's SFX play path into our sfx_filter_array /
    // sfx_mute_array so that rollback re-runs don't replay stale sounds.
    applySfxAsmHacks();
    dm.log.?.info("Pre-load hacks applied", .{});
}

pub fn applyHookMainLoop() void {
    const callback_addr: u32 = @intCast(@intFromPtr(&dm.zzcasterFrameCallback));

    // Patch 1 (at hook_call1_addr):
    //   E8 <rel32>   call zzcasterFrameCallback  (5 bytes)
    //   E9 <rel32>   jmp hook_call2_addr         (5 bytes)
    var p1: [10]u8 = undefined;
    p1[0] = 0xE8;
    std.mem.writeInt(u32, p1[1..5], rel32(callback_addr, hook_call1_addr + 0, 5), .little);
    p1[5] = 0xE9;
    // The E9 sits at hook_call1_addr + 5. next_ip = hook_call1_addr + 10.
    std.mem.writeInt(u32, p1[6..10], rel32(hook_call2_addr, hook_call1_addr + 5, 5), .little);
    writeBytes(hook_call1_addr, &p1);

    // Patch 2 (at hook_call2_addr):
    //   6A 01        push 1
    //   6A 00        push 0
    //   6A 00        push 0
    //   E9 <rel32>   jmp loop_start_addr + 6     (past the patch at loop_start)
    // Total: 2 + 2 + 2 + 5 = 11 bytes.
    //
    // Why +6? The legacy comment says "jmp LOOP_START+6 (AFTER)". The flow
    // is: HOOK_CALL1 calls our callback → jmps to HOOK_CALL2 → pushes args
    // → jmps to loop_start+6 (the original loop body, AFTER our 6-byte
    // hook patch). The original loop body eventually loops back and calls
    // HOOK_CALL1 again. Jumping to loop_start itself would infinite-loop
    // through our own 5-byte jmp and overflow the stack from the 3 pushes.
    var p2: [11]u8 = .{ 0x6A, 0x01, 0x6A, 0x00, 0x6A, 0x00, 0xE9, 0, 0, 0, 0 };
    // The E9 sits at hook_call2_addr + 6. next_ip = hook_call2_addr + 11.
    std.mem.writeInt(u32, p2[7..11], rel32(loop_start_addr + 6, hook_call2_addr + 6, 5), .little);
    writeBytes(hook_call2_addr, &p2);
    dm.log.?.info("hookCall2 bytes: {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
        p2[0], p2[1], p2[2], p2[3], p2[4], p2[5], p2[6], p2[7], p2[8], p2[9], p2[10],
    });

    // Patch 3 (at loop_start_addr):
    //   E9 <rel32>   jmp hook_call1_addr         (5 bytes)
    //   90           nop                          (1 byte)
    var p3: [6]u8 = .{ 0xE9, 0, 0, 0, 0, 0x90 };
    // The E9 sits at loop_start_addr + 0. next_ip = loop_start_addr + 5.
    std.mem.writeInt(u32, p3[1..5], rel32(hook_call1_addr, loop_start_addr + 0, 5), .little);
    writeBytes(loop_start_addr, &p3);

    dm.log.?.info("hookMainLoop applied (callback=0x{x:0>8})", .{callback_addr});
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

// SFX dedup ASM hooks. Ported from legacy_unused/targets/DllAsmHacks.cpp:
//   filterRepeatedSfx — intercepts the SFX play loop, checks sfxMuteArray
//     and sfxFilterArray to suppress repeated/muted playbacks.
//   muteSpecificSfx — when the game does play an SFX marked as mute=1,
//     override the volume with DX_MUTED_VOLUME (effectively silent) and
//     clear the mute flag so subsequent plays are normal.
//
// The two patches together let us "cancel" a stale queued SFX by writing
// 1 to CC_SFX_ARRAY[i] AND 1 to sfxMuteArray[i] — the play hook fires but
// produces no audio, dequeuing the sound without artifact.
pub fn applySfxAsmHacks() void {
    if (dm.log == null) return;
    const filter_arr = @intFromPtr(&sfx_dedup.sfx_filter_array);
    const mute_arr = @intFromPtr(&sfx_dedup.sfx_mute_array);
    const sfx_len = sfx_dedup.sfx_array_len;
    const muted_vol = sfx_dedup.dx_muted_volume;

    // --- filterRepeatedSfx (5 patches, must be applied in order) ---
    // Patch site 0x4DD836: mov eax, sfxMuteArray ; jmp 0x4DD8B6
    // Length = 7 bytes (B8 + DWORD + EB 79). next_ip = 0x4DD83D;
    // target 0x4DD8B6 → rel8 = 0x4DD8B6 - 0x4DD83D = 0x79.
    var p0: [7]u8 = undefined;
    p0[0] = 0xB8; // mov eax, imm32
    std.mem.writeInt(u32, p0[1..5], @intCast(mute_arr), .little);
    p0[5] = 0xEB; // jmp rel8
    p0[6] = 0x79;
    writeBytes(0x4DD836, &p0);

    // 0x4DD8B6: cmp byte ptr [eax+esi], 0 ; jmp 0x4DDB73
    // Length = 9 bytes (4 cmp + 5 jmp). next_ip = 0x4DD8BF;
    // rel32 = 0x4DDB73 - 0x4DD8BF = 0x2B4.
    var p1: [9]u8 = .{ 0x80, 0x3C, 0x30, 0x00, 0xE9, 0, 0, 0, 0 };
    std.mem.writeInt(u32, p1[5..9], 0x4DDB73 -% 0x4DD8BF, .little);
    writeBytes(0x4DD8B6, &p1);

    // 0x4DDB73: je 0x4DDEB3 ; pop eax ; jmp 0x4DDFA4
    // Length = 12 bytes (6 je + 1 pop + 5 jmp).
    // je:  next_ip = 0x4DDB79; rel32 = 0x4DDEB3 - 0x4DDB79 = 0x33A.
    // jmp: next_ip = 0x4DDB7F; rel32 = 0x4DDFA4 - 0x4DDB7F = 0x425.
    var p2: [12]u8 = .{0} ** 12;
    p2[0] = 0x0F; p2[1] = 0x84; // je rel32
    std.mem.writeInt(u32, p2[2..6], 0x4DDEB3 -% 0x4DDB79, .little);
    p2[6] = 0x58; // pop eax
    p2[7] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p2[8..12], 0x4DDFA4 -% 0x4DDB7F, .little);
    writeBytes(0x4DDB73, &p2);

    // 0x4DDEB3: mov eax, sfxFilterArray ; add byte ptr [eax+esi], 1 ; jmp 0x4DDF32
    // Length = 11 bytes (5 mov + 4 add + 2 jmp).
    // jmp: next_ip = 0x4DDEBE; rel8 = 0x4DDF32 - 0x4DDEBE = 0x74.
    var p3: [11]u8 = undefined;
    p3[0] = 0xB8; // mov eax, imm32
    std.mem.writeInt(u32, p3[1..5], @intCast(filter_arr), .little);
    p3[5] = 0x80; p3[6] = 0x04; p3[7] = 0x30; p3[8] = 0x01; // add byte ptr [eax+esi], 1
    p3[9] = 0xEB; // jmp rel8
    p3[10] = 0x74;
    writeBytes(0x4DDEB3, &p3);

    // 0x4DDF32: cmp byte ptr [eax+esi], 1 ; pop eax ; ja 0x4DE223 ; jmp 0x4DDFA4
    // Length = 13 bytes (4 cmp + 1 pop + 6 ja + 2 jmp).
    // ja:  next_ip = 0x4DDF3D; rel32 = 0x4DE223 - 0x4DDF3D = 0x2E6.
    // jmp: next_ip = 0x4DDF3F; rel8 = 0x4DDFA4 - 0x4DDF3F = 0x65.
    var p4: [13]u8 = .{0} ** 13;
    p4[0] = 0x80; p4[1] = 0x3C; p4[2] = 0x30; p4[3] = 0x01; // cmp byte ptr [eax+esi], 1
    p4[4] = 0x58; // pop eax
    p4[5] = 0x0F; p4[6] = 0x87; // ja rel32
    std.mem.writeInt(u32, p4[7..11], 0x4DE223 -% 0x4DDF3D, .little);
    p4[11] = 0xEB; // jmp rel8
    p4[12] = 0x65;
    writeBytes(0x4DDF32, &p4);

    // 0x4DDFA4: mov edi, [esi*4 + 0x76C6F8] ; jmp 0x4DE217 (PLAY_SFX)
    // Length = 12 bytes (7 mov + 5 jmp).
    // jmp: next_ip = 0x4DDFB0; rel32 = 0x4DE217 - 0x4DDFB0 = 0x267.
    var p5: [12]u8 = undefined;
    p5[0] = 0x8B; p5[1] = 0x3C; p5[2] = 0xB5; // mov edi, [esi*4 + imm32]
    std.mem.writeInt(u32, p5[3..7], 0x76C6F8, .little);
    p5[7] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p5[8..12], 0x4DE217 -% 0x4DDFB0, .little);
    writeBytes(0x4DDFA4, &p5);

    // 0x4DE210: push eax ; jmp 0x4DD836 (last — has dependencies)
    // Length = 6 bytes (1 push + 5 jmp). The 7th byte (nop) is left untouched.
    // jmp: next_ip = 0x4DE216; rel32 = 0x4DD836 - 0x4DE216 = -0x9E0 = 0xFFFFF620.
    var p6: [6]u8 = .{0} ** 6;
    p6[0] = 0x50; // push eax
    p6[1] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, p6[2..6], @as(u32, 0x4DD836) -% (@as(u32, 0x4DE210) + 6), .little);
    writeBytes(0x4DE210, &p6);

    // --- muteSpecificSfx (6 patches) ---
    // 0x40EEA1: mov edx, [esp] ; cmp edx, SFX_LEN ; jmp 0x40F1D1
    // Length = 14 bytes (3 mov + 6 cmp + 5 jmp).
    // jmp: next_ip = 0x40EEAF; rel32 = 0x40F1D1 - 0x40EEAF = 0x322.
    var m0: [14]u8 = undefined;
    m0[0] = 0x8B; m0[1] = 0x14; m0[2] = 0x24; // mov edx, [esp]
    m0[3] = 0x81; m0[4] = 0xFA; // cmp edx, imm32
    std.mem.writeInt(u32, m0[5..9], @intCast(sfx_len), .little);
    m0[9] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m0[10..14], @as(u32, 0x40F1D1) -% (@as(u32, 0x40EEA1) + 14), .little);
    writeBytes(0x40EEA1, &m0);

    // 0x40F1D1: jnl 0x40F398 (AFTER) ; jmp 0x40F392
    // Length = 11 bytes (6 jnl + 5 jmp).
    // jnl: next_ip = 0x40F1D7; rel32 = 0x40F398 - 0x40F1D7 = 0x1C1.
    // jmp: next_ip = 0x40F1DC; rel32 = 0x40F392 - 0x40F1DC = 0x1B6.
    var m1: [11]u8 = .{0} ** 11;
    m1[0] = 0x0F; m1[1] = 0x8D; // jnl rel32
    std.mem.writeInt(u32, m1[2..6], @as(u32, 0x40F398) -% (@as(u32, 0x40F1D1) + 6), .little);
    m1[6] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m1[7..11], @as(u32, 0x40F392) -% (@as(u32, 0x40F1D1) + 11), .little);
    writeBytes(0x40F1D1, &m1);

    // 0x40F392: jne 0x40F462 ; (AFTER:) mov edx, [eax+3C] ; push ecx ; push esi ; jmp 0x40F3D5
    // Length = 13 bytes (6 jne + 3 mov + 1 push + 1 push + 2 jmp).
    // jne: next_ip = 0x40F398; rel32 = 0x40F462 - 0x40F398 = 0xCA.
    // jmp: next_ip = 0x40F39F; rel8 = 0x40F3D5 - 0x40F39F = -0xCA → 0x36 (sign-extended).
    //   Wait: 0x40F3D5 - 0x40F39F = -0x6A = 0xFF96, so as rel8 = 0x96. But legacy uses 0x3B.
    //   Let me recompute: legacy patch is 13 bytes. next_ip after EB = 0x40F392 + 13 = 0x40F39F.
    //   0x40F3D5 - 0x40F39F = -0x6A → as u8 = 0x96. Hmm, legacy uses 0x3B which means
    //   target = 0x40F39F + 0x3B = 0x40F3DA. That's 0x40F3D5 + 5, the instruction after
    //   the jmp at 0x40F3D5. So 0x3B is actually a jmp PAST the 0x40F3D5 patch (which is
    //   5 bytes, E9 + rel32). So target = 0x40F3D5 + 5 = 0x40F3DA. Yes, that's correct.
    var m2: [13]u8 = .{0} ** 13;
    m2[0] = 0x0F; m2[1] = 0x85; // jne rel32
    std.mem.writeInt(u32, m2[2..6], @as(u32, 0x40F462) -% (@as(u32, 0x40F392) + 6), .little);
    m2[6] = 0x8B; m2[7] = 0x50; m2[8] = 0x3C; // mov edx, [eax+3C]
    m2[9] = 0x51; // push ecx
    m2[10] = 0x56; // push esi
    m2[11] = 0xEB; // jmp rel8
    m2[12] = 0x3B; // legacy value — jumps to 0x40F3DA (past the 0x40F3D5 patch)
    writeBytes(0x40F392, &m2);

    // 0x40F462: lea edx, [edx + sfxMuteArray] ; jmp 0x40FAE5
    // Length = 11 bytes (6 lea + 5 jmp).
    // jmp: next_ip = 0x40F46D; rel32 = 0x40FAE5 - 0x40F46D = 0x678.
    var m3: [11]u8 = undefined;
    m3[0] = 0x8D; m3[1] = 0x92; // lea edx, [edx + imm32]
    std.mem.writeInt(u32, m3[2..6], @intCast(mute_arr), .little);
    m3[6] = 0xE9; // jmp rel32
    std.mem.writeInt(u32, m3[7..11], @as(u32, 0x40FAE5) -% (@as(u32, 0x40F462) + 11), .little);
    writeBytes(0x40F462, &m3);

    // 0x40FAE5: cmp byte ptr [edx], 0 ; mov byte ptr [edx], 0 ; jmp 0x40FB01
    // Length = 8 bytes (3 cmp + 3 mov + 2 jmp).
    // jmp: next_ip = 0x40FAED; rel8 = 0x40FB01 - 0x40FAED = 0x14.
    var m4: [8]u8 = .{0} ** 8;
    m4[0] = 0x80; m4[1] = 0x3A; m4[2] = 0x00; // cmp byte ptr [edx], 0
    m4[3] = 0xC6; m4[4] = 0x02; m4[5] = 0x00; // mov byte ptr [edx], 0
    m4[6] = 0xEB; m4[7] = 0x14; // jmp rel8
    writeBytes(0x40FAE5, &m4);

    // 0x40FB01: je 0x40FB03 (DONE_MUTE) ; mov ecx, DX_MUTED_VOLUME ; (DONE_MUTE:) jmp 0x40F398 (AFTER)
    // Length = 12 bytes (2 je + 5 mov + 5 jmp).
    // je:  next_ip = 0x40FB03; rel8 = 0x40FB03 - 0x40FB03 = 0 → skip the mov.
    // jmp: next_ip = 0x40FB0D; rel32 = 0x40F398 - 0x40FB0D = -0x775 = 0xFFFFF88B.
    var m5: [12]u8 = .{0} ** 12;
    m5[0] = 0x74; m5[1] = 0x05; // je +5 (DONE_MUTE, just past the mov ecx)
    m5[2] = 0xB9; // mov ecx, imm32
    std.mem.writeInt(u32, m5[3..7], muted_vol, .little);
    m5[7] = 0xE9; // jmp rel32 (DONE_MUTE label)
    std.mem.writeInt(u32, m5[8..12], @as(u32, 0x40F398) -% (@as(u32, 0x40FB01) + 12), .little);
    writeBytes(0x40FB01, &m5);

    // 0x40F3D5: jmp 0x40EEA1 (last — has dependencies)
    // Length = 5 bytes (E9 + rel32).
    // jmp: next_ip = 0x40F3DA; rel32 = 0x40EEA1 - 0x40F3DA = -0x539 = 0xFFFFFAC7.
    var m6: [5]u8 = undefined;
    m6[0] = 0xE9;
    std.mem.writeInt(u32, m6[1..5], @as(u32, 0x40EEA1) -% (@as(u32, 0x40F3D5) + 5), .little);
    writeBytes(0x40F3D5, &m6);

    dm.log.?.info("SFX dedup ASM hooks applied (filter_array=0x{x:0>8} mute_array=0x{x:0>8})", .{
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
