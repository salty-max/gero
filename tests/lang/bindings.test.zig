const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Check `src`, returning the checked program. Caller deinits both.
fn check(src: []const u8) !struct {
    stream: gero.lang.TokenStream,
    tree: gero.lang.ParseTree,
    checked: gero.lang.CheckedProgram,
} {
    var stream = try gero.lang.tokenize(alloc, src);
    errdefer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    errdefer tree.deinit();
    const checked = try gero.lang.typecheck(alloc, src, &tree.program);
    return .{ .stream = stream, .tree = tree, .checked = checked };
}

/// The binding recorded for the reference starting at `needle`'s first
/// occurrence after `from`.
fn bindingAt(checked: *const gero.lang.CheckedProgram, src: []const u8, needle: []const u8, from: usize) ?gero.lang.Binding {
    const idx = std.mem.indexOfPos(u8, src, from, needle) orelse return null;
    return checked.bindings.get(@intCast(idx));
}

test "typecheck: a reference records the declaration it resolves to" {
    const src =
        \\def main()
        \\  let total: i16 = 7
        \\  print total
        \\end
        \\
    ;
    var r = try check(src);
    defer r.stream.deinit();
    defer r.tree.deinit();
    defer r.checked.deinit();

    // The `total` in `print total`, not the one being declared.
    const use = std.mem.indexOf(u8, src, "print total").? + "print ".len;
    const b = r.checked.bindings.get(@intCast(use)) orelse return error.NoBinding;
    try std.testing.expectEqualStrings("total", b.name);
    try std.testing.expectEqual(gero.lang.scope.SymbolKind.let_binding, b.kind);
    // `decl_span` points at the declaring identifier, which is what
    // go-to-definition jumps to.
    const decl = std.mem.indexOf(u8, src, "let total").? + "let ".len;
    try std.testing.expectEqual(@as(u32, @intCast(decl)), b.decl_span.start);
}

test "typecheck: a parameter and a def resolve to their own kinds" {
    const src =
        \\def twice(n: i16) -> i16
        \\  return n + n
        \\end
        \\def main()
        \\  print twice(3)
        \\end
        \\
    ;
    var r = try check(src);
    defer r.stream.deinit();
    defer r.tree.deinit();
    defer r.checked.deinit();

    const n_use = std.mem.indexOf(u8, src, "return n").? + "return ".len;
    const nb = r.checked.bindings.get(@intCast(n_use)) orelse return error.NoBinding;
    try std.testing.expectEqual(gero.lang.scope.SymbolKind.param, nb.kind);

    const call = std.mem.indexOf(u8, src, "twice(3)").?;
    const cb = r.checked.bindings.get(@intCast(call)) orelse return error.NoBinding;
    try std.testing.expectEqual(gero.lang.scope.SymbolKind.function, cb.kind);
    try std.testing.expectEqualStrings("twice", cb.name);
}

test "typecheck: bindings survive a program that does not compile" {
    // An editor wants hover most in a buffer with errors in it, so the
    // table is built whether or not the program checks.
    const src =
        \\def main()
        \\  let total: i16 = 7
        \\  print total
        \\  print undefined_name
        \\end
        \\
    ;
    var r = try check(src);
    defer r.stream.deinit();
    defer r.tree.deinit();
    defer r.checked.deinit();

    try std.testing.expect(r.checked.diagnostics.len > 0);
    const use = std.mem.indexOf(u8, src, "print total").? + "print ".len;
    const b = r.checked.bindings.get(@intCast(use)) orelse return error.NoBinding;
    try std.testing.expectEqualStrings("total", b.name);

    // The unresolved name records nothing rather than guessing.
    const bad = std.mem.indexOf(u8, src, "undefined_name").?;
    try std.testing.expectEqual(@as(?gero.lang.Binding, null), r.checked.bindings.get(@intCast(bad)));
}

test "typecheck: shadowing resolves to the inner declaration" {
    const src =
        \\def main()
        \\  let x: i16 = 1
        \\  if true
        \\    let x: i16 = 2
        \\    print x
        \\  end
        \\end
        \\
    ;
    var r = try check(src);
    defer r.stream.deinit();
    defer r.tree.deinit();
    defer r.checked.deinit();

    const use = std.mem.indexOf(u8, src, "print x").? + "print ".len;
    const b = r.checked.bindings.get(@intCast(use)) orelse return error.NoBinding;
    const inner = std.mem.indexOf(u8, src, "let x: i16 = 2").? + "let ".len;
    try std.testing.expectEqual(@as(u32, @intCast(inner)), b.decl_span.start);
}

test "typecheck: a member access records the field it resolves to" {
    const src =
        \\struct Point
        \\  x: i16,
        \\  y: i16
        \\end
        \\def main()
        \\  let p: Point = Point { x: 1, y: 2 }
        \\  print p.y
        \\end
        \\
    ;
    var r = try check(src);
    defer r.stream.deinit();
    defer r.tree.deinit();
    defer r.checked.deinit();

    const use = std.mem.indexOf(u8, src, "p.y").? + "p.".len;
    const b = r.checked.bindings.get(@intCast(use)) orelse return error.NoBinding;
    try std.testing.expectEqual(gero.lang.scope.SymbolKind.field, b.kind);
    try std.testing.expectEqualStrings("y", b.name);
    // Points at the field's declaration in the struct, not the use.
    const decl = std.mem.indexOf(u8, src, "y: i16").?;
    try std.testing.expectEqual(@as(u32, @intCast(decl)), b.decl_span.start);
}
