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
