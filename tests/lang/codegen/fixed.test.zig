//! Mirror file for `src/lang/codegen/fixed.zig`.

const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Compile and run `src`, asserting on what it printed.
fn expectRuns(src: []const u8, expected: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, src, &tree.program);
    defer checked.deinit();
    var compiled = try gero.lang.compile(alloc, src, &checked, .{});
    defer compiled.deinit();
    try std.testing.expect(!compiled.hasErrors());

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();

    const loaded = try gero.vm.parseGx(compiled.image);
    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    try vm.boot(alloc, loaded);
    vm.host = .{ .out = &writer.writer };
    var i: usize = 0;
    while (i < 5_000_000) : (i += 1) {
        switch (gero.vm.step(&vm)) {
            .cont, .branched => continue,
            else => break,
        }
    }
    try std.testing.expectEqualStrings(expected, writer.written());
}

test "fixed: add and subtract span the full Q16.16 range" {
    // Every one of these is outside Q8.8's ±127.99, which is why the
    // type was widened.
    try expectRuns(
        \\def main()
        \\  print 200.5 + 55.25
        \\  print 1000.75 - 0.5
        \\  print 0.0 - 3.125
        \\  print 30000.0 + 700.5
        \\end
        \\
    , "255.750\n1000.250\n-3.125\n30700.500\n");
}

test "fixed: multiply and divide" {
    try expectRuns(
        \\def main()
        \\  print 2.5 * 1.5
        \\  print 200.0 * 3.0
        \\  print 5.0 / 2.0
        \\  print 100.0 / 8.0
        \\  print 1.0 / 3.0
        \\end
        \\
    , "3.750\n600.000\n2.500\n12.500\n0.333\n");
}

test "fixed: multiply and divide carry the sign" {
    try expectRuns(
        \\def main()
        \\  print (0.0 - 2.5) * 4.0
        \\  print 2.5 * (0.0 - 4.0)
        \\  print (0.0 - 2.5) * (0.0 - 4.0)
        \\  print (0.0 - 10.0) / 4.0
        \\end
        \\
    , "-10.000\n-10.000\n10.000\n-2.500\n");
}

test "fixed: divide by zero raises the divide-by-zero fault" {
    // Matches integer division rather than running the loop to a
    // meaningless all-ones quotient.
    const src =
        \\def main()
        \\  print 7.5 / 0.0
        \\end
        \\
    ;
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, src, &tree.program);
    defer checked.deinit();
    var compiled = try gero.lang.compile(alloc, src, &checked, .{});
    defer compiled.deinit();

    const loaded = try gero.vm.parseGx(compiled.image);
    var vm = gero.vm.VM.init(alloc);
    defer vm.deinit();
    try vm.boot(alloc, loaded);

    var i: usize = 0;
    while (i < 100_000) : (i += 1) {
        if (gero.vm.step(&vm) == .halted_on_fault) break;
    }
    try std.testing.expectEqual(gero.vm.Vector.div_by_zero, vm.last_fault.?);
}

test "fixed: every comparison operator" {
    try expectRuns(
        \\def main()
        \\  let x: fixed = 200.5
        \\  if x > 100.0
        \\    print 1
        \\  end
        \\  if x == 200.5
        \\    print 2
        \\  end
        \\  if x >= 200.5
        \\    print 3
        \\  end
        \\  if x <= 200.5
        \\    print 4
        \\  end
        \\  if x != 1.0
        \\    print 5
        \\  end
        \\  if x < 300.0
        \\    print 6
        \\  end
        \\  if x < 100.0
        \\    print 9
        \\  end
        \\end
        \\
    , "1\n2\n3\n4\n5\n6\n");
}

test "fixed: locals, globals, parameters and returns hold both words" {
    try expectRuns(
        \\let g: fixed = 300.5
        \\def scale(v: fixed) -> fixed
        \\  return v * 2.0
        \\end
        \\def add2(a: fixed, b: fixed) -> fixed
        \\  return a + b
        \\end
        \\def main()
        \\  let x: fixed = 200.5
        \\  print x
        \\  print g
        \\  g = g + 1.25
        \\  print g
        \\  print scale(150.25)
        \\  print add2(200.5, 55.25)
        \\  print -x
        \\end
        \\
    , "200.500\n300.500\n301.750\n300.500\n255.750\n-200.500\n");
}
