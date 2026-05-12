const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Assemble `source` end-to-end and return both the parse tree
/// and codegen output. Tests deinit both.
const Output = struct {
    pt: gero.asm_.ParseTree,
    cg: gero.asm_.Codegen,

    fn deinit(self: *Output) void {
        self.cg.deinit();
        self.pt.deinit();
    }

    /// Slice into the codegen image, excluding the 16-byte header.
    fn imageBody(self: Output) []const u8 {
        return self.cg.image[16..];
    }
};

fn assemble(source: []const u8, opts: gero.asm_.CodegenOptions) !Output {
    var pt = try gero.asm_.parse(alloc, source);
    errdefer pt.deinit();
    const cg = try gero.asm_.assemble(alloc, source, pt, opts);
    return .{ .pt = pt, .cg = cg };
}

// ---------- single-instruction smokes ----------

test "codegen: bare hlt emits one 0xFF byte" {
    var out = try assemble("hlt\n", .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqualSlices(u8, &.{0xFF}, out.imageBody());
}

test "codegen: nop emits 0x91" {
    var out = try assemble("nop\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{0x91}, out.imageBody());
}

test "codegen: mov imm16, reg → 0x10 LE imm reg" {
    // r1 has reg-index 0x02.
    var out = try assemble("mov $ABCD, r1\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0xCD, 0xAB, 0x02 }, out.imageBody());
}

test "codegen: mov reg, reg → 0x11 dst src" {
    var out = try assemble("mov r1, r2\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x02, 0x03 }, out.imageBody());
}

test "codegen: inc reg → 0x48 reg" {
    var out = try assemble("inc r1\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x48, 0x02 }, out.imageBody());
}

test "codegen: cmp reg, imm16 → 0x60 reg imm_lo imm_hi" {
    var out = try assemble("cmp r1, $0010\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x60, 0x02, 0x10, 0x00 }, out.imageBody());
}

// ---------- the §7 worked example ----------

test "codegen: §7 worked example assembles to the spec'd 14 bytes" {
    // Source from docs/asm.md §7 (count-up loop).
    const src =
        \\const TARGET = $10
        \\
        \\start:
        \\  mov $00, r1
        \\loop:
        \\  inc r1
        \\  cmp r1, TARGET
        \\  jne loop
        \\  hlt
        \\
    ;
    var out = try assemble(src, .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());

    // Documented bytecode at 0x0000:
    //   10 00 00 02            mov $0000, r1
    //   48 02                  inc r1                (loop: at 0x0004)
    //   60 02 10 00            cmp r1, $0010
    //   73 04 00               jne &0004
    //   FF                     hlt
    const expected = [_]u8{
        0x10, 0x00, 0x00, 0x02,
        0x48, 0x02, 0x60, 0x02,
        0x10, 0x00, 0x73, 0x04,
        0x00, 0xFF,
    };
    try std.testing.expectEqualSlices(u8, &expected, out.imageBody());
}

// ---------- forward references ----------

test "codegen: forward label reference resolves" {
    var out = try assemble(
        \\jmp end
        \\hlt
        \\end:
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    // jmp Addr = opcode 0x70 + addr LE. `end` is at offset 4
    // (jmp = 3 bytes, hlt = 1 byte). Encoding: 70 04 00.
    try std.testing.expectEqualSlices(u8, &.{ 0x70, 0x04, 0x00, 0xFF, 0xFF }, out.imageBody());
}

// ---------- data directives ----------

test "codegen: data8 with hex values emits raw bytes" {
    var out = try assemble("data8 row = $01, $02, $03\n", .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, out.imageBody());
}

test "codegen: data8 with string literal decodes escapes" {
    var out = try assemble("data8 greet = \"Hi\\n\"\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 'H', 'i', 0x0A }, out.imageBody());
}

test "codegen: data8 with reserve emits zero bytes" {
    var out = try assemble("data8 buf = reserve $04\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, out.imageBody());
}

test "codegen: data16 emits LE words" {
    var out = try assemble("data16 ws = $1234, $ABCD\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12, 0xCD, 0xAB }, out.imageBody());
}

// ---------- org + zero-padding ----------

test "codegen: org advances cursor and zero-pads the gap" {
    var out = try assemble(
        \\hlt
        \\org $0004
        \\hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0, 0, 0, 0xFF }, out.imageBody());
}

test "codegen: backward org raises E014-shape" {
    var out = try assemble(
        \\org $0010
        \\hlt
        \\org $0005
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var saw_backward = false;
    for (out.cg.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "backward `org`") != null) saw_backward = true;
    }
    try std.testing.expect(saw_backward);
}

// ---------- header ----------

test "codegen: header magic + version + entry_point + image_size" {
    var out = try assemble("hlt\n", .{ .entry_point = 0x1100 });
    defer out.deinit();
    // Magic "GERO".
    try std.testing.expectEqualSlices(u8, "GERO", out.cg.image[0..4]);
    // Version = 0x0001 LE.
    try std.testing.expectEqual(@as(u8, 0x01), out.cg.image[4]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[5]);
    // Entry point = 0x1100 LE.
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[8]);
    try std.testing.expectEqual(@as(u8, 0x11), out.cg.image[9]);
    // Image size = 1 byte (just the hlt).
    try std.testing.expectEqual(@as(u8, 0x01), out.cg.image[10]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[11]);
    // bank_count = 0, sram_bank_count = 0.
    try std.testing.expectEqual(@as(u8, 0), out.cg.image[12]);
    try std.testing.expectEqual(@as(u8, 0), out.cg.image[13]);
}

// ---------- errors ----------

test "codegen: duplicate label raises E005-shape" {
    var out = try assemble(
        \\foo:
        \\foo:
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var saw_dup = false;
    for (out.cg.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "duplicate label") != null) saw_dup = true;
    }
    try std.testing.expect(saw_dup);
}

test "codegen: undefined symbol in operand raises E004-shape" {
    var out = try assemble("jmp nowhere\n", .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var saw_undefined = false;
    for (out.cg.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "undefined symbol") != null) saw_undefined = true;
    }
    try std.testing.expect(saw_undefined);
}

test "codegen: unknown mnemonic raises E001-shape" {
    var out = try assemble("foobar r1\n", .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var saw_unknown = false;
    for (out.cg.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "unknown mnemonic") != null) saw_unknown = true;
    }
    try std.testing.expect(saw_unknown);
}

test "codegen: mnemonic with wrong operand shape raises E003-shape" {
    // `add` has Imm16,Reg / Reg,Reg / Reg forms. `add addr, addr`
    // doesn't match anything.
    var out = try assemble("add &1000, &2000\n", .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var saw_mismatch = false;
    for (out.cg.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "operand type mismatch") != null) saw_mismatch = true;
    }
    try std.testing.expect(saw_mismatch);
}

// ---------- symbol table sanity ----------

test "codegen: symbol table records labels at their addresses" {
    var out = try assemble(
        \\start:
        \\  hlt
        \\after:
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    const start = out.cg.symbols.get("start") orelse return error.SymbolMissing;
    const after = out.cg.symbols.get("after") orelse return error.SymbolMissing;
    try std.testing.expectEqual(@as(u16, 0x0000), start.value);
    try std.testing.expectEqual(@as(u16, 0x0001), after.value);
}

test "codegen: symbol table records const + data + struct entries" {
    var out = try assemble(
        \\const N = $42
        \\data8 buf = $01, $02
        \\struct Player { hp: u16, mp: u16 }
        \\hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u16, 0x42), out.cg.symbols.get("N").?.value);
    try std.testing.expectEqual(@as(u16, 0x00), out.cg.symbols.get("buf").?.value);
    try std.testing.expectEqual(@as(u16, 0x00), out.cg.symbols.get("Player.hp").?.value);
    try std.testing.expectEqual(@as(u16, 0x02), out.cg.symbols.get("Player.mp").?.value);
}
