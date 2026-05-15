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

fn assemble(source: []const u8, opts_in: gero.asm_.CodegenOptions) !Output {
    var pt = try gero.asm_.parse(alloc, source);
    errdefer pt.deinit();
    // Force-disable debug symbols by default so byte-layout
    // tests stay tight against the expected image / banks bytes.
    // The dedicated debug-symbols tests pass their own opts with
    // `.debug_symbols = true`.
    var opts = opts_in;
    opts.debug_symbols = false;
    const cg = try gero.asm_.assemble(alloc, source, pt, opts);
    return .{ .pt = pt, .cg = cg };
}

/// Variant that keeps the caller's opts intact (no automatic
/// debug-symbol stripping). Used by the `#100` debug-symbols
/// tests that need to inspect the trailing blob.
fn assembleRaw(source: []const u8, opts: gero.asm_.CodegenOptions) !Output {
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

test "codegen: nop emits 0xC1" {
    var out = try assemble("nop\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{0xC1}, out.imageBody());
}

test "codegen: mov imm16, reg → 0x10 LE imm reg" {
    // r1 has reg-index 0x02.
    var out = try assemble("mov $ABCD, r1\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0xCD, 0xAB, 0x02 }, out.imageBody());
}

test "codegen: mov reg, reg → 0x11 src dst (src first per asm convention)" {
    // `mov r1, r2` is read as src=r1, dst=r2 — r2 ← r1.
    var out = try assemble("mov r1, r2\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x02, 0x03 }, out.imageBody());
}

test "codegen: inc reg → 0x48 reg" {
    var out = try assemble("inc r1\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x48, 0x02 }, out.imageBody());
}

test "codegen: cmp reg, imm16 → 0x80 reg imm_lo imm_hi" {
    var out = try assemble("cmp r1, $0010\n", .{});
    defer out.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x02, 0x10, 0x00 }, out.imageBody());
}

test "codegen: int $10 narrows to 1-byte imm8 operand (0xFC 0x10)" {
    var out = try assemble("int $10\n", .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqualSlices(u8, &.{ 0xFC, 0x10 }, out.imageBody());
}

test "codegen: int CONST narrows when const value ≤ u8" {
    // `const PRINT = $10` resolves the bare ident to an imm8
    // operand, matching the `int Imm8` shape. Same on-wire bytes
    // as `int $10`.
    var out = try assemble(
        \\const PRINT = $10
        \\int PRINT
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqualSlices(u8, &.{ 0xFC, 0x10 }, out.imageBody());
}

test "codegen: local labels resolve against the enclosing global" {
    var out = try assemble(
        \\main:
        \\.loop:
        \\  jmp .loop
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    // image: jmp(0x90) + addr LE(0x0000) — local label resolves to
    // offset 0, the address of `main:` / `.loop:` (they share the
    // same byte address since neither emits code before .loop).
    try std.testing.expectEqualSlices(u8, &.{ 0x90, 0x00, 0x00 }, out.imageBody());
}

test "codegen: same local-label name reuses across global scopes" {
    var out = try assemble(
        \\first:
        \\.done:
        \\  hlt
        \\second:
        \\.done:
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
}

test "codegen: undefined label_ref suggests a close-by name via `note`" {
    var out = try assemble(
        \\nowhere:
        \\  hlt
        \\main:
        \\  jmp nowher
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var found = false;
    for (out.cg.errors) |e| {
        if (e.code == .undefined_symbol) {
            if (e.note) |n| if (std.mem.eql(u8, n, "nowhere")) {
                found = true;
            };
        }
    }
    try std.testing.expect(found);
}

test "codegen: local label with no enclosing global is E004-shape" {
    var out = try assemble(
        \\.orphan:
        \\hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
}

test "codegen: int CONST errors when const value > u8" {
    // `const BIG = $1234` → label_ref reports .imm16, no imm16
    // shape for `int`, no widening possible — E003.
    var out = try assemble(
        \\const BIG = $1234
        \\int BIG
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
}

test "codegen: shl r1, $03 uses imm8 shape (0x70 reg imm8)" {
    var out = try assemble("shl r1, $03\n", .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqualSlices(u8, &.{ 0x70, 0x02, 0x03 }, out.imageBody());
}

test "codegen: mov $00, r1 widens imm8 → imm16 (4 bytes, not 3)" {
    var out = try assemble("mov $00, r1\n", .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    // mov has no Imm8,Reg shape — only Imm16,Reg. Widening picks
    // 0x10 with 2-byte LE imm + reg.
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x00, 0x00, 0x02 }, out.imageBody());
}

test "codegen: int $1234 errors — imm16 won't narrow to imm8 shape" {
    var out = try assemble("int $1234\n", .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var saw_mismatch = false;
    for (out.cg.errors) |e| {
        if (e.code == .operand_type_mismatch) saw_mismatch = true;
    }
    try std.testing.expect(saw_mismatch);
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
    //   80 02 10 00            cmp r1, $0010
    //   93 04 00               jne &0004
    //   FF                     hlt
    const expected = [_]u8{
        0x10, 0x00, 0x00, 0x02,
        0x48, 0x02, 0x80, 0x02,
        0x10, 0x00, 0x93, 0x04,
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
    // jmp Addr = opcode 0x90 + addr LE. `end` is at offset 4
    // (jmp = 3 bytes, hlt = 1 byte). Encoding: 70 04 00.
    try std.testing.expectEqualSlices(u8, &.{ 0x90, 0x04, 0x00, 0xFF, 0xFF }, out.imageBody());
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
        if (e.code == .backward_org) saw_backward = true;
    }
    try std.testing.expect(saw_backward);
}

// ---------- header ----------

// ---------- bank / sram directives (issue #96) ----------

test "codegen: no bank directive → header bank_count = 0, no banked flag" {
    var out = try assemble("hlt\n", .{});
    defer out.deinit();
    // bank_count byte
    try std.testing.expectEqual(@as(u8, 0), out.cg.image[0x0C]);
    // flags low byte — bit 0 = banked → must be 0
    try std.testing.expectEqual(@as(u8, 0), out.cg.image[6] & 0x01);
}

test "codegen: bank $00 emits 1 banked slot + sets banked flag" {
    var out = try assemble(
        \\main:
        \\  hlt
        \\bank $00
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 1), out.cg.image[0x0C]); // bank_count
    try std.testing.expect((out.cg.image[6] & 0x01) != 0); // banked flag set
    // Archive: 16 (header) + base + 16 KB bank = 16 + N + 16384
    // The base is `hlt` = 1 byte → total = 16401.
    try std.testing.expectEqual(@as(usize, 16 + 1 + 0x4000), out.cg.image.len);
}

test "codegen: highest bank index drives bank_count (gaps zero-filled)" {
    var out = try assemble(
        \\main:
        \\  hlt
        \\bank $02
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    // max_bank = 2 → bank_count = 3 (banks 0, 1, 2 — 0 and 1 are zeros)
    try std.testing.expectEqual(@as(u8, 3), out.cg.image[0x0C]);
    try std.testing.expectEqual(@as(usize, 16 + 1 + 3 * 0x4000), out.cg.image.len);
}

test "codegen: sram_banks N populates the header byte" {
    var out = try assemble(
        \\sram_banks $02
        \\bank $00
        \\  hlt
        \\bank $01
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 2), out.cg.image[0x0D]); // sram_bank_count
    try std.testing.expectEqual(@as(u8, 2), out.cg.image[0x0C]); // bank_count
}

test "codegen: sram_banks without any bank declaration is E017" {
    var out = try assemble(
        \\sram_banks $01
        \\main:
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var found = false;
    for (out.cg.errors) |e| if (e.code == .sram_without_banks) {
        found = true;
    };
    try std.testing.expect(found);
}

test "codegen: sram_banks exceeding bank_count is E017" {
    var out = try assemble(
        \\sram_banks $03
        \\bank $00
        \\  hlt
        \\bank $01
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var found = false;
    for (out.cg.errors) |e| if (e.code == .sram_without_banks) {
        found = true;
    };
    try std.testing.expect(found);
}

test "codegen: sram_banks equal to bank_count passes" {
    var out = try assemble(
        \\sram_banks $02
        \\bank $00
        \\  hlt
        \\bank $01
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
}

test "codegen: org in base image targeting bank window is E007" {
    var out = try assemble(
        \\org $C100
        \\hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var found = false;
    for (out.cg.errors) |e| if (e.code == .addr_out_of_range) {
        found = true;
    };
    try std.testing.expect(found);
}

test "codegen: org inside `bank N` targeting outside the window is E007" {
    var out = try assemble(
        \\bank $00
        \\org $0010
        \\hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var found = false;
    for (out.cg.errors) |e| if (e.code == .addr_out_of_range) {
        found = true;
    };
    try std.testing.expect(found);
}

test "codegen: org inside `bank N` targeting the window is accepted" {
    var out = try assemble(
        \\bank $00
        \\org $C100
        \\hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
}

test "codegen: labels inside `bank N` resolve to bank-window addresses" {
    // `call greet` should emit a `call $C000` (the greet label
    // sits at offset 0 of bank 0 → CPU $C000 when mb = $00).
    var out = try assemble(
        \\main:
        \\  call greet
        \\  hlt
        \\bank $00
        \\greet:
        \\  ret
        \\
    , .{});
    defer out.deinit();
    // image[0..3] = call $C000 → 0xA0 LE($C000)
    try std.testing.expectEqual(@as(u8, 0xA0), out.cg.image[16]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[17]);
    try std.testing.expectEqual(@as(u8, 0xC0), out.cg.image[18]);
}

// ---------- debug symbols (issue #100) ----------

test "codegen: debug symbols emit by default — flag bit + sorted entries" {
    var out = try assembleRaw(
        \\main:
        \\  hlt
        \\helper:
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    // Flags low byte: bit 1 = has-debug
    try std.testing.expect((out.cg.image[6] & 0x02) != 0);
    // Trailing blob: count u16 LE = 2, then sorted by address.
    // Entry layout per ISA §7.3: addr(2) + kind(1) + name_len(1) + name.
    const tail_start = 16 + 2; // header + 2-byte image (2 hlt)
    try std.testing.expectEqual(@as(u8, 0x02), out.cg.image[tail_start]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[tail_start + 1]);
    // First entry: addr 0x0000, kind=label(0), name="main"
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[tail_start + 2]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[tail_start + 3]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[tail_start + 4]); // kind = label
    try std.testing.expectEqual(@as(u8, 4), out.cg.image[tail_start + 5]); // name_len
    try std.testing.expectEqualSlices(u8, "main", out.cg.image[tail_start + 6 ..][0..4]);
    // Second entry: addr 0x0001, kind=label, name="helper" — starts at tail+10
    try std.testing.expectEqual(@as(u8, 0x01), out.cg.image[tail_start + 10]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[tail_start + 12]); // kind = label
    try std.testing.expectEqualSlices(u8, "helper", out.cg.image[tail_start + 14 ..][0..6]);
}

test "codegen: debug_symbols=false skips the section + flag" {
    var out = try assembleRaw("main:\n  hlt\n", .{ .debug_symbols = false });
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 0), out.cg.image[6] & 0x02); // flag bit clear
    // Total = 16 header + 1 image byte (hlt), no trailing blob.
    try std.testing.expectEqual(@as(usize, 17), out.cg.image.len);
}

test "codegen: debug symbols skip local labels + consts" {
    // Locals (`.loop`) get mangled with a `.` which isn't a valid
    // ident — exclude. Consts are values, not addresses — also
    // exclude. Only `main` should make it into the blob.
    var out = try assembleRaw(
        \\const N = $05
        \\main:
        \\.loop:
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    const tail_start = 16 + 1; // header + 1 image byte (hlt)
    // symbol_count = 1
    try std.testing.expectEqual(@as(u8, 0x01), out.cg.image[tail_start]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[tail_start + 1]);
    // The one entry is "main" — kind=label(0), name_len=4
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[tail_start + 4]); // kind = label
    try std.testing.expectEqual(@as(u8, 4), out.cg.image[tail_start + 5]); // name_len
    try std.testing.expectEqualSlices(u8, "main", out.cg.image[tail_start + 6 ..][0..4]);
}

test "codegen: data declarations emit with kind=1 (data)" {
    var out = try assembleRaw(
        \\data8 GREETING = $48, $69
        \\
    , .{});
    defer out.deinit();
    const tail_start = 16 + 2; // header + 2 image bytes
    // First entry should have kind = data(1).
    try std.testing.expectEqual(@as(u8, 0x01), out.cg.image[tail_start + 4]);
}

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

test "codegen: entry_point auto-detects a `main:` label" {
    // `nop` then `main:` then `hlt`. main is at offset 1.
    var out = try assemble(
        \\nop
        \\main:
        \\hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 0x01), out.cg.image[8]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[9]);
}

test "codegen: entry_point defaults to 0 when no `main:` label exists" {
    var out = try assemble("hlt\n", .{});
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[8]);
    try std.testing.expectEqual(@as(u8, 0x00), out.cg.image[9]);
}

test "codegen: explicit entry_point overrides `main:` auto-detect" {
    var out = try assemble(
        \\main:
        \\hlt
        \\
    , .{ .entry_point = 0x2222 });
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 0x22), out.cg.image[8]);
    try std.testing.expectEqual(@as(u8, 0x22), out.cg.image[9]);
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
        if (e.code == .duplicate_label) saw_dup = true;
    }
    try std.testing.expect(saw_dup);
}

test "codegen: undefined symbol in operand raises E004-shape" {
    var out = try assemble("jmp nowhere\n", .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var saw_undefined = false;
    for (out.cg.errors) |e| {
        if (e.code == .undefined_symbol) saw_undefined = true;
    }
    try std.testing.expect(saw_undefined);
}

test "codegen: unknown mnemonic raises E001-shape" {
    var out = try assemble("foobar r1\n", .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    var saw_unknown = false;
    for (out.cg.errors) |e| {
        if (e.code == .unknown_mnemonic) saw_unknown = true;
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
        if (e.code == .operand_type_mismatch) saw_mismatch = true;
    }
    try std.testing.expect(saw_mismatch);
}

test "codegen: division by zero in const expr raises E009-shape" {
    // The const evaluator raises div_by_zero; it surfaces in the
    // parse-time errors propagated through codegen.
    var pt = try gero.asm_.parse(alloc, "const N = $0010 / $0000\nhlt\n");
    defer pt.deinit();
    try std.testing.expect(pt.errors.len > 0);
    var saw_div = false;
    for (pt.errors) |e| {
        if (e.code == .div_by_zero) saw_div = true;
    }
    try std.testing.expect(saw_div);
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

// ---------- Zero-page mov peephole ----------

test "codegen: mov reg → &XX (value ≤ 0xFF) downgrades to ZP opcode 0x19" {
    var out = try assemble(
        \\main:
        \\  mov r1, &0042
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    // entry point + program image: instruction at offset 0 should
    // be `0x19 reg zp` (3 bytes), not `0x12 reg addr addr` (4 bytes).
    try std.testing.expectEqual(@as(u8, 0x19), out.imageBody()[0]);
}

test "codegen: mov &XX → reg (value ≤ 0xFF) downgrades to ZP opcode 0x1A" {
    var out = try assemble(
        \\main:
        \\  mov &0080, r1
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x1A), out.imageBody()[0]);
}

test "codegen: mov imm16 → &XX (value ≤ 0xFF) downgrades to ZP opcode 0x1B" {
    var out = try assemble(
        \\main:
        \\  mov $1234, &00FF
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x1B), out.imageBody()[0]);
}

test "codegen: mov reg → &XXXX (value > 0xFF) keeps regular Addr opcode 0x12" {
    var out = try assemble(
        \\main:
        \\  mov r1, &0100
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x12), out.imageBody()[0]);
}

test "codegen: ZP downgrade is byte-for-byte smaller than Addr form" {
    var with_zp = try assemble(
        \\main:
        \\  mov r1, &0042
        \\  hlt
        \\
    , .{});
    defer with_zp.deinit();
    var with_addr = try assemble(
        \\main:
        \\  mov r1, &0142
        \\  hlt
        \\
    , .{});
    defer with_addr.deinit();
    // ZP variant emits 3 bytes (opcode + reg + zp), Addr emits 4
    // (opcode + reg + addr_lo + addr_hi). The hlt + entry-point
    // overhead is identical, so the difference is 1 byte.
    try std.testing.expectEqual(@as(usize, 1), with_addr.cg.image.len - with_zp.cg.image.len);
}

test "codegen: jmp &XX never downgrades (no ZP variant exists)" {
    // Pass 3 resolver fallback widens `.zp` → `.addr` when no
    // matching ZP shape exists. `jmp` has only an Addr form, so the
    // emit stays at 3 bytes (opcode + addr_lo + addr_hi).
    var out = try assemble(
        \\main:
        \\  jmp &0042
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    // jmp opcode 0x90 + 2-byte addr — 3 bytes total.
    try std.testing.expectEqual(@as(u8, 0x90), out.imageBody()[0]);
    try std.testing.expectEqual(@as(u8, 0x42), out.imageBody()[1]);
    try std.testing.expectEqual(@as(u8, 0x00), out.imageBody()[2]);
}

test "codegen: mov8 imm8 → &XX downgrades to ZP opcode 0x28" {
    var out = try assemble(
        \\main:
        \\  mov8 $42, &0080
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x28), out.imageBody()[0]);
}

test "codegen: mov8 &XX → reg downgrades to ZP opcode 0x29" {
    var out = try assemble(
        \\main:
        \\  mov8 &0042, r1
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x29), out.imageBody()[0]);
}

test "codegen: movh reg → &XX downgrades to ZP opcode 0x2A" {
    var out = try assemble(
        \\main:
        \\  movh r1, &0042
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x2A), out.imageBody()[0]);
}

test "codegen: movl reg → &XX downgrades to ZP opcode 0x2B" {
    var out = try assemble(
        \\main:
        \\  movl r1, &0042
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x2B), out.imageBody()[0]);
}

// ---------- bank_call / bank_jump pseudo-instructions ----------

test "codegen: bank_call <label-in-bank> emits mov $bank, mb + call <addr>" {
    var out = try assemble(
        \\main:
        \\  bank_call greet
        \\  hlt
        \\
        \\bank $00
        \\greet:
        \\  ret
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    // 7-byte expansion: 0x10 (movImm16Reg) + imm16($0000) + 0x0C (mb)
    //                 + 0xA0 (call) + addr16
    const body = out.imageBody();
    try std.testing.expectEqual(@as(u8, 0x10), body[0]);
    try std.testing.expectEqual(@as(u8, 0x00), body[1]); // bank low
    try std.testing.expectEqual(@as(u8, 0x00), body[2]); // bank high
    try std.testing.expectEqual(@as(u8, 0x0C), body[3]); // mb register
    try std.testing.expectEqual(@as(u8, 0xA0), body[4]); // call opcode
    // Bytes 5-6 = call target address (bank-window-relative).
}

test "codegen: bank_jump emits jmp opcode (0x90) instead of call (0xA0)" {
    var out = try assemble(
        \\main:
        \\  bank_jump greet
        \\
        \\bank $00
        \\greet:
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    try std.testing.expectEqual(@as(u8, 0x90), out.imageBody()[4]);
}

test "codegen: bank_call into a higher-numbered bank emits the bank index" {
    var out = try assemble(
        \\main:
        \\  bank_call deep
        \\  hlt
        \\
        \\bank $02
        \\deep:
        \\  ret
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(!out.cg.hasErrors());
    const body = out.imageBody();
    try std.testing.expectEqual(@as(u8, 0x10), body[0]);
    try std.testing.expectEqual(@as(u8, 0x02), body[1]); // bank = 2
    try std.testing.expectEqual(@as(u8, 0x0C), body[3]);
}

test "codegen: bank_call on a const rejects with E003" {
    var out = try assemble(
        \\const FOO = $42
        \\main:
        \\  bank_call FOO
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    try std.testing.expectEqual(gero.asm_.ErrorCode.operand_type_mismatch, out.cg.errors[0].code.?);
}

test "codegen: bank_call on undefined symbol rejects with E004" {
    var out = try assemble(
        \\main:
        \\  bank_call missing
        \\  hlt
        \\
    , .{});
    defer out.deinit();
    try std.testing.expect(out.cg.hasErrors());
    try std.testing.expectEqual(gero.asm_.ErrorCode.undefined_symbol, out.cg.errors[0].code.?);
}
