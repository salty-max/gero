/// Gero-lang type representation — the typechecker's internal shape
/// of every value's static type. Mirrors the surface forms documented
/// in `docs/gero-lang.md` §3.
///
/// This module is scaffolding: subsequent typechecker slices populate
/// the `named` variant's payload as user-defined types resolve. The
/// shape here stays stable so dependent passes can build against it.
const std = @import("std");
const ast = @import("ast.zig");

/// One static type. Always allocated through the typechecker's arena —
/// the typechecker owns the lifetime and releases everything at the
/// end of a `gero.lang.typecheck` invocation.
pub const Type = union(enum) {
    /// Built-in scalar type. See `Primitive` for the variant menu.
    primitive: Primitive,
    /// `[T; N]` — fixed-size array (§3.4).
    array: Array,
    /// `Vec(T)` — dynamic array (§3.4.3).
    vec: *const Type,
    /// `(T1, T2, …)` — anonymous tuple (§3.4).
    tuple: []const *const Type,
    /// `fn(T1, T2, …) -> R` — function pointer (§4.6).
    function: Function,
    /// `T?` — nullable (§3.4.1). Inner must be a pointer-like type;
    /// the typechecker validates that elsewhere.
    optional: *const Type,
    /// `&T` — borrowed reference (§3.4.4).
    reference: *const Type,
    /// Reference to a user-defined type (`class` / `struct` / `enum`).
    /// The name span resolves to a declaration during the resolution
    /// slice; until then the `decl` slot stays `null`.
    named: Named,

    /// Structural equality. Two types are equal when their variant
    /// matches and every nested type matches. Named types compare
    /// by name span; primitives by enum tag; arrays by element type
    /// plus length; functions by param-by-param + return.
    pub fn eql(self: Type, other: Type) bool {
        return switch (self) {
            .primitive => |p| switch (other) {
                .primitive => |q| p == q,
                else => false,
            },
            .array => |a| switch (other) {
                .array => |b| a.len == b.len and a.elem.eql(b.elem.*),
                else => false,
            },
            .vec => |e| switch (other) {
                .vec => |f| e.eql(f.*),
                else => false,
            },
            .tuple => |xs| switch (other) {
                .tuple => |ys| eqlSlices(xs, ys),
                else => false,
            },
            .function => |a| switch (other) {
                .function => |b| eqlSlices(a.params, b.params) and a.ret.eql(b.ret.*),
                else => false,
            },
            .optional => |a| switch (other) {
                .optional => |b| a.eql(b.*),
                else => false,
            },
            .reference => |a| switch (other) {
                .reference => |b| a.eql(b.*),
                else => false,
            },
            .named => |a| switch (other) {
                .named => |b| std.mem.eql(u8, a.name, b.name),
                else => false,
            },
        };
    }
};

fn eqlSlices(a: []const *const Type, b: []const *const Type) bool {
    if (a.len != b.len) return false;
    for (a, b) |ai, bi| if (!ai.eql(bi.*)) return false;
    return true;
}

/// Built-in scalar types. Names match the surface keywords from
/// `docs/gero-lang.md` §3.1–3.3, with `_` suffixes on the few that
/// would otherwise collide with Zig keywords (`bool`, `nil`).
pub const Primitive = enum {
    i8,
    u8,
    i16,
    u16,
    bool_,
    nil_,
    str,
    fixed,
    char,
};

/// `[elem; len]` storage. `len` is captured as a 32-bit value to
/// match the parser's int-literal width.
pub const Array = struct {
    elem: *const Type,
    len: u32,
};

/// `fn(params) -> ret` — function pointer / `def` signature.
pub const Function = struct {
    params: []const *const Type,
    ret: *const Type,
};

/// User-defined type (struct / class / enum). The `decl` field is
/// populated by the resolution slice once symbol tables are walked;
/// scaffolding keeps it `null`.
pub const Named = struct {
    /// Type-name lexeme, sliced from source.
    name: []const u8,
    /// Span of the type-name reference at the use site.
    span: ast.Span,
    /// Pointer to the declaration that introduces this name, or
    /// `null` when not yet resolved.
    decl: ?*const ast.Statement = null,
};

// ---------- builders / smart constructors ----------

/// Allocate a primitive `Type` through `allocator`.
pub fn mkPrimitive(allocator: std.mem.Allocator, p: Primitive) !*Type {
    const t = try allocator.create(Type);
    t.* = .{ .primitive = p };
    return t;
}

/// Allocate an `optional` wrapper around `inner`.
pub fn mkOptional(allocator: std.mem.Allocator, inner: *const Type) !*Type {
    const t = try allocator.create(Type);
    t.* = .{ .optional = inner };
    return t;
}

/// Allocate a `reference` wrapper around `inner`.
pub fn mkReference(allocator: std.mem.Allocator, inner: *const Type) !*Type {
    const t = try allocator.create(Type);
    t.* = .{ .reference = inner };
    return t;
}

/// Allocate an `array(elem, len)` value.
pub fn mkArray(allocator: std.mem.Allocator, elem: *const Type, len: u32) !*Type {
    const t = try allocator.create(Type);
    t.* = .{ .array = .{ .elem = elem, .len = len } };
    return t;
}

/// Allocate a `vec(elem)` value.
pub fn mkVec(allocator: std.mem.Allocator, elem: *const Type) !*Type {
    const t = try allocator.create(Type);
    t.* = .{ .vec = elem };
    return t;
}

/// Allocate a `named(name, span)` reference.
pub fn mkNamed(allocator: std.mem.Allocator, name: []const u8, span: ast.Span) !*Type {
    const t = try allocator.create(Type);
    t.* = .{ .named = .{ .name = name, .span = span } };
    return t;
}

/// Map a type-name lexeme to its primitive variant. Returns `null`
/// for unknown names — the caller treats those as user-defined types
/// to resolve via the symbol table.
///
/// Per §3.1: `int` is the alias for `i16`, `uint` for `u16`. `char`
/// is the single-byte type backing char literals (the lexer emits
/// them as `int_lit` with value in 0..255, but the type for binding
/// purposes is `char`).
pub fn primitiveFromName(name: []const u8) ?Primitive {
    const lookup = std.StaticStringMap(Primitive).initComptime(.{
        .{ "i8", .i8 },
        .{ "u8", .u8 },
        .{ "i16", .i16 },
        .{ "u16", .u16 },
        .{ "int", .i16 },
        .{ "uint", .u16 },
        .{ "bool", .bool_ },
        .{ "nil", .nil_ },
        .{ "str", .str },
        .{ "fixed", .fixed },
        .{ "char", .char },
    });
    return lookup.get(name);
}

/// Human-readable form of a `Type`, used for diagnostic rendering.
/// Allocates through the typechecker's arena and returns the byte
/// slice — caller never frees.
pub fn render(allocator: std.mem.Allocator, t: Type) std.mem.Allocator.Error![]const u8 {
    return switch (t) {
        .primitive => |p| try renderPrimitive(allocator, p),
        .array => |a| {
            const inner = try render(allocator, a.elem.*);
            return try std.fmt.allocPrint(allocator, "[{s}; {d}]", .{ inner, a.len });
        },
        .vec => |e| {
            const inner = try render(allocator, e.*);
            return try std.fmt.allocPrint(allocator, "Vec({s})", .{inner});
        },
        .tuple => |xs| {
            // Build `(T1, T2, …)` — small ArrayList suffices.
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.append(allocator, '(');
            for (xs, 0..) |elem, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const elem_s = try render(allocator, elem.*);
                try buf.appendSlice(allocator, elem_s);
            }
            try buf.append(allocator, ')');
            return try buf.toOwnedSlice(allocator);
        },
        .function => |f| {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try buf.appendSlice(allocator, "fn(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try buf.appendSlice(allocator, ", ");
                const ps = try render(allocator, p.*);
                try buf.appendSlice(allocator, ps);
            }
            try buf.appendSlice(allocator, ") -> ");
            const rs = try render(allocator, f.ret.*);
            try buf.appendSlice(allocator, rs);
            return try buf.toOwnedSlice(allocator);
        },
        .optional => |inner| {
            const s = try render(allocator, inner.*);
            return try std.fmt.allocPrint(allocator, "{s}?", .{s});
        },
        .reference => |inner| {
            const s = try render(allocator, inner.*);
            return try std.fmt.allocPrint(allocator, "&{s}", .{s});
        },
        .named => |n| try allocator.dupe(u8, n.name),
    };
}

fn renderPrimitive(allocator: std.mem.Allocator, p: Primitive) std.mem.Allocator.Error![]const u8 {
    const name: []const u8 = switch (p) {
        .i8 => "i8",
        .u8 => "u8",
        .i16 => "i16",
        .u16 => "u16",
        .bool_ => "bool",
        .nil_ => "nil",
        .str => "str",
        .fixed => "fixed",
        .char => "char",
    };
    return allocator.dupe(u8, name);
}
