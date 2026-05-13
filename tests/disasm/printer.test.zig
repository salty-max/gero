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
    // 0x00 isn't in the v0.1 ISA; the disasm comments it then
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
    const bytes = [_]u8{ 0x70, 0x21, 0x00 };
    const entries = [_]gero.disasm.Symbol{.{ .address = 0x0021, .name = "fib" }};
    const symbols: gero.disasm.Symbols = .{ .entries = &entries };

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.disasm.writeBytesPretty(alloc, &allocating.writer, &bytes, .{ .symbols = symbols });
    try std.testing.expectEqualStrings("jmp   fib\n", allocating.written());
}

test "printer: unmatched address stays as &XXXX" {
    const bytes = [_]u8{ 0x70, 0x22, 0x00 }; // jmp &0022
    const entries = [_]gero.disasm.Symbol{.{ .address = 0x0021, .name = "fib" }}; // different addr
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
