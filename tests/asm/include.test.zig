const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

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

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn occurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return count;
}

// ---------- happy path ----------

test "include: root file with no includes round-trips its bytes" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("main.gas", "hlt\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    try std.testing.expectEqualStrings("hlt\n", fused.source);
    try std.testing.expectEqual(@as(usize, 1), fused.source_map.files.items.len);
}

test "include: single include splices the target's bytes and elides the directive" {
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
    // The `include` line itself doesn't survive; lib's `nop` does.
    try std.testing.expect(std.mem.indexOf(u8, fused.source, "include") == null);
    try std.testing.expect(std.mem.indexOf(u8, fused.source, "nop") != null);
    try std.testing.expect(std.mem.indexOf(u8, fused.source, "hlt") != null);
    // Order: lib first, then main's remaining body.
    const nop_idx = std.mem.indexOf(u8, fused.source, "nop").?;
    const hlt_idx = std.mem.indexOf(u8, fused.source, "hlt").?;
    try std.testing.expect(nop_idx < hlt_idx);
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
    const c_idx = std.mem.indexOf(u8, fused.source, "c_ident").?;
    const b_idx = std.mem.indexOf(u8, fused.source, "b_ident").?;
    const a_idx = std.mem.indexOf(u8, fused.source, "a_ident").?;
    try std.testing.expect(c_idx < b_idx);
    try std.testing.expect(b_idx < a_idx);
}

// ---------- textual splice (re-include emits every time) ----------

test "include: diamond — utils is spliced TWICE per asm tradition" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("utils.gas", "u_ident\n");
    try fx.write("a.gas", "include \"utils.gas\"\n");
    try fx.write("b.gas", "include \"utils.gas\"\n");
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
    try std.testing.expectEqual(@as(usize, 2), occurrences(fused.source, "u_ident"));
}

test "include: two direct includes of the same file emit its bytes twice" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("shared.gas", "s_ident\n");
    try fx.write("main.gas",
        \\include "shared.gas"
        \\include "shared.gas"
        \\
    );

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    try std.testing.expectEqual(@as(usize, 2), occurrences(fused.source, "s_ident"));
}

// ---------- include matcher edge cases ----------

test "include: directive inside a comment is NOT processed" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gas", "lib_body\n");
    try fx.write("main.gas",
        \\; include "lib.gas"
        \\hlt
        \\
    );

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, fused.source, "lib_body") == null);
}

test "include: 'include' literal inside a string is NOT processed" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("main.gas",
        \\data8 msg = "include \"x.gas\""
        \\
    );

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    // The string-literal-tracker in the include scanner makes sure
    // we don't recurse on the word `include` that lives inside the
    // double-quoted body. Source survives unchanged.
    try std.testing.expect(!fused.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, fused.source, "data8") != null);
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
        if (std.mem.indexOf(u8, e.parse_error.message, "cycle") != null) saw_cycle = true;
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

test "include: missing target produces E015-shape error" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("main.gas", "include \"nope.gas\"\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(fused.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), fused.errors.len);
    try std.testing.expect(std.mem.indexOf(u8, fused.errors[0].parse_error.message, "not found") != null);
}

test "include: deep chain exceeding 32 levels is rejected (E013)" {
    var fx = Fixture.init();
    defer fx.deinit();
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

// ---------- SourceMap + format helper ----------

test "include: SourceMap.lookup resolves offsets back to their file" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gas", "lib_ident\n");
    try fx.write("main.gas",
        \\include "lib.gas"
        \\main_ident
        \\
    );

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    const lib_off = std.mem.indexOf(u8, fused.source, "lib_ident").?;
    const main_off = std.mem.indexOf(u8, fused.source, "main_ident").?;

    const lib_loc = fused.source_map.lookup(@intCast(lib_off)).?;
    const main_loc = fused.source_map.lookup(@intCast(main_off)).?;
    try std.testing.expect(std.mem.endsWith(u8, lib_loc.file.path, "lib.gas"));
    try std.testing.expect(std.mem.endsWith(u8, main_loc.file.path, "main.gas"));
}

test "include: formatDiagnostic produces path:line:col prefix" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("main.gas", "include \"nope.gas\"\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.asm_.formatDiagnostic(&allocating.writer, fused.source_map, fused.errors[0]);

    const out = allocating.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "main.gas") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "not found") != null);
    // E015 = include target not found — the code prefix must appear.
    try std.testing.expect(std.mem.indexOf(u8, out, "[E015]") != null);
}

test "include: formatPretty emits a caret line under the column" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("main.gas", "include \"nope.gas\"\n");

    const main_path = try fx.pathOf("main.gas");
    defer alloc.free(main_path);

    var fused = try gero.asm_.resolveIncludes(std.testing.io, alloc, main_path);
    defer fused.deinit();

    var allocating = std.Io.Writer.Allocating.init(alloc);
    defer allocating.deinit();
    try gero.asm_.formatPretty(&allocating.writer, fused.source_map, fused.errors[0]);

    const out = allocating.written();
    // Header line has the [E015] prefix.
    try std.testing.expect(std.mem.indexOf(u8, out, "[E015]") != null);
    // Snippet line shows the actual source line.
    try std.testing.expect(std.mem.indexOf(u8, out, "include \"nope.gas\"") != null);
    // A caret line exists.
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
}
