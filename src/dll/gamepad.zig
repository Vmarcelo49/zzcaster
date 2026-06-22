const std = @import("std");
const logging = @import("common").logging;

// SDL2 via @cImport — shared with controller_mapper.zig
pub const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

// MBAA button constants
pub const button_a: u16 = 0x0010;
pub const button_b: u16 = 0x0020;
pub const button_c: u16 = 0x0008;
pub const button_d: u16 = 0x0004;
pub const button_e: u16 = 0x0080;
pub const button_ab: u16 = 0x0040;
pub const button_start: u16 = 0x0001;
pub const button_confirm: u16 = 0x0400;
pub const button_cancel: u16 = 0x0800;

pub const deadzone: c_int = 8000;

pub const GamepadMapping = struct {
    up: c_int = c.SDL_CONTROLLER_BUTTON_DPAD_UP,
    down: c_int = c.SDL_CONTROLLER_BUTTON_DPAD_DOWN,
    left: c_int = c.SDL_CONTROLLER_BUTTON_DPAD_LEFT,
    right: c_int = c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
    // MBAACC Community Edition standard layout (matches original CCCaster
    // defaultXboxMapping):
    //   MBAA A ← Xbox X   (SDL_CONTROLLER_BUTTON_X)
    //   MBAA B ← Xbox Y   (SDL_CONTROLLER_BUTTON_Y)
    //   MBAA C ← Xbox B   (SDL_CONTROLLER_BUTTON_B)
    //   MBAA D ← Xbox A   (SDL_CONTROLLER_BUTTON_A)
    // This is the layout the community expects: the bottom face button
    // (A on Xbox) is MBAA's D (the "weak" attack), and the left face
    // button (X on Xbox) is MBAA's A (the "light" attack).
    a: c_int = c.SDL_CONTROLLER_BUTTON_X,
    b: c_int = c.SDL_CONTROLLER_BUTTON_Y,
    c_btn: c_int = c.SDL_CONTROLLER_BUTTON_B,
    d: c_int = c.SDL_CONTROLLER_BUTTON_A,
    e: c_int = c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
    ab: c_int = c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
    start: c_int = c.SDL_CONTROLLER_BUTTON_START,
    stick_x: c_int = c.SDL_CONTROLLER_AXIS_LEFTX,
    stick_y: c_int = c.SDL_CONTROLLER_AXIS_LEFTY,
};

pub const GamepadReader = struct {
    controller: ?*c.SDL_GameController = null,
    joystick: ?*c.SDL_Joystick = null,
    mapping: GamepadMapping = .{},

    // New: optional controller_mapper mapping. If set, uses SDL_Joystick API
    // with the custom mapping instead of the hardcoded GamepadMapping.
    mapped_joystick: ?*anyopaque = null,
    custom_mapping: ?@import("controller_mapper.zig").ControllerMapping = null,

    pub fn init(log: *logging.Logger) GamepadReader {
        var reader = GamepadReader{};

        // Try GameController API first
        const num = c.SDL_NumJoysticks();
        var i: c_int = 0;
        while (i < num) : (i += 1) {
            if (c.SDL_IsGameController(i) != 0) {
                reader.controller = c.SDL_GameControllerOpen(i);
                if (reader.controller != null) {
                    const name = c.SDL_GameControllerName(reader.controller);
                    const name_str: []const u8 = if (name != null) std.mem.span(name) else "unknown";
                    log.info("GamepadReader: opened GameController '{s}'", .{name_str});
                    return reader;
                }
            }
        }

        // Fall back to raw Joystick API
        i = 0;
        while (i < num) : (i += 1) {
            reader.joystick = c.SDL_JoystickOpen(i);
            if (reader.joystick != null) {
                const name = c.SDL_JoystickName(reader.joystick);
                const axes = c.SDL_JoystickNumAxes(reader.joystick);
                const buttons = c.SDL_JoystickNumButtons(reader.joystick);
                const hats = c.SDL_JoystickNumHats(reader.joystick);
                const name_str: []const u8 = if (name != null) std.mem.span(name) else "unknown";
                log.info("GamepadReader: opened Joystick '{s}' ({d} axes, {d} buttons, {d} hats)", .{
                    name_str, axes, buttons, hats,
                });
                return reader;
            }
        }

        log.info("GamepadReader: no controller detected", .{});
        return reader;
    }

    pub fn deinit(self: *GamepadReader) void {
        if (self.controller != null) {
            c.SDL_GameControllerClose(self.controller);
            self.controller = null;
        }
        if (self.joystick != null) {
            c.SDL_JoystickClose(self.joystick);
            self.joystick = null;
        }
    }

    pub fn hasGamepad(self: *const GamepadReader) bool {
        // A custom keyboard mapping (device_index == -1) is always usable,
        // even with no physical controller plugged in. Without this, the
        // frameStep hook falls through to keyboard.readInput() (the legacy
        // reader that polls MBAA.exe's built-in config at offset 0x14D2C0)
        // and the user's custom keyboard bindings from mapping.ini are
        // silently ignored.
        if (self.custom_mapping) |m| {
            if (m.device_index < 0) return true;
        }
        return self.controller != null or self.joystick != null or self.mapped_joystick != null;
    }

    pub fn update(self: *GamepadReader) void {
        // Pump SDL events for hotplug
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_CONTROLLERDEVICEADDED => {
                    if (self.controller == null) {
                        self.controller = c.SDL_GameControllerOpen(event.cdevice.which);
                    }
                },
                c.SDL_CONTROLLERDEVICEREMOVED => {
                    if (self.controller != null and
                        c.SDL_GameControllerFromInstanceID(event.cdevice.which) == self.controller)
                    {
                        c.SDL_GameControllerClose(self.controller);
                        self.controller = null;
                    }
                },
                else => {},
            }
        }
    }

    pub fn readInput(self: *GamepadReader) u16 {
        // If a custom mapping is loaded, route to readInputMapped() —
        // which handles both keyboard bindings (via GetAsyncKeyState) and
        // joystick bindings (via SDL_Joystick* API). The previous code only
        // routed when mapped_joystick was non-null, which meant keyboard
        // mappings (device_index == -1) were silently dropped here and
        // frameStep fell back to the legacy keyboard reader using MBAA's
        // built-in config.
        if (self.custom_mapping) |m| {
            const mapper = @import("controller_mapper.zig");
            // Keyboard mapping: poll keyboard bindings via GetAsyncKeyState.
            // Pass null as the joystick so readInputMapped skips its
            // analog-stick code path (which would dereference a null joy).
            if (m.device_index < 0) {
                return mapper.readInputMapped(null, m);
            }
            // Joystick mapping: use the opened mapped_joystick.
            if (self.mapped_joystick != null) {
                return mapper.readInputMapped(self.mapped_joystick, m);
            }
            // Custom joystick mapping requested but no joystick could be
            // opened (rare — SDL_Init failed or controller unplugged since
            // GUI saved the mapping). Fall through to the controller /
            // joystick paths below instead of returning 0 (which would
            // silently disable input).
        }
        if (self.controller != null) return self.readGameController();
        if (self.joystick != null) return self.readJoystick();
        return 0;
    }

    fn readGameController(self: *GamepadReader) u16 {
        const gc = self.controller.?;
        const m = self.mapping;

        var up = c.SDL_GameControllerGetButton(gc, m.up) != 0;
        var down = c.SDL_GameControllerGetButton(gc, m.down) != 0;
        var left = c.SDL_GameControllerGetButton(gc, m.left) != 0;
        var right = c.SDL_GameControllerGetButton(gc, m.right) != 0;

        // Analog stick
        const x = c.SDL_GameControllerGetAxis(gc, m.stick_x);
        const y = c.SDL_GameControllerGetAxis(gc, m.stick_y);
        if (x > deadzone) right = true else if (x < -deadzone) left = true;
        if (y > deadzone) down = true else if (y < -deadzone) up = true;

        // SOCD
        if (up and down) { up = false; down = false; }
        if (left and right) { left = false; right = false; }

        // Direction to numpad (start at 5=neutral so +/-1 yields 4=L, 6=R)
        var dir: u16 = 5;
        if (up) dir = 8 else if (down) dir = 2;
        if (left) dir -|= 1 else if (right) dir +|= 1;
        if (dir == 5) dir = 0;

        // Buttons
        var btns: u16 = 0;
        if (c.SDL_GameControllerGetButton(gc, m.a) != 0) btns |= button_a;
        if (c.SDL_GameControllerGetButton(gc, m.b) != 0) btns |= button_b;
        if (c.SDL_GameControllerGetButton(gc, m.c_btn) != 0) btns |= button_c;
        if (c.SDL_GameControllerGetButton(gc, m.d) != 0) btns |= button_d;
        if (c.SDL_GameControllerGetButton(gc, m.e) != 0) btns |= button_e;
        if (c.SDL_GameControllerGetButton(gc, m.ab) != 0) btns |= button_ab;
        if (c.SDL_GameControllerGetButton(gc, m.start) != 0) btns |= button_start;
        if (btns & button_a != 0) btns |= button_confirm;
        if (btns & button_b != 0) btns |= button_cancel;

        return dir | (btns << 4);
    }

    fn readJoystick(self: *GamepadReader) u16 {
        const joy = self.joystick.?;

        var up = false;
        var down = false;
        var left = false;
        var right = false;

        // Hat for D-pad
        const num_hats = c.SDL_JoystickNumHats(joy);
        if (num_hats > 0) {
            const hat = c.SDL_JoystickGetHat(joy, 0);
            up = (hat & c.SDL_HAT_UP) != 0;
            down = (hat & c.SDL_HAT_DOWN) != 0;
            left = (hat & c.SDL_HAT_LEFT) != 0;
            right = (hat & c.SDL_HAT_RIGHT) != 0;
        }

        // Analog stick
        const num_axes = c.SDL_JoystickNumAxes(joy);
        if (num_axes > 0) {
            const x = c.SDL_JoystickGetAxis(joy, 0);
            if (x > deadzone) right = true else if (x < -deadzone) left = true;
        }
        if (num_axes > 1) {
            const y = c.SDL_JoystickGetAxis(joy, 1);
            if (y > deadzone) down = true else if (y < -deadzone) up = true;
        }

        // SOCD
        if (up and down) { up = false; down = false; }
        if (left and right) { left = false; right = false; }

        var dir: u16 = 5;
        if (up) dir = 8 else if (down) dir = 2;
        if (left) dir -|= 1 else if (right) dir +|= 1;
        if (dir == 5) dir = 0;

        // Buttons (Xbox-style default: 0=A, 1=B, 2=X=C, 3=Y=D, 4=LB=E, 5=RB=AB, 7=Start)
        const num_buttons = c.SDL_JoystickNumButtons(joy);
        var btns: u16 = 0;

        if (num_buttons > 0 and c.SDL_JoystickGetButton(joy, 0) != 0) btns |= button_a;
        if (num_buttons > 1 and c.SDL_JoystickGetButton(joy, 1) != 0) btns |= button_b;
        if (num_buttons > 2 and c.SDL_JoystickGetButton(joy, 2) != 0) btns |= button_c;
        if (num_buttons > 3 and c.SDL_JoystickGetButton(joy, 3) != 0) btns |= button_d;
        if (num_buttons > 4 and c.SDL_JoystickGetButton(joy, 4) != 0) btns |= button_e;
        if (num_buttons > 5 and c.SDL_JoystickGetButton(joy, 5) != 0) btns |= button_ab;
        if (num_buttons > 7 and c.SDL_JoystickGetButton(joy, 7) != 0) btns |= button_start;
        if (btns & button_a != 0) btns |= button_confirm;
        if (btns & button_b != 0) btns |= button_cancel;

        return dir | (btns << 4);
    }
};
