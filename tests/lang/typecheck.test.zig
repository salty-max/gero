/// Smoke tests for `gero.lang.typecheck` — the scaffolding pass.
/// The walker visits every AST variant without yet emitting any
/// rule violation, so a well-formed parse should typecheck to an
/// empty diagnostic list.
const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

fn check(source: []const u8) !gero.lang.CheckedProgram {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    errdefer tree.deinit();
    return gero.lang.typecheck(alloc, source, &tree.program) catch |err| {
        tree.deinit();
        return err;
    };
}

fn checkClean(source: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
    try std.testing.expect(!checked.hasErrors());
}

test "typecheck: empty program produces no diagnostics" {
    try checkClean("");
}

test "typecheck: trivial let binding" {
    try checkClean("let x = 0");
}

test "typecheck: const decl + binary expression" {
    try checkClean("const PI_FIXED = 3 + 4 * 5");
}

test "typecheck: function declaration walks body" {
    try checkClean(
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
    );
}

test "typecheck: control-flow blocks are visited" {
    try checkClean(
        \\def f(x: i16) -> i16
        \\  if x > 0
        \\    return x
        \\  end
        \\  while x > 0
        \\    x -= 1
        \\  end
        \\  for i in 0..10
        \\    x += i
        \\  end
        \\  return x
        \\end
    );
}

test "typecheck: match arm visited (including guards)" {
    try checkClean(
        \\def handle(e: Event)
        \\  match e
        \\    case Event.Quit => cleanup()
        \\    case Event.KeyDown(k) when k == 0 => quit()
        \\    case _ => skip()
        \\  end
        \\end
    );
}

test "typecheck: class + struct + enum walk" {
    try checkClean(
        \\struct Stats
        \\  hp: i16
        \\  mp: i16
        \\end
        \\
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\
        \\class Player
        \\  let hp: i16
        \\  let mp: i16
        \\
        \\  def take_damage(self, n: i16)
        \\    self.hp -= n
        \\  end
        \\end
    );
}

test "typecheck: defer + asm + bake nodes walk cleanly" {
    try checkClean(
        \\def f()
        \\  defer cleanup()
        \\  asm "noop"
        \\end
        \\
        \\bake def make() -> i16
        \\  return 42
        \\end
    );
}

test "typecheck: short lambda body visited" {
    try checkClean("let f = |x| x * 2");
}

test "typecheck: ref expr + array-repeat literal visited" {
    try checkClean(
        \\def apply(s: &Stats)
        \\  let buf: [u8; 64] = [0; 64]
        \\end
    );
}

test "typecheck: program node retained in CheckedProgram" {
    var stream = try gero.lang.tokenize(alloc, "let x = 0");
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, "let x = 0", stream);
    defer tree.deinit();

    var checked = try gero.lang.typecheck(alloc, "let x = 0", &tree.program);
    defer checked.deinit();

    // The CheckedProgram holds a pointer back to the parser's AST.
    try std.testing.expectEqual(&tree.program, checked.program);
}
