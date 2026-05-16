/// Smoke tests for `gero.lang.types` — the typechecker's static-type
/// representation. Covers the constructors and structural equality.
const std = @import("std");
const gero = @import("gero");

const types = gero.lang.types;
const alloc = std.testing.allocator;

test "types: primitive equality" {
    try std.testing.expect((types.Type{ .primitive = .i16 }).eql(.{ .primitive = .i16 }));
    try std.testing.expect(!(types.Type{ .primitive = .i16 }).eql(.{ .primitive = .u16 }));
}

test "types: mkPrimitive allocates a value" {
    const t = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(t);
    try std.testing.expectEqual(types.Primitive.i16, t.primitive);
}

test "types: mkOptional wraps inner" {
    const inner = try types.mkPrimitive(alloc, .str);
    defer alloc.destroy(inner);
    const opt = try types.mkOptional(alloc, inner);
    defer alloc.destroy(opt);
    try std.testing.expectEqual(types.Primitive.str, opt.optional.primitive);
}

test "types: mkReference wraps inner" {
    const inner = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(inner);
    const ref = try types.mkReference(alloc, inner);
    defer alloc.destroy(ref);
    try std.testing.expectEqual(types.Primitive.i16, ref.reference.primitive);
}

test "types: mkArray captures element type + length" {
    const elem = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(elem);
    const arr = try types.mkArray(alloc, elem, 64);
    defer alloc.destroy(arr);
    try std.testing.expectEqual(@as(u32, 64), arr.array.len);
    try std.testing.expectEqual(types.Primitive.u8, arr.array.elem.primitive);
}

test "types: mkVec captures element type" {
    const elem = try types.mkPrimitive(alloc, .i16);
    defer alloc.destroy(elem);
    const v = try types.mkVec(alloc, elem);
    defer alloc.destroy(v);
    try std.testing.expectEqual(types.Primitive.i16, v.vec.primitive);
}

test "types: mkNamed captures the lexeme + span" {
    const t = try types.mkNamed(alloc, "Player", .{ .start = 10, .end = 16 });
    defer alloc.destroy(t);
    try std.testing.expectEqualStrings("Player", t.named.name);
    try std.testing.expectEqual(@as(u32, 10), t.named.span.start);
}

test "types: array equality requires matching length AND element" {
    const e1 = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(e1);
    const e2 = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(e2);
    const a = types.Type{ .array = .{ .elem = e1, .len = 64 } };
    const b = types.Type{ .array = .{ .elem = e2, .len = 64 } };
    const c = types.Type{ .array = .{ .elem = e1, .len = 128 } };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "types: named equality compares by lexeme" {
    const a = types.Type{ .named = .{ .name = "Player", .span = .{ .start = 0, .end = 6 } } };
    const b = types.Type{ .named = .{ .name = "Player", .span = .{ .start = 100, .end = 106 } } };
    const c = types.Type{ .named = .{ .name = "Enemy", .span = .{ .start = 0, .end = 5 } } };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}
