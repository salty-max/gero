//! Mirror file for `src/diagnostics_json.zig`.
//!
//! This is the shape `lang-diagnostics.md` §9 specifies and that every
//! producer emits — `gero check --format=json`, the language server,
//! and the wasm module. The point of the shared writer is that they
//! cannot disagree; these tests pin the shape they agree on.

const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Render one Gero diagnostic into `out`. The caller owns the
/// writer, so the JSON stays valid for as long as it is being read.
fn encodeLang(out: *std.Io.Writer.Allocating, src: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, src, &tree.program);
    defer checked.deinit();
    try std.testing.expect(checked.diagnostics.len > 0);

    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    try gero.diagnostics_json.writeLang(&jw, .{
        .path = "main.gr",
        .source = src,
        .diagnostics = checked.diagnostics,
    }, checked.diagnostics[0]);
}

test "writeLang: carries the fields a consumer decodes" {
    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    try encodeLang(&out, "def main()\n  print undefined_thing()\nend\n");

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;

    try std.testing.expectEqualStrings("main.gr", o.get("file").?.string);
    try std.testing.expectEqualStrings("error", o.get("severity").?.string);
    try std.testing.expectEqualStrings("E_UNDEFINED_SYMBOL", o.get("code").?.string);
    // Second line of the source, so a 1-based line of 2.
    try std.testing.expectEqual(@as(i64, 2), o.get("line").?.integer);
    try std.testing.expect(o.get("column").?.integer >= 1);
    // The end position is what lets an editor underline a range.
    try std.testing.expect(o.get("end_col").?.integer > o.get("column").?.integer);
    try std.testing.expect(o.get("message").?.string.len > 0);
}

test "writeAsm: carries the fields a consumer decodes" {
    const src = "start:\n  bogus r1\n  hlt\n";
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, src, pt, .{});
    defer cg.deinit();
    try std.testing.expect(cg.errors.len > 0);

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    const empty: gero.asm_.SourceMap = .{ .files = .empty, .regions = .empty, .allocator = alloc };
    try gero.diagnostics_json.writeAsm(&jw, empty, cg.errors[0]);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    const o = parsed.value.object;

    try std.testing.expectEqualStrings("error", o.get("severity").?.string);
    try std.testing.expectEqualStrings("E001", o.get("code").?.string);
    try std.testing.expectEqualStrings("unknown mnemonic", o.get("message").?.string);
}

test "writeAsm: a diagnostic with no code omits the field" {
    // A generic syntax error carries no E-code, and the object must
    // leave `code` out rather than emit null — a consumer branching on
    // presence should not have to also check for null.
    const src = "start:\n  mov r0, 1\n";
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    try std.testing.expect(pt.errors.len > 0);
    try std.testing.expect(pt.errors[0].code == null);

    var out = std.Io.Writer.Allocating.init(alloc);
    defer out.deinit();
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .whitespace = .minified } };
    const empty: gero.asm_.SourceMap = .{ .files = .empty, .regions = .empty, .allocator = alloc };
    try gero.diagnostics_json.writeAsm(&jw, empty, pt.errors[0]);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("code") == null);
}

test "lineColIn: 1-based, and a newline starts the next line" {
    const src = "ab\ncd";
    try std.testing.expectEqual(@as(usize, 1), gero.diagnostics_json.lineColIn(src, 0).line);
    try std.testing.expectEqual(@as(usize, 1), gero.diagnostics_json.lineColIn(src, 0).col);
    try std.testing.expectEqual(@as(usize, 2), gero.diagnostics_json.lineColIn(src, 3).line);
    try std.testing.expectEqual(@as(usize, 1), gero.diagnostics_json.lineColIn(src, 3).col);
}
