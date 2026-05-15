const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Convenience: round-trip-style render of a bytecode buffer.
fn renderBytes(bytes: []const u8) ![]u8 {
    var allocating = std.Io.Writer.Allocating.init(alloc);
    errdefer allocating.deinit();
    try gero.disasm.writeBytes(alloc, &allocating.writer, bytes);
    return allocating.toOwnedSlice();
}

test "printer: hlt → \"hlt\\n\"" {
    const out = try renderBytes(&.{0xFF});
    defer alloc.free(out);
    try std.testing.expectEqualStrings("hlt\n", out);
}

test "printer: mov imm16, reg uses $XXXX and asm register name" {
    // mov $1234, r1
    const out = try renderBytes(&.{ 0x10, 0x34, 0x12, 0x02 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("mov   $1234, r1\n", out);
}

test "printer: mov reg, reg src-first per #94" {
    const out = try renderBytes(&.{ 0x11, 0x02, 0x03 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("mov   r1, r2\n", out);
}

test "printer: addr operand uses &XXXX" {
    // mov r1, &2620 (store r1 → mem[$2620])  →  0x12 02 20 26
    const out = try renderBytes(&.{ 0x12, 0x02, 0x20, 0x26 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("mov   r1, &2620\n", out);
}

test "printer: indirect operand uses [reg]" {
    // mov [r1], r2  →  0x16 02 03
    const out = try renderBytes(&.{ 0x16, 0x02, 0x03 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("mov   [r1], r2\n", out);
}

test "printer: indexed operand uses [&XXXX + reg]" {
    // mov [&2620 + r1], r2  →  0x17 20 26 02 03
    const out = try renderBytes(&.{ 0x17, 0x20, 0x26, 0x02, 0x03 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("mov   [&2620 + r1], r2\n", out);
}

test "printer: int imm8 → \"int $XX\\n\"" {
    const out = try renderBytes(&.{ 0xFC, 0x10 });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("int   $10\n", out);
}

test "printer: unknown opcode emits a `.byte $XX` comment + continues" {
    // 0x00 isn't a defined opcode; the disasm comments it then
    // resumes with the next byte (0xFF = hlt).
    const out = try renderBytes(&.{ 0x00, 0xFF });
    defer alloc.free(out);
    try std.testing.expectEqualStrings("; .byte $00\nhlt\n", out);
}

test "printer: truncated tail comments instead of crashing" {
    // 0x10 mov expects 3 more operand bytes; only one is here.
    const out = try renderBytes(&.{ 0x10, 0x12 });
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "truncated") != null);
}

test "printer: symbols substitute matching addresses" {
    // jmp &0021 — with a symbol for $0021 named "fib", renders
    // as `jmp fib`.
    const bytes = [_]u8{ 0x90, 0x21, 0x00 };
    const entries = [_]gero.disasm.Symbol{.{ .address = 0x0021, .kind = .label, .name = "fib" }};
    const symbols: gero.disasm.Symbols = .{ .entries = &entries };

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.disasm.writeBytesPretty(alloc, &allocating.writer, &bytes, .{ .symbols = symbols });
    try std.testing.expectEqualStrings("jmp   fib\n", allocating.written());
}

test "printer: data symbol switches to data-mode rendering" {
    // 3 bytes of data followed by a hlt. The first byte is a
    // `data` symbol, so the disasm should emit a `data8 ... =`
    // directive for those 3 bytes (up to next symbol = hlt label
    // at offset 3) instead of trying to decode them as code.
    const bytes = [_]u8{ 0x48, 0x69, 0x21, 0xFF };
    const entries = [_]gero.disasm.Symbol{
        .{ .address = 0x0000, .kind = .data, .name = "msg" },
        .{ .address = 0x0003, .kind = .label, .name = "main" },
    };
    const symbols: gero.disasm.Symbols = .{ .entries = &entries };

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.disasm.writeBytesPretty(alloc, &allocating.writer, &bytes, .{
        .base_addr = 0x0000,
        .symbols = symbols,
    });
    const out = allocating.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "data8 msg = $48, $69, $21") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hlt") != null);
}

test "printer: unmatched address stays as &XXXX" {
    const bytes = [_]u8{ 0x90, 0x22, 0x00 }; // jmp &0022
    const entries = [_]gero.disasm.Symbol{.{ .address = 0x0021, .kind = .label, .name = "fib" }};
    const symbols: gero.disasm.Symbols = .{ .entries = &entries };

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.disasm.writeBytesPretty(alloc, &allocating.writer, &bytes, .{ .symbols = symbols });
    try std.testing.expectEqualStrings("jmp   &0022\n", allocating.written());
}

test "printer: multi-instruction sequence emits one line each" {
    // mov $48, r1 ; int $10 ; hlt
    const bytes = [_]u8{ 0x10, 0x48, 0x00, 0x02, 0xFC, 0x10, 0xFF };
    const out = try renderBytes(&bytes);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("mov   $0048, r1\nint   $10\nhlt\n", out);
}

test "printer: zero run ≥ 4 collapses to single `org $XXXX` comment" {
    // 6 leading $00 bytes (padding), then `hlt`. The 6 zeros
    // should fold into one annotated comment instead of 6
    // `; .byte $00` lines.
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF };
    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.disasm.writeBytesPretty(alloc, &allocating.writer, &bytes, .{
        .base_addr = 0x0000,
    });
    const out = allocating.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "; 6 bytes zero padding (org $0006)") != null);
    // The hlt at offset 6 still renders normally.
    try std.testing.expect(std.mem.indexOf(u8, out, "hlt") != null);
    // No bare `; .byte $00` lines (they all collapsed).
    try std.testing.expect(std.mem.indexOf(u8, out, "; .byte $00") == null);
}

test "printer: zero run < 4 stays as individual `.byte $00` lines" {
    // 3 zeros + hlt — under threshold, no collapse.
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0xFF };
    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.disasm.writeBytesPretty(alloc, &allocating.writer, &bytes, .{
        .base_addr = 0x0000,
    });
    const out = allocating.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "zero padding") == null);
    // Each $00 still gets its own `; .byte $00` line.
    var occurrences: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, out, search_from, "; .byte $00")) |pos| {
        occurrences += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 3), occurrences);
}

test "printer: zero run stops at a symbol that lands inside it" {
    // 4 zeros — would collapse — but a `main` label sits at offset
    // 2. The run must split: 2 zeros before, label-decode resumes
    // at offset 2.
    const bytes = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0xFF };
    const entries = [_]gero.disasm.Symbol{
        .{ .address = 0x0002, .kind = .label, .name = "main" },
    };
    const symbols: gero.disasm.Symbols = .{ .entries = &entries };

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.disasm.writeBytesPretty(alloc, &allocating.writer, &bytes, .{
        .base_addr = 0x0000,
        .symbols = symbols,
    });
    const out = allocating.written();
    // The 2-byte head is below the collapse threshold and stays
    // as two `; .byte $00` lines.
    try std.testing.expect(std.mem.indexOf(u8, out, "zero padding") == null);
    var byte_lines: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, out, search_from, "; .byte $00")) |pos| {
        byte_lines += 1;
        search_from = pos + 1;
    }
    // 2 leading + 2 more between `main` and `hlt` = 4 lines total.
    try std.testing.expectEqual(@as(usize, 4), byte_lines);
}
