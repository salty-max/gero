//! Mirror file for `src/lang/codegen/objfile.zig`.

const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Compile `src` with fragment extraction on.
fn compileWithFragments(src: []const u8) !gero.lang.Compiled {
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, src, &tree.program);
    defer checked.deinit();
    return gero.lang.compile(alloc, src, &checked, .{ .emit_fragments = true });
}

const sample =
    \\def add(a: i16, b: i16) -> i16
    \\  return a + b
    \\end
    \\def label() -> str
    \\  return "hello"
    \\end
    \\def main()
    \\  print add(1, 2)
    \\  print label()
    \\end
    \\
;

test "encode/decode: fragments survive a round-trip" {
    var compiled = try compileWithFragments(sample);
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    const blob = try gero.lang.encodeFragments(alloc, compiled.fragments);
    defer alloc.free(blob);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const back = try gero.lang.decodeFragments(arena.allocator(), blob);

    try std.testing.expectEqual(compiled.fragments.len, back.len);
    for (compiled.fragments, back) |a, b| {
        try std.testing.expectEqualStrings(a.symbol, b.symbol);
        try std.testing.expectEqual(a.module, b.module);
        try std.testing.expectEqual(a.bank, b.bank);
        try std.testing.expectEqualSlices(u8, a.bytes, b.bytes);
        try std.testing.expectEqual(a.relocs.len, b.relocs.len);
        try std.testing.expectEqual(a.refs.len, b.refs.len);
        try std.testing.expectEqual(a.strings.len, b.strings.len);
        try std.testing.expectEqual(a.defines.len, b.defines.len);
    }
}

test "decode: a decoded fragment still builds the same image" {
    var stream = try gero.lang.tokenize(alloc, sample);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, sample, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, sample, &tree.program);
    defer checked.deinit();

    var full = try gero.lang.compile(alloc, sample, &checked, .{ .emit_fragments = true });
    defer full.deinit();

    const blob = try gero.lang.encodeFragments(alloc, full.fragments);
    defer alloc.free(blob);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const back = try gero.lang.decodeFragments(arena.allocator(), blob);

    // The point of the format: bytes that went to disk splice back into
    // the same image the original build produced.
    var cached = try gero.lang.compile(alloc, sample, &checked, .{ .cached_fragments = back });
    defer cached.deinit();
    try std.testing.expectEqualSlices(u8, full.image, cached.image);
}

test "decode: a blob that isn't a fragment file is rejected" {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try std.testing.expectError(error.BadMagic, gero.lang.decodeFragments(arena.allocator(), "not a fragment file"));
    try std.testing.expectError(error.BadMagic, gero.lang.decodeFragments(arena.allocator(), ""));
}

test "decode: a truncated file is rejected rather than read past" {
    var compiled = try compileWithFragments(sample);
    defer compiled.deinit();
    const blob = try gero.lang.encodeFragments(alloc, compiled.fragments);
    defer alloc.free(blob);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try std.testing.expectError(error.Truncated, gero.lang.decodeFragments(arena.allocator(), blob[0 .. blob.len / 2]));
}

test "decode: a file from another format version is rejected" {
    var compiled = try compileWithFragments(sample);
    defer compiled.deinit();
    const blob = try gero.lang.encodeFragments(alloc, compiled.fragments);
    defer alloc.free(blob);

    const bumped = try alloc.dupe(u8, blob);
    defer alloc.free(bumped);
    // Byte 4 is the low half of the version field, right after the magic.
    bumped[4] +%= 1;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    try std.testing.expectError(error.VersionMismatch, gero.lang.decodeFragments(arena.allocator(), bumped));
}
