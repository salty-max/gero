const std = @import("std");
const gero = @import("gero");

/// Where blessed images live, relative to the repo root.
const golden_dir = "tests/golden";

/// Roots walked for source programs, and the suffix each contributes.
const sources = [_]Source{
    .{ .dir = "examples/asm", .suffix = ".gas" },
    .{ .dir = "examples/lang", .suffix = ".gr" },
};

const Source = struct {
    dir: []const u8,
    suffix: []const u8,
};

/// One program's source path and the golden image it is checked against.
const Entry = struct {
    /// Repo-relative source path, e.g. `examples/asm/banks/main.gas`.
    source: []const u8,
    /// Flattened golden name, e.g. `asm-banks-main.gx`. Flattened so
    /// the golden directory is one readable list rather than a tree
    /// mirroring two unrelated example layouts.
    golden: []const u8,
};

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_file.interface;
    defer out.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    var bless = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--bless")) bless = true;
    }

    const entries = try collect(io, arena);
    if (entries.len == 0) {
        try out.print("golden: no example programs found\n", .{});
        return 1;
    }

    var failed: usize = 0;
    var blessed: usize = 0;
    for (entries) |entry| {
        const built = compile(io, arena, entry.source) catch |err| {
            try out.print("  {s} ... BUILD FAILED ({s})\n", .{ entry.source, @errorName(err) });
            failed += 1;
            continue;
        };
        const golden_path = try std.fs.path.join(arena, &.{ golden_dir, entry.golden });

        if (bless) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = golden_path, .data = built });
            blessed += 1;
            continue;
        }

        const expected = std.Io.Dir.cwd().readFileAlloc(io, golden_path, arena, .unlimited) catch {
            try out.print("  {s} ... MISSING golden ({s}) — run `zig build bless-golden`\n", .{ entry.source, golden_path });
            failed += 1;
            continue;
        };

        if (try diff(arena, expected, built)) |d| {
            try out.print("  {s} ... DIFFERS\n", .{entry.source});
            try out.print("      {s}\n", .{d});
            failed += 1;
        }
    }

    if (bless) {
        try out.print("\ngolden: blessed {d} image(s)\n", .{blessed});
        return 0;
    }

    if (failed == 0) {
        try out.print("golden: {d} image(s) match\n", .{entries.len});
        return 0;
    }
    try out.print(
        \\
        \\❌ {d} image(s) differ from the blessed corpus.
        \\   A codegen change that alters emitted bytes is not
        \\   necessarily wrong — but it must be deliberate. Justify the
        \\   change in the PR, then re-bless with:
        \\
        \\     zig build bless-golden
        \\
    , .{failed});
    return 1;
}

/// Every example program under the source roots, sorted so the run
/// order — and any failure list — is stable.
fn collect(io: std.Io, arena: std.mem.Allocator) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (sources) |src| {
        var dir = try std.Io.Dir.cwd().openDir(io, src.dir, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(arena);
        while (try walker.next(io)) |it| {
            if (it.kind != .file) continue;
            if (!std.mem.endsWith(u8, it.path, src.suffix)) continue;
            // `gero test` modules live under tests/; they are not carts.
            if (std.mem.indexOf(u8, it.path, "tests/") != null) continue;
            // An asm example split across `include`s, or a Gero
            // module imported with `use`, is not an entry point.
            if (try isIncludeFragment(io, arena, src.dir, it.path)) continue;
            if (try isUseFragment(io, arena, src.dir, it.path)) continue;
            try out.append(arena, .{
                .source = try std.fs.path.join(arena, &.{ src.dir, it.path }),
                .golden = try goldenName(arena, src.dir, it.path),
            });
        }
    }
    std.mem.sort(Entry, out.items, {}, lessBySource);
    return out.toOwnedSlice(arena);
}

fn lessBySource(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.source, b.source) == .lt;
}

/// True when `rel` is pulled in by a sibling's `include` rather than
/// being an entry point of its own. Assembling a fragment alone yields
/// an image no one runs.
fn isIncludeFragment(io: std.Io, arena: std.mem.Allocator, dir: []const u8, rel: []const u8) !bool {
    const base = std.fs.path.basename(rel);
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var walker = try d.walk(arena);
    while (try walker.next(io)) |it| {
        if (it.kind != .file) continue;
        if (std.mem.eql(u8, it.path, rel)) continue;
        if (!std.mem.endsWith(u8, it.path, ".gas")) continue;
        const path = try std.fs.path.join(arena, &.{ dir, it.path });
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch continue;
        if (mentionsInclude(text, base)) return true;
    }
    return false;
}

/// True when `rel` is pulled in by a sibling's `use` rather than
/// being a program of its own.
fn isUseFragment(io: std.Io, arena: std.mem.Allocator, dir: []const u8, rel: []const u8) !bool {
    if (!std.mem.endsWith(u8, rel, ".gr")) return false;
    const base = std.fs.path.basename(rel);
    const stem = base[0 .. base.len - ".gr".len];
    var d = try std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var walker = try d.walk(arena);
    while (try walker.next(io)) |it| {
        if (it.kind != .file) continue;
        if (std.mem.eql(u8, it.path, rel)) continue;
        if (!std.mem.endsWith(u8, it.path, ".gr")) continue;
        const path = try std.fs.path.join(arena, &.{ dir, it.path });
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch continue;
        if (mentionsUse(text, stem)) return true;
    }
    return false;
}

/// True when `text` has a `use` of `./stem` (with or without `.gr`).
fn mentionsUse(text: []const u8, stem: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "use ")) continue;
        if (std.mem.indexOf(u8, trimmed, stem) != null) return true;
    }
    return false;
}

/// True when `text` has an `include` directive naming `base`.
fn mentionsInclude(text: []const u8, base: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "include")) continue;
        if (std.mem.indexOf(u8, trimmed, base) != null) return true;
    }
    return false;
}

/// `examples/asm` + `banks/main.gas` → `asm-banks-main.gx`.
fn goldenName(arena: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    const root = std.fs.path.basename(dir);
    const stem = rel[0 .. rel.len - std.fs.path.extension(rel).len];
    const flat = try arena.dupe(u8, stem);
    for (flat) |*c| {
        if (c.* == '/' or c.* == '\\') c.* = '-';
    }
    return std.fmt.allocPrint(arena, "{s}-{s}.gx", .{ root, flat });
}

/// Build `path` through the same library entry points the CLI uses,
/// returning the `.gx` bytes.
fn compile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, path, ".gas")) return compileAsm(io, arena, path);
    return compileLang(io, arena, path);
}

fn compileAsm(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var fused = try gero.asm_.resolveIncludes(io, arena, path);
    if (fused.errors.len > 0) return error.IncludeFailed;
    const pt = try gero.asm_.parse(arena, fused.source);
    const cg = try gero.asm_.assemble(arena, fused.source, pt, .{ .source_map = &fused.source_map });
    if (cg.hasErrors()) return error.AssembleFailed;
    return cg.image;
}

fn compileLang(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    var fused = try gero.lang.resolveUseImports(io, arena, path);
    if (fused.hasErrors()) return error.ImportsFailed;
    const stream = try gero.lang.tokenize(arena, fused.source);
    var tree = try gero.lang.parseAllModules(arena, fused.source, stream, &fused.source_map);
    if (tree.errors.len > 0) return error.ParseFailed;
    var checked = try gero.lang.typecheckGraph(arena, fused.source, &tree.program, &fused.import_aliases, .{
        .source_map = &fused.source_map,
        .imports = fused.imports,
    });
    if (checked.hasErrors()) return error.TypecheckFailed;
    checked.program = &tree.program;
    const compiled = try gero.lang.compile(arena, fused.source, &checked, .{
        .import_aliases = &fused.import_aliases,
        .graph = .{ .source_map = &fused.source_map, .imports = fused.imports },
    });
    if (compiled.hasErrors()) return error.CodegenFailed;
    return compiled.image;
}

/// Describe the first difference between two `.gx` images, or `null`
/// when they are equivalent.
///
/// The header, base image, and banks are compared byte for byte —
/// those are the bytes a VM executes. The debug section is compared by
/// *content*, because symbol order is not stable across builds even
/// when the code is identical (`roundtrip.zig` documents the same
/// caveat). Ordering churn must not fail the gate; a changed symbol,
/// or a changed line table, must.
fn diff(arena: std.mem.Allocator, expected: []const u8, actual: []const u8) !?[]const u8 {
    const want = gero.vm.parseGx(expected) catch return try arena.dupe(u8, "blessed image no longer parses — re-bless it");
    const got = gero.vm.parseGx(actual) catch return try arena.dupe(u8, "rebuilt image does not parse");

    // Everything up to the debug section, byte for byte.
    const want_exec = expected[0 .. expected.len - want.debug.len];
    const got_exec = actual[0 .. actual.len - got.debug.len];
    if (firstDifference(want_exec, got_exec)) |at| {
        return try std.fmt.allocPrint(
            arena,
            "executable bytes differ at offset 0x{X:0>4} (blessed 0x{X:0>2}, rebuilt 0x{X:0>2}); {s}",
            .{ at, byteAt(want_exec, at), byteAt(got_exec, at), regionOf(at, want.header) },
        );
    }
    if (want_exec.len != got_exec.len) {
        return try std.fmt.allocPrint(
            arena,
            "image size differs: blessed {d} bytes, rebuilt {d}",
            .{ want_exec.len, got_exec.len },
        );
    }

    return diffDebug(arena, want.debug, got.debug);
}

/// Compare two debug sections by content rather than by bytes.
fn diffDebug(arena: std.mem.Allocator, want: []const u8, got: []const u8) !?[]const u8 {
    if ((want.len == 0) != (got.len == 0)) {
        return try arena.dupe(u8, "one image carries a debug section and the other does not");
    }
    if (want.len == 0) return null;

    var want_syms = gero.disasm.parseSymbols(arena, want) catch return try arena.dupe(u8, "blessed debug symbols do not parse");
    defer want_syms.deinit(arena);
    var got_syms = gero.disasm.parseSymbols(arena, got) catch return try arena.dupe(u8, "rebuilt debug symbols do not parse");
    defer got_syms.deinit(arena);

    if (want_syms.entries.len != got_syms.entries.len) {
        return try std.fmt.allocPrint(
            arena,
            "debug symbol count differs: blessed {d}, rebuilt {d}",
            .{ want_syms.entries.len, got_syms.entries.len },
        );
    }

    // Sorted before comparing, so a reordering alone is not a failure.
    const a = try arena.dupe(gero.disasm.Symbol, want_syms.entries);
    const b = try arena.dupe(gero.disasm.Symbol, got_syms.entries);
    std.mem.sort(gero.disasm.Symbol, a, {}, lessBySymbol);
    std.mem.sort(gero.disasm.Symbol, b, {}, lessBySymbol);
    for (a, b) |x, y| {
        if (x.address != y.address or x.kind != y.kind or !std.mem.eql(u8, x.name, y.name)) {
            return try std.fmt.allocPrint(
                arena,
                "debug symbol differs: blessed `{s}` at 0x{X:0>4}, rebuilt `{s}` at 0x{X:0>4}",
                .{ x.name, x.address, y.name, y.address },
            );
        }
    }

    return diffLines(arena, want, got);
}

/// Compare the line tables. Rows are emitted in a deterministic order,
/// so these are compared as-is.
fn diffLines(arena: std.mem.Allocator, want: []const u8, got: []const u8) !?[]const u8 {
    const want_p = (gero.gx.findChunk(want, .lines) catch null) orelse return null;
    const got_p = (gero.gx.findChunk(got, .lines) catch null) orelse
        return try arena.dupe(u8, "blessed image has a line table and the rebuilt one does not");

    const want_rows = try gero.gx.decodeLines(arena, want_p);
    const got_rows = try gero.gx.decodeLines(arena, got_p);
    if (want_rows.len != got_rows.len) {
        return try std.fmt.allocPrint(
            arena,
            "line table differs: blessed {d} rows, rebuilt {d}",
            .{ want_rows.len, got_rows.len },
        );
    }
    for (want_rows, got_rows, 0..) |x, y, i| {
        if (std.meta.eql(x, y)) continue;
        return try std.fmt.allocPrint(
            arena,
            "line row {d} differs: blessed [{X:0>4},{X:0>4}) -> {d}:{d}, rebuilt [{X:0>4},{X:0>4}) -> {d}:{d}",
            .{ i, x.start_addr, x.end_addr, x.line, x.column, y.start_addr, y.end_addr, y.line, y.column },
        );
    }
    return null;
}

fn lessBySymbol(_: void, a: gero.disasm.Symbol, b: gero.disasm.Symbol) bool {
    if (a.address != b.address) return a.address < b.address;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Index of the first differing byte, or `null` when the shorter slice
/// is a prefix of the longer.
fn firstDifference(a: []const u8, b: []const u8) ?usize {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i]) return i;
    }
    return null;
}

fn byteAt(bytes: []const u8, at: usize) u8 {
    return if (at < bytes.len) bytes[at] else 0;
}

/// Which part of the archive `at` falls in, so a diff points at a
/// region rather than a bare number.
fn regionOf(at: usize, header: gero.vm.Header) []const u8 {
    if (at < gero.gx.header_size) return "in the header";
    // @as: image_size is a u16 by the ISA; widen for the comparison.
    const image_end = gero.gx.header_size + @as(usize, header.image_size);
    if (at < image_end) return "in the base image";
    return "in the bank pool";
}

// ---------- tests ----------

const testing = std.testing;

/// Rebuild a `.gx` with its symbol rows in a different order, leaving
/// every other byte alone. Symbol order is an emission detail — hash
/// iteration today — so the gate must not treat a permutation as a
/// codegen change.
fn permuteSymbols(arena: std.mem.Allocator, image: []const u8) ![]u8 {
    const loaded = try gero.vm.parseGx(image);
    var syms = try gero.disasm.parseSymbols(arena, loaded.debug);
    defer syms.deinit(arena);
    try testing.expect(syms.entries.len >= 2);

    var payload: std.ArrayList(u8) = .empty;
    var count_bytes: [2]u8 = undefined;
    // safety: entry count came from a parsed section, so it fits u16.
    gero.gx.writeU16Le(&count_bytes, @intCast(syms.entries.len));
    try payload.appendSlice(arena, &count_bytes);

    // Reversed — a permutation that is guaranteed to differ.
    var i: usize = syms.entries.len;
    while (i > 0) {
        i -= 1;
        const e = syms.entries[i];
        var addr_bytes: [2]u8 = undefined;
        gero.gx.writeU16Le(&addr_bytes, e.address);
        try payload.appendSlice(arena, &addr_bytes);
        try payload.append(arena, @intFromEnum(e.kind));
        // safety: names came from a section that encodes length in a byte.
        try payload.append(arena, @intCast(e.name.len));
        try payload.appendSlice(arena, e.name);
    }

    var debug = gero.gx.DebugBuilder.init(arena);
    defer debug.deinit();
    try debug.addChunk(.symbols, payload.items);
    if (try gero.gx.findChunk(loaded.debug, .files)) |p| try debug.addChunk(.files, p);
    if (try gero.gx.findChunk(loaded.debug, .lines)) |p| try debug.addChunk(.lines, p);

    const exec = image[0 .. image.len - loaded.debug.len];
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, exec);
    try out.appendSlice(arena, debug.section().?);
    return out.toOwnedSlice(arena);
}

/// Build one example straight from the working tree.
fn buildExample(io: std.Io, arena: std.mem.Allocator) ![]const u8 {
    return compile(io, arena, "examples/lang/factorial.gr");
}

test "diff: reordered debug symbols are not a difference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const image = try buildExample(testing.io, arena);
    const shuffled = try permuteSymbols(arena, image);

    // The bytes differ...
    try testing.expect(!std.mem.eql(u8, image, shuffled));
    // ...but nothing a VM executes, and no symbol's content.
    try testing.expect((try diff(arena, image, shuffled)) == null);
}

test "diff: a changed symbol name is a difference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const image = try buildExample(testing.io, arena);
    const loaded = try gero.vm.parseGx(image);
    var syms = try gero.disasm.parseSymbols(arena, loaded.debug);
    defer syms.deinit(arena);

    // Flip one byte inside a symbol's name, in place.
    const tampered = try arena.dupe(u8, image);
    const name = syms.entries[0].name;
    const at = std.mem.indexOf(u8, tampered, name).?;
    tampered[at] = if (tampered[at] == 'z') 'y' else tampered[at] + 1;

    const d = (try diff(arena, image, tampered)).?;
    try testing.expect(std.mem.indexOf(u8, d, "debug symbol differs") != null);
}

test "diff: a changed executable byte names its offset and region" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const image = try buildExample(testing.io, arena);
    const tampered = try arena.dupe(u8, image);
    // Entry point's low byte — inside the header.
    tampered[8] +%= 1;

    const d = (try diff(arena, image, tampered)).?;
    try testing.expect(std.mem.indexOf(u8, d, "0x0008") != null);
    try testing.expect(std.mem.indexOf(u8, d, "in the header") != null);
}
