const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Lex `source` and feed the resulting tokens to the parser.
/// Used by every test below so each scenario can stay focused on
/// the AST it expects.
fn parseSource(source: []const u8) !gero.asm_.ParseTree {
    var ts = try gero.asm_.tokenize(alloc, source);
    defer ts.deinit();
    return gero.asm_.parse(alloc, ts.tokens);
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
            try std.testing.expectEqual(@as(u32, 5), l.name.end); // "start"
            try std.testing.expectEqual(@as(u32, 0), l.span.start);
            try std.testing.expectEqual(@as(u32, 6), l.span.end); // includes ":"
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
    // Labels are colon-terminated, not newline-terminated, so two
    // can appear without an intervening newline.
    var pt = try parseSource("start: loop:\n");
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), pt.program.statements.len);
}

// ---------- recovery on unknown lines ----------

test "parser: unknown line emits a diagnostic + an `unknown` statement" {
    // `mov` isn't yet a recognized statement shape — recovery should
    // skip past the line and keep the parser running.
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

test "parser: an unknown line doesn't poison subsequent labels" {
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
        \\garbage_one
        \\start:
        \\garbage_two
        \\garbage_three
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
            // 11 chars in "hello_world", then ':' at offset 11.
            try std.testing.expectEqual(@as(u32, 0), l.name.start);
            try std.testing.expectEqual(@as(u32, 11), l.name.end);
            try std.testing.expectEqual(@as(u32, 0), l.span.start);
            try std.testing.expectEqual(@as(u32, 12), l.span.end);
        },
        else => return error.WrongStatementKind,
    }
}

test "parser: label tokens preserve their file_id" {
    // The lexer produces file_id = 0 by default — the resolver
    // overwrites it when fusing. This test makes sure the parser
    // copies file_id from tokens to spans without mangling it.
    var ts = try gero.asm_.tokenize(alloc, "label:");
    defer ts.deinit();

    // Manually pretend these tokens came from file_id = 5.
    var tokens = try alloc.alloc(gero.asm_.Token, ts.tokens.len);
    defer alloc.free(tokens);
    for (ts.tokens, 0..) |t, i| {
        tokens[i] = t;
        tokens[i].file_id = 5;
    }

    var pt = try gero.asm_.parse(alloc, tokens);
    defer pt.deinit();
    try std.testing.expect(!pt.hasErrors());
    switch (pt.program.statements[0]) {
        .label => |l| {
            try std.testing.expectEqual(@as(u16, 5), l.name.file_id);
            try std.testing.expectEqual(@as(u16, 5), l.span.file_id);
        },
        else => return error.WrongStatementKind,
    }
}
