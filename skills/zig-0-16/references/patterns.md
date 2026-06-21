# Modern 0.16 patterns

This is the cookbook: patterns that demonstrate the right way to use the new 0.16 features
together. Each pattern is self-contained and ready to lift into a real codebase.

## Table of contents

1. [Threading `Io` through a codebase](#threading-io-through-a-codebase)
2. [Error set ergonomics](#error-set-ergonomics)
3. [Tagged unions as state machines](#tagged-unions-as-state-machines)
4. [Generational indices for entity pools](#generational-indices-for-entity-pools)
5. [Deterministic simulation patterns](#deterministic-simulation-patterns)
6. [Arena-scoped work units](#arena-scoped-work-units)
7. [Comptime-driven configuration](#comptime-driven-configuration)
8. [Result types and error chaining](#result-types-and-error-chaining)
9. [Builder DSLs with `@Type` replaced](#builder-dsls-with-type-replaced)
10. [Testing with `Io.failing`](#testing-with-iofailing)
11. [Logging with structured output](#logging-with-structured-output)

## Threading `Io` through a codebase

Treat `Io` exactly like `Allocator`: store it on every struct that does I/O, pass it to
every function that does I/O. Don't use globals.

```zig
const Database = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, path: []const u8) Database {
        return .{ .io = io, .gpa = gpa, .path = path };
    }

    pub fn load(self: *Database) ![]u8 {
        var cwd: std.Io.Dir = .cwd(self.io);
        defer cwd.close(self.io);
        return cwd.readFileAlloc(self.io, self.gpa, self.path, 1 << 20);
    }

    pub fn save(self: *Database, data: []const u8) !void {
        var cwd: std.Io.Dir = .cwd(self.io);
        defer cwd.close(self.io);
        var f = try cwd.createFile(self.io, self.path, .{});
        defer f.close(self.io);
        _ = try f.writeAllStreaming(self.io, data);
    }
};
```

This pattern means:
- The same `Database` struct works on `Io.Threaded`, `Io.Evented`, `Io.Dispatch`, or
  `Io.failing` without code changes.
- Tests can construct a `Database` with `Io.failing` and assert that errors propagate.
- Embedding in a game loop uses `Io.Dispatch` and pumps the Io alongside the sim.

## Error set ergonomics

Zig's error sets are intentionally minimal — no exceptions, no inheritance, just sets.
Two patterns make them ergonomic:

### Coarse-grained public error sets

```zig
const PublicError = error{
    InvalidInput,
    NotFound,
    Permission,
    Internal,
};

pub fn load(path: []const u8) PublicError![]u8 {
    return loadImpl(io, gpa, path) catch |err| switch (err) {
        error.FileNotFound => PublicError.NotFound,
        error.AccessDenied => PublicError.Permission,
        error.OutOfMemory => PublicError.Internal,
        else => PublicError.Internal,
    };
}

fn loadImpl(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    // ...
}
```

This way the public API is stable even as the implementation adds new error variants.

### Inferring error sets in internal code

```zig
fn parseHeader(r: *std.Io.Reader) !Header {
    // Return type is `!Header` — error set is inferred.
    // Don't write `!Header` for public API; do write it for internal helpers.
}
```

Inferred error sets are great for internal code because they don't need maintenance when
you add a new error path. But they make the public API brittle (any change in the
implementation can add a new error variant that callers don't know to handle).

## Tagged unions as state machines

Zig's tagged unions are the cleanest way to model a state machine:

```zig
const ConnectionState = enum { connecting, handshake, ready, closing };

const Connection = union(ConnectionState) {
    connecting: struct {
        addr: std.net.Address,
    },
    handshake: struct {
        conn: *TcpConn,
        challenge: [16]u8,
    },
    ready: struct {
        conn: *TcpConn,
        session_id: u64,
    },
    closing: struct {
        conn: *TcpConn,
        reason: CloseReason,
    },

    pub fn advance(self: *Connection, io: std.Io, gpa: std.mem.Allocator) !void {
        switch (self.*) {
            .connecting => |*s| {
                var conn = try tcpConnect(io, s.addr);
                var challenge: [16]u8 = undefined;
                try conn.reader(io, &buf).readAll(&challenge);
                self.* = .{ .handshake = .{ .conn = conn, .challenge = challenge } };
            },
            .handshake => |*s| {
                var response: [16]u8 = undefined;
                try respondToChallenge(&s.challenge, &response);
                _ = try s.conn.writeAllStreaming(io, &response);
                const session_id = try s.conn.reader(io, &buf).takeInt(u64, .little);
                self.* = .{ .ready = .{ .conn = s.conn, .session_id = session_id } };
            },
            .ready => |*s| {
                // ... handle protocol ...
            },
            .closing => |*s| {
                _ = try s.conn.writeAllStreaming(io, "bye\n");
                s.conn.close(io);
                self.* = undefined;   // caller should now destroy
            },
        }
    }
};
```

The compiler enforces exhaustiveness in `switch`, so adding a new state requires updating
every transition function. This is the killer feature of tagged unions for FSMs.

## Generational indices for entity pools

For deterministic simulation (games, rollback netcode), you can't use raw pointers as
entity handles — they leak allocator state. Use generational indices: an ID + a generation
counter. The pool stores a `generation` per slot; if you try to access an entity whose
stored generation doesn't match your handle, it's been despawned and reused.

```zig
pub const EntityId = struct {
    index: u32,
    generation: u32,

    pub fn eql(a: EntityId, b: EntityId) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

pub const EntityPool = struct {
    const Slot = struct {
        generation: u32,
        alive: bool,
        entity: Entity,
    };

    slots: []Slot,
    free_list: std.ArrayList(u32),
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, capacity: usize) !EntityPool {
        const slots = try gpa.alloc(Slot, capacity);
        @memset(slots, .{ .generation = 0, .alive = false, .entity = undefined });
        var free_list: std.ArrayList(u32) = .empty;
        free_list.initContext(gpa);
        for (0..capacity) |i| try free_list.append(gpa, @intCast(i));
        return .{ .slots = slots, .free_list = free_list, .gpa = gpa };
    }

    pub fn deinit(self: *EntityPool) void {
        self.gpa.free(self.slots);
        self.free_list.deinit(self.gpa);
    }

    pub fn spawn(self: *EntityPool, e: Entity) !EntityId {
        const idx = self.free_list.pop() orelse return error.OutOfMemory;
        const slot = &self.slots[idx];
        slot.generation +%= 1;
        slot.alive = true;
        slot.entity = e;
        return .{ .index = idx, .generation = slot.generation };
    }

    pub fn despawn(self: *EntityPool, id: EntityId) void {
        const slot = &self.slots[id.index];
        if (slot.generation != id.generation) return;   // already despawned
        slot.alive = false;
        self.free_list.append(self.gpa, id.index) catch {};
    }

    pub fn get(self: *EntityPool, id: EntityId) ?*Entity {
        const slot = &self.slots[id.index];
        if (slot.generation != id.generation or !slot.alive) return null;
        return &slot.entity;
    }
};
```

Why this matters:
- `EntityId` is a value type — copyable, comparable, stashable in saved states.
- A saved state captures the same `EntityId` values on both peers, regardless of allocator
  address layout.
- Despawning an already-despawned entity is a no-op (not a crash).
- The pool has a fixed capacity — no per-frame allocation.

## Deterministic simulation patterns

For [rollback netcode](../../rollback-netcode/SKILL.md) and replay systems:

### Use fixed-point, not floating-point

```zig
// 16.16 fixed-point: i32 with 16 bits of fraction
const Fixed = struct {
    v: i32,

    pub fn fromInt(x: i32) Fixed { return .{ .v = x << 16 }; }
    pub fn toInt(self: Fixed) i32 { return self.v >> 16; }
    pub fn add(a: Fixed, b: Fixed) Fixed { return .{ .v = a.v + b.v }; }
    pub fn mul(a: Fixed, b: Fixed) Fixed { return .{ .v = @as(i64, a.v) * @as(i64, b.v) >> 16 }; }
};
```

IEEE-754 floats are deterministic *on the same CPU+compiler combo* but break across
architectures, FMA-modes, and optimization levels. Fixed-point Just Works.

### Never use `io.rng()` inside `advance_frame`

```zig
// WRONG — non-deterministic
fn advanceFrame(state: *GameState, io: std.Io) !void {
    const r = io.rng().random().int(u32);
    state.entities[0].vx = @as(f32, @floatFromInt(r)) / 4294967296.0;
}

// CORRECT — RNG is part of the state, seeded identically on all peers
const GameState = struct {
    prng: std.Random.DefaultPrng,
    entities: [MAX]Entity,

    fn advance(self: *GameState) void {
        const r = self.prng.random().int(u32);
        self.entities[0].vx = fixed_from_u32(r);
    }
};
```

### Avoid allocation inside `advance_frame`

Pre-allocate everything in a fixed-size pool. Per-frame allocation breaks determinism if
the allocator's address layout affects pointer comparisons.

### Hash saved states for sync testing

```zig
fn saveState(state: *const GameState, buf: []u8) void {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(state));
    const hash = hasher.final();
    @memcpy(buf[0..8], std.mem.asBytes(&hash));
}
```

Compare hashes across peers; if they disagree, you have a determinism bug.

## Arena-scoped work units

For request-style work (HTTP handlers, CLI commands, asset loads):

```zig
const AssetLoader = struct {
    io: std.Io,
    gpa: std.mem.Allocator,

    pub fn load(self: *AssetLoader, path: []const u8) !LoadedAsset {
        var arena: std.heap.ArenaAllocator = .empty;
        arena.initContext(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // All per-load allocations go to `a` — freed on return
        const bytes = try self.loadBytes(a, path);
        const parsed = try parseAsset(a, bytes);
        return try persistAsset(self.gpa, parsed);   // copy what we keep
    }
};
```

This pattern eliminates leak bugs: even if `loadBytes` allocates 50 things and `parseAsset`
allocates 100 more, they're all freed when the arena dies. Only `persistAsset`'s output
survives.

## Comptime-driven configuration

Use comptime to generate type-specific code:

```zig
fn ComponentStorage(comptime T: type) type {
    return struct {
        const Self = @This();
        items: [MAX_ENTITIES]T,
        sparse: [MAX_ENTITIES]u32,   // entity_index -> dense_index
        dense: [MAX_ENTITIES]u32,    // dense_index -> entity_index
        len: u32 = 0,

        pub fn init() Self {
            return .{
                .items = undefined,
                .sparse = std.mem.zeroes([MAX_ENTITIES]u32),
                .dense = std.mem.zeroes([MAX_ENTITIES]u32),
            };
        }

        pub fn insert(self: *Self, entity: u32, item: T) void {
            const dense_idx = self.len;
            self.items[dense_idx] = item;
            self.dense[dense_idx] = entity;
            self.sparse[entity] = dense_idx;
            self.len += 1;
        }

        pub fn get(self: *Self, entity: u32) ?*T {
            const dense_idx = self.sparse[entity];
            if (dense_idx >= self.len) return null;
            if (self.dense[dense_idx] != entity) return null;
            return &self.items[dense_idx];
        }
    };
}

const PositionStorage = ComponentStorage(Position);
const VelocityStorage = ComponentStorage(Velocity);
```

The same code works for any component type — no runtime polymorphism, no vtable lookups.

## Result types and error chaining

Zig doesn't have Rust's `Result<T, E>` as a first-class type, but you can build it:

```zig
fn Result(comptime T: type, comptime E: type) type {
    return union(enum) { ok: T, err: E };
}

const FetchResult = Result([]u8, FetchError);

fn fetch(io: std.Io, url: []const u8) FetchResult {
    // ...
    if (conn_failed) return .{ .err = .network };
    return .{ .ok = body };
}

// Usage
const r = fetch(io, "https://example.com");
switch (r) {
    .ok => |body| io.out().print("got {d} bytes\n", .{body.len}) catch {},
    .err => |e| io.err().print("fetch failed: {s}\n", .{@tagName(e)}) catch {},
}
```

Use this when you want to carry a typed error through code that doesn't use Zig's
`!T` syntax (e.g. across a callback boundary, or when chaining multiple operations with
different error sets).

## Builder DSLs with `@Type` replaced

Before 0.16, you might have used `@Type` to generate a struct from a builder description.
Now use the specialized builtins:

```zig
fn StructBuilder(comptime fields: []const struct { name: []const u8, type: type }) type {
    var field_arr: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |f, i| {
        field_arr[i] = .{
            .name = f.name,
            .type = f.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(f.type),
        };
    }
    return @Struct(.{
        .layout = .auto,
        .fields = &field_arr,
        .decls = &.{},
        .is_tuple = false,
    });
}

const Point = StructBuilder(&.{
    .{ .name = "x", .type = f32 },
    .{ .name = "y", .type = f32 },
});
```

## Testing with `Io.failing`

`Io.failing` is the killer test tool: every I/O operation returns an error, which lets you
verify your error handling without mocking.

```zig
test "loadAsset returns NetworkError on connection failure" {
    var io_state = std.testing.io;
    io_state.fail_next = .network;   // first network op fails
    const io = &io_state.io;

    const loader = AssetLoader{ .io = io, .gpa = std.testing.allocator };
    try std.testing.expectError(error.Network, loader.loadAsset("foo.png"));
}
```

`std.testing.io` also captures stdout/stderr so you can assert on log output.

## Logging with structured output

Don't reach for `std.log` for everything — it's still available, but for structured logs
use the Io's writer directly:

```zig
const Logger = struct {
    io: std.Io,
    w: std.Io.Writer,   // typically init.io.err() with a fixed buffer

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.w.print("[info] " ++ fmt ++ "\n", args) catch {};
        self.w.flush() catch {};
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.w.print("[err ] " ++ fmt ++ "\n", args) catch {};
        self.w.flush() catch {};
    }
};
```

For JSON-structured logs, use `std.json.stringify` into the writer.

## See also

- [code-review.md](code-review.md) — What to look for in 0.16 PRs
- [migration-015-016.md](migration-015-016.md) — Porting an existing codebase
