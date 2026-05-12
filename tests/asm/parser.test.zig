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

test "parser: blank lines + comments produce no statements" {
    var pt = try parseSource(
        \\
        \\; just a comment
        \\
        \\
    );
    defer pt.deinit();
    try std.testing.expectEqual(@as(usize, 0), pt.program.statements.len);
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

test "parser: unknown line emits a diagnostic + an `unknown` statement" {
    var pt = try parseSource("mov $01, r1\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), pt.program.statements.len);
    try std.testing.expectEqual(
        @as(std.meta.Tag(gero.asm_.Statement), .unknown),
        @as(std.meta.Tag(gero.asm_.Statement), pt.program.statements[0]),
    );
    try std.testing.expectEqual(@as(usize, 1), pt.errors.len);
    try std.testing.expectEqualStrings("statement", pt.errors[0].parse_error.parser);
}

test "parser: unknown line doesn't poison subsequent labels" {
    var pt = try parseSource(
        \\mov $01, r1
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
        \\garbage_one extra
        \\start:
        \\garbage_two extra
        \\garbage_three extra
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

test "parser: data16 with string literal surfaces a diagnostic" {
    var pt = try parseSource("data16 bad = \"hi\"\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_data16_rejection = false;
    for (pt.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "string literals are only allowed in `data8`") != null) {
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
        if (std.mem.indexOf(u8, e.parse_error.message, "unknown field type") != null) {
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
