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
        for (f.calls) |c| {
            if (c.callee) |n| if (std.mem.eql(u8, n, "callee")) {
                names_callee = true;
            };
            try std.testing.expect(c.patch_offset + 1 < f.bytes.len);
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
