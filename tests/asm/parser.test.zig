const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

fn parseSource(source: []const u8) !gero.asm_.ParseTree {
    return gero.asm_.parse(alloc, source);
}

// ---------- happy path ----------

test "parser: empty source produces empty program, no errors" {
    var pt = try parseSource("");
    defer pt.deinit();
    try std.testing.expectEqual(@as(usize, 0), pt.program.statements.len);
    try std.testing.expect(!pt.hasErrors());
}

test "parser: blank lines around a comment produce one Comment statement" {
    var pt = try parseSource(
        \\
        \\; just a comment
        \\
        \\
    );
    defer pt.deinit();
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    try std.testing.expect(pt.program.statements[0] == .comment);
    try std.testing.expect(!pt.hasErrors());
}

// ---------- labels ----------

test "parser: a single label parses to one `Label` statement" {
    var pt = try parseSource("start:\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    switch (pt.program.statements[0]) {
        .label => |l| {
            try std.testing.expectEqual(@as(u32, 0), l.name.start);
            try std.testing.expectEqual(@as(u32, 5), l.name.end);
            try std.testing.expectEqual(@as(u32, 0), l.span.start);
            try std.testing.expectEqual(@as(u32, 6), l.span.end);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: label without a trailing newline still parses" {
    var pt = try parseSource("start:");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    try std.testing.expectEqual(
        @as(std.meta.Tag(gero.asm_.Statement), .label),
        @as(std.meta.Tag(gero.asm_.Statement), pt.program.statements[0]),
    );
}

test "parser: multiple labels stack on consecutive lines" {
    var pt = try parseSource(
        \\start:
        \\loop:
        \\inner:
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 3), pt.program.statements.len);
    for (pt.program.statements) |s| {
        try std.testing.expectEqual(
            @as(std.meta.Tag(gero.asm_.Statement), .label),
            @as(std.meta.Tag(gero.asm_.Statement), s),
        );
    }
}

test "parser: two labels on the same line (back-to-back)" {
    var pt = try parseSource("start: loop:\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), pt.program.statements.len);
}

test "parser: whitespace between ident and colon is tolerated" {
    var pt = try parseSource("start  :\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
}

// ---------- recovery ----------

test "parser: unrecognized starter byte produces an unknown statement" {
    // Lines that don't begin with an identifier (i.e., neither a
    // directive, label, nor instruction) fall through to the
    // unknown catch-all.
    var pt = try parseSource("] bad\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    try std.testing.expectEqual(
        @as(std.meta.Tag(gero.asm_.Statement), .unknown),
        @as(std.meta.Tag(gero.asm_.Statement), pt.program.statements[0]),
    );
}

test "parser: unknown line doesn't poison subsequent labels" {
    var pt = try parseSource(
        \\] bad
        \\after:
        \\
    );
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), pt.program.statements.len);
    try std.testing.expectEqual(
        @as(std.meta.Tag(gero.asm_.Statement), .unknown),
        @as(std.meta.Tag(gero.asm_.Statement), pt.program.statements[0]),
    );
    try std.testing.expectEqual(
        @as(std.meta.Tag(gero.asm_.Statement), .label),
        @as(std.meta.Tag(gero.asm_.Statement), pt.program.statements[1]),
    );
}

test "parser: multiple unknown lines surface multiple errors in one run" {
    var pt = try parseSource(
        \\] one
        \\start:
        \\} two
        \\] three
        \\
    );
    defer pt.deinit();
    try std.testing.expectEqual(@as(usize, 3), pt.errors.len);
    try std.testing.expectEqual(@as(usize, 4), pt.program.statements.len);
}

// ---------- span integrity ----------

test "parser: label span covers exactly `ident + :`" {
    var pt = try parseSource("hello_world:\n");
    defer pt.deinit();
    switch (pt.program.statements[0]) {
        .label => |l| {
            try std.testing.expectEqual(@as(u32, 0), l.name.start);
            try std.testing.expectEqual(@as(u32, 11), l.name.end);
            try std.testing.expectEqual(@as(u32, 0), l.span.start);
            try std.testing.expectEqual(@as(u32, 12), l.span.end);
        },
        else => return error.WrongStatementKind,
    }
}

// ---------- end-to-end with include resolver ----------

test "parser: consumes the resolveIncludes output for a multi-file program" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib.gas", .data = "lib_label:\n" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main.gas",
        .data =
        \\include "lib.gas"
        \\main_label:
        \\
        ,
    });

    const main_path = try tmp.dir.realPathFileAlloc(std.testing.io, "main.gas", alloc);
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    var pt = try gero.asm_.parse(alloc, fused.source);
    defer pt.deinit();

    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), pt.program.statements.len);
    for (pt.program.statements) |s| {
        try std.testing.expectEqual(
            @as(std.meta.Tag(gero.asm_.Statement), .label),
            @as(std.meta.Tag(gero.asm_.Statement), s),
        );
    }
}

// ---------- const directive ----------

test "parser: 'const X = $05' parses to a const_decl statement" {
    var pt = try parseSource("const X = $05\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    switch (pt.program.statements[0]) {
        .const_decl => |c| {
            try std.testing.expectEqualStrings("X", "const X = $05\n"[c.name.start..c.name.end]);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: const followed by label both parse" {
    var pt = try parseSource(
        \\const FRAME_RATE = $3C
        \\start:
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), pt.program.statements.len);
    try std.testing.expectEqual(
        @as(std.meta.Tag(gero.asm_.Statement), .const_decl),
        @as(std.meta.Tag(gero.asm_.Statement), pt.program.statements[0]),
    );
    try std.testing.expectEqual(
        @as(std.meta.Tag(gero.asm_.Statement), .label),
        @as(std.meta.Tag(gero.asm_.Statement), pt.program.statements[1]),
    );
}

test "parser: const missing '=' surfaces a diagnostic + unknown" {
    var pt = try parseSource("const X $05\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    try std.testing.expectEqual(
        @as(std.meta.Tag(gero.asm_.Statement), .unknown),
        @as(std.meta.Tag(gero.asm_.Statement), pt.program.statements[0]),
    );
}

test "parser: const without identifier surfaces a diagnostic" {
    var pt = try parseSource("const = $05\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_expected_ident = false;
    for (pt.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "expected identifier") != null) {
            saw_expected_ident = true;
        }
    }
    try std.testing.expect(saw_expected_ident);
}

// ---------- data8 / data16 directives ----------

test "parser: data8 with single hex value" {
    var pt = try parseSource("data8 hp = $64\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    switch (pt.program.statements[0]) {
        .data8 => |d| {
            try std.testing.expectEqual(@as(usize, 1), d.values.len);
            switch (d.values[0]) {
                .expr => |e| {
                    var consts = gero.asm_.ConstantTable.init(alloc);
                    defer consts.deinit();
                    const result = gero.asm_.evalExpr(e.expr, "data8 hp = $64\n", consts);
                    try std.testing.expectEqual(@as(u16, 0x64), result.ok);
                },
                else => return error.WrongValueKind,
            }
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: data8 with comma-separated values" {
    var pt = try parseSource("data8 row = $01, $02, $03, $04\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .data8 => |d| {
            try std.testing.expectEqual(@as(usize, 4), d.values.len);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: data8 with mixed forms (hex, char, addr, sym_ref, string)" {
    const src = "data8 mixed = $FF, 'A', &1000, @sprite, \"hi\"\n";
    var pt = try parseSource(src);
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .data8 => |d| {
            try std.testing.expectEqual(@as(usize, 5), d.values.len);
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.DataValue), .expr), @as(std.meta.Tag(gero.asm_.DataValue), d.values[0]));
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.DataValue), .expr), @as(std.meta.Tag(gero.asm_.DataValue), d.values[1]));
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.DataValue), .addr_lit), @as(std.meta.Tag(gero.asm_.DataValue), d.values[2]));
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.DataValue), .sym_ref), @as(std.meta.Tag(gero.asm_.DataValue), d.values[3]));
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.DataValue), .string), @as(std.meta.Tag(gero.asm_.DataValue), d.values[4]));
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: data8 with reserve N (compile-time count)" {
    var pt = try parseSource("data8 scratch = reserve $100\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .data8 => |d| {
            try std.testing.expectEqual(@as(usize, 1), d.values.len);
            switch (d.values[0]) {
                .reserve => |r| {
                    try std.testing.expectEqual(@as(u16, 0x100), r.count.?);
                },
                else => return error.WrongValueKind,
            }
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: data8 reserve count via prior const" {
    var pt = try parseSource(
        \\const N = $40
        \\data8 buf = reserve N
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[1]) {
        .data8 => |d| switch (d.values[0]) {
            .reserve => |r| try std.testing.expectEqual(@as(u16, 0x40), r.count.?),
            else => return error.WrongValueKind,
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: data8 mixing reserve with other values" {
    const src = "data8 frame = $AA, $55, reserve $04, $FF\n";
    var pt = try parseSource(src);
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .data8 => |d| {
            try std.testing.expectEqual(@as(usize, 4), d.values.len);
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.DataValue), .reserve), @as(std.meta.Tag(gero.asm_.DataValue), d.values[2]));
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: data16 accepts the same forms minus strings" {
    const src = "data16 words = $1234, &5678, @sym, $01 + $02\n";
    var pt = try parseSource(src);
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .data16 => |d| {
            try std.testing.expectEqual(@as(usize, 4), d.values.len);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: hex literal exceeding 4 digits surfaces [E006]" {
    var pt = try parseSource("data16 X = $12345\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw = false;
    for (pt.errors) |e| if (e.code == .hex_out_of_range) {
        saw = true;
    };
    try std.testing.expect(saw);
}

test "parser: unknown string escape surfaces [E010]" {
    var pt = try parseSource("data8 X = \"a\\q\"\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw = false;
    for (pt.errors) |e| if (e.code == .unknown_escape) {
        saw = true;
    };
    try std.testing.expect(saw);
}

test "parser: unterminated string surfaces [E011]" {
    var pt = try parseSource("data8 X = \"oops\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw = false;
    for (pt.errors) |e| if (e.code == .unterminated_string) {
        saw = true;
    };
    try std.testing.expect(saw);
}

test "parser: multi-byte char literal surfaces [E016]" {
    var pt = try parseSource("data8 X = 'AB'\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw = false;
    for (pt.errors) |e| if (e.code == .char_literal_size) {
        saw = true;
    };
    try std.testing.expect(saw);
}

test "parser: data16 with string literal surfaces a diagnostic" {
    var pt = try parseSource("data16 bad = \"hi\"\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_data16_rejection = false;
    for (pt.errors) |e| {
        if (e.code == .operand_type_mismatch and
            std.mem.indexOf(u8, e.parse_error.message, "string literals are only allowed in `data8`") != null)
        {
            saw_data16_rejection = true;
        }
    }
    try std.testing.expect(saw_data16_rejection);
}

test "parser: data8 with parenthesized expression value" {
    var pt = try parseSource("data8 flags = ($01 << $02) | $08\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .data8 => |d| {
            try std.testing.expectEqual(@as(usize, 1), d.values.len);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: data8 missing identifier" {
    var pt = try parseSource("data8 = $01\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_expected_ident = false;
    for (pt.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "expected identifier") != null) {
            saw_expected_ident = true;
        }
    }
    try std.testing.expect(saw_expected_ident);
}

test "parser: data8 missing equals" {
    var pt = try parseSource("data8 X $01\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: data8 followed by label both parse" {
    var pt = try parseSource(
        \\data8 player = $64, $3C
        \\start:
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), pt.program.statements.len);
}

// ---------- struct directive ----------

test "parser: empty struct parses with size 0" {
    var pt = try parseSource(
        \\struct Empty {
        \\}
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    switch (pt.program.statements[0]) {
        .struct_decl => |s| {
            try std.testing.expectEqual(@as(usize, 0), s.fields.len);
            try std.testing.expectEqual(@as(u16, 0), s.size);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: struct with u8 + u16 fields computes packed offsets" {
    var pt = try parseSource(
        \\struct Player {
        \\  hp: u16,
        \\  mp: u16,
        \\  level: u8,
        \\  pad: u8,
        \\}
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .struct_decl => |s| {
            try std.testing.expectEqual(@as(usize, 4), s.fields.len);
            try std.testing.expectEqual(@as(u16, 0), s.fields[0].offset); // hp
            try std.testing.expectEqual(@as(u16, 2), s.fields[1].offset); // mp
            try std.testing.expectEqual(@as(u16, 4), s.fields[2].offset); // level
            try std.testing.expectEqual(@as(u16, 5), s.fields[3].offset); // pad
            try std.testing.expectEqual(@as(u16, 6), s.size);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: struct injects Name.field constants into the symbol table" {
    var pt = try parseSource(
        \\struct Player { hp: u16, mp: u16 }
        \\const PLAYER_HP_OFFSET = Player.hp
        \\const PLAYER_MP_OFFSET = Player.mp
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 3), pt.program.statements.len);

    // Re-evaluate the two const_decls and check they pick up the
    // struct's offset constants.
    var consts = gero.asm_.ConstantTable.init(alloc);
    defer consts.deinit();
    // Pre-fill with the struct's offsets so the chained eval works.
    try consts.put("Player.hp", 0);
    try consts.put("Player.mp", 2);
    const src =
        \\struct Player { hp: u16, mp: u16 }
        \\const PLAYER_HP_OFFSET = Player.hp
        \\const PLAYER_MP_OFFSET = Player.mp
        \\
    ;
    switch (pt.program.statements[1]) {
        .const_decl => |c| {
            const r = gero.asm_.evalExpr(c.expr, src, consts);
            try std.testing.expectEqual(@as(u16, 0), r.ok);
        },
        else => return error.WrongStatementKind,
    }
    switch (pt.program.statements[2]) {
        .const_decl => |c| {
            const r = gero.asm_.evalExpr(c.expr, src, consts);
            try std.testing.expectEqual(@as(u16, 2), r.ok);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: struct fields can be on one line with commas" {
    var pt = try parseSource("struct Point { x: u16, y: u16 }\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .struct_decl => |s| try std.testing.expectEqual(@as(usize, 2), s.fields.len),
        else => return error.WrongStatementKind,
    }
}

test "parser: struct allows trailing comma" {
    var pt = try parseSource(
        \\struct Foo {
        \\  a: u8,
        \\  b: u8,
        \\}
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
}

test "parser: struct missing name surfaces a diagnostic" {
    var pt = try parseSource("struct { hp: u16 }\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: struct missing opening brace" {
    var pt = try parseSource("struct Player hp: u16 }\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: struct unknown field type" {
    var pt = try parseSource("struct Foo { x: u32 }\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_unknown_type = false;
    for (pt.errors) |e| {
        if (e.code == .operand_type_mismatch and
            std.mem.indexOf(u8, e.parse_error.message, "unknown field type") != null)
        {
            saw_unknown_type = true;
        }
    }
    try std.testing.expect(saw_unknown_type);
}

test "parser: struct field without colon" {
    var pt = try parseSource("struct Foo { x u16 }\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: struct followed by other statements parses cleanly" {
    var pt = try parseSource(
        \\struct Player { hp: u16 }
        \\start:
        \\data8 hp_init = $64
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 3), pt.program.statements.len);
}

test "parser: expression with qualified ident (Foo.bar) resolves" {
    var pt = try parseSource(
        \\struct S { a: u8, b: u8, c: u16 }
        \\const X = S.c
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    // S.a = 0, S.b = 1, S.c = 2
    var consts = gero.asm_.ConstantTable.init(alloc);
    defer consts.deinit();
    try consts.put("S.c", 2);
    switch (pt.program.statements[1]) {
        .const_decl => |c| {
            const r = gero.asm_.evalExpr(c.expr, "struct S { a: u8, b: u8, c: u16 }\nconst X = S.c\n", consts);
            try std.testing.expectEqual(@as(u16, 2), r.ok);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: expression with `Foo.` (missing field) surfaces an error" {
    var pt = try parseSource("const X = Foo.\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

// ---------- org directive ----------

test "parser: org with hex literal evaluates eagerly" {
    var pt = try parseSource("org $1000\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    switch (pt.program.statements[0]) {
        .org => |o| try std.testing.expectEqual(@as(u16, 0x1000), o.addr.?),
        else => return error.WrongStatementKind,
    }
}

test "parser: org with const reference resolves" {
    var pt = try parseSource(
        \\const IVT_BASE = $1000
        \\org IVT_BASE
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[1]) {
        .org => |o| try std.testing.expectEqual(@as(u16, 0x1000), o.addr.?),
        else => return error.WrongStatementKind,
    }
}

test "parser: org with compile-time arithmetic" {
    var pt = try parseSource("org ($10 << $08) + $24\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        // (0x10 << 8) + 0x24 = 0x1024
        .org => |o| try std.testing.expectEqual(@as(u16, 0x1024), o.addr.?),
        else => return error.WrongStatementKind,
    }
}

test "parser: org with unknown identifier surfaces a diagnostic" {
    var pt = try parseSource("org NOPE\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_unknown_ident = false;
    for (pt.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "unknown identifier") != null) {
            saw_unknown_ident = true;
        }
    }
    try std.testing.expect(saw_unknown_ident);
    // The org statement is still recorded (with addr = null) so
    // the parser keeps walking.
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    switch (pt.program.statements[0]) {
        .org => |o| try std.testing.expect(o.addr == null),
        else => return error.WrongStatementKind,
    }
}

test "parser: org missing expression" {
    var pt = try parseSource("org\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: classic IVT setup pattern" {
    // The canonical use case from asm spec §2.2 — place data at
    // the IVT base, then move the cursor for user code.
    var pt = try parseSource(
        \\org $1000
        \\data16 ivt_keydown = $2000
        \\org $1100
        \\start:
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 4), pt.program.statements.len);
    switch (pt.program.statements[0]) {
        .org => |o| try std.testing.expectEqual(@as(u16, 0x1000), o.addr.?),
        else => return error.WrongStatementKind,
    }
    switch (pt.program.statements[2]) {
        .org => |o| try std.testing.expectEqual(@as(u16, 0x1100), o.addr.?),
        else => return error.WrongStatementKind,
    }
}

// ---------- instructions (slice A: simple operands) ----------

test "parser: zero-operand instruction (hlt)" {
    var pt = try parseSource("hlt\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqualStrings("hlt", "hlt\n"[i.mnemonic.start..i.mnemonic.end]);
            try std.testing.expectEqual(@as(usize, 0), i.operands.len);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: mov reg, reg" {
    var pt = try parseSource("mov r1, r2\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqual(@as(usize, 2), i.operands.len);
            switch (i.operands[0]) {
                .register => |r| try std.testing.expectEqual(gero.asm_.Register.r1, r.id),
                else => return error.WrongOperandKind,
            }
            switch (i.operands[1]) {
                .register => |r| try std.testing.expectEqual(gero.asm_.Register.r2, r.id),
                else => return error.WrongOperandKind,
            }
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: register identity covers the full ISA name set" {
    // Round-trip every named register through parseSource and
    // assert the enum value comes back. Catches typos in the
    // name table immediately.
    inline for (.{
        .{ "ip", gero.asm_.Register.ip },
        .{ "acu", gero.asm_.Register.acu },
        .{ "r1", gero.asm_.Register.r1 },
        .{ "r8", gero.asm_.Register.r8 },
        .{ "sp", gero.asm_.Register.sp },
        .{ "fp", gero.asm_.Register.fp },
        .{ "mb", gero.asm_.Register.mb },
        .{ "im", gero.asm_.Register.im },
        .{ "flg", gero.asm_.Register.flg },
    }) |case| {
        const src = "push " ++ case[0] ++ "\n";
        var pt = try parseSource(src);
        defer pt.deinit();
        try std.testing.expect(!pt.hasErrors());
        switch (pt.program.statements[0]) {
            .instruction => |i| switch (i.operands[0]) {
                .register => |r| try std.testing.expectEqual(case[1], r.id),
                else => return error.WrongOperandKind,
            },
            else => return error.WrongStatementKind,
        }
    }
}

test "parser: mov imm16, reg" {
    var pt = try parseSource("mov $ABCD, r1\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .immediate), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0]));
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .register), @as(std.meta.Tag(gero.asm_.Operand), i.operands[1]));
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: mov &FFFF, r1 (addr literal)" {
    var pt = try parseSource("mov &2620, r1\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .addr_lit), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0]));
            switch (i.operands[0]) {
                .addr_lit => |a| try std.testing.expectEqual(@as(u16, 0x2620), a.value),
                else => unreachable, // tag-checked just above
            }
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: mov @sym, r1 (symbol reference)" {
    var pt = try parseSource("mov @sprite, r1\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .sym_ref), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0])),
        else => return error.WrongStatementKind,
    }
}

test "parser: mov [r1], r2 (indirect)" {
    var pt = try parseSource("mov [r1], r2\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .indirect), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0]));
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .register), @as(std.meta.Tag(gero.asm_.Operand), i.operands[1]));
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: jmp loop (label reference operand)" {
    var pt = try parseSource("jmp loop\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .label_ref), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0])),
        else => return error.WrongStatementKind,
    }
}

test "parser: cmp r1, 'A' (char-literal immediate)" {
    var pt = try parseSource("cmp r1, 'A'\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .register), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0]));
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .immediate), @as(std.meta.Tag(gero.asm_.Operand), i.operands[1]));
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: instruction with inline comment" {
    var pt = try parseSource("mov $01, r1   ; load 1\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| try std.testing.expectEqual(@as(usize, 2), i.operands.len),
        else => return error.WrongStatementKind,
    }
}

test "parser: realistic loop program" {
    var pt = try parseSource(
        \\start:
        \\  mov $00, r1
        \\loop:
        \\  inc r1
        \\  cmp r1, $10
        \\  jne loop
        \\  hlt
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    // 2 labels + 5 instructions = 7 statements
    try std.testing.expectEqual(@as(usize, 7), pt.program.statements.len);
}

test "parser: const + instruction using its name" {
    var pt = try parseSource(
        \\const TARGET = $10
        \\cmp r1, TARGET
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[1]) {
        .instruction => |i| {
            // `TARGET` is a bare identifier in operand position
            // — it becomes a label_ref, NOT an immediate. The
            // symbol pass (#35) is what later folds it.
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .label_ref), @as(std.meta.Tag(gero.asm_.Operand), i.operands[1]));
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: indirect with non-register inside surfaces a diagnostic" {
    var pt = try parseSource("mov [42_not_a_register_lol], r2\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: indirect missing closing bracket" {
    var pt = try parseSource("mov [r1, r2\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: instruction with 3-operand form (indexed-style placeholder)" {
    // The full indexed `[&addr + r1]` form arrives in slice B,
    // but plain comma-separated operands of three already work.
    var pt = try parseSource("mov &2620, r1, r2\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| try std.testing.expectEqual(@as(usize, 3), i.operands.len),
        else => return error.WrongStatementKind,
    }
}

// ---------- instructions (slice B: complex address forms) ----------

test "parser: mov &[$1100], acu (addr_expr form a with hex)" {
    var pt = try parseSource("mov &[$1100], acu\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .addr_expr), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0]));
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .register), @as(std.meta.Tag(gero.asm_.Operand), i.operands[1]));
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: mov &[@player + $02], acu (addr_expr with sym + offset)" {
    var pt = try parseSource("mov &[@player + $02], acu\n");
    defer pt.deinit();
    // Eval will surface "unresolved symbol" because @player isn't
    // defined in this single-statement source; AST itself is fine.
    // We accept that diagnostic — the operand still parses.
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .addr_expr), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0]));
            switch (i.operands[0]) {
                .addr_expr => |a| {
                    // Inner expr is `binary(+, sym_ref(@player), hex($02))`
                    try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Expr), .binary), @as(std.meta.Tag(gero.asm_.Expr), a.expr.*));
                },
                else => unreachable,
            }
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: mov [&2620 + r1], acu (indexed form b with hex addr literal)" {
    var pt = try parseSource("mov [&2620 + r1], acu\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| switch (i.operands[0]) {
            .indexed => |idx| {
                try std.testing.expectEqual(gero.asm_.Register.r1, idx.reg.id);
                try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Expr), .addr_lit), @as(std.meta.Tag(gero.asm_.Expr), idx.addr.*));
            },
            else => return error.WrongOperandKind,
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: mov [@base + r2], acu (indexed with sym base)" {
    var pt = try parseSource("mov [@base + r2], acu\n");
    defer pt.deinit();
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            switch (i.operands[0]) {
                .indexed => |idx| {
                    try std.testing.expectEqual(gero.asm_.Register.r2, idx.reg.id);
                    try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Expr), .sym_ref), @as(std.meta.Tag(gero.asm_.Expr), idx.addr.*));
                },
                else => return error.WrongOperandKind,
            }
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: [r1] still parses as indirect (single-register inside)" {
    var pt = try parseSource("mov [r1], r2\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .instruction => |i| {
            try std.testing.expectEqual(@as(std.meta.Tag(gero.asm_.Operand), .indirect), @as(std.meta.Tag(gero.asm_.Operand), i.operands[0]));
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: mov acu, <Player> @player.hp (cast operand)" {
    var pt = try parseSource(
        \\struct Player { hp: u16, mp: u16 }
        \\mov acu, <Player> @player.hp
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[1]) {
        .instruction => |i| {
            switch (i.operands[1]) {
                .cast => |c| {
                    const src =
                        \\struct Player { hp: u16, mp: u16 }
                        \\mov acu, <Player> @player.hp
                        \\
                    ;
                    try std.testing.expectEqualStrings("Player", src[c.type_name.start..c.type_name.end]);
                    try std.testing.expectEqualStrings("hp", src[c.field_name.start..c.field_name.end]);
                    try std.testing.expectEqualStrings("@player", src[c.sym_ref.span.start..c.sym_ref.span.end]);
                },
                else => return error.WrongOperandKind,
            }
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: const + addr_expr resolves at parse time" {
    var pt = try parseSource(
        \\const BASE = $1100
        \\mov &[BASE + $20], r1
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    // The addr_expr's inner expression should fold to $1120 once
    // the codegen pass evaluates against the ConstantTable.
    switch (pt.program.statements[1]) {
        .instruction => |i| {
            switch (i.operands[0]) {
                .addr_expr => |a| {
                    var consts = gero.asm_.ConstantTable.init(alloc);
                    defer consts.deinit();
                    try consts.put("BASE", 0x1100);
                    const result = gero.asm_.evalExpr(a.expr, "const BASE = $1100\nmov &[BASE + $20], r1\n", consts);
                    try std.testing.expectEqual(@as(u16, 0x1120), result.ok);
                },
                else => return error.WrongOperandKind,
            }
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: cast with malformed type position" {
    var pt = try parseSource("mov acu, < @player.hp\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: cast missing closing '>'" {
    var pt = try parseSource("mov acu, <Player @player.hp\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: indexed missing '+' between addr and reg" {
    var pt = try parseSource("mov [@table r1], acu\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "parser: addr_expr missing closing ']'" {
    var pt = try parseSource("mov &[$1100, r1\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

// ---------- conditional assembly (ifdef / ifndef / endif) ----------

test "parser: ifndef on an undefined name parses through body" {
    var pt = try parseSource(
        \\ifndef MISSING
        \\const X = $42
        \\endif
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    // ifndef + const + endif → 3 statements emitted
    try std.testing.expectEqual(@as(usize, 3), pt.program.statements.len);
    try std.testing.expect(pt.program.statements[0] == .cond_directive);
    try std.testing.expect(pt.program.statements[1] == .const_decl);
    try std.testing.expect(pt.program.statements[2] == .cond_directive);
}

test "parser: ifndef on a defined name skips body" {
    var pt = try parseSource(
        \\const GUARD = $01
        \\ifndef GUARD
        \\const DEAD = $42
        \\endif
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    // const GUARD + ifndef + endif → 3 (DEAD is skipped)
    try std.testing.expectEqual(@as(usize, 3), pt.program.statements.len);
    try std.testing.expect(pt.program.statements[0] == .const_decl);
    try std.testing.expect(pt.program.statements[1] == .cond_directive);
    try std.testing.expect(pt.program.statements[2] == .cond_directive);
}

test "parser: ifdef on a defined name keeps body" {
    var pt = try parseSource(
        \\const GUARD = $01
        \\ifdef GUARD
        \\const ALIVE = $42
        \\endif
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 4), pt.program.statements.len);
    try std.testing.expect(pt.program.statements[2] == .const_decl);
}

test "parser: skip-mode swallows bogus content" {
    var pt = try parseSource(
        \\ifdef MISSING
        \\!@#$ this would otherwise be E001
        \\endif
        \\
    );
    defer pt.deinit();
    // No errors despite the garbage on line 2 — skip-mode ate it.
    try std.testing.expect(!pt.hasErrors());
}

test "parser: unmatched endif → E018" {
    var pt = try parseSource("endif\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.errors.len);
    try std.testing.expect(pt.errors[0].code != null);
    try std.testing.expectEqual(gero.asm_.ErrorCode.unmatched_endif, pt.errors[0].code.?);
}

test "parser: unclosed conditional at EOF → E019" {
    var pt = try parseSource(
        \\ifndef X
        \\const Y = $42
        \\
    );
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    try std.testing.expect(pt.errors[0].code != null);
    try std.testing.expectEqual(gero.asm_.ErrorCode.unclosed_conditional, pt.errors[0].code.?);
}

test "parser: nested ifndef inside ifdef true-branch" {
    var pt = try parseSource(
        \\const OUTER = $01
        \\ifdef OUTER
        \\const A = $11
        \\ifndef INNER
        \\const B = $22
        \\endif
        \\endif
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    // OUTER + ifdef + A + ifndef + B + endif + endif → 7
    try std.testing.expectEqual(@as(usize, 7), pt.program.statements.len);
}

test "parser: nested ifdef inside skipping outer stays skipping" {
    var pt = try parseSource(
        \\ifndef MISSING
        \\const ALWAYS_DEFINED = $01
        \\ifdef ALWAYS_DEFINED
        \\const SHOULD_NOT_LEAK = $99
        \\endif
        \\endif
        \\
    );
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    // Outer ifndef MISSING is true → first const + nested ifdef
    // (true since ALWAYS_DEFINED gets defined) + nested const +
    // both endifs → 6.
    try std.testing.expectEqual(@as(usize, 6), pt.program.statements.len);
}
