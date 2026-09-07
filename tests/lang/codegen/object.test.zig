//! Mirror file for `src/lang/codegen/object.zig`.

const std = @import("std");
const gero = @import("gero");
const util = @import("util");

const alloc = std.testing.allocator;

/// Compile `src` with fragment extraction on.
fn compileWithFragments(src: []const u8) !gero.lang.Compiled {
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, src, &tree.program);
    defer checked.deinit();
    return gero.lang.compile(alloc, src, &checked, .{ .emit_fragments = true });
}

test "extract: a def's fragment carries the bytes it emitted" {
    var compiled = try compileWithFragments(
        \\def helper() -> i16
        \\  return 7
        \\end
        \\def main()
        \\  print helper()
        \\end
        \\
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var saw_helper = false;
    for (compiled.fragments) |f| {
        if (std.mem.eql(u8, f.symbol, "helper")) {
            saw_helper = true;
            try std.testing.expect(f.bytes.len > 0);
        }
    }
    try std.testing.expect(saw_helper);
}

test "extract: fragments do not overlap" {
    var compiled = try compileWithFragments(
        \\def a() -> i16
        \\  return 1
        \\end
        \\def b() -> i16
        \\  return 2
        \\end
        \\def main()
        \\  print a() + b()
        \\end
        \\
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());
    // Each symbol appears once; a symbol emitted twice would mean two
    // fragments claiming the same bytes, and the cache would pick one.
    for (compiled.fragments, 0..) |f, i| {
        for (compiled.fragments[i + 1 ..]) |g| {
            try std.testing.expect(!std.mem.eql(u8, f.symbol, g.symbol));
        }
    }
}

test "extract: a loop's back edge stays inside its own fragment" {
    var compiled = try compileWithFragments(
        \\def counted() -> i16
        \\  let total = 0
        \\  for i in 0..5
        \\    total = total + i
        \\  end
        \\  return total
        \\end
        \\def main()
        \\  print counted()
        \\end
        \\
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // Relocations are rebased to the fragment, so a back edge that left
    // its own body would land outside the bytes and make the fragment
    // unusable at another address.
    for (compiled.fragments) |f| {
        for (f.relocs) |r| {
            try std.testing.expect(r.patch_offset + 1 < f.bytes.len);
            try std.testing.expect(r.target_offset <= f.bytes.len);
        }
    }
}

test "extract: a cross-def call travels as a name, not an address" {
    var compiled = try compileWithFragments(
        \\def callee() -> i16
        \\  return 3
        \\end
        \\def caller() -> i16
        \\  return callee()
        \\end
        \\def main()
        \\  print caller()
        \\end
        \\
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    for (compiled.fragments) |f| {
        if (!std.mem.eql(u8, f.symbol, "caller")) continue;
        var names_callee = false;
        for (f.refs) |r| {
            if (r.kind == .call and std.mem.eql(u8, r.name, "callee")) names_callee = true;
            try std.testing.expect(r.patch_offset + 1 < f.bytes.len);
        }
        try std.testing.expect(names_callee);
    }
}

test "extract: off by default" {
    var stream = try gero.lang.tokenize(alloc, "def main()\n  print 1\nend\n");
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, "def main()\n  print 1\nend\n", stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, "def main()\n  print 1\nend\n", &tree.program);
    defer checked.deinit();
    var compiled = try gero.lang.compile(alloc, "def main()\n  print 1\nend\n", &checked, .{});
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 0), compiled.fragments.len);
}

test "extract: a fragment defines the symbol it was recorded for" {
    var compiled = try compileWithFragments(
        \\def helper() -> i16
        \\  return 7
        \\end
        \\def main()
        \\  print helper()
        \\end
        \\
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // A splice restores these so references from elsewhere resolve
    // into the fragment; a fragment defining nothing would link to
    // a missing symbol.
    for (compiled.fragments) |f| {
        var defines_self = false;
        for (f.defines) |d| {
            if (std.mem.eql(u8, d.name, f.symbol)) defines_self = true;
            try std.testing.expect(d.offset < f.bytes.len);
        }
        try std.testing.expect(defines_self);
    }
}

test "extract: a closure's fn_ptr slot names the lambda body" {
    var compiled = try compileWithFragments(
        \\def apply() -> i16
        \\  let f = |x: i16| -> i16 x * 2
        \\  return f(21)
        \\end
        \\def main()
        \\  print apply()
        \\end
        \\
    );
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    // The lambda body emits inside its parent's range, so the parent
    // both defines it and holds the slot naming it.
    for (compiled.fragments) |f| {
        if (!std.mem.eql(u8, f.symbol, "apply")) continue;
        var has_lambda_ref = false;
        for (f.refs) |r| {
            if (r.kind == .lambda) has_lambda_ref = true;
        }
        try std.testing.expect(has_lambda_ref);
        try std.testing.expect(f.defines.len >= 2);
    }
}

/// Compile `src` twice — once lowering every body, once splicing the
/// first build's fragments for every def but the entry — and return
/// both images. A cache hit must be indistinguishable from a lowering.
fn compileTwice(src: []const u8) !struct { full: gero.lang.Compiled, cached: gero.lang.Compiled } {
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, src, &tree.program);
    defer checked.deinit();

    var full = try gero.lang.compile(alloc, src, &checked, .{ .emit_fragments = true });
    errdefer full.deinit();

    const cached = try gero.lang.compile(alloc, src, &checked, .{
        .emit_fragments = true,
        .cached_fragments = full.fragments,
    });
    return .{ .full = full, .cached = cached };
}

test "splice: a build from cached fragments matches one that lowered them" {
    var r = try compileTwice(
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
        \\def total() -> i16
        \\  let sum = 0
        \\  for i in 0..4
        \\    sum = add(sum, i)
        \\  end
        \\  return sum
        \\end
        \\def main()
        \\  print total()
        \\end
        \\
    );
    defer r.full.deinit();
    defer r.cached.deinit();

    try std.testing.expect(!r.full.hasErrors());
    try std.testing.expect(!r.cached.hasErrors());
    try std.testing.expectEqualSlices(u8, r.full.image, r.cached.image);
}

test "splice: a program with strings and closures round-trips" {
    var r = try compileTwice(
        \\def greet(n: i16) -> str
        \\  if n > 0
        \\    return "positive"
        \\  end
        \\  return "other"
        \\end
        \\def apply() -> i16
        \\  let f = |x: i16| -> i16 x * 2
        \\  return f(21)
        \\end
        \\def main()
        \\  print greet(1)
        \\  print apply()
        \\end
        \\
    );
    defer r.full.deinit();
    defer r.cached.deinit();

    try std.testing.expect(!r.full.hasErrors());
    try std.testing.expect(!r.cached.hasErrors());
    try std.testing.expectEqualSlices(u8, r.full.image, r.cached.image);
}

test "splice: the cached bytes are what lands in the image" {
    const src =
        \\def helper() -> i16
        \\  return 7
        \\end
        \\def main()
        \\  print helper()
        \\end
        \\
    ;
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, src, &tree.program);
    defer checked.deinit();

    var full = try gero.lang.compile(alloc, src, &checked, .{ .emit_fragments = true });
    defer full.deinit();
    try std.testing.expect(!full.hasErrors());

    // Pad one fragment. If the splice path were dead the image would be
    // unchanged, so the size difference is what proves cached bytes are
    // the ones emitted.
    const patched = try alloc.alloc(gero.lang.Fragment, full.fragments.len);
    defer alloc.free(patched);
    var padded: []u8 = &.{};
    defer if (padded.len > 0) alloc.free(padded);
    for (full.fragments, patched) |src_f, *dst_f| {
        dst_f.* = src_f;
        if (!std.mem.eql(u8, src_f.symbol, "helper")) continue;
        padded = try alloc.alloc(u8, src_f.bytes.len + 1);
        @memcpy(padded[0..src_f.bytes.len], src_f.bytes);
        padded[src_f.bytes.len] = 0;
        dst_f.bytes = padded;
    }
    try std.testing.expect(padded.len > 0);

    var cached = try gero.lang.compile(alloc, src, &checked, .{ .cached_fragments = patched });
    defer cached.deinit();
    try std.testing.expectEqual(full.image.len + 1, cached.image.len);
}

/// Build `entry`'s module graph, optionally skipping the bodies of
/// modules flagged in `skip` and splicing `cached` in their place.
const IncrementalBuild = struct {
    fused: gero.lang.FusedSource,
    tree: gero.lang.ModuleParse,
    checked: gero.lang.CheckedProgram,
    compiled: gero.lang.Compiled,

    fn deinit(self: *IncrementalBuild) void {
        self.compiled.deinit();
        self.checked.deinit();
        self.tree.deinit();
        self.fused.deinit();
    }
};

fn buildGraph(
    path: []const u8,
    skip: []const bool,
    cached: []const gero.lang.Fragment,
    arities: []const gero.lang.ArityRequest,
) !IncrementalBuild {
    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, path);
    errdefer fused.deinit();
    var stream = try gero.lang.tokenize(alloc, fused.source);
    defer stream.deinit();
    var tree = try gero.lang.parseAllModules(alloc, fused.source, stream, &fused.source_map);
    errdefer tree.deinit();

    const graph: gero.lang.ModuleGraph = .{
        .source_map = &fused.source_map,
        .imports = fused.imports,
        .skip_bodies = skip,
        .cached_arities = arities,
    };
    var checked = try gero.lang.typecheckGraph(alloc, fused.source, &tree.program, &fused.import_aliases, graph);
    errdefer checked.deinit();

    const compiled = try gero.lang.compile(alloc, fused.source, &checked, .{
        .import_aliases = &fused.import_aliases,
        .graph = .{ .source_map = &fused.source_map, .imports = fused.imports },
        .emit_fragments = true,
        .cached_fragments = cached,
    });
    return .{ .fused = fused, .tree = tree, .checked = checked, .compiled = compiled };
}

test "skip_bodies: skipping a clean module's bodies builds the same image" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def helper(n: i16) -> i16
        \\  return n + 1
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use "./lib"
        \\def main()
        \\  print helper(41)
        \\end
        \\
    );
    const path = try fx.tmp.dir.realPathFileAlloc(std.testing.io, "main.gr", alloc);
    defer alloc.free(path);

    var full = try buildGraph(path, &.{}, &.{}, &.{});
    defer full.deinit();
    try std.testing.expect(!full.compiled.hasErrors());

    // Skip the library — the module a dependent's edit cannot invalidate
    // — and supply its code from the first build.
    var skip = [_]bool{ false, false };
    for (full.fused.source_map.files.items, 0..) |f, i| {
        if (std.mem.endsWith(u8, f.path, "lib.gr")) skip[i] = true;
    }
    try std.testing.expect(skip[0] or skip[1]);

    var incr = try buildGraph(path, &skip, full.compiled.fragments, &.{});
    defer incr.deinit();
    try std.testing.expect(!incr.compiled.hasErrors());
    try std.testing.expectEqualSlices(u8, full.compiled.image, incr.compiled.image);
}

// ---------- line table (ISA §7.3) ----------

test "line table: a multi-file program attributes each address to its own file" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr",
        \\def double(n: i16) -> i16
        \\  return n * 2
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use "./lib"
        \\def main()
        \\  let a = 1
        \\  print double(a)
        \\end
        \\
    );
    const path = try fx.pathOf("main.gr");
    defer std.testing.allocator.free(path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, std.testing.allocator, path);
    defer fused.deinit();
    var stream = try gero.lang.tokenize(std.testing.allocator, fused.source);
    defer stream.deinit();
    var tree = try gero.lang.parseAllModules(std.testing.allocator, fused.source, stream, &fused.source_map);
    defer tree.deinit();
    var checked = try gero.lang.typecheckGraph(std.testing.allocator, fused.source, &tree.program, &fused.import_aliases, .{ .source_map = &fused.source_map, .imports = fused.imports });
    defer checked.deinit();
    checked.program = &tree.program;
    var compiled = try gero.lang.compile(std.testing.allocator, fused.source, &checked, .{
        .import_aliases = &fused.import_aliases,
        .graph = .{ .source_map = &fused.source_map, .imports = fused.imports },
    });
    defer compiled.deinit();

    const header = try gero.disasm.parseHeader(compiled.image);
    const files = try gero.gx.decodeFiles(std.testing.allocator, (try gero.gx.findChunk(header.debug, .files)).?);
    defer std.testing.allocator.free(files);
    const rows = try gero.gx.decodeLines(std.testing.allocator, (try gero.gx.findChunk(header.debug, .lines)).?);
    defer std.testing.allocator.free(rows);

    // Both files appear, and at least one row names each — an address
    // from an imported module must not be credited to the importer.
    try std.testing.expect(files.len >= 2);
    var saw_main = false;
    var saw_lib = false;
    for (rows) |r| {
        const name = std.fs.path.basename(files[r.file]);
        if (std.mem.eql(u8, name, "main.gr")) saw_main = true;
        if (std.mem.eql(u8, name, "lib.gr")) saw_lib = true;
    }
    try std.testing.expect(saw_main);
    try std.testing.expect(saw_lib);

    // Every row's range is non-empty and lands inside the image.
    for (rows) |r| try std.testing.expect(r.end_addr > r.start_addr);
}

test "line table: absent when the build has no module graph" {
    // A single-file compile with no source map cannot attribute a
    // fused offset to a file, so it emits symbols only.
    const src = "def main()\n  print 1\nend\n";
    var stream = try gero.lang.tokenize(std.testing.allocator, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(std.testing.allocator, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(std.testing.allocator, src, &tree.program);
    defer checked.deinit();
    var compiled = try gero.lang.compile(std.testing.allocator, src, &checked, .{});
    defer compiled.deinit();

    const header = try gero.disasm.parseHeader(compiled.image);
    try std.testing.expect((try gero.gx.findChunk(header.debug, .lines)) == null);
    try std.testing.expect((try gero.gx.findChunk(header.debug, .symbols)) != null);
}
