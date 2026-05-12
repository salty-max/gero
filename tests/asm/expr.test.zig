const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Run `source` through the parser and assert that:
///  - exactly N const_decl statements were emitted
///  - the i-th has lexeme name `names[i]`
///  - the i-th evaluated to `values[i]` (verified by chaining
///    `const __probe_i = <name>` and re-running, which forces
///    a table lookup).
fn expectConsts(source: []const u8, comptime values: anytype) !void {
    var pt = try gero.asm_.parse(alloc, source);
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(values.len, pt.program.statements.len);
    inline for (values, 0..) |expected, i| {
        switch (pt.program.statements[i]) {
            .const_decl => |c| {
                // Evaluate the expression standalone (with empty
                // constants for the no-ident cases — chained const
                // tests use the full table via a separate fixture).
                var consts = gero.asm_.ConstantTable.init(alloc);
                defer consts.deinit();
                // Walk previous const_decls in this run and pre-fill
                // the table so this eval sees them.
                var j: usize = 0;
                while (j < i) : (j += 1) {
                    switch (pt.program.statements[j]) {
                        .const_decl => |prior| {
                            const name = source[prior.name.start..prior.name.end];
                            const v = gero.asm_.evalExpr(prior.expr, source, consts);
                            switch (v) {
                                .ok => |val| try consts.put(name, val),
                                .err => unreachable, // hasErrors() already false
                            }
                        },
                        else => {},
                    }
                }
                const result = gero.asm_.evalExpr(c.expr, source, consts);
                switch (result) {
                    .ok => |actual| try std.testing.expectEqual(@as(u16, expected), actual),
                    .err => return error.EvalFailed,
                }
            },
            else => return error.NotAConst,
        }
    }
}

// ---------- literals ----------

test "expr: hex literal folds" {
    try expectConsts("const X = $FF\n", .{0xFF});
}

test "expr: hex max width" {
    try expectConsts("const X = $FFFF\n", .{0xFFFF});
}

test "expr: char literal folds" {
    try expectConsts("const X = 'A'\n", .{0x41});
}

test "expr: char escape folds" {
    try expectConsts("const X = '\\n'\n", .{0x0A});
}

// ---------- binary operators ----------

test "expr: add" {
    try expectConsts("const X = $01 + $02\n", .{0x03});
}

test "expr: sub wraps unsigned" {
    try expectConsts("const X = $0000 - $0001\n", .{0xFFFF});
}

test "expr: mul" {
    try expectConsts("const X = $03 * $04\n", .{12});
}

test "expr: div" {
    try expectConsts("const X = $10 / $04\n", .{4});
}

test "expr: mod" {
    try expectConsts("const X = $0A % $03\n", .{1});
}

test "expr: shl" {
    try expectConsts("const X = $01 << $08\n", .{0x0100});
}

test "expr: shr" {
    try expectConsts("const X = $0100 >> $04\n", .{0x0010});
}

test "expr: bit_and" {
    try expectConsts("const X = $FF & $0F\n", .{0x0F});
}

test "expr: bit_or" {
    try expectConsts("const X = $F0 | $0F\n", .{0xFF});
}

test "expr: bit_xor" {
    try expectConsts("const X = $F0 ^ $FF\n", .{0x0F});
}

// ---------- unary operators ----------

test "expr: unary minus wraps" {
    try expectConsts("const X = -$0001\n", .{0xFFFF});
}

test "expr: unary bit_not" {
    try expectConsts("const X = ~$00FF\n", .{0xFF00});
}

test "expr: chained unary -~$01 = 2" {
    // ~$01 = $FFFE; -$FFFE = $0002 (wraps).
    try expectConsts("const X = -~$01\n", .{0x0002});
}

// ---------- precedence + grouping ----------

test "expr: mul binds tighter than add" {
    // $01 + $02 * $03 = 1 + 6 = 7
    try expectConsts("const X = $01 + $02 * $03\n", .{7});
}

test "expr: parens override precedence" {
    // ($01 + $02) * $03 = 9
    try expectConsts("const X = ($01 + $02) * $03\n", .{9});
}

test "expr: left-associative sub" {
    // $0A - $03 - $02 = (10 - 3) - 2 = 5
    try expectConsts("const X = $0A - $03 - $02\n", .{5});
}

test "expr: shift binds looser than add/sub" {
    // ($01 + $02) << $01 = 6 ; without precedence rules, $01 + ($02 << $01) = 5
    try expectConsts("const X = $01 + $02 << $01\n", .{6});
}

test "expr: bitwise precedence and < xor < or" {
    // 0b1100 | 0b1010 ^ 0b0101 & 0b0011
    //   = 0b1100 | (0b1010 ^ (0b0101 & 0b0011))
    //   = 0b1100 | (0b1010 ^ 0b0001)
    //   = 0b1100 | 0b1011
    //   = 0b1111 = 15
    try expectConsts("const X = $0C | $0A ^ $05 & $03\n", .{0x0F});
}

test "expr: realistic bitfield" {
    // (1 << 8) | (1 << 5) = 256 + 32 = 288 = $0120
    try expectConsts("const X = ($01 << $08) | ($01 << $05)\n", .{0x0120});
}

// ---------- ident refs (chained consts) ----------

test "expr: identifier resolves to previously-defined const" {
    try expectConsts(
        \\const A = $05
        \\const B = A + $01
        \\
    , .{ 5, 6 });
}

test "expr: forward use of unknown ident is an error" {
    var pt = try gero.asm_.parse(alloc, "const X = NOPE + $01\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_unknown_ident = false;
    for (pt.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "unknown identifier") != null) {
            saw_unknown_ident = true;
        }
    }
    try std.testing.expect(saw_unknown_ident);
}

// ---------- error cases ----------

test "expr: division by zero surfaces a diagnostic" {
    var pt = try gero.asm_.parse(alloc, "const X = $0A / $00\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_div_zero = false;
    for (pt.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "division by zero") != null) {
            saw_div_zero = true;
        }
    }
    try std.testing.expect(saw_div_zero);
}

test "expr: missing RHS surfaces a parser diagnostic" {
    var pt = try gero.asm_.parse(alloc, "const X = $01 +\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
}

test "expr: unclosed paren surfaces a parser diagnostic" {
    var pt = try gero.asm_.parse(alloc, "const X = ($01 + $02\n");
    defer pt.deinit();
    try std.testing.expect(pt.hasErrors());
    var saw_paren = false;
    for (pt.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "')'") != null) {
            saw_paren = true;
        }
    }
    try std.testing.expect(saw_paren);
}
