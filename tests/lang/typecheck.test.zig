/// Tests for `gero.lang.typecheck` — covers the scaffolding walker
/// AND the slice-2 resolution + inference behaviors.
const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

fn checkSource(source: []const u8) !gero.lang.CheckedProgram {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    errdefer tree.deinit();
    if (tree.errors.len != 0) {
        std.debug.print("unexpected parse errors for `{s}`:\n", .{source});
        for (tree.errors) |e| std.debug.print("  - {s}\n", .{e.message});
        tree.deinit();
        return error.UnexpectedParseErrors;
    }
    return gero.lang.typecheck(alloc, source, &tree.program) catch |err| {
        tree.deinit();
        return err;
    };
}

/// Assert the typechecker runs without panicking. Diagnostics may
/// fire — useful for smoke-testing the walker covers a shape without
/// caring whether the input has resolved symbols.
fn expectRuns(source: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
}

/// Assert the typechecker produces zero diagnostics on a
/// fully-self-contained source.
fn expectClean(source: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();
    if (checked.diagnostics.len > 0) {
        std.debug.print("unexpected typecheck diagnostics for `{s}`:\n", .{source});
        for (checked.diagnostics) |d| std.debug.print("  - {s}\n", .{d.message});
    }
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}

/// Assert at least one diagnostic with `code` fires.
fn expectCode(source: []const u8, code: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();

    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    for (checked.diagnostics) |d| {
        if (d.expected) |exp| if (std.mem.eql(u8, exp, code)) return;
    }
    std.debug.print("missing diagnostic code `{s}` for `{s}`; got:\n", .{ code, source });
    for (checked.diagnostics) |d| {
        std.debug.print("  - {s}: {s}\n", .{ d.expected orelse "?", d.message });
    }
    return error.MissingDiagnosticCode;
}

// ---------- scaffolding walker smoke (slice-1 coverage) ----------

test "typecheck: empty program runs cleanly" {
    try expectClean("");
}

test "typecheck: walker visits every shape without crashing" {
    // Each fragment exercises a different AST surface. Symbols may
    // be undefined — we only assert the walker doesn't crash.
    try expectRuns(
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
        \\  match x
        \\    case _ => return x
        \\  end
        \\  return x
        \\end
    );
}

test "typecheck: class + struct + enum walk" {
    try expectRuns(
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
        \\
        \\  def take_damage(self, n: i16)
        \\    self.hp -= n
        \\  end
        \\end
    );
}

test "typecheck: defer + asm + bake nodes walk cleanly" {
    try expectRuns(
        \\def cleanup() end
        \\
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

test "typecheck: short lambda body resolves params" {
    try expectClean("let f = |x| x");
}

test "typecheck: ref expr + array-repeat literal walks" {
    // Bidirectional inference for integer literals lands in slice 3
    // — until then `[0; 64]` infers as `[i16; 64]` regardless of
    // annotation. Use a matching literal-array shape here.
    try expectClean(
        \\let buf: [i16; 64] = [0; 64]
    );
}

// ---------- slice 2: literal inference ----------

test "typecheck: let x = 0 binds x to i16" {
    try expectClean("let x = 0");
}

test "typecheck: let x: i16 = 0 accepts" {
    try expectClean("let x: i16 = 0");
}

test "typecheck: let x: str = \"hi\" accepts" {
    try expectClean("let x: str = \"hi\"");
}

test "typecheck: let x: str = 42 errors with E_TYPE_MISMATCH" {
    try expectCode("let x: str = 42", "E_TYPE_MISMATCH");
}

test "typecheck: let x: bool = true accepts" {
    try expectClean("let x: bool = true");
}

test "typecheck: let v: fixed = 1.5 accepts" {
    try expectClean("let v: fixed = 1.5");
}

// ---------- slice 2: identifier resolution ----------

test "typecheck: ident referencing a let binding resolves" {
    try expectClean(
        \\let x = 10
        \\let y = x
    );
}

test "typecheck: undefined ident emits E_UNDEFINED_SYMBOL" {
    try expectCode("let x = undefined_name", "E_UNDEFINED_SYMBOL");
}

test "typecheck: forward reference to top-level let resolves (two-pass)" {
    try expectClean(
        \\let y = x
        \\let x = 10
    );
}

// ---------- slice 2: named-type resolution ----------

test "typecheck: primitive type names resolve" {
    // Same caveat: integer literals pin to `i16` until slice 3
    // adds bidirectional inference. Stick to the matching primitive
    // for each annotated binding.
    try expectClean(
        \\let a: i16 = 0
        \\let c: bool = true
        \\let d: str = "hi"
    );
}

test "typecheck: `int` is an alias for i16" {
    try expectClean(
        \\let a: int = 0
        \\let b: i16 = a
    );
}

test "typecheck: undefined type name emits E_TYPE_UNDEFINED" {
    try expectCode("let x: NoSuchType = 0", "E_TYPE_UNDEFINED");
}

test "typecheck: user-defined struct type resolves" {
    try expectRuns(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\let s: Stats = Stats { hp: 0 }
    );
}

// ---------- slice 2: redefinition ----------

test "typecheck: duplicate name in same scope errors with E_TYPE_REDEFINED" {
    try expectCode(
        \\let x = 0
        \\let x = 1
    , "E_TYPE_REDEFINED");
}

test "typecheck: shadowing across scopes is allowed" {
    try expectClean(
        \\let x = 0
        \\
        \\def f()
        \\  let x = 1
        \\end
    );
}

// ---------- slice 2: function signature registration ----------

test "typecheck: def signature registered in scope" {
    try expectClean(
        \\def add(a: i16, b: i16) -> i16
        \\  return 0
        \\end
        \\
        \\let f = add
    );
}

test "typecheck: recursive fn without explicit return errors" {
    try expectCode(
        \\def fib(n: i16)
        \\  return fib(n - 1) + fib(n - 2)
        \\end
    , "E_TYPE_RECURSIVE_NO_RET");
}

test "typecheck: recursive fn WITH explicit return type accepts" {
    try expectClean(
        \\def fib(n: i16) -> i16
        \\  return fib(n - 1) + fib(n - 2)
        \\end
    );
}

// ---------- slice 2: import resolution ----------

test "typecheck: whole-module import registers an alias in scope" {
    try expectClean(
        \\use math
        \\let m = math
    );
}

test "typecheck: selective import registers each item" {
    try expectClean(
        \\use abs from math
        \\let a = abs
    );
}

// ---------- CheckedProgram surface ----------

test "typecheck: CheckedProgram retains program pointer" {
    var stream = try gero.lang.tokenize(alloc, "let x = 0");
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, "let x = 0", stream);
    defer tree.deinit();

    var checked = try gero.lang.typecheck(alloc, "let x = 0", &tree.program);
    defer checked.deinit();

    try std.testing.expectEqual(&tree.program, checked.program);
}
