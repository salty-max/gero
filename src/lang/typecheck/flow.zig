/// Small, heterogeneous helpers consumed by flow-sensitive
/// inference and decl-resolution paths in the typechecker.
/// Grouped here because each is too small to warrant its own
/// file and they share the common shape of "lookup or shape
/// inspection that doesn't drive its own pass".
const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const typecheck = @import("../typecheck.zig");

const Checker = typecheck.Checker;

/// Extract the source-buffer lexeme when `e` is a bare ident
/// (possibly wrapped in `paren`). Returns `null` otherwise — used
/// by nil-check pattern matching and by flow-sensitive deref
/// lookups.
pub fn identName(c: *const Checker, e: *const ast.Expr) ?[]const u8 {
    return switch (e.*) {
        .ident => |i| c.lexeme(i.span),
        .paren => |p| identName(c, p.inner),
        else => null,
    };
}

/// `true` when the last statement of `body` is `return` / `break` /
/// `continue` — used by the `if x == nil then return end`
/// fall-through detector.
pub fn bodyAlwaysExits(body: []const ast.Statement) bool {
    if (body.len == 0) return false;
    return switch (body[body.len - 1]) {
        .return_stmt, .break_stmt, .continue_stmt => true,
        else => false,
    };
}

/// Lexeme of a `Named` type, or `null` for other type shapes.
pub fn namedNameOf(t: types.Type) ?[]const u8 {
    return switch (t) {
        .named => |n| n.name,
        else => null,
    };
}

/// Locate a field on a struct decl by name.
pub fn findStructField(c: *const Checker, fields: []const ast.StructField, name: []const u8) ?*const ast.StructField {
    for (fields) |*f| {
        if (std.mem.eql(u8, c.lexeme(f.name), name)) return f;
    }
    return null;
}

/// Locate a field on a class decl by name (walks the inheritance
/// chain). Returns the first hit.
pub fn findClassField(c: *const Checker, cd: *const ast.ClassDecl, name: []const u8) ?*const ast.ClassField {
    for (cd.fields) |*f| {
        if (std.mem.eql(u8, c.lexeme(f.name), name)) return f;
    }
    if (cd.extends) |ext| if (c.class_registry.get(c.lexeme(ext))) |parent| {
        return findClassField(c, parent, name);
    };
    return null;
}
