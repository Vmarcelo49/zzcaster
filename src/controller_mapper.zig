const std = @import("std");
const gamepad = @import("gamepad.zig");
const logging = @import("logging.zig");

const c = gamepad.c;

// Win32 for keyboard polling
const win32 = struct {
    extern "user32" fn GetAsyncKeyState(vKey: c_int) callconv(.winapi) i16;
};

// ============================================================================
// Input Binding Types
// ============================================================================

pub const InputType = enum(u8) {
    none,
    sdl_button,
    sdl_axis_pos,
    sdl_axis_neg,
    sdl_hat,
    keyboard_key,
};

pub const InputBinding = struct {
    type: InputType = .none,
    index: u16 = 0, // For sdl_hat: (direction << 8) | hat_index

    pub fn label(self: InputBinding, buf: []u8) []const u8 {
        return switch (self.type) {
            .none => "—",
            .sdl_button => std.fmt.bufPrint(buf, "Btn {d}", .{self.index}) catch "Btn",
            .sdl_axis_pos => std.fmt.bufPrint(buf, "Ax {d}+", .{self.index}) catch "Ax+",
            .sdl_axis_neg => std.fmt.bufPrint(buf, "Ax {d}-", .{self.index}) catch "Ax-",
            .sdl_hat => blk: {
                const hat_idx = self.index & 0xFF;
                const dir: u8 = @intCast(self.index >> 8);
                const dir_str: []const u8 = switch (dir) {
                    1 => "DL", 2 => "D", 3 => "DR",
                    4 => "L", 6 => "R",
                    7 => "UL", 8 => "U", 9 => "UR",
                    else => "?",
                };
                break :blk std.fmt.bufPrint(buf, "Hat{d} {s}", .{ hat_idx, dir_str }) catch "Hat";
            },
            .keyboard_key => std.fmt.bufPrint(buf, "Key 0x{x:0>2}", .{self.index}) catch "Key",
        };
    }

    pub fn serialize(self: InputBinding, buf: []u8) []const u8 {
        return switch (self.type) {
            .none => std.fmt.bufPrint(buf, "none", .{}) catch "none",
            .sdl_button => std.fmt.bufPrint(buf, "btn:{d}", .{self.index}) catch "btn:0",
            .sdl_axis_pos => std.fmt.bufPrint(buf, "axp:{d}", .{self.index}) catch "axp:0",
            .sdl_axis_neg => std.fmt.bufPrint(buf, "axn:{d}", .{self.index}) catch "axn:0",
            .sdl_hat => std.fmt.bufPrint(buf, "hat:{d}:{d}", .{ self.index & 0xFF, self.index >> 8 }) catch "hat:0:0",
            .keyboard_key => std.fmt.bufPrint(buf, "key:{d}", .{self.index}) catch "key:0",
        };
    }

    pub fn parse(str: []const u8) InputBinding {
        if (std.mem.eql(u8, str, "none")) return .{};
        if (std.mem.startsWith(u8, str, "btn:")) {
            const idx = std.fmt.parseInt(u16, str[4..], 10) catch return .{};
            return .{ .type = .sdl_button, .index = idx };
        }
        if (std.mem.startsWith(u8, str, "axp:")) {
            const idx = std.fmt.parseInt(u16, str[4..], 10) catch return .{};
            return .{ .type = .sdl_axis_pos, .index = idx };
        }
        if (std.mem.startsWith(u8, str, "axn:")) {
            const idx = std.fmt.parseInt(u16, str[4..], 10) catch return .{};
            return .{ .type = .sdl_axis_neg, .index = idx };
        }
        if (std.mem.startsWith(u8, str, "hat:")) {
            // hat:hat_idx:direction
            const rest = str[4..];
            const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return .{};
            const hat_idx = std.fmt.parseInt(u16, rest[0..colon], 10) catch return .{};
            const dir = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return .{};
            return .{ .type = .sdl_hat, .index = (dir << 8) | hat_idx };
        }
        if (std.mem.startsWith(u8, str, "key:")) {
            const idx = std.fmt.parseInt(u16, str[4..], 10) catch return .{};
            return .{ .type = .keyboard_key, .index = idx };
        }
        return .{};
    }
};

pub const ControllerMapping = struct {
    a: InputBinding = .{ .type = .sdl_button, .index = 0 },
    b: InputBinding = .{ .type = .sdl_button, .index = 1 },
    c: InputBinding = .{ .type = .sdl_button, .index = 2 },
    d: InputBinding = .{ .type = .sdl_button, .index = 3 },
    e: InputBinding = .{ .type = .sdl_button, .index = 4 },
    ab: InputBinding = .{ .type = .sdl_button, .index = 5 },
    start: InputBinding = .{ .type = .sdl_button, .index = 7 },
    fn1: InputBinding = .{},
    fn2: InputBinding = .{},
    up: InputBinding = .{ .type = .sdl_hat, .index = (8 << 8) | 0 },
    down: InputBinding = .{ .type = .sdl_hat, .index = (2 << 8) | 0 },
    left: InputBinding = .{ .type = .sdl_hat, .index = (4 << 8) | 0 },
    right: InputBinding = .{ .type = .sdl_hat, .index = (6 << 8) | 0 },
    stick_x_axis: u8 = 0,
    stick_y_axis: u8 = 1,
    deadzone: u32 = 8000,
    socd_mode: u8 = 1, // 1=L+R negate, 2=U+D negate, 3=both (0 unused, normalized to 1)
    device_index: c_int = 0, // -1 = keyboard
};

pub const BindingTarget = enum {
    none,
    a, b, c, d, e, ab,
    start, fn1, fn2,
    up, down, left, right,
};

// ============================================================================
// Input Polling for Click-to-Bind
// ============================================================================

/// Poll the given joystick (or keyboard if device_index == -1) for any input.
/// Returns the first detected input as an InputBinding, or null if nothing
/// is pressed. Used by the controller mapper's click-to-bind UI.
/// joy is ?*anyopaque to avoid SDL type mismatch between different @cImport instances.
pub fn pollForBindInput(joy: ?*anyopaque, device_index: c_int) ?InputBinding {
    if (device_index >= 0) {
        if (joy == null) return null;
        const j: ?*c.SDL_Joystick = @ptrCast(joy);

        // Check buttons first (highest priority)
        const num_buttons = c.SDL_JoystickNumButtons(j);
        var i: c_int = 0;
        while (i < num_buttons) : (i += 1) {
            if (c.SDL_JoystickGetButton(j, i) != 0) {
                return .{ .type = .sdl_button, .index = @intCast(i) };
            }
        }

        // Check axes — use high threshold to avoid trigger noise.
        // Analog triggers on Xbox controllers rest at -32768 and move toward 0
        // when pressed. We skip axes at exactly -32768 (trigger at rest) and
        // require significant movement (>20000) for stick axes.
        const num_axes = c.SDL_JoystickNumAxes(j);
        i = 0;
        while (i < num_axes) : (i += 1) {
            const val = c.SDL_JoystickGetAxis(j, i);
            // Skip triggers at rest (value == -32768)
            if (val == -32768) continue;
            // Positive direction (stick right/down, trigger pressed)
            if (val > 20000) return .{ .type = .sdl_axis_pos, .index = @intCast(i) };
            // Negative direction (stick left/up) — but not trigger resting
            if (val < -20000 and val > -32000) return .{ .type = .sdl_axis_neg, .index = @intCast(i) };
        }

        // Check hats
        const num_hats = c.SDL_JoystickNumHats(j);
        i = 0;
        while (i < num_hats) : (i += 1) {
            const hat = c.SDL_JoystickGetHat(j, i);
            if (hat != c.SDL_HAT_CENTERED) {
                var dir: u16 = 5;
                if (hat & c.SDL_HAT_UP != 0) dir = 8;
                if (hat & c.SDL_HAT_DOWN != 0) dir = 2;
                if (hat & c.SDL_HAT_LEFT != 0) dir -|= 1;
                if (hat & c.SDL_HAT_RIGHT != 0) dir +|= 1;
                if (dir != 5) return .{ .type = .sdl_hat, .index = (dir << 8) | @as(u16, @intCast(i)) };
            }
        }
    } else {
        // Keyboard: poll all VK codes (skip mouse buttons 0x01-0x06)
        var vk: c_int = 0x08;
        while (vk <= 0xFE) : (vk += 1) {
            if (win32.GetAsyncKeyState(vk) & @as(i16, @bitCast(@as(u16, 0x8000))) != 0) {
                return .{ .type = .keyboard_key, .index = @intCast(vk) };
            }
        }
    }
    return null;
}

/// Default Xbox controller mapping for MBAA.
/// MBAA button → Xbox button (raw SDL_Joystick button index):
///   A → X (btn 2), B → Y (btn 3), C → B (btn 1), D → A (btn 0)
///   E → LB (btn 4), A+B → RB (btn 5)
///   Start → Start (btn 7), FN1 → Select/Back (btn 6), FN2 → R-Stick press (btn 9)
///   Directions → D-pad hat 0
pub fn defaultXboxMapping() ControllerMapping {
    return .{
        .a = .{ .type = .sdl_button, .index = 2 },   // X
        .b = .{ .type = .sdl_button, .index = 3 },   // Y
        .c = .{ .type = .sdl_button, .index = 1 },   // B
        .d = .{ .type = .sdl_button, .index = 0 },   // A
        .e = .{ .type = .sdl_button, .index = 4 },   // LB
        .ab = .{ .type = .sdl_button, .index = 5 },  // RB
        .start = .{ .type = .sdl_button, .index = 7 }, // Start
        .fn1 = .{ .type = .sdl_button, .index = 6 }, // Select/Back
        .fn2 = .{ .type = .sdl_button, .index = 9 }, // R-Stick press
        .up = .{ .type = .sdl_hat, .index = (8 << 8) | 0 },
        .down = .{ .type = .sdl_hat, .index = (2 << 8) | 0 },
        .left = .{ .type = .sdl_hat, .index = (4 << 8) | 0 },
        .right = .{ .type = .sdl_hat, .index = (6 << 8) | 0 },
        .stick_x_axis = 0,
        .stick_y_axis = 1,
        .deadzone = 8000,
        .socd_mode = 1,
        .device_index = 0,
    };
}

// ============================================================================
// Read Input Using Mapping (for the DLL's GamepadReader)
// ============================================================================

/// Read a single binding's state (true = pressed).
///
/// `deadzone` only affects `.sdl_axis_pos` / `.sdl_axis_neg` bindings — it's
/// the absolute value (0..32767) above which an axis is considered "pressed".
/// Passing the user-configurable `m.deadzone` here (instead of a hardcoded
/// 8000) ensures that axis-bound buttons (e.g. D-pad mapped to left stick)
/// respect the deadzone slider in the GUI. Otherwise a higher deadzone set
/// to suppress stick drift would have no effect on axis bindings.
fn isBindingActive(binding: InputBinding, joy: ?*anyopaque, deadzone: u32) bool {
    return switch (binding.type) {
        .none => false,
        .sdl_button => joy != null and c.SDL_JoystickGetButton(@ptrCast(joy), binding.index) != 0,
        .sdl_axis_pos => joy != null and c.SDL_JoystickGetAxis(@ptrCast(joy), binding.index) > @as(c_int, @intCast(deadzone)),
        .sdl_axis_neg => joy != null and c.SDL_JoystickGetAxis(@ptrCast(joy), binding.index) < -@as(c_int, @intCast(deadzone)),
        .sdl_hat => blk: {
            if (joy == null) break :blk false;
            const hat_idx: c_int = @intCast(binding.index & 0xFF);
            const dir: u8 = @intCast(binding.index >> 8);
            const hat = c.SDL_JoystickGetHat(@ptrCast(joy), hat_idx);
            const matched = switch (dir) {
                1 => (hat & c.SDL_HAT_LEFT != 0) and (hat & c.SDL_HAT_DOWN != 0),
                2 => (hat & c.SDL_HAT_DOWN != 0) and (hat & c.SDL_HAT_LEFT == 0) and (hat & c.SDL_HAT_RIGHT == 0),
                3 => (hat & c.SDL_HAT_RIGHT != 0) and (hat & c.SDL_HAT_DOWN != 0),
                4 => (hat & c.SDL_HAT_LEFT != 0) and (hat & c.SDL_HAT_UP == 0) and (hat & c.SDL_HAT_DOWN == 0),
                6 => (hat & c.SDL_HAT_RIGHT != 0) and (hat & c.SDL_HAT_UP == 0) and (hat & c.SDL_HAT_DOWN == 0),
                7 => (hat & c.SDL_HAT_LEFT != 0) and (hat & c.SDL_HAT_UP != 0),
                8 => (hat & c.SDL_HAT_UP != 0) and (hat & c.SDL_HAT_LEFT == 0) and (hat & c.SDL_HAT_RIGHT == 0),
                9 => (hat & c.SDL_HAT_RIGHT != 0) and (hat & c.SDL_HAT_UP != 0),
                else => false,
            };
            break :blk matched;
        },
        .keyboard_key => (win32.GetAsyncKeyState(@intCast(binding.index)) & @as(i16, @bitCast(@as(u16, 0x8000)))) != 0,
    };
}

/// Read input using a ControllerMapping. Returns the MBAA combined input u16.
pub fn readInputMapped(joy: ?*anyopaque, m: ControllerMapping) u16 {
    const dz = m.deadzone;

    // Directions
    var up = isBindingActive(m.up, joy, dz);
    var down = isBindingActive(m.down, joy, dz);
    var left = isBindingActive(m.left, joy, dz);
    var right = isBindingActive(m.right, joy, dz);

    // Analog stick also contributes to directions
    if (joy != null) {
        const x = c.SDL_JoystickGetAxis(@ptrCast(joy), m.stick_x_axis);
        const y = c.SDL_JoystickGetAxis(@ptrCast(joy), m.stick_y_axis);
        if (x > @as(c_int, @intCast(m.deadzone))) right = true else if (x < -@as(c_int, @intCast(m.deadzone))) left = true;
        if (y > @as(c_int, @intCast(m.deadzone))) down = true else if (y < -@as(c_int, @intCast(m.deadzone))) up = true;
    }

    // SOCD resolution
    const socd = m.socd_mode;
    if ((socd & 1) != 0 and left and right) { left = false; right = false; }
    if ((socd & 2) != 0 and up and down) { up = false; down = false; }

    // Direction to numpad (start at 5=neutral so +/-1 yields 4=L, 6=R)
    var dir: u16 = 5;
    if (up) dir = 8 else if (down) dir = 2;
    if (left) dir -|= 1 else if (right) dir +|= 1;
    if (dir == 5) dir = 0;

    // Buttons
    var btns: u16 = 0;
    if (isBindingActive(m.a, joy, dz)) btns |= gamepad.button_a;
    if (isBindingActive(m.b, joy, dz)) btns |= gamepad.button_b;
    if (isBindingActive(m.c, joy, dz)) btns |= gamepad.button_c;
    if (isBindingActive(m.d, joy, dz)) btns |= gamepad.button_d;
    if (isBindingActive(m.e, joy, dz)) btns |= gamepad.button_e;
    if (isBindingActive(m.ab, joy, dz)) btns |= gamepad.button_ab;
    if (isBindingActive(m.start, joy, dz)) btns |= gamepad.button_start;
    if (isBindingActive(m.fn1, joy, dz)) btns |= 0x0100; // FN1
    if (isBindingActive(m.fn2, joy, dz)) btns |= 0x0200; // FN2
    if (btns & gamepad.button_a != 0) btns |= gamepad.button_confirm;
    if (btns & gamepad.button_b != 0) btns |= gamepad.button_cancel;

    return dir | (btns << 4);
}

// ============================================================================
// Save / Load Mapping
// ============================================================================

pub fn saveMapping(p1: ControllerMapping, p2: ControllerMapping, path: []const u8, io: std.Io, log: *logging.Logger) void {
    // Ensure the parent directory exists. createFile does NOT create
    // intermediate directories — if "zzcaster/" doesn't exist yet (e.g.
    // first run), the save would silently fail.
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) {
            std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        }
    }

    // Build the INI content in a fixed memory buffer first, then write it
    // to the file in a single call. This avoids the buffered-writer issues
    // that previously left the file empty (file.writer(&buf) + w.print +
    // w.flush silently produced 0-byte files because the print errors were
    // swallowed by catch {}).
    var content_buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&content_buf);
    var buf: [64]u8 = undefined;

    w.print("[Player1]\ndevice={d}\n", .{p1.device_index}) catch {
        log.warn("saveMapping: P1 header write failed", .{});
        return;
    };
    w.print("a={s}\n", .{p1.a.serialize(&buf)}) catch {};
    w.print("b={s}\n", .{p1.b.serialize(&buf)}) catch {};
    w.print("c={s}\n", .{p1.c.serialize(&buf)}) catch {};
    w.print("d={s}\n", .{p1.d.serialize(&buf)}) catch {};
    w.print("e={s}\n", .{p1.e.serialize(&buf)}) catch {};
    w.print("ab={s}\n", .{p1.ab.serialize(&buf)}) catch {};
    w.print("start={s}\n", .{p1.start.serialize(&buf)}) catch {};
    w.print("fn1={s}\n", .{p1.fn1.serialize(&buf)}) catch {};
    w.print("fn2={s}\n", .{p1.fn2.serialize(&buf)}) catch {};
    w.print("up={s}\n", .{p1.up.serialize(&buf)}) catch {};
    w.print("down={s}\n", .{p1.down.serialize(&buf)}) catch {};
    w.print("left={s}\n", .{p1.left.serialize(&buf)}) catch {};
    w.print("right={s}\n", .{p1.right.serialize(&buf)}) catch {};
    w.print("stick_x={d}\nstick_y={d}\ndeadzone={d}\nsocd={d}\n", .{
        p1.stick_x_axis, p1.stick_y_axis, p1.deadzone, p1.socd_mode,
    }) catch {};

    w.print("\n[Player2]\ndevice={d}\n", .{p2.device_index}) catch {};
    w.print("a={s}\n", .{p2.a.serialize(&buf)}) catch {};
    w.print("b={s}\n", .{p2.b.serialize(&buf)}) catch {};
    w.print("c={s}\n", .{p2.c.serialize(&buf)}) catch {};
    w.print("d={s}\n", .{p2.d.serialize(&buf)}) catch {};
    w.print("e={s}\n", .{p2.e.serialize(&buf)}) catch {};
    w.print("ab={s}\n", .{p2.ab.serialize(&buf)}) catch {};
    w.print("start={s}\n", .{p2.start.serialize(&buf)}) catch {};
    w.print("fn1={s}\n", .{p2.fn1.serialize(&buf)}) catch {};
    w.print("fn2={s}\n", .{p2.fn2.serialize(&buf)}) catch {};
    w.print("up={s}\n", .{p2.up.serialize(&buf)}) catch {};
    w.print("down={s}\n", .{p2.down.serialize(&buf)}) catch {};
    w.print("left={s}\n", .{p2.left.serialize(&buf)}) catch {};
    w.print("right={s}\n", .{p2.right.serialize(&buf)}) catch {};
    w.print("stick_x={d}\nstick_y={d}\ndeadzone={d}\nsocd={d}\n", .{
        p2.stick_x_axis, p2.stick_y_axis, p2.deadzone, p2.socd_mode,
    }) catch {};

    const written = w.buffered();
    log.info("saveMapping: built {d} bytes of INI content", .{written.len});

    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch {
        log.warn("Failed to create mapping file {s}", .{path});
        return;
    };
    defer file.close(io);

    file.writeStreamingAll(io, written) catch {
        log.warn("Failed to write mapping to {s}", .{path});
        return;
    };

    log.info("Mapping saved to {s} ({d} bytes)", .{ path, written.len });
}

pub fn loadMapping(path: []const u8, io: std.Io, log: *logging.Logger) ?struct { p1: ControllerMapping, p2: ControllerMapping } {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        log.info("loadMapping: openFile('{s}') failed: {s}", .{ path, @errorName(err) });
        return null;
    };
    defer file.close(io);

    // Read the file into a fixed buffer. readSliceShort returns the number
    // of bytes actually read (0 for empty files) instead of erroring with
    // EndOfStream like readAlloc does.
    var read_buf: [8192]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const len = reader.interface.readSliceShort(&read_buf) catch |err| {
        log.warn("loadMapping: readSliceShort failed: {s}", .{@errorName(err)});
        return null;
    };

    if (len == 0) {
        log.warn("loadMapping: file is empty (0 bytes read from {s})", .{path});
        return null;
    }

    const data = read_buf[0..len];
    log.info("loadMapping: read {d} bytes from {s}", .{ len, path });

    var p1 = ControllerMapping{};
    var p2 = ControllerMapping{};
    var current: *ControllerMapping = &p1;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '[') {
            if (std.mem.startsWith(u8, trimmed, "[Player2]")) current = &p2;
            if (std.mem.startsWith(u8, trimmed, "[Player1]")) current = &p1;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " ");
        const val = std.mem.trim(u8, trimmed[eq + 1 ..], " ");

        if (std.mem.eql(u8, key, "device")) {
            current.device_index = std.fmt.parseInt(c_int, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "stick_x")) {
            current.stick_x_axis = std.fmt.parseInt(u8, val, 10) catch 0;
        } else if (std.mem.eql(u8, key, "stick_y")) {
            current.stick_y_axis = std.fmt.parseInt(u8, val, 10) catch 1;
        } else if (std.mem.eql(u8, key, "deadzone")) {
            current.deadzone = std.fmt.parseInt(u32, val, 10) catch 8000;
        } else if (std.mem.eql(u8, key, "socd")) {
            current.socd_mode = std.fmt.parseInt(u8, val, 10) catch 1;
        } else {
            const binding = InputBinding.parse(val);
            if (std.mem.eql(u8, key, "a")) current.a = binding;
            if (std.mem.eql(u8, key, "b")) current.b = binding;
            if (std.mem.eql(u8, key, "c")) current.c = binding;
            if (std.mem.eql(u8, key, "d")) current.d = binding;
            if (std.mem.eql(u8, key, "e")) current.e = binding;
            if (std.mem.eql(u8, key, "ab")) current.ab = binding;
            if (std.mem.eql(u8, key, "start")) current.start = binding;
            if (std.mem.eql(u8, key, "fn1")) current.fn1 = binding;
            if (std.mem.eql(u8, key, "fn2")) current.fn2 = binding;
            if (std.mem.eql(u8, key, "up")) current.up = binding;
            if (std.mem.eql(u8, key, "down")) current.down = binding;
            if (std.mem.eql(u8, key, "left")) current.left = binding;
            if (std.mem.eql(u8, key, "right")) current.right = binding;
        }
    }

    log.info("Mapping loaded from {s} (P1 device={d}, P2 device={d})", .{ path, p1.device_index, p2.device_index });
    return .{ .p1 = p1, .p2 = p2 };
}
