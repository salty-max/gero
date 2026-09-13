//! Mirror file for `src/lang/codegen/fixed.zig`.

const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;
const debug_dump = false;

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
    if (debug_dump and compiled.hasErrors()) {
        for (compiled.diagnostics) |d| std.debug.print("{s}: {s}\n", .{ d.code, d.message });
    }
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
    try expectRuns(
        \\def main()
        \\  print 200.5 + 55.25
        \\  print 1000.75 - 0.5
        \\  print 0.0 - 3.125
        \\  print 30000.0 + 700.5
        \\  let screen: fixed = 200.8
        \\  screen += 0.35
        \\  print screen
        \\  screen++
        \\  print screen
        \\  screen--
        \\  print screen
        \\  let across: fixed = 0.0
        \\  let steps: i16 = 0
        \\  while across < 320.0
        \\    across += 0.3
        \\    steps += 1
        \\  end
        \\  print across
        \\  print steps
        \\end
        \\
    , "255.750\n1000.250\n-3.125\n30700.500\n201.150\n202.150\n201.150\n320.103\n1067\n");
}

test "fixed: range endpoints format, compare, and wrap correctly" {
    try expectRuns(
        \\def main()
        \\  let high: fixed = 32767.9999847412109375
        \\  let low: fixed = -32768.0
        \\  let quantum: fixed = 0.00001526
        \\  let one: fixed = 1.0
        \\  print high
        \\  print low
        \\  if high > 0.0
        \\    print 1
        \\  end
        \\  if low < 0.0
        \\    print 2
        \\  end
        \\  print high + quantum
        \\  print low - quantum
        \\  print high * one
        \\  print low * one
        \\end
        \\
    , "32767.999\n-32768.000\n1\n2\n-32768.000\n32767.999\n32767.999\n-32768.000\n");
}

test "fixed: structs, tuples, arrays, and vectors retain both words" {
    try expectRuns(
        \\struct Position
        \\  x: fixed
        \\  y: fixed
        \\end
        \\def main()
        \\  let p: Position = Position { x: 200.5, y: -300.25 }
        \\  print p.x
        \\  p.x = p.x + 1.25
        \\  print p
        \\  if p == Position { x: 201.75, y: -300.25 }
        \\    print 1
        \\  end
        \\  let t = (1000.5, -2.25)
        \\  print t.0
        \\  t.1 = 300.75
        \\  print t.1
        \\  if t == (1000.5, 300.75)
        \\    print 2
        \\  end
        \\  let a: [fixed; 3] = [200.5, -300.25, 1000.75]
        \\  print a[1]
        \\  a[1] = 400.5
        \\  print a[1]
        \\  let repeated: [fixed; 2] = [512.25; 2]
        \\  print repeated[1]
        \\  let v: Vec(fixed) = Vec.from(a)
        \\  v.push(-700.125)
        \\  v.set(0, 800.875)
        \\  print v.at(0)
        \\  print v.at(3)
        \\end
        \\
    , "200.500\nPosition { x: 201.750, y: -300.250 }\n1\n1000.500\n300.750\n2\n-300.250\n400.500\n512.250\n800.875\n-700.125\n");
}

test "fixed: destructuring and enum payloads retain both words" {
    try expectRuns(
        \\enum Reading
        \\  case Value(amount: fixed)
        \\  case Missing
        \\end
        \\def main()
        \\  let (left, right) = (200.5, -300.25)
        \\  print left
        \\  print right
        \\  let reading = Reading.Value(1000.75)
        \\  match reading
        \\    case Reading.Value(amount) => print amount
        \\    case Reading.Missing => print 0
        \\  end
        \\  print reading
        \\  if reading == Reading.Value(1000.75)
        \\    print 1
        \\  end
        \\end
        \\
    , "200.500\n-300.250\n1000.750\nReading.Value(1000.750)\n1\n");
}

test "fixed: class fields, methods, closures, and iteration retain both words" {
    try expectRuns(
        \\class Meter
        \\  let value: fixed
        \\  def init(self, value: fixed)
        \\    self.value = value
        \\  end
        \\  def add(self, amount: fixed) -> fixed
        \\    self.value = self.value + amount
        \\    return self.value
        \\  end
        \\end
        \\def main()
        \\  let meter = Meter(200.5)
        \\  print meter.add(300.25)
        \\  let base: fixed = 1000.5
        \\  let add = |amount: fixed| -> fixed base + amount
        \\  print add(2.25)
        \\  let total: fixed = 200.5
        \\  let bump = lambda (amount: fixed)
        \\    total += amount
        \\  end
        \\  bump(300.25)
        \\  print total
        \\  let values: [fixed; 2] = [300.5, -400.25]
        \\  for value in values
        \\    print value
        \\  end
        \\  let dynamic: Vec(fixed) = Vec.from(values)
        \\  for value in dynamic
        \\    print value
        \\  end
        \\end
        \\
    , "500.750\n1002.750\n500.750\n300.500\n-400.250\n300.500\n-400.250\n");
}

test "fixed: optional values retain both words" {
    try expectRuns(
        \\def echo(value: fixed) -> fixed
        \\  return value
        \\end
        \\def maybe(value: fixed, present: bool) -> fixed?
        \\  if present
        \\    return value
        \\  end
        \\  return nil
        \\end
        \\def main()
        \\  let a: fixed? = 200.5
        \\  if let value = a
        \\    let copy: fixed = value
        \\    print echo(copy)
        \\  end
        \\  if let value = maybe(-300.25, true)
        \\    print value
        \\  end
        \\  if let value = maybe(1000.0, false)
        \\    print value
        \\  else
        \\    print 9
        \\  end
        \\  let values: Vec(fixed) = Vec.from([400.75])
        \\  if let value = values.get(0)
        \\    print value
        \\  end
        \\  if let value = values.pop()
        \\    print value
        \\  end
        \\end
        \\
    , "200.500\n-300.250\n9\n400.750\n400.750\n");
}

test "fixed: class iterators return fixed optionals" {
    try expectRuns(
        \\class Samples
        \\  let index: i16
        \\  def init(self)
        \\    self.index = 0
        \\  end
        \\  def next(self) -> fixed?
        \\    if self.index >= 2
        \\      return nil
        \\    end
        \\    self.index = self.index + 1
        \\    return 200.5 + (self.index as fixed)
        \\  end
        \\end
        \\def main()
        \\  let samples = Samples()
        \\  for sample in samples
        \\    print sample
        \\  end
        \\end
        \\
    , "201.500\n202.500\n");
}

test "fixed: casts apply the scale and round toward zero" {
    try expectRuns(
        \\def main()
        \\  let positive: i16 = 300
        \\  let negative: i16 = -300
        \\  print positive as fixed
        \\  print negative as fixed
        \\  print 200.75 as i16
        \\  print -200.75 as i16
        \\  let first = true
        \\  while let value = 200.5 when first
        \\    print value
        \\    first = false
        \\  end
        \\end
        \\
    , "300.000\n-300.000\n200\n-200\n200.500\n");
}

test "fixed: formatting and variadic arguments retain both words" {
    try expectRuns(
        \\def second(args: ...) -> fixed
        \\  return args.1
        \\end
        \\def line(fmt: str, args: ...) -> str
        \\  return str.format(fmt, args)
        \\end
        \\def main()
        \\  print str.format("{0} / {1}", 200.5, -300.25)
        \\  let pair = (1000.75, -2.5)
        \\  print str.format("{0}, {1}", pair)
        \\  print second(1.25, 600.5)
        \\  print line("{0} + {1}", 700.125, 800.25)
        \\  print "$(200.5) $(255:04X)"
        \\  print "$(1.2345:.2)"
        \\  print str.format("{0:.4}", 1.2345)
        \\end
        \\
    , "200.500 / -300.250\n1000.750, -2.500\n600.500\n700.125 + 800.250\n200.500 00FF\n1.23\n1.2344\n");
}

test "fixed: math helpers operate on full Q16.16 values" {
    try expectRuns(
        \\def main()
        \\  print math.abs(-300.25)
        \\  print math.min(200.5, -300.25)
        \\  print math.max(200.5, 1000.75)
        \\  print math.clamp(900.5, -100.0, 500.25)
        \\  print math.wrap_add(30000.0, 1000.5)
        \\  print math.wrap_sub(-30000.0, 1000.5)
        \\  print math.wrap_mul(200.0, 3.0)
        \\end
        \\
    , "300.250\n-300.250\n1000.750\n500.250\n31000.500\n-31000.500\n600.000\n");
}

test "fixed: division by power-of-two constants rounds toward zero" {
    try expectRuns(
        \\def main()
        \\  print 1000.5 / 2.0
        \\  print -1000.5 / 2.0
        \\  print 1.25 / 0.5
        \\  print 1.25 / -0.5
        \\end
        \\
    , "500.250\n-500.250\n2.500\n-2.500\n");
}

test "fixed: inline parameters and assertions retain both words" {
    try expectRuns(
        \\@inline
        \\def add_inline(a: fixed, b: fixed) -> fixed
        \\  return a + b
        \\end
        \\def main()
        \\  let result: fixed = add_inline(200.5, 300.25)
        \\  test.assert_eq(result, 500.75)
        \\  test.assert_ne(result, -500.75)
        \\  print result
        \\end
        \\
    , "500.750\n");
}

test "fixed: cross-bank calls preserve parameters and return values" {
    try expectRuns(
        \\@bank 2
        \\def banked_add(a: fixed, b: fixed) -> fixed
        \\  return a + b
        \\end
        \\def main()
        \\  print banked_add(200.5, 300.25)
        \\end
        \\
    , "500.750\n");
}

test "fixed: deferred work preserves a return value" {
    try expectRuns(
        \\def measured() -> fixed
        \\  defer print 2.0 * 3.0
        \\  return 300.25
        \\end
        \\def main()
        \\  print measured()
        \\end
        \\
    , "6.000\n300.250\n");
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

test "fixed: modulo is floored" {
    // A remainder takes the divisor's sign, so wrapping a value into a
    // range never lands outside it — the property `angle % 360.0`
    // depends on.
    try expectRuns(
        \\def main()
        \\  let turn: fixed = 0.0 - 90.0
        \\  print turn % 360.0
        \\  print 7.5 % 2.0
        \\  print 7.5 % (0.0 - 2.0)
        \\  print (0.0 - 7.5) % (0.0 - 2.0)
        \\  print 1.0 % 0.25
        \\end
        \\
    , "270.000\n1.500\n-0.500\n-1.500\n0.000\n");
}

test "fixed: a zero remainder stays zero whatever the signs" {
    // The floored correction rewrites a remainder to `|b| - r`, which
    // would turn an exact division's zero into the divisor itself.
    try expectRuns(
        \\def main()
        \\  print (0.0 - 8.0) % 2.0
        \\  print 8.0 % (0.0 - 2.0)
        \\  print 8.0 % 2.0
        \\end
        \\
    , "0.000\n0.000\n0.000\n");
}

test "fixed: compound modulo assignment retains both words" {
    try expectRuns(
        \\def main()
        \\  let x: fixed = 200.5
        \\  x %= 60.0
        \\  print x
        \\end
        \\
    , "20.500\n");
}

test "fixed: baked multiplication matches runtime rounding" {
    try expectRuns(
        \\const BAKED: fixed = bake do
        \\  (0.0 - 0.1) * 0.1
        \\end
        \\def main()
        \\  let runtime: fixed = (0.0 - 0.1) * 0.1
        \\  test.assert_eq(BAKED, runtime)
        \\  print runtime
        \\end
        \\
    , "-0.009\n");
}

test "fixed: runtime helpers match baked arithmetic" {
    try expectRuns(
        \\const PRODUCT: fixed = bake do
        \\  123.456 * (0.0 - 7.89)
        \\end
        \\const QUOTIENT: fixed = bake do
        \\  123.456 / (0.0 - 7.89)
        \\end
        \\def main()
        \\  let factor: fixed = 0.0 - 7.89
        \\  test.assert_eq(PRODUCT, 123.456 * factor)
        \\  test.assert_eq(QUOTIENT, 123.456 / factor)
        \\  print PRODUCT
        \\  print QUOTIENT
        \\end
        \\
    , "-974.067\n-15.647\n");
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

test "fixed: modulo by zero raises the divide-by-zero fault" {
    const src =
        \\def main()
        \\  print 7.5 % 0.0
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
        \\let inferred_g = 700.25
        \\const INFERRED_C = -900.75
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
        \\  print inferred_g
        \\  print INFERRED_C
        \\  g = g + 1.25
        \\  print g
        \\  print scale(150.25)
        \\  print add2(200.5, 55.25)
        \\  print -x
        \\end
        \\
    , "200.500\n300.500\n700.250\n-900.750\n301.750\n300.500\n255.750\n-200.500\n");
}
