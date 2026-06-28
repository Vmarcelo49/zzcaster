const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const rb = @import("rollback.zig");

pub const NetplayState = enum(u8) {
    pre_initial = 0,
    initial = 1,
    chara_select = 2,
    loading = 3,
    chara_intro = 4,
    skippable = 5,
    in_game = 6,
    retry_menu = 7,
};

const CachedRng = struct {
    valid: bool = false,
    index: u32 = 0,
    rng_value: u32 = 0,
};

const SavedState = struct {
    frame: u32 = 0,
    x: u32 = 0,
    rng: u32 = 0,
};

const MockSyncHash = struct {
    indexed_frame: u64 = 0,
    hash: u32 = 0,
    
    pub fn matches(self: MockSyncHash, other: MockSyncHash) bool {
        return self.hash == other.hash;
    }
};

const MockPeer = struct {
    name: []const u8,
    is_host: bool,
    state: NetplayState = .pre_initial,
    frame: u32 = 0,
    index: u32 = 0,
    delay: u8 = 0,
    rollback: u8 = 0,
    is_netplay: bool = true,
    is_spectator: bool = false,
    
    // RNG state
    rng_synced: bool = false,
    rng_synced_index: u32 = 0,
    should_sync_rng: bool = false,
    intro_rng_enabled: bool = false,
    rng_acked: bool = false,
    rng_value: u32 = 12345, // simple RNG representation
    
    // Cached RNG states (ring/simple buffer of 8 elements)
    cached_rng_states: [8]CachedRng = [_]CachedRng{.{}} ** 8,
    
    // Inputs: end frame and index
    remote_end_frame: u32 = 0,
    remote_end_index: u32 = 0,

    // Round start
    last_round_start: u32 = 0,
    round_start_waiting_logged: bool = false,
    round_start_counter: u32 = 0,

    // Rollback StatePool Mock
    saved_states: [60]SavedState = [_]SavedState{.{}} ** 60,
    saved_states_count: usize = 0,
    fast_fwd_stop_frame: u32 = 0,
    last_changed_frame: ?u64 = null,

    // SyncHash queues
    local_sync: [8]MockSyncHash = [_]MockSyncHash{.{}} ** 8,
    local_sync_count: u8 = 0,
    remote_sync: [8]MockSyncHash = [_]MockSyncHash{.{}} ** 8,
    remote_sync_count: u8 = 0,
    desync_detected: bool = false,
    
    pub fn init(name: []const u8, is_host: bool, delay: u8, rollback: u8) MockPeer {
        return .{
            .name = name,
            .is_host = is_host,
            .delay = delay,
            .rollback = rollback,
        };
    }
    
    pub fn isInRollback(self: *const MockPeer) bool {
        if (self.is_spectator) return false;
        return self.state == .in_game and self.rollback > 0 and self.is_netplay;
    }
    
    pub fn isRemoteInputReady(self: *const MockPeer) bool {
        switch (self.state) {
            .pre_initial, .initial, .loading, .skippable, .retry_menu => return true,
            .chara_select, .chara_intro, .in_game => {},
        }

        if (!self.is_netplay or self.is_spectator) return true;

        // Match production: gate only during .chara_intro and .in_game,
        // NOT during .chara_select. See netplay_manager.zig for rationale.
        if (self.state != .chara_select and
            self.should_sync_rng and !self.is_host and !self.rng_synced)
        {
            return false;
        }
        
        if (self.remote_end_index == 0) return false;
        const remote_idx = self.remote_end_index - 1;
        
        if (remote_idx < self.index) return false;
        if (remote_idx > self.index) return true;
        
        const max_frames_ahead = if (self.isInRollback()) self.rollback else 0;
        const needed = self.frame;
        const end_frame = self.remote_end_frame;
        return (end_frame + max_frames_ahead) > needed;
    }
    
    pub fn cacheRngState(self: *MockPeer, idx: u32, value: u32) void {
        // First pass: update existing
        for (&self.cached_rng_states) |*entry| {
            if (entry.valid and entry.index == idx) {
                entry.rng_value = value;
                return;
            }
        }
        // Second pass: first invalid slot
        for (&self.cached_rng_states) |*entry| {
            if (!entry.valid) {
                entry.valid = true;
                entry.index = idx;
                entry.rng_value = value;
                return;
            }
        }
        // Third pass: overwrite oldest/smallest index
        var oldest_idx: usize = 0;
        for (self.cached_rng_states, 0..) |entry, i| {
            if (entry.index < self.cached_rng_states[oldest_idx].index) {
                oldest_idx = i;
            }
        }
        self.cached_rng_states[oldest_idx].index = idx;
        self.cached_rng_states[oldest_idx].rng_value = value;
    }
    
    pub fn getCachedRngState(self: *const MockPeer, idx: u32, out_rng: *u32) bool {
        for (self.cached_rng_states) |entry| {
            if (entry.valid and entry.index == idx) {
                out_rng.* = entry.rng_value;
                return true;
            }
        }
        return false;
    }
    
    pub fn applyRemoteRng(self: *MockPeer, rng_index: u32, rng_val: u32) void {
        if (self.is_spectator) {
            if (rng_index > self.index + 1) return;
        } else {
            if (rng_index != self.index and rng_index != self.index + 1) return;
        }
        
        self.cacheRngState(rng_index, rng_val);
        
        if (rng_index == self.index + 1) {
            // Caching only
            return;
        }
        
        if (self.rng_synced and rng_index == self.rng_synced_index) {
            return;
        }
        
        self.rng_value = rng_val;
        self.rng_synced = true;
        self.rng_synced_index = rng_index;
    }
    
    pub fn onStateTransition(self: *MockPeer, old: NetplayState, new: NetplayState) void {
        _ = old;
        const new_val = @intFromEnum(new);
        const chara_select_val = @intFromEnum(NetplayState.chara_select);

        if (new_val < chara_select_val) return;

        self.index += 1;
        self.frame = 0;

        // Match production: arm RNG sync on .chara_select AND .in_game entry.
        if (new == .in_game or new == .chara_select) {
            self.rng_synced = false;
            self.rng_acked = false;
            self.should_sync_rng = true;
            self.intro_rng_enabled = true;

            if (!self.is_host) {
                var cached_val: u32 = 0;
                if (self.getCachedRngState(self.index, &cached_val)) {
                    self.rng_value = cached_val;
                    self.rng_synced = true;
                    self.rng_synced_index = self.index;
                }
            }
        }

        // Match production: only .loading clears intro_rng_enabled (not .chara_select).
        if (new == .loading) {
            self.intro_rng_enabled = false;
        }
    }

    // Mock StatePool implementation
    pub fn saveState(self: *MockPeer, frame_num: u32, x: u32) void {
        if (self.saved_states_count >= 60) {
            std.mem.copyForwards(SavedState, self.saved_states[0..59], self.saved_states[1..60]);
            self.saved_states[59] = .{ .frame = frame_num, .x = x, .rng = self.rng_value };
        } else {
            self.saved_states[self.saved_states_count] = .{ .frame = frame_num, .x = x, .rng = self.rng_value };
            self.saved_states_count += 1;
        }
    }
    
    pub fn loadStateForFrame(self: *MockPeer, target_frame: u32) ?SavedState {
        var best: ?SavedState = null;
        var i: usize = 0;
        while (i < self.saved_states_count) : (i += 1) {
            const s = self.saved_states[i];
            if (s.frame <= target_frame) {
                if (best == null or s.frame > best.?.frame) {
                    best = s;
                }
            }
        }
        return best;
    }

    pub fn checkRollback(self: *MockPeer) bool {
        if (!self.isInRollback()) return false;
        const lcf = self.last_changed_frame;
        if (lcf == null) return false;
        
        const lcf_frame = @as(u32, @intCast(lcf.? & 0xFFFFFFFF));
        if (lcf_frame >= self.frame) return false;
        
        const loaded = self.loadStateForFrame(lcf_frame);
        if (loaded == null) {
            self.last_changed_frame = null;
            return false;
        }
        
        // Trigger rollback!
        const current_frame = self.frame;
        self.fast_fwd_stop_frame = current_frame;
        self.frame = loaded.?.frame;
        self.rng_value = loaded.?.rng;
        
        self.last_changed_frame = null;
        return true;
    }
    
    pub fn isRerunning(self: *const MockPeer) bool {
        return self.fast_fwd_stop_frame != 0;
    }

    pub fn checkRoundStart(self: *MockPeer) void {
        const current = self.round_start_counter;
        if (current == self.last_round_start) return;

        if (self.state == .skippable or self.state == .chara_intro) {
            if (self.state == .chara_intro) {
                if (self.remote_end_index <= self.index) {
                    if (!self.round_start_waiting_logged) {
                        self.round_start_waiting_logged = true;
                    }
                    return;
                }
            }
            self.round_start_waiting_logged = false;
            const prev = self.last_round_start;
            self.last_round_start = current;
            _ = prev;
            self.state = .in_game;
        } else {
            self.round_start_waiting_logged = false;
            self.last_round_start = current;
        }
    }

    // Mock SyncHash queue implementation
    pub fn pushLocalSync(self: *MockPeer, sh: MockSyncHash) void {
        self.pushSync(&self.local_sync, &self.local_sync_count, sh);
    }
    
    pub fn pushRemoteSync(self: *MockPeer, sh: MockSyncHash) void {
        self.pushSync(&self.remote_sync, &self.remote_sync_count, sh);
    }
    
    fn pushSync(_: *MockPeer, buf: *[8]MockSyncHash, count: *u8, sh: MockSyncHash) void {
        if (count.* >= 8) {
            std.mem.copyForwards(MockSyncHash, buf[0..7], buf[1..8]);
            buf[7] = sh;
        } else {
            buf[count.*] = sh;
            count.* += 1;
        }
    }
    
    pub fn checkSyncHashDesync(self: *MockPeer) void {
        if (self.desync_detected) return;
        if (self.state != .in_game) return;
        if (self.local_sync_count == 0 or self.remote_sync_count == 0) return;
        
        var li: usize = 0;
        var ri: usize = 0;
        while (li < self.local_sync_count and ri < self.remote_sync_count) {
            const l = self.local_sync[li];
            const r = self.remote_sync[ri];
            if (l.indexed_frame > r.indexed_frame) {
                ri += 1;
                continue;
            }
            if (r.indexed_frame > l.indexed_frame) {
                li += 1;
                continue;
            }
            if (!l.matches(r)) {
                self.desync_detected = true;
                return;
            }
            li += 1;
            ri += 1;
        }
        
        if (li > 0) {
            const keep = self.local_sync_count - @as(u8, @intCast(li));
            std.mem.copyForwards(MockSyncHash, self.local_sync[0..keep], self.local_sync[li..self.local_sync_count]);
            self.local_sync_count = keep;
        }
        if (ri > 0) {
            const keep = self.remote_sync_count - @as(u8, @intCast(ri));
            std.mem.copyForwards(MockSyncHash, self.remote_sync[0..keep], self.remote_sync[ri..self.remote_sync_count]);
            self.remote_sync_count = keep;
        }
    }
};

const Packet = union(enum) {
    input: struct { index: u32, frame: u32 },
    rng: struct { index: u32, value: u32 },
    transition: struct { index: u32, state: NetplayState },
    rng_ack: struct { index: u32 },
};

const EnqueuedPacket = struct {
    packet: Packet,
    delivery_frame: u32,
};

const MockNetwork = struct {
    to_host: std.ArrayList(EnqueuedPacket) = .empty,
    to_client: std.ArrayList(EnqueuedPacket) = .empty,
    current_frame: u32 = 0,
    
    // Configurations
    loss_rate: f32 = 0.0,
    dup_rate: f32 = 0.0,
    base_latency: u32 = 0,
    jitter: u32 = 0,
    prng: std.Random.DefaultPrng,
    
    pub fn init(seed: u64) MockNetwork {
        return .{
            .to_host = .empty,
            .to_client = .empty,
            .prng = std.Random.DefaultPrng.init(seed),
        };
    }
    
    pub fn deinit(self: *MockNetwork, allocator: std.mem.Allocator) void {
        self.to_host.deinit(allocator);
        self.to_client.deinit(allocator);
    }
    
    pub fn sendToHost(self: *MockNetwork, allocator: std.mem.Allocator, pkt: Packet) !void {
        // Roll for packet loss
        if (self.prng.random().float(f32) < self.loss_rate) {
            return;
        }
        
        // Calculate delivery frame
        const delay = self.base_latency + if (self.jitter > 0) self.prng.random().uintLessThan(u32, self.jitter + 1) else 0;
        const delivery = self.current_frame + delay;
        
        // Append packet
        try self.to_host.append(allocator, .{ .packet = pkt, .delivery_frame = delivery });
        
        // Roll for duplication
        if (self.prng.random().float(f32) < self.dup_rate) {
            try self.to_host.append(allocator, .{ .packet = pkt, .delivery_frame = delivery });
        }
    }
    
    pub fn sendToClient(self: *MockNetwork, allocator: std.mem.Allocator, pkt: Packet) !void {
        // Roll for packet loss
        if (self.prng.random().float(f32) < self.loss_rate) {
            return;
        }
        
        // Calculate delivery frame
        const delay = self.base_latency + if (self.jitter > 0) self.prng.random().uintLessThan(u32, self.jitter + 1) else 0;
        const delivery = self.current_frame + delay;
        
        // Append packet
        try self.to_client.append(allocator, .{ .packet = pkt, .delivery_frame = delivery });
        
        // Roll for duplication
        if (self.prng.random().float(f32) < self.dup_rate) {
            try self.to_client.append(allocator, .{ .packet = pkt, .delivery_frame = delivery });
        }
    }

    pub fn tick(self: *MockNetwork) void {
        self.current_frame += 1;
    }
    
    pub fn deliverAll(self: *MockNetwork, allocator: std.mem.Allocator, host: *MockPeer, client: *MockPeer) void {
        // Drain to_host
        var new_to_host: std.ArrayList(EnqueuedPacket) = .empty;
        for (self.to_host.items) |ep| {
            if (ep.delivery_frame <= self.current_frame) {
                switch (ep.packet) {
                    .input => |inp| {
                        if (inp.index >= host.remote_end_index) {
                            host.remote_end_index = inp.index + 1;
                        }
                        if (inp.index == host.index) {
                            host.remote_end_frame = inp.frame + 1;
                        }
                    },
                    .rng_ack => |ack| {
                        if (ack.index == host.index) {
                            host.rng_acked = true;
                            host.rng_synced = true;
                            host.rng_synced_index = ack.index;
                        }
                    },
                    .transition => |t| {
                        if (t.index >= host.remote_end_index) {
                            host.remote_end_index = t.index + 1;
                            host.remote_end_frame = 0;
                        }
                    },
                    else => {},
                }
            } else {
                new_to_host.append(allocator, ep) catch {};
            }
        }
        self.to_host.deinit(allocator);
        self.to_host = new_to_host;
        
        // Drain to_client
        var new_to_client: std.ArrayList(EnqueuedPacket) = .empty;
        for (self.to_client.items) |ep| {
            if (ep.delivery_frame <= self.current_frame) {
                switch (ep.packet) {
                    .input => |inp| {
                        if (inp.index >= client.remote_end_index) {
                            client.remote_end_index = inp.index + 1;
                        }
                        if (inp.index == client.index) {
                            client.remote_end_frame = inp.frame + 1;
                        }
                    },
                    .rng => |rng| {
                        client.applyRemoteRng(rng.index, rng.value);
                        if (!client.is_spectator) {
                            self.sendToHost(allocator, .{ .rng_ack = .{ .index = rng.index } }) catch {};
                        }
                    },
                    .transition => |t| {
                        if (t.index >= client.remote_end_index) {
                            client.remote_end_index = t.index + 1;
                            client.remote_end_frame = 0;
                        }
                    },
                    else => {},
                }
            } else {
                new_to_client.append(allocator, ep) catch {};
            }
        }
        self.to_client.deinit(allocator);
        self.to_client = new_to_client;
    }
};

test "Fast and Slow PC Loading Sync" {
    const allocator = std.testing.allocator;
    var network = MockNetwork.init(42);
    defer network.deinit(allocator);
    
    var host = MockPeer.init("Host (Fast PC)", true, 0, 0); // Lockstep
    var client = MockPeer.init("Client (Slow PC)", false, 0, 0); // Lockstep
    
    // 1. Both start at menu, move to character select
    host.state = .chara_select;
    client.state = .chara_select;
    
    // 2. Both transition state to Loading. This increases index to 1.
    host.onStateTransition(.chara_select, .loading);
    client.onStateTransition(.chara_select, .loading);
    try expectEqual(@as(u32, 1), host.index);
    try expectEqual(@as(u32, 1), client.index);
    
    // Send transition packets
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .loading } });
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .loading } });
    network.deliverAll(allocator, &host, &client);
    
    // 3. Fast PC finishes loading instantly and tries to transition to .chara_intro
    // The fast PC transitions locally to .chara_intro. This increments index to 2.
    const old_host_state = host.state;
    host.state = .chara_intro;
    host.onStateTransition(old_host_state, .chara_intro);
    try expectEqual(@as(u32, 2), host.index);
    
    // Host sends transition to client
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .chara_intro } });
    
    // BUT the slow PC (client) is still loading (index 1).
    // Let's deliver network events to client. Client receives index 2 transition from host.
    network.deliverAll(allocator, &host, &client);
    
    // Now, isRemoteInputReady check on Host.
    // Host is at index 2 (chara_intro), frame 0.
    // Client is still at index 1 (loading).
    // Since client has not transitioned to index 2 or sent any inputs/index packets,
    // host.remote_end_index received from client is still 1.
    // Since remote_idx (0) < host.index (2), isRemoteInputReady() must return false!
    try expectEqual(false, host.isRemoteInputReady());
    
    // Host is blocked at frame 0 of .chara_intro.
    // We simulate host loop ticking, but since isRemoteInputReady() is false, it does NOT advance its frame count.
    var ticks: usize = 0;
    while (ticks < 10) : (ticks += 1) {
        if (host.isRemoteInputReady()) {
            host.frame += 1;
        }
    }
    // Host frame must still be 0!
    try expectEqual(@as(u32, 0), host.frame);
    
    // 4. Now the slow PC (client) finally finishes loading and transitions to .chara_intro.
    const old_client_state = client.state;
    client.state = .chara_intro;
    client.onStateTransition(old_client_state, .chara_intro);
    try expectEqual(@as(u32, 2), client.index);
    
    // Client sends transition to host
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .chara_intro } });
    network.deliverAll(allocator, &host, &client);
    
    // Now client sends input for frame 0
    try network.sendToHost(allocator, .{ .input = .{ .index = 2, .frame = 0 } });
    network.deliverAll(allocator, &host, &client);
    
    // Now host's remote_end_index from client is 3 (remote_idx = 2 == our_index = 2).
    // and remote_end_frame is 1.
    // host.isRemoteInputReady() checks (1 + 0) > 0, which is true!
    try expect(host.isRemoteInputReady());
}

test "RNG Caching and Transition Application" {
    const allocator = std.testing.allocator;
    var network = MockNetwork.init(42);
    defer network.deinit(allocator);
    
    var host = MockPeer.init("Host", true, 0, 0);
    var client = MockPeer.init("Client", false, 0, 0);
    
    // Set both to .chara_select (index 1)
    host.state = .chara_select;
    client.state = .chara_select;
    host.onStateTransition(.pre_initial, .chara_select);
    client.onStateTransition(.pre_initial, .chara_select);
    
    // Transition to loading (index 2)
    host.onStateTransition(.chara_select, .loading);
    client.onStateTransition(.chara_select, .loading);
    
    // Transition to chara_intro (index 3)
    host.onStateTransition(.loading, .chara_intro);
    client.onStateTransition(.loading, .chara_intro);
    
    // Now Host finishes intro early and transitions to .in_game (index 4)
    host.onStateTransition(.chara_intro, .in_game);
    try expectEqual(@as(u32, 4), host.index);
    
    // Host is host, so it captures its current RNG and sends it to client for index 4
    host.rng_value = 99999; // Host RNG for index 4
    try network.sendToClient(allocator, .{ .rng = .{ .index = 4, .value = host.rng_value } });
    
    // Client is still in index 3 (chara_intro) and has not transitioned.
    try expectEqual(@as(u32, 3), client.index);
    const client_old_rng = client.rng_value;
    
    // Deliver packet to client
    network.deliverAll(allocator, &host, &client);
    
    // Verify that the client cached the RNG, but did NOT overwrite its active RNG memory!
    var cached_rng: u32 = 0;
    try expect(client.getCachedRngState(4, &cached_rng));
    try expectEqual(@as(u32, 99999), cached_rng);
    try expectEqual(client_old_rng, client.rng_value); // active RNG still unchanged
    
    // Now client transitions to .in_game (index 4)
    client.onStateTransition(.chara_intro, .in_game);
    try expectEqual(@as(u32, 4), client.index);
    
    // Verify that the client applied the cached RNG on transition
    try expectEqual(@as(u32, 99999), client.rng_value);
    try expect(client.rng_synced);
    try expectEqual(@as(u32, 4), client.rng_synced_index);
}

test "CharaSelect RNG sync — Random character pick matches between peers" {
    const allocator = std.testing.allocator;
    var network = MockNetwork.init(42);
    defer network.deinit(allocator);

    var host = MockPeer.init("Host", true, 0, 0);
    var client = MockPeer.init("Client", false, 0, 0);

    // Both peers enter chara_select.
    host.state = .chara_select;
    client.state = .chara_select;
    host.onStateTransition(.pre_initial, .chara_select);
    client.onStateTransition(.pre_initial, .chara_select);

    // Host should have armed RNG sync (this is the fix — was previously
    // NOT armed during chara_select, causing Random pick divergence).
    try expect(host.should_sync_rng == true);
    try expect(host.intro_rng_enabled == true);

    // Host captures and sends RNG for the chara_select index.
    const chara_select_index = host.index;
    const host_rng_value: u32 = 99999;
    host.rng_value = host_rng_value; // host "captures" its RNG state
    try network.sendToClient(allocator, .{ .rng = .{ .index = chara_select_index, .value = host_rng_value } });
    network.deliverAll(allocator, &host, &client);

    // Client applies the host's RNG.
    try expect(client.rng_value == host_rng_value);
    try expect(client.rng_synced == true);

    // Both peers advance several chara_select frames (simulating
    // the Random character pick consuming RNG). Because both
    // started from the same RNG state, they must produce the
    // same Random pick.
    var frame: u32 = 0;
    while (frame < 30) : (frame += 1) {
        host.rng_value +%= frame; // mock "RNG advance"
        client.rng_value +%= frame;
    }
    try expect(host.rng_value == client.rng_value);
}

test "Lockstep vs Rollback needed check" {
    // 1. Lockstep (rollback = 0)
    {
        var peer = MockPeer.init("Peer", false, 0, 0);
        peer.state = .in_game;
        peer.index = 4;
        peer.remote_end_index = 5; // index matched
        
        // Remote has sent inputs up to frame 5 (peer needs frame 5)
        peer.frame = 5;
        peer.remote_end_frame = 5;
        
        // end_frame (5) > needed (5) is false. Input is NOT ready!
        try expectEqual(false, peer.isRemoteInputReady());
        
        // Now remote sends frame 6
        peer.remote_end_frame = 6;
        // end_frame (6) > needed (5) is true. Input is ready!
        try expect(peer.isRemoteInputReady());
    }
    
    // 2. Rollback (rollback = 3)
    {
        var peer = MockPeer.init("Peer", false, 0, 3);
        peer.state = .in_game;
        peer.index = 4;
        peer.remote_end_index = 5;
        
        // Peer is at frame 5, but remote end_frame is only 3.
        peer.frame = 5;
        peer.remote_end_frame = 3;
        
        // needed = 5. (end_frame + rollback) = 3 + 3 = 6.
        // (6) > 5 is true! Peer is ready to simulate ahead!
        try expect(peer.isRemoteInputReady());
        
        // Peer advances to frame 6.
        peer.frame = 6;
        // (end_frame + rollback) = 6. needed = 6.
        // 6 > 6 is false! Peer must block (limit reached)!
        try expectEqual(false, peer.isRemoteInputReady());
    }
}

test "Rollback Re-Simulation" {
    var peer = MockPeer.init("Peer", false, 0, 5); // rollback = 5
    peer.state = .in_game;
    peer.index = 4;
    peer.rng_value = 100;
    
    // 1. Save states at frame 5, 10, 15
    peer.frame = 5;
    peer.saveState(5, 50); // x = 50
    
    peer.frame = 10;
    peer.rng_value = 200;
    peer.saveState(10, 100); // x = 100
    
    peer.frame = 15;
    peer.rng_value = 300;
    peer.saveState(15, 150); // x = 150
    
    // 2. Peer simulates ahead using prediction from frame 10 to 18
    // Let's say current frame is 18, and simulated coordinate x is 180.
    peer.frame = 18;
    var x: u32 = 180;
    
    // 3. Peer receives late packet indicating misprediction at frame 12
    peer.last_changed_frame = 12 | (@as(u64, 4) << 32); // index 4, frame 12
    
    // 4. Verify checkRollback triggers
    try expect(peer.checkRollback());
    
    // 5. Verify it loaded the state for frame 10 (latest saved state <= 12)
    try expectEqual(@as(u32, 10), peer.frame);
    try expectEqual(@as(u32, 200), peer.rng_value); // restored RNG
    
    // Verify that the restored game state variable (x) is loaded
    const loaded_state = peer.loadStateForFrame(12).?;
    try expectEqual(@as(u32, 10), loaded_state.frame);
    x = loaded_state.x;
    try expectEqual(@as(u32, 100), x); // restored x
    
    // Verify that rerun flags are set
    try expectEqual(@as(u32, 18), peer.fast_fwd_stop_frame);
    try expect(peer.isRerunning());
    
    // 6. Simulate re-running loop from 10 to 18
    while (peer.isRerunning()) {
        peer.frame += 1;
        x += 10; // re-simulating movement
        if (peer.frame == peer.fast_fwd_stop_frame) {
            peer.fast_fwd_stop_frame = 0; // stop re-running
        }
    }
    
    // Verify rerun completed
    try expectEqual(false, peer.isRerunning());
    try expectEqual(@as(u32, 18), peer.frame);
    try expectEqual(@as(u32, 180), x);
}

test "SyncHash Queue Compaction under Packet Loss" {
    var host = MockPeer.init("Host", true, 0, 0);
    host.state = .in_game;
    
    // 1. Simulating connection lag: Host enqueues 10 local SyncHashes (exceeding queue size limit 8)
    // while client hashes are delayed (remote_sync_count remains 0).
    var f: u32 = 150;
    while (f <= 1500) : (f += 150) {
        const indexed_frame = f | (@as(u64, 1) << 32);
        host.pushLocalSync(.{ .indexed_frame = indexed_frame, .hash = f * 3 });
    }
    
    // Verify host local_sync_count is saturated at 8
    try expectEqual(@as(u8, 8), host.local_sync_count);
    // Verify oldest entries (150 and 300) were dropped, and the oldest remaining is 450
    try expectEqual(450 | (@as(u64, 1) << 32), host.local_sync[0].indexed_frame);
    try expectEqual(1500 | (@as(u64, 1) << 32), host.local_sync[7].indexed_frame);
    
    // 2. Client's delayed hashes finally arrive (frame 150 to 1500)
    f = 150;
    while (f <= 1500) : (f += 150) {
        const indexed_frame = f | (@as(u64, 1) << 32);
        host.pushRemoteSync(.{ .indexed_frame = indexed_frame, .hash = f * 3 });
    }
    
    // Verify host remote_sync_count is also saturated at 8
    try expectEqual(@as(u8, 8), host.remote_sync_count);
    
    // 3. Run checkSyncHashDesync and verify:
    // - Unpaired Client hashes (150 and 300) are skipped/dropped.
    // - The remaining 8 hashes (450 to 1500) are matched successfully.
    // - No desync is detected.
    host.checkSyncHashDesync();
    
    try expectEqual(false, host.desync_detected);
    // Verify both queues are now empty (fully matched and compacted)
    try expectEqual(@as(u8, 0), host.local_sync_count);
    try expectEqual(@as(u8, 0), host.remote_sync_count);
}

test "High Packet Loss Input Recovery" {
    const allocator = std.testing.allocator;
    var network = MockNetwork.init(42); // seed 42
    network.loss_rate = 0.30; // 30% packet loss
    defer network.deinit(allocator);
    
    var host = MockPeer.init("Host", true, 0, 0);
    var client = MockPeer.init("Client", false, 0, 0);
    
    host.state = .in_game;
    client.state = .in_game;
    host.index = 4;
    client.index = 4;
    
    // Simulate Host sending inputs for frame 0..20.
    // In real game, during input loss, Host resends inputs continuously.
    // Let's simulate Host resending its inputs every frame (which sends last 30 inputs).
    // So for each frame F from 0 to 20, we send inputs.
    var f: u32 = 0;
    while (f < 20) : (f += 1) {
        // Send local inputs (redundantly resending previous inputs)
        var prev: u32 = 0;
        while (prev <= f) : (prev += 1) {
            try network.sendToClient(allocator, .{ .input = .{ .index = 4, .frame = prev } });
        }
        
        network.tick();
        network.deliverAll(allocator, &host, &client);
    }
    
    // Despite 30% packet loss, the client should have received inputs up to frame 20
    // because subsequent resends eventually got through!
    try expectEqual(@as(u32, 20), client.remote_end_frame);
}

test "Jitter Out-of-Order and Burst Delivery" {
    const allocator = std.testing.allocator;
    var network = MockNetwork.init(12345);
    network.base_latency = 5;
    network.jitter = 3;
    defer network.deinit(allocator);
    
    var host = MockPeer.init("Host", true, 0, 0);
    var client = MockPeer.init("Client", false, 0, 0);
    
    host.state = .in_game;
    client.state = .in_game;
    host.index = 4;
    client.index = 4;
    
    // Host sends inputs for frame 0, 1, 2, 3, 4, 5
    // Due to jitter, they will arrive out of order and in bursts
    try network.sendToClient(allocator, .{ .input = .{ .index = 4, .frame = 0 } });
    try network.sendToClient(allocator, .{ .input = .{ .index = 4, .frame = 1 } });
    try network.sendToClient(allocator, .{ .input = .{ .index = 4, .frame = 2 } });
    try network.sendToClient(allocator, .{ .input = .{ .index = 4, .frame = 3 } });
    try network.sendToClient(allocator, .{ .input = .{ .index = 4, .frame = 4 } });
    try network.sendToClient(allocator, .{ .input = .{ .index = 4, .frame = 5 } });
    
    // Verify that nothing is delivered at network frame 0 (since latency is 5)
    network.deliverAll(allocator, &host, &client);
    try expectEqual(@as(u32, 0), client.remote_end_frame);
    
    // Tick network and deliver until all packets arrive
    var ticks: usize = 0;
    while (ticks < 10) : (ticks += 1) {
        network.tick();
        network.deliverAll(allocator, &host, &client);
    }
    
    // Verify that all inputs were eventually delivered and compiled correctly
    try expectEqual(@as(u32, 6), client.remote_end_frame);
}

test "Packet Duplication Idempotency" {
    const allocator = std.testing.allocator;
    var network = MockNetwork.init(777);
    network.dup_rate = 1.0; // Force 100% duplication (every packet sent twice)
    defer network.deinit(allocator);
    
    var host = MockPeer.init("Host", true, 0, 0);
    var client = MockPeer.init("Client", false, 0, 0);
    
    host.state = .chara_select;
    client.state = .chara_select;
    host.onStateTransition(.pre_initial, .chara_select);
    client.onStateTransition(.pre_initial, .chara_select);
    
    // 1. Transition packet duplicated
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .chara_select } });
    network.deliverAll(allocator, &host, &client);
    
    // Client received two duplicate transition packets. Verify remote_end_index is still correct (2).
    try expectEqual(@as(u32, 2), client.remote_end_index);
    
    // 2. RNG packet for CURRENT index duplicated
    // client is at index 1, so we send RNG for index 1
    try network.sendToClient(allocator, .{ .rng = .{ .index = 1, .value = 54321 } });
    network.deliverAll(allocator, &host, &client);
    
    // Verify that client applied it immediately and remains synced
    try expectEqual(@as(u32, 54321), client.rng_value);
    try expect(client.rng_synced);
    try expectEqual(@as(u32, 1), client.rng_synced_index);
    
    // Deliver client's ACKs to host (since they were duplicated, host gets duplicate ACKs)
    network.deliverAll(allocator, &host, &client);
    
    // Verify host handles duplicate ACKs idempotently (still marked synced and acked)
    try expect(host.rng_acked);
    try expect(host.rng_synced);
}

test "Full Game Cycle State Transition Simulation" {
    const allocator = std.testing.allocator;
    var network = MockNetwork.init(42);
    defer network.deinit(allocator);
    
    var host = MockPeer.init("Host", true, 0, 0); // Lockstep
    var client = MockPeer.init("Client", false, 0, 0);
    
    // 1. Startup & Connection (pre_initial -> initial)
    try expectEqual(NetplayState.pre_initial, host.state);
    try expectEqual(NetplayState.pre_initial, client.state);
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
    
    host.state = .initial;
    client.state = .initial;
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
    
    // 2. Character Select (initial -> chara_select)
    // Host transitions locally
    host.onStateTransition(.initial, .chara_select);
    host.state = .chara_select;
    try expectEqual(@as(u32, 1), host.index);
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .chara_select } });

    // Host should block waiting for Client to enter index 1 (remote_end_index is still 0)
    try expectEqual(false, host.isRemoteInputReady());

    // Client transitions locally
    client.onStateTransition(.initial, .chara_select);
    client.state = .chara_select;
    try expectEqual(@as(u32, 1), client.index);
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .chara_select } });

    // Deliver packets
    network.deliverAll(allocator, &host, &client);

    // Both send frame 0 input in chara_select
    try network.sendToClient(allocator, .{ .input = .{ .index = 1, .frame = 0 } });
    try network.sendToHost(allocator, .{ .input = .{ .index = 1, .frame = 0 } });
    network.deliverAll(allocator, &host, &client);

    // Host sends RNG for chara_select (index 1). With chara_select RNG sync
    // now armed (matching production), the host captures and sends its RNG.
    // The client must receive and apply it before isRemoteInputReady returns
    // true during .chara_intro and .in_game.
    try network.sendToClient(allocator, .{ .rng = .{ .index = 1, .value = host.rng_value } });
    network.deliverAll(allocator, &host, &client);

    // Both should now be unblocked
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
    
    // 3. Loading Screen (chara_select -> loading)
    host.onStateTransition(.chara_select, .loading);
    host.state = .loading;
    try expectEqual(@as(u32, 2), host.index);
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .loading } });
    
    client.onStateTransition(.chara_select, .loading);
    client.state = .loading;
    try expectEqual(@as(u32, 2), client.index);
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .loading } });
    
    // Verify loading is non-blocking
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
    
    network.deliverAll(allocator, &host, &client);
    
    // 4. Character Intro (loading -> chara_intro)
    // Host loads instantly and transitions early
    host.onStateTransition(.loading, .chara_intro);
    host.state = .chara_intro;
    try expectEqual(@as(u32, 3), host.index);
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .chara_intro } });
    
    // Host must block at intro frame 0 waiting for Client (client is still loading at index 2)
    network.deliverAll(allocator, &host, &client);
    try expectEqual(false, host.isRemoteInputReady());
    
    // Client finishes loading and transitions
    client.onStateTransition(.loading, .chara_intro);
    client.state = .chara_intro;
    try expectEqual(@as(u32, 3), client.index);
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .chara_intro } });
    
    network.deliverAll(allocator, &host, &client);
    
    // Both send intro frame 0 inputs
    try network.sendToClient(allocator, .{ .input = .{ .index = 3, .frame = 0 } });
    try network.sendToHost(allocator, .{ .input = .{ .index = 3, .frame = 0 } });
    network.deliverAll(allocator, &host, &client);
    
    // Both should now be unblocked in intro
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
    
    // 5. Intro Skip (chara_intro -> skippable)
    host.onStateTransition(.chara_intro, .skippable);
    host.state = .skippable;
    try expectEqual(@as(u32, 4), host.index);
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .skippable } });
    
    client.onStateTransition(.chara_intro, .skippable);
    client.state = .skippable;
    try expectEqual(@as(u32, 4), client.index);
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .skippable } });
    
    // Skippable state is non-blocking
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
    
    network.deliverAll(allocator, &host, &client);
    
    // 6. Gameplay Match (skippable -> in_game)
    host.onStateTransition(.skippable, .in_game);
    host.state = .in_game;
    try expectEqual(@as(u32, 5), host.index);
    
    // Host is host, generates RNG for index 5 and sends it
    host.rng_value = 88888;
    try network.sendToClient(allocator, .{ .rng = .{ .index = 5, .value = host.rng_value } });
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .in_game } });
    
    // Client transitions locally
    client.onStateTransition(.skippable, .in_game);
    client.state = .in_game;
    try expectEqual(@as(u32, 5), client.index);
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .in_game } });
    
    // Deliver RNG and transition packets
    network.deliverAll(allocator, &host, &client);
    
    // Verify client has successfully applied and synced the host RNG
    try expectEqual(@as(u32, 88888), client.rng_value);
    try expect(client.rng_synced);
    
    // Exchange frame 0 inputs
    try network.sendToClient(allocator, .{ .input = .{ .index = 5, .frame = 0 } });
    try network.sendToHost(allocator, .{ .input = .{ .index = 5, .frame = 0 } });
    network.deliverAll(allocator, &host, &client);
    
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
    
    // Simulate advancing to frame 1
    host.frame = 1;
    client.frame = 1;
    
    // 7. Match Ends (in_game -> retry_menu)
    host.onStateTransition(.in_game, .retry_menu);
    host.state = .retry_menu;
    try expectEqual(@as(u32, 6), host.index);
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .retry_menu } });
    
    client.onStateTransition(.in_game, .retry_menu);
    client.state = .retry_menu;
    try expectEqual(@as(u32, 6), client.index);
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .retry_menu } });
    
    // RetryMenu is non-blocking
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
    
    network.deliverAll(allocator, &host, &client);
    
    // 8. Rematch Loop (retry_menu -> loading)
    // Both select rematch
    host.onStateTransition(.retry_menu, .loading);
    host.state = .loading;
    try expectEqual(@as(u32, 7), host.index);
    try network.sendToClient(allocator, .{ .transition = .{ .index = host.index, .state = .loading } });
    
    client.onStateTransition(.retry_menu, .loading);
    client.state = .loading;
    try expectEqual(@as(u32, 7), client.index);
    try network.sendToHost(allocator, .{ .transition = .{ .index = client.index, .state = .loading } });
    
    // Verify rematch load is also non-blocking
    try expect(host.isRemoteInputReady());
    try expect(client.isRemoteInputReady());
}

test "Real InputBuffer Misprediction Detection" {
    const allocator = std.testing.allocator;
    var buf = rb.InputBuffer.init(allocator);
    defer buf.deinit();

    // 1. Simulating we didn't receive peer's input for index 1, frame 5 yet.
    // get() will return predicted input (falls back to last_inputs, which is 0 since no inputs yet).
    // Let's set frame 4 input to 0x01 (button A).
    buf.set(1, 4, 0x01);

    // For frame 5, since key is missing, get() predicts 0x01 (repeats last input)
    try expectEqual(@as(u16, 0x01), buf.get(1, 5));

    // 2. Peer's actual input for frame 5 arrives via setRemote, and it is 0x00 (release).
    // Our fix compares the used input (0x01) with actual (0x00).
    const actual_inputs = [_]u16{0x00};
    buf.setRemote(1, 5, &actual_inputs, true);

    // Verify last_changed_frame is now correctly set to frame 5 (which triggers rollback)!
    try expect(buf.last_changed_frame != null);
    const index_frame = buf.last_changed_frame.?;
    try expectEqual(@as(u32, 1), @as(u32, @intCast(index_frame >> 32)));
    try expectEqual(@as(u32, 5), @as(u32, @intCast(index_frame & 0xFFFFFFFF)));
}

test "Real StatePool Save, Load, and Reset" {
    const allocator = std.testing.allocator;
    var pool = rb.StatePool.init(allocator);
    defer pool.deinit();

    // 1. Declare some mock game variables
    var dummy_val0: u32 = 100;
    var dummy_val1: u32 = 200;
    var dummy_buf: [10]u8 = [_]u8{1} ** 10;

    // 2. Register them as regions in the StatePool
    try pool.addRegion(@intFromPtr(&dummy_val0), @sizeOf(u32));
    try pool.addRegion(@intFromPtr(&dummy_val1), @sizeOf(u32));
    try pool.addRegion(@intFromPtr(&dummy_buf), dummy_buf.len);

    try expectEqual(@as(usize, 4 + 4 + 10), pool.totalRegionSize());

    // 3. Allocate pool for 5 states
    try pool.allocate(5, 0);

    // 4. Save state at frame 10
    const slot0 = pool.saveState(10, 1, 0, 0).?;
    try expectEqual(@as(usize, 0), slot0);
    try expectEqual(@as(usize, 1), pool.saved_states_count());

    // 5. Modify dummy variables
    dummy_val0 = 999;
    dummy_val1 = 888;
    dummy_buf[0] = 99;

    // 6. Load state for frame 10 (should restore the old values!)
    const loaded_frame = pool.loadStateForFrame(10, 1);
    try expect(loaded_frame != null);
    try expectEqual(@as(u32, 10), loaded_frame.?.frame);

    try expectEqual(@as(u32, 100), dummy_val0);
    try expectEqual(@as(u32, 200), dummy_val1);
    try expectEqual(@as(u8, 1), dummy_buf[0]);

    // 7. Test reset() - should clear saved states and refill free stack
    pool.reset();
    try expectEqual(@as(usize, 0), pool.saved_states_count());
    try expectEqual(@as(usize, 5), pool.free_stack_count());
}

test "Mock Rollback Out-of-Bounds Canceled" {
    var peer = MockPeer.init("Peer", false, 0, 5); // rollback = 5
    peer.state = .in_game;
    peer.index = 4;
    peer.rng_value = 100;
    
    // 1. Save state at frame 10
    peer.frame = 10;
    peer.saveState(10, 100);
    
    // 2. Peer simulates ahead to frame 18
    peer.frame = 18;
    
    // 3. Peer receives a late packet for frame 5.
    // Since 5 < 10, the oldest saved state is 10.
    // So there is no saved state <= 5!
    peer.last_changed_frame = 5 | (@as(u64, 4) << 32); // index 4, frame 5
    
    // 4. Verify checkRollback returns false (aborts rollback!)
    try expectEqual(false, peer.checkRollback());
    
    // 5. Verify the frame remains unchanged (18) and last_changed_frame is cleared
    try expectEqual(@as(u32, 18), peer.frame);
    try expect(peer.last_changed_frame == null);
}

test "checkRoundStart deadlock regression test" {
    var peer = MockPeer.init("Peer", false, 0, 0);
    peer.state = .chara_intro;
    peer.index = 2;
    peer.last_round_start = 0;
    peer.round_start_counter = 0;

    // 1. Remote is behind (remote_end_index is 2 <= peer.index of 2).
    peer.remote_end_index = 2;
    
    // Increment counter to 1
    peer.round_start_counter = 1;
    
    // 2. Call checkRoundStart — should return early without transitioning
    peer.checkRoundStart();
    try expectEqual(NetplayState.chara_intro, peer.state);
    
    // 3. Remote catches up (remote_end_index becomes 3 > peer.index of 2).
    peer.remote_end_index = 3;
    
    // 4. Call checkRoundStart again.
    // With the fix: last_round_start was NOT updated to 1 during the early return,
    // so checkRoundStart will run and transition us to .in_game!
    peer.checkRoundStart();
    try expectEqual(NetplayState.in_game, peer.state);
    try expectEqual(@as(u32, 1), peer.last_round_start);
}

// Import the desync tests so they run as part of the same test binary.
pub const desync_tests = @import("rollback_desync_tests.zig");

// Import the CCCaster parity tests (rollback-improvements branch fixes).
pub const parity_tests = @import("rollback_parity_tests.zig");
