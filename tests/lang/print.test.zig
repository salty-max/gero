/// Tests for `gero.lang.print` — the canonical pretty-printer.
///
/// Three flavors of coverage:
///   1. `expectPrint(source, expected)` — exact-output tests for
///      individual AST variants, calibrating the canonical shape.
///   2. `expectIdempotent(source)` — round-trip property tests
///      asserting `print(parse(print(parse(s)))) == print(parse(s))`.
///      Once a source canonicalizes, re-parsing + re-printing
///      yields byte-identical output.
///   3. A fixture-driven loop over `print_fixtures.fixtures` so
///      printer drift on a node variant is caught even when the
///      variant only appears in the wider corpus.
const std = @import("std");
const gero = @import("gero");
const fixtures_mod = @import("print_fixtures.zig");

const alloc = std.testing.allocator;

fn parseSource(source: []const u8) !gero.lang.ParseTree {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    return gero.lang.parse(alloc, source, stream);
}

/// Parse + print into a freshly allocated buffer.
fn renderSource(source: []const u8) ![]u8 {
    var tree = try parseSource(source);
    defer tree.deinit();
    if (tree.errors.len != 0) {
        std.debug.print("unexpected parse errors for `{s}`:\n", .{source});
        for (tree.errors) |e| std.debug.print("  - {s}\n", .{e.message});
        return error.UnexpectedParseErrors;
    }

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    var writer = std.Io.Writer.Allocating.fromArrayList(alloc, &buf);
    defer writer.deinit();

    try gero.lang.print(&writer.writer, &tree.program, source);
    return writer.toOwnedSlice();
}

fn expectPrint(source: []const u8, expected: []const u8) !void {
    const out = try renderSource(source);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

fn expectIdempotent(source: []const u8) !void {
    const first = try renderSource(source);
    defer alloc.free(first);
    const second = try renderSource(first);
    defer alloc.free(second);
    try std.testing.expectEqualStrings(first, second);
}

// ---------- bindings ----------

test "print: let with init" {
    try expectPrint("let x = 42", "let x = 42\n");
}

test "print: let with type annotation" {
    try expectPrint("let x: i16 = 0", "let x: i16 = 0\n");
}

test "print: let without init (typed)" {
    try expectPrint("let x: i16", "let x: i16\n");
}

test "print: const decl" {
    try expectPrint("const MAX = 100", "const MAX = 100\n");
}

test "print: local prefix on let" {
    try expectPrint("local let helper = 0", "local let helper = 0\n");
}

// ---------- assignment ----------

test "print: plain assign" {
    try expectPrint("x = 1", "x = 1\n");
}

test "print: compound assigns" {
    try expectPrint("x += 1", "x += 1\n");
    try expectPrint("x -= 1", "x -= 1\n");
    try expectPrint("x *= 1", "x *= 1\n");
    try expectPrint("x <<= 1", "x <<= 1\n");
}

test "print: increment / decrement" {
    try expectPrint("x++", "x++\n");
    try expectPrint("y--", "y--\n");
}

test "print: discard" {
    try expectPrint("_ = call()", "_ = call()\n");
}

// ---------- expressions: precedence + parens ----------

test "print: binary precedence keeps minimum parens" {
    try expectPrint("let x = a + b * c", "let x = a + b * c\n");
}

test "print: explicit parens preserved" {
    try expectPrint("let x = (a + b) * c", "let x = (a + b) * c\n");
}

test "print: unary minus tighter than mul" {
    try expectPrint("let x = -a * b", "let x = -a * b\n");
}

test "print: bitwise NOT" {
    try expectPrint("let x = ~mask & $FF", "let x = ~mask & $FF\n");
}

test "print: ref of ident" {
    try expectPrint("let r = &x", "let r = &x\n");
}

test "print: cast" {
    try expectPrint("let v = x as i16", "let v = x as i16\n");
}

test "print: is-test" {
    try expectPrint("let b = item is Item.Sword", "let b = item is Item.Sword\n");
}

test "print: range exclusive + inclusive" {
    try expectPrint("let r = 0..10", "let r = 0..10\n");
    try expectPrint("let r = 0..=10", "let r = 0..=10\n");
}

// ---------- literals ----------

test "print: list literal" {
    try expectPrint("let xs = [1, 2, 3]", "let xs = [1, 2, 3]\n");
}

test "print: empty list literal" {
    try expectPrint("let xs = []", "let xs = []\n");
}

test "print: array-repeat literal" {
    try expectPrint("let buf = [0; 64]", "let buf = [0; 64]\n");
}

test "print: tuple literal" {
    try expectPrint("let t = (1, 2)", "let t = (1, 2)\n");
}

test "print: struct literal" {
    try expectPrint(
        "let s = Stats { hp: 100, mp: 30 }",
        "let s = Stats { hp: 100, mp: 30 }\n",
    );
}

test "print: hex literal preserved" {
    try expectPrint("let n = $FF", "let n = $FF\n");
}

test "print: string with interpolation" {
    try expectPrint(
        \\let s = "hi $(name)"
    ,
        "let s = \"hi $(name)\"\n",
    );
}

// ---------- short lambda ----------

test "print: short lambda" {
    try expectPrint("let f = |x| x * 2", "let f = |x| x * 2\n");
}

test "print: short lambda multi-arg" {
    try expectPrint("let add = |x, y| x + y", "let add = |x, y| x + y\n");
}

test "print: short lambda zero-arg" {
    try expectPrint("let f = || read()", "let f = || read()\n");
}

// ---------- control flow ----------

test "print: if/end" {
    try expectPrint(
        \\if x > 0
        \\  print x
        \\end
    ,
        "if x > 0\n  print x\nend\n",
    );
}

test "print: if/elif/else" {
    try expectPrint(
        \\if x > 0
        \\  return x
        \\elif x == 0
        \\  return 0
        \\else
        \\  return -x
        \\end
    ,
        "if x > 0\n  return x\nelif x == 0\n  return 0\nelse\n  return -x\nend\n",
    );
}

test "print: if let" {
    try expectPrint(
        \\if let Item.Potion(n) = item
        \\  drink(n)
        \\end
    ,
        "if let Item.Potion(n) = item\n  drink(n)\nend\n",
    );
}

test "print: while" {
    try expectPrint(
        \\while i < 10
        \\  i += 1
        \\end
    ,
        "while i < 10\n  i += 1\nend\n",
    );
}

test "print: for in range" {
    try expectPrint(
        \\for i in 0..10
        \\  print i
        \\end
    ,
        "for i in 0..10\n  print i\nend\n",
    );
}

test "print: for in range with step" {
    try expectPrint(
        \\for i in 0..=100 step 5
        \\  print i
        \\end
    ,
        "for i in 0..=100 step 5\n  print i\nend\n",
    );
}

test "print: labeled while + break :label" {
    try expectPrint(
        \\while true :outer
        \\  break :outer
        \\end
    ,
        "while true :outer\n  break :outer\nend\n",
    );
}

test "print: repeat until" {
    try expectPrint(
        \\repeat
        \\  x -= 1
        \\until x == 0
    ,
        "repeat\n  x -= 1\nuntil x == 0\n",
    );
}

test "print: match arms with =>" {
    try expectPrint(
        \\match item
        \\  case Item.Sword => equip()
        \\  case _ => skip()
        \\end
    ,
        "match item\n  case Item.Sword => equip()\n  case _ => skip()\nend\n",
    );
}

test "print: match arm with guard" {
    try expectPrint(
        \\match item
        \\  case Item.Potion(n) when n > 50 => big()
        \\  case _ => small()
        \\end
    ,
        "match item\n  case Item.Potion(n) when n > 50 => big()\n  case _ => small()\nend\n",
    );
}

test "print: do block as statement" {
    try expectPrint(
        \\do
        \\  let temp = compute()
        \\  print temp
        \\end
    ,
        "do\n  let temp = compute()\n  print temp\nend\n",
    );
}

// ---------- functions / classes / structs / enums ----------

test "print: def with params + return" {
    try expectPrint(
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
    ,
        "def add(a: i16, b: i16) -> i16\n  return a + b\nend\n",
    );
}

test "print: def with annotation" {
    try expectPrint(
        \\@inline
        \\def clamp(x: i16) -> i16
        \\  return x
        \\end
    ,
        "@inline\ndef clamp(x: i16) -> i16\n  return x\nend\n",
    );
}

test "print: variadic param" {
    try expectPrint(
        \\def log(fmt: str, args: ...)
        \\  print fmt
        \\end
    ,
        "def log(fmt: str, args: ...)\n  print fmt\nend\n",
    );
}

test "print: bake def" {
    try expectPrint(
        \\bake def make() -> i16
        \\  return 42
        \\end
    ,
        "bake def make() -> i16\n  return 42\nend\n",
    );
}

test "print: bake do in const init" {
    try expectPrint(
        \\const X = bake do
        \\  let n = 1
        \\  n
        \\end
    ,
        "const X = bake do\n  let n = 1\n  n\nend\n",
    );
}

test "print: struct decl" {
    try expectPrint(
        \\struct Stats
        \\  hp: i16
        \\  mp: i16
        \\end
    ,
        "struct Stats\n  hp: i16\n  mp: i16\nend\n",
    );
}

test "print: enum decl with payloads" {
    try expectPrint(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
    ,
        "enum Item\n  case Sword\n  case Potion(amount: i16)\nend\n",
    );
}

// ---------- types ----------

test "print: nullable type" {
    try expectPrint("let s: str? = nil", "let s: str? = nil\n");
}

test "print: reference type" {
    try expectPrint(
        \\def foo(s: &Stats)
        \\end
    ,
        "def foo(s: &Stats)\nend\n",
    );
}

test "print: array type" {
    try expectPrint("let buf: [u8; 64]", "let buf: [u8; 64]\n");
}

test "print: Vec type" {
    try expectPrint("let xs: Vec(i16) = Vec.new()", "let xs: Vec(i16) = Vec.new()\n");
}

test "print: tuple type" {
    try expectPrint("let p: (i16, str)", "let p: (i16, str)\n");
}

test "print: function type" {
    try expectPrint(
        "let op: fn(i16, i16) -> i16",
        "let op: fn(i16, i16) -> i16\n",
    );
}

// ---------- imports ----------

test "print: use module" {
    try expectPrint("use math", "use math\n");
}

test "print: use selective from" {
    try expectPrint("use abs from math", "use abs from math\n");
}

test "print: use rename + selective" {
    try expectPrint(
        "use abs as absolute from math",
        "use abs as absolute from math\n",
    );
}

test "print: use quoted path" {
    try expectPrint("use \"./physics\"", "use \"./physics\"\n");
}

// ---------- misc statements ----------

test "print: defer + return" {
    try expectPrint(
        \\def f()
        \\  defer cleanup()
        \\  return
        \\end
    ,
        "def f()\n  defer cleanup()\n  return\nend\n",
    );
}

test "print: asm statement" {
    try expectPrint(
        \\def swap(a: u16, b: u16)
        \\  asm "swap {a}, {b}"
        \\end
    ,
        "def swap(a: u16, b: u16)\n  asm \"swap {a}, {b}\"\nend\n",
    );
}

test "print: print statement multi-arg" {
    try expectPrint("print x, y, z", "print x, y, z\n");
}

// ---------- idempotency property ----------

test "print: idempotent on full J-RPG loop sketch (§8.3 lite)" {
    try expectIdempotent(
        \\class GameState
        \\  let player_x: i16
        \\  let player_y: i16
        \\
        \\  def init(self)
        \\    self.player_x = 128
        \\    self.player_y = 96
        \\  end
        \\
        \\  def update(self)
        \\    if input.up()
        \\      self.player_y -= 1
        \\    end
        \\  end
        \\end
        \\
        \\let state = GameState()
        \\
        \\while true
        \\  state.update()
        \\end
    );
}

test "print: idempotent on annotations stack" {
    try expectIdempotent(
        \\@bank 5
        \\@cold
        \\def boss_battle()
        \\  return
        \\end
    );
}

test "print: idempotent on pattern matching" {
    try expectIdempotent(
        \\match e
        \\  case Event.Quit => cleanup()
        \\  case Event.KeyDown(k) when k == $1B => quit()
        \\  case Event.MouseClick(x, y) => hit(x, y)
        \\  case _ => skip()
        \\end
    );
}

test "print: idempotent on nested expressions" {
    try expectIdempotent("let r = (a + b) * c - d / (e + f)");
}

test "print: idempotent on HOF chains" {
    try expectIdempotent("let r = xs.filter(|x| x > 0).map(|x| x * 2)");
}

// ---------- fixture-driven round-trip property ----------

test "print: round-trip every fixture" {
    for (fixtures_mod.fixtures) |src| {
        expectIdempotent(src) catch |err| {
            std.debug.print("round-trip failed on fixture:\n--- src ---\n{s}\n", .{src});
            return err;
        };
    }
}
