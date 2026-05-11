const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Bundle a `tmpDir` plus a few helpers so tests stay readable.
const Fixture = struct {
    tmp: std.testing.TmpDir,

    fn init() Fixture {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, body: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = body });
    }

    fn mkdir(self: *Fixture, name: []const u8) !void {
        try self.tmp.dir.createDirPath(std.testing.io, name);
    }

    fn pathOf(self: *Fixture, name: []const u8) ![:0]u8 {
        return self.tmp.dir.realPathFileAlloc(std.testing.io, name, alloc);
    }
};

fn countKind(tokens: []const gero.asm_.Token, kind: gero.asm_.Token.Kind) usize {
    var n: usize = 0;
    for (tokens) |t| if (t.kind == kind) {
        n += 1;
    };
    return n;
}

// ---------- happy path ----------

test "include: root file with no includes round-trips its token kinds" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("main.gas", "hlt\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), fused.file_table.files.items.len);

    // Should see: ident(hlt), newline. (eof isn't copied by the resolver.)
    try std.testing.expectEqual(@as(usize, 1), countKind(fused.tokens, .ident));
    try std.testing.expectEqual(@as(usize, 1), countKind(fused.tokens, .newline));
    try std.testing.expectEqual(@as(u16, 0), fused.tokens[0].file_id);
}

test "include: single include splices the target's tokens, drops the include statement" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gas", "nop\n");
    try fx.write("main.gas",
        \\include "lib.gas"
        \\hlt
        \\
    );

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), fused.file_table.files.items.len);
    // Two ident tokens: `nop` from lib, `hlt` from main. The `include`
    // and `"lib.gas"` themselves are consumed by the resolver.
    try std.testing.expectEqual(@as(usize, 2), countKind(fused.tokens, .ident));
    try std.testing.expectEqual(@as(usize, 0), countKind(fused.tokens, .string));
}

test "include: nested 3-deep include resolves in order" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("c.gas", "c_ident\n");
    try fx.write("b.gas",
        \\include "c.gas"
        \\b_ident
        \\
    );
    try fx.write("a.gas",
        \\include "b.gas"
        \\a_ident
        \\
    );

    const a_path = try fx.pathOf("a.gas");
    defer alloc.free(a_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, a_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    try std.testing.expectEqual(@as(usize, 3), fused.file_table.files.items.len);

    // Walking the token stream we should hit c_ident, b_ident, a_ident in that order.
    var idents: [3][]const u8 = undefined;
    var idx: usize = 0;
    for (fused.tokens) |t| {
        if (t.kind != .ident) continue;
        const f = fused.file_table.get(t.file_id);
        idents[idx] = f.content[t.start..t.end];
        idx += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), idx);
    try std.testing.expectEqualStrings("c_ident", idents[0]);
    try std.testing.expectEqualStrings("b_ident", idents[1]);
    try std.testing.expectEqualStrings("a_ident", idents[2]);
}

// ---------- pragma-once dedup ----------

test "include: diamond include — utils is resolved once even when reached twice" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("utils.gas", "u_ident\n");
    try fx.write("a.gas",
        \\include "utils.gas"
        \\
    );
    try fx.write("b.gas",
        \\include "utils.gas"
        \\
    );
    try fx.write("main.gas",
        \\include "a.gas"
        \\include "b.gas"
        \\
    );

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    // 4 files in the table (main, a, b, utils) — utils appears exactly once.
    try std.testing.expectEqual(@as(usize, 4), fused.file_table.files.items.len);
    // u_ident should appear ONCE in the fused stream, not twice.
    var u_ident_count: usize = 0;
    for (fused.tokens) |t| {
        if (t.kind != .ident) continue;
        const f = fused.file_table.get(t.file_id);
        if (std.mem.eql(u8, f.content[t.start..t.end], "u_ident")) u_ident_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), u_ident_count);
}

test "include: same file referenced via different relative paths still dedups" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.mkdir("sub");
    try fx.write("utils.gas", "u_ident\n");
    try fx.write("sub/inner.gas", "include \"../utils.gas\"\n");
    try fx.write("main.gas",
        \\include "utils.gas"
        \\include "sub/inner.gas"
        \\
    );

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    // utils.gas must appear once even though the second include
    // names it via `../utils.gas` from inside sub/.
    var u_ident_count: usize = 0;
    for (fused.tokens) |t| {
        if (t.kind != .ident) continue;
        const f = fused.file_table.get(t.file_id);
        if (std.mem.eql(u8, f.content[t.start..t.end], "u_ident")) u_ident_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), u_ident_count);
}

// ---------- cycle / depth / missing ----------

test "include: direct self-include detected as cycle (E012)" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("main.gas", "include \"main.gas\"\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(fused.hasErrors());
    var saw_cycle = false;
    for (fused.errors) |e| {
        if (std.mem.eql(u8, e.parse_error.parser, "include") and
            std.mem.indexOf(u8, e.parse_error.message, "cycle") != null) saw_cycle = true;
    }
    try std.testing.expect(saw_cycle);
}

test "include: indirect cycle a→b→a detected (E012)" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("a.gas", "include \"b.gas\"\n");
    try fx.write("b.gas", "include \"a.gas\"\n");

    const a_path = try fx.pathOf("a.gas");
    defer alloc.free(a_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, a_path);
    defer fused.deinit();

    try std.testing.expect(fused.hasErrors());
    var saw_cycle = false;
    for (fused.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "cycle") != null) saw_cycle = true;
    }
    try std.testing.expect(saw_cycle);
}

test "include: missing target produces E015-shape error pointing at including file" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("main.gas", "include \"nope.gas\"\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(fused.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), fused.errors.len);
    const e = fused.errors[0];
    try std.testing.expect(std.mem.indexOf(u8, e.parse_error.message, "not found") != null);
    // Error should be attached to main (the file doing the include),
    // not the missing target.
    const main_info = fused.file_table.get(e.file_id);
    try std.testing.expect(std.mem.endsWith(u8, main_info.path, "main.gas"));
}

test "include: deep chain exceeding 32 levels is rejected (E013)" {
    var fx = Fixture.init();
    defer fx.deinit();
    // Build 34 files where file_N includes file_{N+1}.
    var name_buf: [32]u8 = undefined;
    var next_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 34) : (i += 1) {
        const name = try std.fmt.bufPrint(&name_buf, "f{d}.gas", .{i});
        if (i < 33) {
            const next = try std.fmt.bufPrint(&next_buf, "f{d}.gas", .{i + 1});
            const body = try std.fmt.allocPrint(alloc, "include \"{s}\"\n", .{next});
            defer alloc.free(body);
            try fx.write(name, body);
        } else {
            try fx.write(name, "leaf\n");
        }
    }

    const root_path = try fx.pathOf("f0.gas");
    defer alloc.free(root_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, root_path);
    defer fused.deinit();

    try std.testing.expect(fused.hasErrors());
    var saw_depth = false;
    for (fused.errors) |e| {
        if (std.mem.indexOf(u8, e.parse_error.message, "depth") != null) saw_depth = true;
    }
    try std.testing.expect(saw_depth);
}

// ---------- error-site preservation ----------

test "include: lexer error in an included file references that file's path + line" {
    var fx = Fixture.init();
    defer fx.deinit();
    // `$ABCDE` is a 5-digit hex literal — rejected by the lexer.
    // Put it on line 2 of the included file so we can check line/col.
    try fx.write("bad.gas",
        \\hlt
        \\mov $ABCDE, r1
        \\
    );
    try fx.write("main.gas", "include \"bad.gas\"\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(fused.hasErrors());

    // Find the lexer error (parser == "hexLiteral") and check the
    // file pinned on it is bad.gas, not main.gas.
    var saw_in_bad = false;
    for (fused.errors) |e| {
        if (std.mem.eql(u8, e.parse_error.parser, "hexLiteral")) {
            const info = fused.file_table.get(e.file_id);
            if (std.mem.endsWith(u8, info.path, "bad.gas")) saw_in_bad = true;
        }
    }
    try std.testing.expect(saw_in_bad);
}

test "include: formatDiagnostic produces path:line:col prefix" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("bad.gas",
        \\hlt
        \\$ABCDE
        \\
    );
    try fx.write("main.gas", "include \"bad.gas\"\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();

    // Find the hex-literal error and format it.
    for (fused.errors) |e| {
        if (std.mem.eql(u8, e.parse_error.parser, "hexLiteral")) {
            try gero.asm_.formatDiagnostic(&allocating.writer, fused.file_table, e);
            break;
        }
    }

    const out = allocating.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "bad.gas") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ":2:") != null); // line 2
}

// ---------- token stream invariants ----------

test "include: token file_ids match the files they came from" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gas", "lib_token\n");
    try fx.write("main.gas",
        \\include "lib.gas"
        \\main_token
        \\
    );

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    for (fused.tokens) |t| {
        if (t.kind != .ident) continue;
        const f = fused.file_table.get(t.file_id);
        const lex = f.content[t.start..t.end];
        if (std.mem.eql(u8, lex, "lib_token")) {
            try std.testing.expect(std.mem.endsWith(u8, f.path, "lib.gas"));
        } else if (std.mem.eql(u8, lex, "main_token")) {
            try std.testing.expect(std.mem.endsWith(u8, f.path, "main.gas"));
        }
    }
}

test "include: standalone tokenize still emits file_id = 0" {
    // The lexer is file-agnostic — only the resolver sets file_id.
    // Anyone calling `tokenize` directly (e.g., tests, smoke tools)
    // should still see the default.
    var ts = try gero.asm_.tokenize(alloc, "hlt\n");
    defer ts.deinit();
    for (ts.tokens) |t| {
        try std.testing.expectEqual(@as(u16, 0), t.file_id);
    }
}
