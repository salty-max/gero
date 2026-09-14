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

// ---------- selective imports from a project file (§5.2) ----------

const util = @import("util");

/// `true` when `codes` holds `want`.
fn has(codes: []const []const u8, want: []const u8) bool {
    for (codes) |c| if (std.mem.eql(u8, c, want)) return true;
    return false;
}

fn freeCodes(out: *std.ArrayList([]const u8)) void {
    for (out.items) |c| alloc.free(c);
    out.deinit(alloc);
}

test "imports: a selective import binds only the names it lists" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\struct Vec2
        \\  x: i16
        \\end
        \\def zero() -> i16
        \\  return 0
        \\end
        \\
    );
    // `zero` is never imported, so naming it must not resolve.
    try fx.write("main.gr",
        \\use Vec2 from "./lib"
        \\def main()
        \\  let v: Vec2 = Vec2 { x: 1 }
        \\  print v.x + zero()
        \\end
        \\
    );

    var codes: std.ArrayList([]const u8) = .empty;
    defer freeCodes(&codes);
    try fx.collectCodes("main.gr", &codes);
    try std.testing.expect(has(codes.items, "E_UNDEFINED_SYMBOL"));
}

test "imports: a whole-module import brings every export into scope" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def zero() -> i16
        \\  return 0
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use "./lib"
        \\def main()
        \\  print zero()
        \\end
        \\
    );

    var codes: std.ArrayList([]const u8) = .empty;
    defer freeCodes(&codes);
    try fx.collectCodes("main.gr", &codes);
    try std.testing.expectEqual(@as(usize, 0), codes.items.len);
}

test "imports: importing a name the target does not export is rejected" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def zero() -> i16
        \\  return 0
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use nope from "./lib"
        \\def main()
        \\  print 1
        \\end
        \\
    );

    var codes: std.ArrayList([]const u8) = .empty;
    defer freeCodes(&codes);
    try fx.collectCodes("main.gr", &codes);
    try std.testing.expect(has(codes.items, "E_USE_UNDEFINED_MEMBER"));
}

test "imports: a misspelled import names the export it nearly matched" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\struct Vec2
        \\  x: i16
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use Vec3 from "./lib"
        \\def main()
        \\  print 1
        \\end
        \\
    );

    const path = try fx.pathOf("main.gr");
    defer alloc.free(path);
    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, path);
    defer fused.deinit();
    var stream = try gero.lang.tokenize(alloc, fused.source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, fused.source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheckGraph(alloc, fused.source, &tree.program, &fused.import_aliases, .{
        .source_map = &fused.source_map,
        .imports = fused.imports,
    });
    defer checked.deinit();

    for (checked.diagnostics) |d| {
        if (!std.mem.eql(u8, d.code, "E_USE_UNDEFINED_MEMBER")) continue;
        const help = d.help orelse return error.NoHelp;
        try std.testing.expect(std.mem.indexOf(u8, help, "Vec2") != null);
        return;
    }
    return error.MissingDiagnostic;
}

test "imports: importing a `local` declaration is rejected" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\local def hidden() -> i16
        \\  return 0
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use hidden from "./lib"
        \\def main()
        \\  print 1
        \\end
        \\
    );

    var codes: std.ArrayList([]const u8) = .empty;
    defer freeCodes(&codes);
    try fx.collectCodes("main.gr", &codes);
    try std.testing.expect(has(codes.items, "E_USE_UNDEFINED_MEMBER"));
}

test "imports: a rename binds the alias and not the original name" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def zero() -> i16
        \\  return 0
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use zero as nought from "./lib"
        \\def main()
        \\  print nought()
        \\  print zero()
        \\end
        \\
    );

    var codes: std.ArrayList([]const u8) = .empty;
    defer freeCodes(&codes);
    try fx.collectCodes("main.gr", &codes);
    // `nought` resolves; the original `zero` no longer does.
    try std.testing.expect(has(codes.items, "E_UNDEFINED_SYMBOL"));
}

test "imports: a selective project import nothing references is reported" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def zero() -> i16
        \\  return 0
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use zero from "./lib"
        \\def main()
        \\  print 1
        \\end
        \\
    );

    var codes: std.ArrayList([]const u8) = .empty;
    defer freeCodes(&codes);
    try fx.collectCodes("main.gr", &codes);
    try std.testing.expect(has(codes.items, "W_UNUSED_IMPORT"));
}

test "imports: a selective project import that is used is not reported" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def zero() -> i16
        \\  return 0
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use zero from "./lib"
        \\def main()
        \\  print zero()
        \\end
        \\
    );

    var codes: std.ArrayList([]const u8) = .empty;
    defer freeCodes(&codes);
    try fx.collectCodes("main.gr", &codes);
    try std.testing.expectEqual(@as(usize, 0), codes.items.len);
}
