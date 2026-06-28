// Port of CCCaster's `InputsContainer<T>` (netplay/InputsContainer.hpp).
//
// This is the input-history data structure that backs `NetplayManager._inputs`.
// It maps `index -> frame -> input`, and tracks `_lastChangedFrame` so the
// rollback loop knows the earliest frame whose input differed from the
// prediction. The semantics are faithful to CCCaster:
//
//   - `get(index, frame)` returns the input at (index, frame), or the last
//     known input before that index if the cell is empty. If nothing is known,
//     returns 0 (T's default).
//   - `set(index, frame, t)` CANNOT change an existing input — it only fills
//     in previously-unknown cells. This is the local-input path.
//   - `assign(index, frame, t)` CAN change an existing input. Used during
//     rollback to overwrite predictions with the authoritative remote input.
//   - `set(index, frame, t, n)` fills n cells (set-batch).
//   - `set(index, frame, t[], n, checkStartingFromIndex)` is the REMOTE input
//     path. When `index >= checkStartingFromIndex`, it scans for the first
//     cell where the new input differs from the old and records that frame in
//     `_lastChangedFrame` (taking the min, so the EARLIEST change wins).
//   - `clearLastChangedFrame()` resets `_lastChangedFrame` to MaxIndexedFrame.
//
// CCCaster uses `std::vector<std::vector<T>>` as the outer->inner storage.
// We use `std.ArrayList(std.ArrayList(T))` with the same semantics. Each
// outer index is lazily grown on demand; missing inner frames are filled
// with the last known input for that index (matching CCCaster's `resize`).

const std = @import("std");
const IndexedFrame = @import("indexed_frame.zig").IndexedFrame;

pub fn InputsContainer(comptime T: type) type {
    return struct {
        const Self = @This();
        const Inner = std.ArrayList(T);

        allocator: std.mem.Allocator,
        inputs: std.ArrayList(Inner),
        /// Last frame of input that changed. Initialized to "max" (= no
        /// pending change). Matches CCCaster's `_lastChangedFrame = MaxIndexedFrame`.
        last_changed_frame: IndexedFrame = IndexedFrame.max_value,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .inputs = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.inputs.items) |*inner| inner.deinit(self.allocator);
            self.inputs.deinit(self.allocator);
        }

        // ---- getters -----------------------------------------------------

        /// Get a single input for (index, frame), returns the last known
        /// input before that index if the cell is empty. Matches CCCaster's
        /// `T get(index, frame) const`.
        pub fn get(self: *const Self, index: u32, frame: u32) T {
            if (index >= self.inputs.items.len or self.inputs.items[index].items.len == 0)
                return self.lastInputBefore(index);

            const inner = self.inputs.items[index];
            if (frame >= inner.items.len) return inner.items[inner.items.len - 1];
            return inner.items[frame];
        }

        /// Get n inputs starting at (index, frame). Asserts enough are present.
        /// Matches CCCaster's `void get(index, frame, T*, n) const`.
        pub fn getRange(self: *const Self, index: u32, frame: u32, out: []T) void {
            std.debug.assert(index < self.inputs.items.len);
            const inner = self.inputs.items[index];
            std.debug.assert(frame + out.len <= inner.items.len);
            @memcpy(out, inner.items[frame .. frame + out.len]);
        }

        pub fn empty(self: *const Self) bool {
            return self.inputs.items.len == 0;
        }

        pub fn emptyIndex(self: *const Self, index: u32) bool {
            if (index >= self.inputs.items.len) return true;
            return self.inputs.items[index].items.len == 0;
        }

        /// Number of outer indices allocated. Matches CCCaster's `getEndIndex()`.
        pub fn getEndIndex(self: *const Self) u32 {
            return @intCast(self.inputs.items.len);
        }

        /// Number of frames stored at the last index. Matches `getEndFrame()`.
        pub fn getEndFrame(self: *const Self) u32 {
            if (self.inputs.items.len == 0) return 0;
            const last = self.inputs.items[self.inputs.items.len - 1];
            return @intCast(last.items.len);
        }

        /// Number of frames stored at `index`. Matches `getEndFrame(index)`.
        pub fn getEndFrameAt(self: *const Self, index: u32) u32 {
            if (index >= self.inputs.items.len) return 0;
            return @intCast(self.inputs.items[index].items.len);
        }

        pub fn getLastChangedFrame(self: *const Self) IndexedFrame {
            return self.last_changed_frame;
        }

        pub fn clearLastChangedFrame(self: *Self) void {
            self.last_changed_frame = IndexedFrame.max_value;
        }

        // ---- setters -----------------------------------------------------

        /// Set a single input. CANNOT change an existing input — matches
        /// CCCaster's `set(index, frame, t)`.
        pub fn set(self: *Self, index: u32, frame: u32, t: T) void {
            if (index < self.inputs.items.len and self.inputs.items[index].items.len > frame)
                return; // already set, ignore (CCCaster semantics)
            self.resize(index, frame, 1);
            self.inputs.items[index].items[frame] = t;
        }

        /// Assign a single input. CAN change an existing input.
        /// Matches CCCaster's `assign(index, frame, t)`.
        pub fn assign(self: *Self, index: u32, frame: u32, t: T) void {
            self.resize(index, frame, 1);
            self.inputs.items[index].items[frame] = t;
        }

        /// Fill n cells with the same value. Matches `set(index, frame, t, n)`.
        pub fn setRepeated(self: *Self, index: u32, frame: u32, t: T, n: usize) void {
            self.resize(index, frame, n);
            @memset(self.inputs.items[index].items[frame .. frame + n], t);
        }

        /// Set n cells from a slice. This is the REMOTE-input path: when
        /// `index >= checkStartingFromIndex`, it scans for the first cell
        /// whose new value differs from the current one and records that
        /// frame in `_lastChangedFrame` (taking the min, so the EARLIEST
        /// change wins). Matches CCCaster's
        /// `set(index, frame, const T* t, size_t n, uint32_t checkStartingFromIndex)`.
        pub fn setBatch(
            self: *Self,
            index: u32,
            frame: u32,
            items: []const T,
            check_starting_from_index: u32,
        ) void {
            const n = items.len;
            if (index >= check_starting_from_index) {
                var f = frame;
                var i: usize = 0;
                while (i < n) : ({ i += 1; f += 1; }) {
                    if (self.get(index, f) == items[i]) continue;
                    // Record the earliest changed frame.
                    const candidate = IndexedFrame.init(f, index);
                    if (candidate.lessThan(self.last_changed_frame))
                        self.last_changed_frame = candidate;
                    break;
                }
            }
            self.resize(index, frame, n);
            @memcpy(self.inputs.items[index].items[frame .. frame + n], items);
        }

        // ---- lifecycle ---------------------------------------------------

        pub fn clear(self: *Self) void {
            for (self.inputs.items) |*inner| inner.deinit(self.allocator);
            self.inputs.clearRetainingCapacity();
            self.last_changed_frame = IndexedFrame.max_value;
        }

        /// Erase all outer indices older than `index`. Matches CCCaster's
        /// `eraseIndexOlderThan(index)`.
        pub fn eraseIndexOlderThan(self: *Self, index: u32) void {
            if (index + 1 >= self.inputs.items.len) {
                self.clear();
                return;
            }
            var i: u32 = 0;
            while (i < index) : (i += 1) self.inputs.items[i].deinit(self.allocator);
            // Shift the survivors down to slot 0.
            std.mem.copyForwards(Inner, self.inputs.items[0..], self.inputs.items[index..]);
            self.inputs.shrinkRetainingCapacity(self.inputs.items.len - index);
        }

        // ---- internals ---------------------------------------------------

        /// Grow the container so it can hold inputs up to (index, frame+n).
        /// New outer indices are seeded with `lastInputBefore`. New inner
        /// frames are back-filled with the index's last known input. Matches
        /// CCCaster's `resize(index, frame, n)`.
        fn resize(self: *Self, index: u32, frame: u32, n: usize) void {
            var last: T = 0;
            if (index >= self.inputs.items.len) {
                last = self.lastInputBefore(@intCast(self.inputs.items.len));
                self.inputs.appendNTimes(self.allocator, .empty, index + 1 - self.inputs.items.len) catch return;
            } else if (self.inputs.items[index].items.len != 0) {
                last = self.inputs.items[index].items[self.inputs.items[index].items.len - 1];
            }
            const inner = &self.inputs.items[index];
            if (frame + n > inner.items.len) {
                inner.appendNTimes(self.allocator, last, (frame + n) - inner.items.len) catch {};
            }
        }

        /// Get the last known input BEFORE the given outer index. Returns 0
        /// if nothing is known. Matches CCCaster's `lastInputBefore`.
        fn lastInputBefore(self: *const Self, index_in: u32) T {
            if (self.inputs.items.len == 0 or index_in == 0) return 0;
            var index = index_in;
            if (index > self.inputs.items.len) index = @intCast(self.inputs.items.len);
            while (index > 0) {
                index -= 1;
                if (self.inputs.items[index].items.len != 0)
                    return self.inputs.items[index].items[self.inputs.items[index].items.len - 1];
            }
            return 0;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — verify the behavior matches CCCaster's InputsContainer.
// ---------------------------------------------------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "empty container returns 0 for any get" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    try expectEqual(@as(u16, 0), c.get(0, 0));
    try expectEqual(@as(u16, 0), c.get(5, 10));
    try expect(c.empty());
    try expectEqual(@as(u32, 0), c.getEndIndex());
    try expectEqual(@as(u32, 0), c.getEndFrame());
}

test "set then get returns the stored value" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.set(0, 0, 0x0102);
    c.set(0, 1, 0x0304);
    try expectEqual(@as(u16, 0x0102), c.get(0, 0));
    try expectEqual(@as(u16, 0x0304), c.get(0, 1));
    try expectEqual(@as(u32, 2), c.getEndFrame());
    try expectEqual(@as(u32, 1), c.getEndIndex());
}

test "set cannot overwrite an existing cell (CCCaster semantics)" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.set(0, 0, 0x1111);
    c.set(0, 0, 0x2222); // ignored
    try expectEqual(@as(u16, 0x1111), c.get(0, 0));
}

test "assign CAN overwrite an existing cell" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.set(0, 0, 0x1111);
    c.assign(0, 0, 0x2222);
    try expectEqual(@as(u16, 0x2222), c.get(0, 0));
}

test "get past end-of-index returns the last stored input" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.set(0, 0, 0x01);
    c.set(0, 1, 0x02);
    c.set(0, 2, 0x03);
    // frame 99 is past the end; CCCaster returns the back() of the vector.
    try expectEqual(@as(u16, 0x03), c.get(0, 99));
}

test "get at an unknown index returns lastInputBefore" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.set(0, 0, 0xAA);
    c.set(0, 1, 0xBB);
    // Index 1 has no inputs yet — should fall back to index 0's last input.
    try expectEqual(@as(u16, 0xBB), c.get(1, 0));
    try expectEqual(@as(u16, 0xBB), c.get(1, 5));
}

test "setBatch records the earliest changed frame in last_changed_frame" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    // Predicted inputs for frames 3,4,5,6 at index 4.
    c.set(4, 3, 0x01);
    c.set(4, 4, 0x01);
    c.set(4, 5, 0x01);
    c.set(4, 6, 0x01);
    // checkStartingFromIndex = 0 (always check).
    // Frame 3 matches; frame 4 differs → last_changed_frame = 4:4.
    const actual = [_]u16{ 0x01, 0x09, 0x09, 0x09 };
    c.setBatch(4, 3, &actual, 0);
    try expectEqual(@as(u32, 4), c.last_changed_frame.index());
    try expectEqual(@as(u32, 4), c.last_changed_frame.frame());
}

test "setBatch with checkStartingFromIndex = UINT_MAX skips the change check" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.set(4, 3, 0x01);
    const actual = [_]u16{0x09};
    c.setBatch(4, 3, &actual, std.math.maxInt(u32));
    // No change recorded because checkStartingFromIndex is UINT_MAX.
    try expectEqual(IndexedFrame.max_value.value, c.last_changed_frame.value);
}

test "setBatch takes the minimum (earliest) changed frame" {
    // CCCaster: `_lastChangedFrame.value = std::min(_lastChangedFrame.value, f.value)`.
    // The min is on the full 64-bit value, so a smaller frame (same index) IS
    // smaller. A change at frame 0 updates lcf from (4<<32|2) to (4<<32|0).
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.last_changed_frame = IndexedFrame.init(2, 4);
    c.set(4, 0, 0x00);
    const actual = [_]u16{0x01};
    c.setBatch(4, 0, &actual, 0); // changes frame 0 — (4<<32|0) < (4<<32|2) → update
    try expectEqual(@as(u32, 0), c.last_changed_frame.frame());
}

test "clearLastChangedFrame resets to MaxIndexedFrame" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.last_changed_frame = IndexedFrame.init(7, 3);
    c.clearLastChangedFrame();
    try expectEqual(IndexedFrame.max_value.value, c.last_changed_frame.value);
}

test "eraseIndexOlderThan shifts surviving indices down to slot 0" {
    var c = InputsContainer(u16).init(std.testing.allocator);
    defer c.deinit();
    c.set(0, 0, 0x0A);
    c.set(1, 0, 0x0B);
    c.set(2, 0, 0x0C);
    c.eraseIndexOlderThan(1); // drop index 0
    try expectEqual(@as(u32, 2), c.getEndIndex());
    try expectEqual(@as(u16, 0x0B), c.get(0, 0)); // old index 1 is now at 0
    try expectEqual(@as(u16, 0x0C), c.get(1, 0)); // old index 2 is now at 1
}
