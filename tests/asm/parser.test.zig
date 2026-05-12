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
