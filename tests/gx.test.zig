//! Mirror file for `src/gx.zig` — the `.gx` container format.
//!
//! End-to-end coverage of the format through the two front-ends lives
//! in `tests/asm/codegen.test.zig` and `tests/lang/codegen.test.zig`;
//! this file pins the encoding itself.

const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;
const gx = gero.gx;

test "gx: module reachable through the barrel" {
    _ = gx.build;
    _ = gx.LineRow;
    _ = gx.DebugBuilder;
}

test "build: a bank-free, debug-free image is header + base only" {
    const image = try gx.build(alloc, .{ .base_image = &.{0xFF}, .entry_point = 0x1100 });
    defer alloc.free(image);
    try std.testing.expectEqual(gx.header_size + 1, image.len);
    try std.testing.expectEqualSlices(u8, "GERO", image[0..4]);
    try std.testing.expectEqual(gx.version, gx.readU16Le(image[4..6]));
    // Neither flag set: no banks, no debug section.
    try std.testing.expectEqual(@as(u16, 0), gx.readU16Le(image[6..8]));
    try std.testing.expectEqual(@as(u16, 0x1100), gx.readU16Le(image[8..10]));
}

test "build: a short bank is zero-padded to the full window" {
    const banks = [_][]const u8{&.{ 0xAA, 0xBB }};
    const image = try gx.build(alloc, .{ .base_image = &.{0xFF}, .entry_point = 0, .banks = &banks });
    defer alloc.free(image);
    try std.testing.expectEqual(gx.header_size + 1 + gx.bank_disk_size, image.len);
    try std.testing.expectEqual(gx.flag_banked, gx.readU16Le(image[6..8]) & gx.flag_banked);
    // The window's tail is zeros, not whatever the allocator held.
    const window = image[gx.header_size + 1 ..];
    try std.testing.expectEqual(@as(u8, 0xAA), window[0]);
    for (window[2..]) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "DebugBuilder: an empty payload writes no chunk and no section" {
    var b = gx.DebugBuilder.init(alloc);
    defer b.deinit();
    try b.addChunk(.symbols, &.{});
    // No chunk means no section, which leaves the has-debug flag clear
    // rather than attaching an empty one.
    try std.testing.expect(b.section() == null);
}

test "ChunkIter: walks chunks in the order they were added" {
    var b = gx.DebugBuilder.init(alloc);
    defer b.deinit();
    try b.addChunk(.symbols, &[_]u8{ 1, 2 });
    try b.addChunk(.lines, &[_]u8{ 3, 4, 5 });

    var it: gx.ChunkIter = .{ .bytes = b.section().? };
    const first = (try it.next()).?;
    try std.testing.expectEqual(gx.ChunkKind.symbols, first.kind);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, first.payload);
    const second = (try it.next()).?;
    try std.testing.expectEqual(gx.ChunkKind.lines, second.kind);
    try std.testing.expectEqualSlices(u8, &.{ 3, 4, 5 }, second.payload);
    try std.testing.expect((try it.next()) == null);
}

test "findChunk: an unknown kind is skipped, not fatal" {
    var b = gx.DebugBuilder.init(alloc);
    defer b.deinit();
    // The framing exists so a producer can add a table this reader
    // predates without breaking it.
    try b.addChunk(@enumFromInt(0x7E), &[_]u8{ 0xDE, 0xAD });
    try b.addChunk(.lines, &[_]u8{ 0x00, 0x00 });

    const found = (try gx.findChunk(b.section().?, .lines)).?;
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00 }, found);
    try std.testing.expect((try gx.findChunk(b.section().?, .files)) == null);
}

test "findChunk: a chunk running past the section is rejected" {
    // kind + a length claiming 16 bytes of payload that isn't there.
    const bytes = [_]u8{ 0x01, 0x10, 0x00, 0x00, 0x00, 0xAA };
    try std.testing.expectError(error.TruncatedChunk, gx.findChunk(&bytes, .symbols));
}

test "encodeFiles / decodeFiles: paths round-trip" {
    const paths = [_][]const u8{ "/tmp/main.gr", "/tmp/deep/lib.gr" };
    const payload = try gx.encodeFiles(alloc, &paths);
    defer alloc.free(payload);
    const back = try gx.decodeFiles(alloc, payload);
    defer alloc.free(back);

    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqualStrings(paths[0], back[0]);
    try std.testing.expectEqualStrings(paths[1], back[1]);
}

test "decodeFiles: a path longer than its payload is rejected" {
    // count=1, path_len=8, but only 2 bytes follow.
    const payload = [_]u8{ 0x01, 0x00, 0x08, 0x00, 'a', 'b' };
    try std.testing.expectError(error.TruncatedPayload, gx.decodeFiles(alloc, &payload));
}

test "encodeLines / decodeLines: rows round-trip" {
    const rows = [_]gx.LineRow{
        .{ .start_addr = 0x1100, .end_addr = 0x1108, .file = 0, .line = 3, .column = 3 },
        .{ .start_addr = 0x1108, .end_addr = 0x1120, .file = 1, .line = 42, .column = 7 },
    };
    const payload = try gx.encodeLines(alloc, &rows);
    defer alloc.free(payload);
    const back = try gx.decodeLines(alloc, payload);
    defer alloc.free(back);

    try std.testing.expectEqual(@as(usize, 2), back.len);
    try std.testing.expectEqual(rows[1].start_addr, back[1].start_addr);
    try std.testing.expectEqual(@as(u16, 1), back[1].file);
    try std.testing.expectEqual(@as(u16, 42), back[1].line);
    try std.testing.expectEqual(@as(u16, 7), back[1].column);
}

test "decodeLines: a count larger than the payload is rejected" {
    const payload = [_]u8{ 0x02, 0x00, 0x00, 0x00 }; // claims 2 rows, carries none
    try std.testing.expectError(error.TruncatedPayload, gx.decodeLines(alloc, &payload));
}

test "lineAt: an address in a gap resolves to no row" {
    const rows = [_]gx.LineRow{
        .{ .start_addr = 0x10, .end_addr = 0x14, .file = 0, .line = 1, .column = 1 },
        .{ .start_addr = 0x20, .end_addr = 0x24, .file = 0, .line = 2, .column = 1 },
    };
    // Ranges are explicit, so a prologue or jump table between two
    // statements reports nothing rather than the preceding statement.
    try std.testing.expect(gx.lineAt(&rows, 0x18) == null);
    try std.testing.expectEqual(@as(u16, 1), gx.lineAt(&rows, 0x10).?.line);
    // End is exclusive.
    try std.testing.expect(gx.lineAt(&rows, 0x14) == null);
}

test "lineAt: nested statements resolve to the innermost" {
    const rows = [_]gx.LineRow{
        // An `if` spanning its whole body, and a statement inside it.
        .{ .start_addr = 0x10, .end_addr = 0x40, .file = 0, .line = 5, .column = 3 },
        .{ .start_addr = 0x20, .end_addr = 0x28, .file = 0, .line = 6, .column = 5 },
    };
    // The innermost statement is the one actually executing.
    try std.testing.expectEqual(@as(u16, 6), gx.lineAt(&rows, 0x24).?.line);
    // Outside the inner range, the enclosing statement still answers.
    try std.testing.expectEqual(@as(u16, 5), gx.lineAt(&rows, 0x30).?.line);
}
