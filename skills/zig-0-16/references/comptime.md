# Comptime in Zig 0.16: `@Type` removed, 8 specialized builtins

The biggest comptime change in 0.16 is the removal of `@Type` (the kitchen-sink reflective
builtin that could reify any type). In its place are 8 focused builtins, each handling one
kind of type. This makes the compiler simpler and the resulting code more readable.

## Table of contents

1. [Why `@Type` was removed](#why-type-was-removed)
2. [The 8 new builtins](#the-8-new-builtins)
3. [`@Int` examples](#int-examples)
4. [`@Struct` examples](#struct-examples)
5. [`@Union` examples](#union-examples)
6. [`@Enum` examples](#enum-examples)
7. [`@Pointer` / `@Fn` / `@Tuple` / `@EnumLiteral`](#pointer--fn--tuple--enumliteral)
8. [Error sets can no longer be reified](#error-sets-can-no-longer-be-reified)
9. [Other comptime changes in 0.16](#other-comptime-changes-in-0-16)
10. [Patterns that used `@Type` and how to migrate](#patterns-that-used-type-and-how-to-migrate)

## Why `@Type` was removed

`@Type` took a tagged union describing the kind of type and all its fields. It was powerful
but had problems:

1. The tagged union duplicated the language's type taxonomy — every change to the type
   system required updating `@TypeInfo` and `@Type` in parallel.
2. The compiler's type reification logic was centralized in one giant function, making
   incremental improvements hard.
3. Most call sites only needed one specific kind of type, but had to navigate the entire
   union.

The 8 specialized builtins are smaller, faster to compile, and produce better error
messages because each one knows exactly what kind of type you want.

## The 8 new builtins

| Builtin         | Reifies                                  | Replaces `@Type` field           |
|-----------------|------------------------------------------|----------------------------------|
| `@Int`          | Integer types                            | `.Int`                           |
| `@Tuple`        | Tuple types                              | `.Tuple` or anonymous struct     |
| `@Pointer`      | Pointer types                            | `.Pointer`                       |
| `@Fn`           | Function types                           | `.Fn`                            |
| `@Struct`       | Struct types                             | `.Struct`                        |
| `@Union`        | Union types                              | `.Union`                         |
| `@Enum`         | Enum types                               | `.Enum`                          |
| `@EnumLiteral`  | Enum literal types (new!)                | (no equivalent before 0.16)      |

Note: `@TypeOf` (the type-of operator) is **unchanged**. So is `@typeInfo` (which returns
the reflective `@Type.TypeInfo` union). The change is only to *reification* — going from a
description to a type.

## `@Int` examples

```zig
// Reify an unsigned 16-bit integer type
const U16 = @Int(.unsigned, 16);
const x: U16 = 42;

// Reify a signed 8-bit integer type
const I8 = @Int(.signed, 8);

// At runtime (comptime-only values are fine)
fn intType(signed: bool, bits: u16) type {
    return @Int(if (signed) .signed else .unsigned, bits);
}

const Score = intType(false, 24);   // u24
```

Validation: `bits` must be 1..65535, must be a power of 2 for some operations, and the
`signedness` is `std.builtin.Signedness`.

## `@Struct` examples

```zig
const Point = @Struct(.{
    .layout = .auto,
    .fields = &.{
        .{ .name = "x", .type = f32, .default_value_ptr = null, .is_comptime = false, .alignment = 4 },
        .{ .name = "y", .type = f32, .default_value_ptr = null, .is_comptime = false, .alignment = 4 },
    },
    .decls = &.{},
    .is_tuple = false,
});

const p: Point = .{ .x = 1, .y = 2 };
```

For default values, you need a pointer to a stable comptime value:

```zig
const default_zero: f32 = 0;
const Vec3 = @Struct(.{
    .layout = .auto,
    .fields = &.{
        .{ .name = "x", .type = f32, .default_value_ptr = @ptrCast(&default_zero), .is_comptime = false, .alignment = 4 },
        .{ .name = "y", .type = f32, .default_value_ptr = @ptrCast(&default_zero), .is_comptime = false, .alignment = 4 },
        .{ .name = "z", .type = f32, .default_value_ptr = @ptrCast(&default_zero), .is_comptime = false, .alignment = 4 },
    },
    .decls = &.{},
    .is_tuple = false,
});

const v: Vec3 = .{};   // x=0, y=0, z=0
```

## `@Union` examples

```zig
const Tag = enum { number, text };

const Value = @Union(.{
    .layout = .auto,
    .tag_type = Tag,
    .fields = &.{
        .{ .name = "number", .type = i64, .alignment = 8 },
        .{ .name = "text", .type = []const u8, .alignment = 8 },
    },
    .decls = &.{},
});

const v: Value = .{ .number = 42 };
const t: Value = .{ .text = "hi" };
```

For a bare (untagged) union, omit `tag_type`:

```zig
const Bare = @Union(.{
    .layout = .auto,
    .tag_type = null,
    .fields = &.{
        .{ .name = "a", .type = u32, .alignment = 4 },
        .{ .name = "b", .type = f32, .alignment = 4 },
    },
    .decls = &.{},
});
```

## `@Enum` examples

```zig
const Color = @Enum(.{
    .tag_type = u8,
    .fields = &.{
        .{ .name = "red", .value = 0 },
        .{ .name = "green", .value = 1 },
        .{ .name = "blue", .value = 2 },
    },
    .decls = &.{},
    .is_exhaustive = true,
});

const c: Color = .red;
```

For non-exhaustive enums (where you can have unspecified values):

```zig
const StatusCode = @Enum(.{
    .tag_type = u16,
    .fields = &.{
        .{ .name = "ok", .value = 200 },
        .{ .name = "not_found", .value = 404 },
        .{ .name = "internal_error", .value = 500 },
    },
    .decls = &.{},
    .is_exhaustive = false,
});

const sc: StatusCode = @enumFromInt(403);   // OK, _ catchall
```

## `@Pointer` / `@Fn` / `@Tuple` / `@EnumLiteral`

### `@Pointer`

```zig
const P = @Pointer(.{
    .size = .one,
    .is_const = true,
    .is_volatile = false,
    .alignment = 4,
    .address = .{ .child = u32 },
    .is_allowzero = false,
    .sentinel_ptr = null,
});

const p: P = &x;
```

`.size` is `std.builtin.Type.Pointer.Size`: `.one`, `.slice`, `.many`, `.c`.

### `@Fn`

```zig
const F = @Fn(.{
    .calling_convention = .c,
    .is_generic = false,
    .is_var_args = false,
    .return_type = u32,
    .params = &.{
        .{ .is_generic = false, .type = u32 },
        .{ .is_generic = false, .type = u32 },
    },
});

extern fn hash(a: u32, b: u32) callconv(.c) u32;
const f: F = hash;
```

### `@Tuple`

```zig
const Pair = @Tuple(&.{ u32, []const u8 });
const p: Pair = .{ 42, "hi" };
```

### `@EnumLiteral`

New in 0.16. Represents the type of an enum literal like `.red` before it's coerced to a
specific enum. Useful for APIs that accept enum literals generically:

```zig
fn acceptLiteral(comptime T: type, v: T) void {
    if (T == @EnumLiteral()) {
        // v is something like .red, no specific enum yet
    }
}
```

## Error sets can no longer be reified

`@Type` had an `.ErrorSet` variant. In 0.16, **error sets cannot be reified at comptime**.
You can still *inspect* them via `@typeInfo(T).ErrorSet`, but you can't construct one
programmatically.

If you need a dynamically-built error set, declare it by name:

```zig
const MyErrors = error{ Foo, Bar, Baz };
```

Or use `anyerror` for an open set:

```zig
fn mightFail() anyerror!void {
    return error.SomethingElse;
}
```

The compiler can still merge error sets at compile time via `||`:

```zig
const Combined = MyErrors || error{Qux};
```

## Other comptime changes in 0.16

### `@branchHint(.cold)` replaces `@setCold`

```zig
// WRONG — 0.15
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);
    // ...
}

// CORRECT — 0.16
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @branchHint(.cold);
    // ...
}
```

Hints available: `.cold`, `.hot`, `.likely`, `.unlikely`, `.none`.

### `@intFromFloat` deprecated — use `@trunc`

See the SKILL.md quick table. `@trunc` now does both float→float and float→int conversion
based on context.

### Inline loops are more aggressive

`inline for` and `inline while` now have higher inlining budgets. Be careful with very
large unrolls — they can blow up binary size. Use `@compileLog` to inspect.

### `@field` for runtime field access on comptime-known types

```zig
const Player = struct { x: f32, y: f32 };

inline fn getField(comptime field: []const u8, p: Player) f32 {
    return @field(p, field);
}

const x = getField("x", player);
const y = getField("y", player);
```

This is unchanged from 0.15 but worth noting because it composes nicely with the new
`@Struct` reification.

## Patterns that used `@Type` and how to migrate

### Pattern: tagged union from a list of names

```zig
// 0.15 — using @Type
fn TaggedUnionFromNames(comptime names: []const []const u8) type {
    var fields: [names.len]std.builtin.Type.UnionField = undefined;
    for (names, 0..) |name, i| {
        fields[i] = .{ .name = name, .type = void, .alignment = 0 };
    }
    return @Type(.{
        .Union = .{
            .layout = .auto,
            .tag_type = null,
            .fields = &fields,
            .decls = &.{},
        },
    });
}

// 0.16 — using @Union
fn TaggedUnionFromNames(comptime names: []const []const u8) type {
    var fields: [names.len]std.builtin.Type.UnionField = undefined;
    for (names, 0..) |name, i| {
        fields[i] = .{ .name = name, .type = void, .alignment = 0 };
    }
    return @Union(.{
        .layout = .auto,
        .tag_type = null,
        .fields = &fields,
        .decls = &.{},
    });
}
```

The only change is `@Type(.{ .Union = ... })` → `@Union(...)`.

### Pattern: bit-packed struct from a layout description

```zig
// 0.16
fn PackedFromLayout(comptime layout: []const struct { name: []const u8, type: type }) type {
    var fields: [layout.len]std.builtin.Type.StructField = undefined;
    for (layout, 0..) |field, i| {
        fields[i] = .{
            .name = field.name,
            .type = field.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(field.type),
        };
    }
    return @Struct(.{
        .layout = .@"packed",
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    });
}

const Pixel = PackedFromLayout(&.{
    .{ .name = "r", .type = u8 },
    .{ .name = "g", .type = u8 },
    .{ .name = "b", .type = u8 },
    .{ .name = "a", .type = u8 },
});
```

### Pattern: type from a `@typeInfo` roundtrip

If you previously round-tripped through `@typeInfo` and `@Type` to clone a type with one
field changed, look at `@Type.modify` (still present) which works on the reflective side:

```zig
// Clone a struct, add a field
const Modified = @Type.modify(Original, .{
    .Struct = .{
        .fields = original_fields ++ &.{new_field},
    },
});
```

## Common mistakes

### Forgetting `.default_value_ptr = null`

When constructing struct fields, you must pass `null` if there's no default — passing
`undefined` will be a comptime error.

### Using `[]const u8` for field names

Field names must be `[:0]const u8` (zero-terminated). Use string literals, which are
already zero-terminated.

### Trying to reify an error set

```zig
// WRONG — won't compile
const E = @Type(.{ .ErrorSet = &.{
    .{ .name = "foo" },
    .{ .name = "bar" },
} });
```

Error sets can only be declared, not reified. Declare them statically and combine with `||`.

### Constructing fields with wrong alignment

If you set `.alignment = 1` on a `u64` field in a `@"packed"` struct, the compiler will
reject it. Use `@alignOf(field.type)` to get the natural alignment.

## See also

- [patterns.md](patterns.md) — Comptime patterns in real codebases
- [code-review.md](code-review.md) — What to look for in comptime-heavy PRs
