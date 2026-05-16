/// Smoke tests for `gero.lang.scope` — symbol-table + nested-scope
/// primitives. Subsequent typechecker slices build the real
/// resolution logic on top of this.
const std = @import("std");
const gero = @import("gero");

const scope_mod = gero.lang.scope;
const Scope = scope_mod.Scope;
const SymbolInfo = scope_mod.SymbolInfo;
const alloc = std.testing.allocator;

test "scope: define + lookup hit in same scope" {
    var s: Scope = .init(alloc, null);
    defer s.deinit();
    try s.define("x", .{ .kind = .let_binding, .decl_span = .{ .start = 0, .end = 1 } });
    const got = s.lookup("x") orelse unreachable;
    try std.testing.expectEqual(scope_mod.SymbolKind.let_binding, got.kind);
}

test "scope: lookup miss returns null" {
    var s: Scope = .init(alloc, null);
    defer s.deinit();
    try std.testing.expect(s.lookup("missing") == null);
}

test "scope: redefining a name in the same scope errors" {
    var s: Scope = .init(alloc, null);
    defer s.deinit();
    try s.define("x", .{ .kind = .let_binding, .decl_span = .{ .start = 0, .end = 1 } });
    try std.testing.expectError(error.AlreadyDefined, s.define("x", .{
        .kind = .let_binding,
        .decl_span = .{ .start = 5, .end = 6 },
    }));
}

test "scope: child scope sees parent bindings via lookup" {
    var parent: Scope = .init(alloc, null);
    defer parent.deinit();
    try parent.define("outer", .{ .kind = .const_binding, .decl_span = .{ .start = 0, .end = 5 } });

    var child: Scope = .init(alloc, &parent);
    defer child.deinit();
    const got = child.lookup("outer") orelse unreachable;
    try std.testing.expectEqual(scope_mod.SymbolKind.const_binding, got.kind);
}

test "scope: shadowing — child entry hides parent entry" {
    var parent: Scope = .init(alloc, null);
    defer parent.deinit();
    try parent.define("x", .{ .kind = .const_binding, .decl_span = .{ .start = 0, .end = 1 } });

    var child: Scope = .init(alloc, &parent);
    defer child.deinit();
    try child.define("x", .{ .kind = .let_binding, .decl_span = .{ .start = 10, .end = 11 } });

    const got = child.lookup("x") orelse unreachable;
    try std.testing.expectEqual(scope_mod.SymbolKind.let_binding, got.kind);

    const parent_only = parent.lookup("x") orelse unreachable;
    try std.testing.expectEqual(scope_mod.SymbolKind.const_binding, parent_only.kind);
}

test "scope: lookupLocal does not walk parent chain" {
    var parent: Scope = .init(alloc, null);
    defer parent.deinit();
    try parent.define("outer", .{ .kind = .let_binding, .decl_span = .{ .start = 0, .end = 5 } });

    var child: Scope = .init(alloc, &parent);
    defer child.deinit();
    try std.testing.expect(child.lookupLocal("outer") == null);
    try std.testing.expect(child.lookup("outer") != null);
}

test "scope: setType updates an existing entry" {
    var s: Scope = .init(alloc, null);
    defer s.deinit();
    try s.define("x", .{ .kind = .let_binding, .decl_span = .{ .start = 0, .end = 1 } });

    const ty = try gero.lang.types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(ty);
    try s.setType("x", ty);

    const got = s.lookup("x") orelse unreachable;
    try std.testing.expectEqual(gero.lang.types.Primitive.i16, got.ty.?.primitive);
}

test "scope: setType errors on a missing name" {
    var s: Scope = .init(alloc, null);
    defer s.deinit();
    const ty = try gero.lang.types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(ty);
    try std.testing.expectError(error.NotFound, s.setType("missing", ty));
}
