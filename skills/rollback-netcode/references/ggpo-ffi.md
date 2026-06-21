# Calling the C++ GGPO SDK from Zig via FFI

Sometimes you don't want to write rollback from scratch. The C++ GGPO SDK is mature,
battle-tested, and shipped in dozens of commercial games. This file shows how to call it
from Zig 0.16.

## Table of contents

1. [Why use the C++ SDK](#why-use-the-c-sdk)
2. [The SDK layout](#the-sdk-layout)
3. [Build setup](#build-setup)
4. [The `extern "C"` surface](#the-extern-c-surface)
5. [Session lifecycle](#session-lifecycle)
6. [The seven callbacks](#the-seven-callbacks)
7. [The missing `user_data` parameter](#the-missing-user_data-parameter)
8. [SyncTest via the SDK](#synctest-via-the-sdk)
9. [Spectating](#spectating)
10. [Threading model](#threading-model)
11. [Gotchas](#gotchas)

## Why use the C++ SDK

Reasons to use the C++ SDK instead of writing from scratch:

1. **Mature.** Shipped in Skullgirls, Killer Instinct, Fightcade, and many others. Edge
   cases are handled.
2. **Battle-tested networking.** The UDP protocol has been tuned over 15+ years of real-
   world play.
3. **Interop with Fightcade.** If you want your game to be playable on Fightcade, you
   need to use the SDK's wire protocol.
4. **Less code to write.** ~5000 LOC of C++ vs ~1000 LOC of Zig you'd write yourself.

Reasons to write from scratch (covered in the rest of this skill):

1. **No C++ compiler needed.** Your build is pure Zig + C.
2. **Better integration with Zig 0.16 Io.** The C++ SDK has its own threading; mixing it
   with `Io.Evented` is awkward.
3. **Smaller binary.** The C++ SDK pulls in its own STL.
4. **You want to learn.** Writing it from scratch is the only way to truly understand
   the algorithm.

For most projects, "write from scratch" is the better default. Use the C++ SDK if you
need Fightcade compat or you're porting an existing C++ game.

## The SDK layout

The official repo is [github.com/otac0n/GGPO](https://github.com/otac0n/GGPO) (the C#
reference; the C++ original is in `libggpo`). The relevant files:

```text
ggpo/
├── include/
│   └── ggponet.h           — public C API
├── src/
│   ├── libggpo.cpp         — main entry points
│   ├── main.cpp            — implementation
│   ├── sync.cpp            — InputQueue + StateStore
│   ├── network/
│   │   ├── udp.cpp
│   │   └── poll.cpp
│   └── timesync.cpp
└── build/
    └── Makefile            — builds libggpo.a (or .lib on Windows)
```

`ggponet.h` is the entire public surface. It's `extern "C"` so it can be called from
any language, including Zig.

## Build setup

### Step 1: Build libggpo

```bash
git clone https://github.com/otac0n/GGPO.git
cd GGPO
make -C build
```

This produces `build/libggpo.a` (or `.lib` on Windows). Copy it into your project:

```bash
mkdir -p vendor/ggpo/lib
cp build/libggpo.a vendor/ggpo/lib/
cp -r include vendor/ggpo/
```

### Step 2: Configure `build.zig`

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = exe_mod,
    });

    // Link libggpo
    exe.addLibraryPath(b.path("vendor/ggpo/lib"));
    exe.linkSystemLibrary("ggpo");
    exe.addIncludePath(b.path("vendor/ggpo/include"));

    // On Windows, link ws2_32 (winsock) — required by GGPO's UDP code
    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ws2_32");
    }

    // Translate ggponet.h to a Zig module
    const c_mod = b.addTranslateC(.{
        .root_source_file = b.path("src/ggpo_imports.h"),
        .target = target,
        .optimize = optimize,
    });
    c_mod.addIncludePath(b.path("vendor/ggpo/include"));
    exe_mod.addImport("c", c_mod);

    // GGPO needs libc for socket APIs
    exe.linkLibC();
    // GGPO is C++, so link C++ runtime
    exe.linkLibCpp();

    b.installArtifact(exe);
}
```

### Step 3: The umbrella header

```c
// src/ggpo_imports.h
#include "ggponet.h"
```

### Step 4: Use it from Zig

```zig
// src/main.zig
const std = @import("std");
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Create a session
    var cb: c.GGPOSessionCallbacks = std.mem.zeroes(c.GGPOSessionCallbacks);
    cb.begin_game = beginGame;
    cb.advance_frame = advanceFrame;
    cb.save_game_state = saveGameState;
    cb.load_game_state = loadGameState;
    cb.free_buffer = freeBuffer;
    cb.log_game_state = logGameState;
    cb.on_event = onEvent;

    var session: c.GGPOSession = undefined;
    var players: [2]c.GGPOPlayer = undefined;
    players[0].size = @sizeOf(c.GGPOPlayer);
    players[0].type = c.GGPOPlayerType.GGPO_PLAYERTYPE_LOCAL;
    players[1].size = @sizeOf(c.GGPOPlayer);
    players[1].type = c.GGPOPlayerType.GGPO_PLAYERTYPE_REMOTE;
    players[1].remote.ip_address = "127.0.0.1";
    players[1].remote.port = 7001;

    var handles: [2]c.GGPOPlayerHandle = undefined;
    var result = c.ggpo_start_session(
        &session,
        &cb,
        "my_game",
        2,
        sizeof(c.int),
        7000,   // local port
    );
    if (result != c.GGPOErrorCode.GGPO_OK) return error.GGPOStartFailed;

    for (players, 0..) |p, i| {
        result = c.ggpo_add_player(session, &p, &handles[i]);
        if (result != c.GGPOErrorCode.GGPO_OK) return error.GGPOAddPlayerFailed;
    }

    // Main loop
    while (true) {
        _ = c.ggpo_idle(session, 0);

        // Read local input
        var input: c.int = 0;
        if (readLocalInput(&input)) {
            _ = c.ggpo_add_local_input(session, handles[0], &input, @sizeOf(c.int));
        }

        _ = c.ggpo_advance_frame(session);
    }
}
```

## The `extern "C"` surface

`ggponet.h` exposes the full API as `extern "C"` functions. Key entries:

```c
// Session lifecycle
GGPOErrorCode ggpo_start_session(GGPOSession**, GGPOSessionCallbacks*,
                                  const char*, int, int, int);
GGPOErrorCode ggpo_start_synctest(GGPOSession**, GGPOSessionCallbacks*,
                                   const char*, int, int, int);
GGPOErrorCode ggpo_start_spectating(GGPOSession**, GGPOSessionCallbacks*,
                                     const char*, int, int, int, int, char*, int);
GGPOErrorCode ggpo_close_session(GGPOSession*);

// Player management
GGPOErrorCode ggpo_add_player(GGPOSession*, GGPOPlayer*, GGPOPlayerHandle*);
GGPOErrorCode ggpo_set_frame_delay(GGPOSession*, GGPOPlayerHandle, int);

// Per-frame
GGPOErrorCode ggpo_idle(GGPOSession*, int timeout_ms);
GGPOErrorCode ggpo_add_local_input(GGPOSession*, GGPOPlayerHandle,
                                    void* values, int size);
GGPOErrorCode ggpo_advance_frame(GGPOSession*);

// Sync
GGPOErrorCode ggpo_synchronize_input(GGPOSession*, void* values, int size,
                                      int* disconnect_flags);
```

From Zig, all of these are accessible via `@import("c").ggpo_*`.

## Session lifecycle

The C++ SDK uses an opaque `GGPOSession*` handle. You create it with one of:

- `ggpo_start_session` — peer-to-peer play
- `ggpo_start_synctest` — SyncTest mode (no network)
- `ggpo_start_spectating` — spectator mode

After creation:

1. Add players via `ggpo_add_player`.
2. Optionally set frame delay via `ggpo_set_frame_delay`.
3. Enter the main loop: `ggpo_idle` → `ggpo_add_local_input` → `ggpo_advance_frame`.
4. On exit, `ggpo_close_session`.

```zig
const SESSION_STEPS = struct {
    fn create(callbacks: *c.GGPOSessionCallbacks) !c.GGPOSession {
        var session: c.GGPOSession = undefined;
        const result = c.ggpo_start_session(
            &session, callbacks, "my_game", 2, @sizeOf(c.int), 7000,
        );
        if (result != c.GGPOErrorCode.GGPO_OK) return error.GGPOStartFailed;
        return session;
    }

    fn addPlayers(session: c.GGPOSession) ![2]c.GGPOPlayerHandle {
        var players: [2]c.GGPOPlayer = std.mem.zeroes([2]c.GGPOPlayer);
        players[0].size = @sizeOf(c.GGPOPlayer);
        players[0].type = c.GGPOPlayerType.GGPO_PLAYERTYPE_LOCAL;

        players[1].size = @sizeOf(c.GGPOPlayer);
        players[1].type = c.GGPOPlayerType.GGPO_PLAYERTYPE_REMOTE;
        @memcpy(players[1].remote.ip_address[0..9], "127.0.0.1");
        players[1].remote.port = 7001;

        var handles: [2]c.GGPOPlayerHandle = undefined;
        for (players, 0..) |*p, i| {
            const result = c.ggpo_add_player(session, p, &handles[i]);
            if (result != c.GGPOErrorCode.GGPO_OK) return error.GGPOAddPlayerFailed;
        }
        return handles;
    }
};
```

## The seven callbacks

The C++ SDK calls back into your game via function pointers. You provide them in
`GGPOSessionCallbacks`:

```zig
fn beginGame(game: [*c]u8) callconv(.c) c_int {
    // Called once when the session starts.
    return 0;
}

fn advanceFrame(checksum: c_int) callconv(.c) c_int {
    // The sim should advance by one frame using the synchronized inputs.
    // Get them via ggpo_synchronize_input first.
    var inputs: c.int = 0;
    var flags: c_int = 0;
    _ = c.ggpo_synchronize_input(SESSION, &inputs, @sizeOf(c.int), &flags);

    GAME_STATE.advanceFrame(inputs) catch return -1;
    return 0;
}

fn saveGameState(values: [*c][*c]u8, len: [*c]c_int, checksum: [*c]c_int, frame: c_int) callconv(.c) c_int {
    // Serialize the current state into a buffer.
    const buf = GAME_STATE.serialize(GLOBAL_ALLOCATOR) catch return -1;
    values.* = buf.ptr;
    len.* = @intCast(buf.len);
    checksum.* = @intCast(GAME_STATE.checksum());
    return 0;
}

fn loadGameState(values: [*c]const u8, len: c_int) callconv(.c) c_int {
    // Deserialize a previously-saved buffer.
    GAME_STATE.deserialize(values[0..@intCast(len)]) catch return -1;
    return 0;
}

fn freeBuffer(buffer: [*c]u8) callconv(.c) void {
    // Free a buffer previously allocated by saveGameState.
    GLOBAL_ALLOCATOR.free(std.mem.span(buffer));
}

fn logGameState(label: [*c]const u8, values: [*c]const u8, len: c_int) callconv(.c) void {
    // Debug logging — pretty-print the state.
}

fn onEvent(info: [*c]c.GGPOEvent) callconv(.c) c_int {
    // Handle async events.
    switch (info.*.code) {
        c.GGPOEventCode.GGPO_EVENTCODE_CONNECTED_TO_CLIENT => {},
        c.GGPOEventCode.GGPO_EVENTCODE_SYNCHRONIZED_WITH_CLIENT => {},
        c.GGPOEventCode.GGPO_EVENTCODE_RUNNING => {},
        c.GGPOEventCode.GGPO_EVENTCODE_DISCONNECTED_FROM_CLIENT => {},
        c.GGPOEventCode.GGPO_EVENTCODE_TIMESYNC => {
            // Sleep info.*.u.timesync.frames_ahead frames on next idle.
        },
        else => {},
    }
    return 0;
}
```

Note the `callconv(.c)` — required for any function passed across the FFI boundary.

## The missing `user_data` parameter

The C++ SDK's callbacks don't take a `void* user_data` parameter. They expect you to use
**globals** to communicate with your game state. This is the single biggest friction
point when integrating with Zig.

In the example above, `GAME_STATE` and `SESSION` are global `var`s. This works for a
single-session game (which is most games), but breaks if you ever want:

- Multiple sessions in one process (e.g. for testing).
- A library that wraps GGPO and doesn't want to leak globals.
- A test harness that runs many sessions.

### Workaround 1: globals

The pragmatic approach. Just use globals:

```zig
var GAME_STATE: *GameState = undefined;
var SESSION: c.GGPOSession = undefined;
var GLOBAL_ALLOCATOR: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    GLOBAL_ALLOCATOR = init.gpa;
    GAME_STATE = try init.gpa.create(GameState);
    defer init.gpa.destroy(GAME_STATE);

    SESSION = try SESSION_STEPS.create(&callbacks);
    defer _ = c.ggpo_close_session(SESSION);

    // ... main loop ...
}
```

For most games this is fine. The "single session per process" assumption holds.

### Workaround 2: fork the SDK

Most serious downstream users (including Fightcade) fork GGPO to add a `void* user_data`
parameter to every callback. This is a small diff against `ggponet.h` and the
implementation files.

If you're going to fork, fork early — you don't want to redo it after building a lot of
integration code.

### Workaround 3: thread-local storage

Use Zig's `threadlocal` to communicate state per-thread:

```zig
threadlocal var GAME_STATE: ?*GameState = null;
threadlocal var SESSION: ?c.GGPOSession = null;

fn saveGameState(values: [*c][*c]u8, len: [*c]c_int, checksum: [*c]c_int, frame: c_int) callconv(.c) c_int {
    const gs = GAME_STATE orelse return -1;
    // ... use gs ...
}
```

This works if you run each session on its own thread. It's more complex than globals but
allows multiple sessions per process.

## SyncTest via the SDK

```zig
var session: c.GGPOSession = undefined;
const result = c.ggpo_start_synctest(
    &session, &callbacks, "my_game", 2, @sizeOf(c.int), 1,   // check_distance = 1
);
if (result != c.GGPOErrorCode.GGPO_OK) return error.SyncTestStartFailed;

// Drive the session with scripted inputs:
for (scripted_inputs) |input| {
    _ = c.ggpo_add_local_input(session, handles[0], &input, @sizeOf(c.int));
    _ = c.ggpo_advance_frame(session);
}
```

The SDK will call `save_game_state` and `load_game_state` automatically as part of the
sync test, and call `on_event` with `GGPO_EVENTCODE_DESYNC` if it detects a divergence.

## Spectating

```zig
var session: c.GGPOSession = undefined;
const result = c.ggpo_start_spectating(
    &session, &callbacks, "my_game", 2, @sizeOf(c.int), 7000,   // local port
    "127.0.0.1", 7001,   // remote broadcaster
);
```

The spectator session receives all inputs over the network, runs the sim deterministically,
and never calls `ggpo_add_local_input`. The seven callbacks are the same as for a regular
session.

## Threading model

GGPO is **single-threaded by contract**. All calls and all callbacks happen on the thread
that called `ggpo_idle`. There is no internal locking.

This is a deliberate design choice — it makes the API simpler and avoids lock contention
on the per-frame hot path. The implication for Zig:

1. Don't call `ggpo_*` from multiple threads.
2. Don't call `ggpo_idle` from inside a callback.
3. If you want to use `Io.Evented` for the rest of your game, do it on a different thread
   from GGPO.

For a simple game, GGPO can run on the main thread and `Io.Threaded` handles everything
else. For a game with heavy I/O (asset streaming, voice chat), put GGPO on its own thread
and use a queue to pass inputs in and events out.

### Mixing GGPO with `Io.Dispatch`

The cleanest integration: use `Io.Dispatch` and pump both GGPO and the Io in the same
loop:

```zig
pub fn main(init: std.process.Init) !void {
    var dispatch: std.Io.Dispatch = .empty;
    dispatch.initContext(init.gpa);
    defer dispatch.deinit(init.gpa);
    const io: std.Io = dispatch.io;

    SESSION = try SESSION_STEPS.create(&callbacks);
    defer _ = c.ggpo_close_session(SESSION);

    while (running) {
        // Pump Io (for asset loading, network, etc.)
        try dispatch.pump();

        // Pump GGPO (with a 16ms timeout to allow it to do its own work)
        _ = c.ggpo_idle(SESSION, 16);

        // Advance the sim
        const input = readLocalInput(io);
        _ = c.ggpo_add_local_input(SESSION, handles[0], &input, @sizeOf(c.int));
        _ = c.ggpo_advance_frame(SESSION);

        // Render
        try render(io);
    }
}
```

This puts everything on one thread, which is what GGPO expects.

## Gotchas

### `sizeof(GGPOPlayer)` must be set

The `GGPOPlayer` struct has a `size` field that must be set to `sizeof(GGPOPlayer)` before
calling `ggpo_add_player`. The SDK uses this for version checking.

```zig
players[0].size = @sizeOf(c.GGPOPlayer);
```

Forget this and you get a confusing `GGPO_ERRORCODE_INVALID_REQUEST`.

### IP address string lifetime

`players[1].remote.ip_address` is a `char[16]` — it's copied into the struct. So:

```zig
// OK — string is copied into the struct
players[1].remote.ip_address = "127.0.0.1";   // actually @memcpy into the [16]u8
```

But if you have a runtime-determined IP:

```zig
// BAD — points to a temporary
const ip = try std.fmt.allocPrint(gpa, "{s}", .{host});
players[1].remote.ip_address = ip.ptr;   // dangling after `gpa.free(ip)`

// GOOD — copy into the struct
@memcpy(players[1].remote.ip_address[0..ip.len], ip);
players[1].remote.ip_address[ip.len] = 0;
```

### `ggpo_idle` timeout semantics

`ggpo_idle(session, timeout_ms)` does two things:
1. Pumps the network for `timeout_ms` milliseconds.
2. Updates internal timers.

If you pass `0`, it pumps non-blocking and returns immediately. If you pass `16`, it
blocks for up to 16ms (which is one frame at 60 FPS).

Don't pass large timeouts (>20ms) — you'll stall the sim.

### `advance_frame` recursion

When a rollback happens, `ggpo_advance_frame` may recursively call your `advance_frame`
callback to replay frames. This is normal — your callback must handle being called
multiple times per `ggpo_advance_frame` call.

If your `advance_frame` callback ever calls `ggpo_*` itself, you'll get a deadlock or
stack overflow. Don't.

### Windows: link ws2_32

On Windows, GGPO's UDP code uses Winsock, which requires linking `ws2_32.lib`. In
`build.zig`:

```zig
if (target.result.os.tag == .windows) {
    exe.linkSystemLibrary("ws2_32");
}
```

(Zig 0.16's std lib no longer needs ws2_32 — but the C++ GGPO SDK still does, because it
was written before that change.)

### Memory ownership

Buffers allocated in `save_game_state` are owned by the SDK until `free_buffer` is called.
Don't free them yourself. The SDK may keep them around for many frames.

Buffers passed to `load_game_state` are still owned by the SDK — don't free them or
modify them.

## See also

- [data-structures.md](data-structures.md) — The from-scratch alternative
- [sync-test.md](sync-test.md) — How SyncTest works under the hood
- [c-interop in the zig-0-16 skill](../../zig-0-16/references/c-interop.md#c-wrappers-you-still-need-a-hand-written-extern-c-shim)
  — More on `extern "C"` shims and `b.addTranslateC`
