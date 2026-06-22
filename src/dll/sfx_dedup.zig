const std = @import("std");
const logging = @import("common").logging;

// SfxDedup — sound-effect deduplication during rollback re-runs.

pub const sfx_array_addr: usize = 0x76E008;
pub const sfx_array_len: usize = 1500;
pub const num_rollback_states: usize = 60; // matches StatePool default
pub const dx_muted_volume: u32 = 0xFFFE0000; // -2.0 in fixed-point volume

// Game's SFX trigger array (read each frame; the game writes 1 to byte i to
// trigger playback of sound i).
pub const sfx_array: [*]u8 = @ptrFromInt(sfx_array_addr);

// Public filter/mute arrays — exposed by pointer to the ASM trampolines.
// `export` makes the symbol visible to the C side if needed and ensures
// the array address is stable at link time.
pub export var sfx_filter_array: [sfx_array_len]u8 = [_]u8{0} ** sfx_array_len;
pub export var sfx_mute_array: [sfx_array_len]u8 = [_]u8{0} ** sfx_array_len;

pub const SfxDedup = struct {
    allocator: std.mem.Allocator,
    log: ?*logging.Logger = null,

    // Ring buffer of sfx_filter snapshots, indexed by frame % num_rollback_states.
    // Each entry is a full 1500-byte copy of sfx_filter_array at save time.
    history: [][sfx_array_len]u8,
    history_size: usize = num_rollback_states,

    // True between loadState() and finishedRerun() — gates saveRerunSounds.
    in_rerun: bool = false,

    pub fn init(allocator: std.mem.Allocator) !SfxDedup {
        return SfxDedup{
            .allocator = allocator,
            .history = try allocator.alloc([sfx_array_len]u8, num_rollback_states),
        };
    }

    pub fn deinit(self: *SfxDedup) void {
        self.allocator.free(self.history);
    }

    pub fn setLogger(self: *SfxDedup, l: *logging.Logger) void {
        self.log = l;
    }

    pub fn reset(self: *SfxDedup) void {
        @memset(&sfx_filter_array, 0);
        @memset(&sfx_mute_array, 0);
        for (self.history) |*slot| @memset(slot, 0);
        self.in_rerun = false;
    }

    // ----- per-frame hooks (called by NetplayManager) -----

    /// Called by state_pool.saveState: snapshot the current sfx_filter_array
    /// into the history ring at slot (frame % N).
    pub fn snapshotToHistory(self: *SfxDedup, frame: u32) void {
        const slot = frame % self.history_size;
        @memcpy(&self.history[slot], &sfx_filter_array);
    }

    /// Called by state_pool.loadState: walk the history between the loaded
    /// frame and the current (pre-rollback) frame, OR all snapshots together
    /// into sfx_filter_array, then mark each non-zero entry as 0x80.
    ///
    /// This implements the legacy:
    ///   for (i = target_frame; i <= current_frame; ++i)
    ///     for (j = 0; j < LEN; ++j)
    ///       sfxFilterArray[j] |= sfxHistory[i % N][j];
    ///   for (j = 0; j < LEN; ++j)
    ///     if (sfxFilterArray[j]) sfxFilterArray[j] = 0x80;
    pub fn applyRollbackFilter(self: *SfxDedup, loaded_frame: u32, current_frame: u32) void {
        // OR together all snapshots from loaded_frame..current_frame (inclusive).
        // The legacy code iterates the loaded state's slot forward to the current
        // state's slot. We walk forward (mod N) to include all frames in between.
        var frame: u32 = loaded_frame;
        while (true) {
            const slot = frame % self.history_size;
            for (0..sfx_array_len) |j| {
                sfx_filter_array[j] |= self.history[slot][j];
            }
            if (frame == current_frame) break;
            frame +%= 1;
        }

        // Mark each non-zero entry with the 0x80 sentinel.
        for (0..sfx_array_len) |j| {
            if (sfx_filter_array[j] != 0) sfx_filter_array[j] = 0x80;
        }

        self.in_rerun = true;
        if (self.log) |l| l.info("SfxDedup: rollback filter applied [{d} -> {d}]", .{ loaded_frame, current_frame });
    }

    /// Called during re-run, each frame: rewrite the SFX history slot for
    /// this frame with which sounds actually got played.
    /// The legacy code uses `sfxFilterArray[j] & ~0x80` to detect "was
    /// incremented past 0x80 by the play hook" — i.e. the SFX really did
    /// fire this re-run frame.
    pub fn saveRerunSounds(self: *SfxDedup, frame: u32) void {
        if (!self.in_rerun) return;
        const slot = frame % self.history_size;
        for (0..sfx_array_len) |j| {
            if (sfx_filter_array[j] & ~@as(u8, 0x80) != 0) {
                self.history[slot][j] = 1;
            } else {
                self.history[slot][j] = 0;
            }
        }
    }

    /// Called when re-run finishes: for each SFX with filter == 0x80 (was
    /// queued pre-rollback but never re-fired post-rollback), trigger a
    /// muted playback to cancel the stale sound.
    pub fn finishedRerun(self: *SfxDedup) void {
        if (!self.in_rerun) return;
        for (0..sfx_array_len) |j| {
            if (sfx_filter_array[j] == 0x80) {
                // Play the SFX muted to cancel the queued playback.
                sfx_array[j] = 1;
                sfx_mute_array[j] = 1;
            }
        }
        @memset(&sfx_filter_array, 0);
        self.in_rerun = false;
        if (self.log) |l| l.info("SfxDedup: rerun finished — stale SFX muted", .{});
    }

    /// Clear filter+mute at the start of each round / state transition.
    /// (Legacy clears these at the bottom of frameStep when not rolling back.)
    pub fn clearPerFrame(self: *SfxDedup) void {
        _ = self;
        @memset(&sfx_filter_array, 0);
        @memset(&sfx_mute_array, 0);
    }
};
