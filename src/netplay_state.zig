// Port of CCCaster's `NetplayState` enum (netplay/NetplayStates.hpp).
//
// The numeric values matter: CCCaster serializes them and uses ordered
// comparisons like `_state.value < NetplayState::CharaSelect`. We preserve
// the exact numeric ordering from the original `ENUM(...)` macro.
//
// State transition graph (from NetplayStates.hpp):
//   Unknown -> PreInitial -> Initial -> { AutoCharaSelect, CharaSelect, ReplayMenu }
//   { AutoCharaSelect, CharaSelect, ReplayMenu } -> Loading
//   Loading -> { CharaIntro, InGame (training) }
//   CharaIntro -> { InGame (versus) }
//   Skippable -> { InGame (versus), RetryMenu }
//   InGame -> { Skippable, CharaSelect (not on netplay), ReplayMenu }
//   RetryMenu -> { Loading, CharaSelect }

const std = @import("std");

pub const NetplayState = enum(u8) {
    unknown = 0,
    pre_initial = 1,
    initial = 2,
    auto_chara_select = 3,
    chara_select = 4,
    loading = 5,
    chara_intro = 6,
    skippable = 7,
    in_game = 8,
    retry_menu = 9,
    replay_menu = 10,

    pub fn name(self: NetplayState) []const u8 {
        return switch (self) {
            .unknown => "Unknown",
            .pre_initial => "PreInitial",
            .initial => "Initial",
            .auto_chara_select => "AutoCharaSelect",
            .chara_select => "CharaSelect",
            .loading => "Loading",
            .chara_intro => "CharaIntro",
            .skippable => "Skippable",
            .in_game => "InGame",
            .retry_menu => "RetryMenu",
            .replay_menu => "ReplayMenu",
        };
    }

    pub fn format(
        self: NetplayState,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.print("{s}", .{self.name()});
    }

    /// Matches CCCaster's `isValidNext` (DllNetplayManager.cpp:1140-1156).
    /// Returns true if `from -> to` is a legal state transition.
    pub fn isValidNext(from: NetplayState, to: NetplayState) bool {
        const allowed = [_]struct { from: NetplayState, to: []const NetplayState }{
            .{ .from = .unknown, .to = &.{.pre_initial} },
            .{ .from = .pre_initial, .to = &.{.initial} },
            .{ .from = .initial, .to = &.{ .auto_chara_select, .chara_select, .replay_menu } },
            .{ .from = .auto_chara_select, .to = &.{.loading} },
            .{ .from = .chara_select, .to = &.{.loading} },
            .{ .from = .loading, .to = &.{ .skippable, .chara_intro, .in_game } },
            .{ .from = .chara_intro, .to = &.{.in_game} },
            .{ .from = .skippable, .to = &.{ .in_game, .retry_menu } },
            .{ .from = .in_game, .to = &.{ .skippable, .chara_select, .replay_menu, .retry_menu } },
            .{ .from = .retry_menu, .to = &.{ .loading, .chara_select, .replay_menu } },
            .{ .from = .replay_menu, .to = &.{.loading} },
        };
        for (allowed) |a| {
            if (a.from == from) {
                for (a.to) |t| if (t == to) return true;
                return false;
            }
        }
        return false;
    }
};

test "NetplayState numeric values match CCCaster ordering" {
    // The ordering matters because CCCaster uses `_state.value < CharaSelect`.
    try std.testing.expect(@intFromEnum(NetplayState.unknown) < @intFromEnum(NetplayState.chara_select));
    try std.testing.expect(@intFromEnum(NetplayState.pre_initial) < @intFromEnum(NetplayState.chara_select));
    try std.testing.expect(@intFromEnum(NetplayState.loading) < @intFromEnum(NetplayState.in_game));
}

test "isValidNext matches CCCaster transition table" {
    try std.testing.expect(NetplayState.isValidNext(.loading, .in_game));
    try std.testing.expect(NetplayState.isValidNext(.chara_intro, .in_game));
    try std.testing.expect(NetplayState.isValidNext(.in_game, .skippable));
    try std.testing.expect(!NetplayState.isValidNext(.in_game, .initial));
    try std.testing.expect(!NetplayState.isValidNext(.chara_select, .in_game));
}
