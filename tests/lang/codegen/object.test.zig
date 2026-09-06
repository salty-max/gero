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
