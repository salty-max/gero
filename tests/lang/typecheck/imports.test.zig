/// `W_UNUSED_IMPORT` — an import no reference in the module binds to.
/// The pass reads the checker's binding table, so these tests go
/// through a real type-check rather than calling it directly.
const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Every `W_UNUSED_IMPORT` message `src` produces, in order.
fn unusedIn(src: []const u8, out: *std.ArrayList([]const u8)) !void {
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, src, &tree.program);
    defer checked.deinit();

    for (checked.diagnostics) |d| {
        if (!std.mem.eql(u8, d.code, "W_UNUSED_IMPORT")) continue;
        try std.testing.expectEqual(gero.lang.Severity.warning, d.severity);
        try out.append(alloc, try alloc.dupe(u8, d.message));
    }
}

fn freeAll(out: *std.ArrayList([]const u8)) void {
    for (out.items) |m| alloc.free(m);
    out.deinit(alloc);
}

test "imports: a selective import nothing references is reported" {
    var got: std.ArrayList([]const u8) = .empty;
    defer freeAll(&got);
    try unusedIn(
        \\use min from math
        \\def main()
        \\  print 1
        \\end
    , &got);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("unused import `min`", got.items[0]);
}

test "imports: a selective import called bare is not reported" {
    var got: std.ArrayList([]const u8) = .empty;
    defer freeAll(&got);
    try unusedIn(
        \\use abs from math
        \\def main()
        \\  print abs(0 - 3)
        \\end
    , &got);
    try std.testing.expectEqual(@as(usize, 0), got.items.len);
}

test "imports: each item of one `use` is judged on its own" {
    var got: std.ArrayList([]const u8) = .empty;
    defer freeAll(&got);
    try unusedIn(
        \\use abs, min from math
        \\def main()
        \\  print abs(0 - 3)
        \\end
    , &got);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("unused import `min`", got.items[0]);
}

test "imports: a whole-module import used through a qualified call is not reported" {
    var got: std.ArrayList([]const u8) = .empty;
    defer freeAll(&got);
    try unusedIn(
        \\use math
        \\def main()
        \\  print math.abs(0 - 3)
        \\end
    , &got);
    try std.testing.expectEqual(@as(usize, 0), got.items.len);
}

test "imports: a whole-module import nothing qualifies is reported" {
    var got: std.ArrayList([]const u8) = .empty;
    defer freeAll(&got);
    try unusedIn(
        \\use math
        \\def main()
        \\  print 1
        \\end
    , &got);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("unused import `math`", got.items[0]);
}

test "imports: an aliased import is named by its alias" {
    var got: std.ArrayList([]const u8) = .empty;
    defer freeAll(&got);
    try unusedIn(
        \\use math as m
        \\def main()
        \\  print 1
        \\end
    , &got);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("unused import `m`", got.items[0]);
}

test "imports: an alias reached under its new name is not reported" {
    var got: std.ArrayList([]const u8) = .empty;
    defer freeAll(&got);
    try unusedIn(
        \\use math as m
        \\def main()
        \\  print m.abs(0 - 3)
        \\end
    , &got);
    try std.testing.expectEqual(@as(usize, 0), got.items.len);
}

test "imports: an import a local shadows everywhere is reported" {
    var got: std.ArrayList([]const u8) = .empty;
    defer freeAll(&got);
    try unusedIn(
        \\use max from math
        \\def main()
        \\  let max = |a: i16, b: i16| -> i16 a + b
        \\  print max(2, 9)
        \\end
    , &got);
    try std.testing.expectEqual(@as(usize, 1), got.items.len);
    try std.testing.expectEqualStrings("unused import `max`", got.items[0]);
}
