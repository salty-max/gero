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
    if (tree.errors.len > 0) {
        std.debug.print("unexpected parse errors for source:\n{s}\n", .{source});
        for (tree.errors) |e| std.debug.print("  - parser={s} @ {d}: {s}\n", .{ e.parser, e.index, e.message });
    }
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
        if (std.mem.eql(u8, d.code, code)) return;
    }
    std.debug.print("missing diagnostic code `{s}` for `{s}`; got:\n", .{ code, source });
    for (checked.diagnostics) |d| {
        std.debug.print("  - {s}: {s}\n", .{ d.code, d.message });
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

test "typecheck: if let binds the pattern in guard and body" {
    // The `when` guard and the arm body both resolve the pattern's
    // bindings — here `n` from `E.A(n)` (§4.4.1).
    try expectClean(
        \\enum E
        \\  case A(x: i16)
        \\  case B
        \\end
        \\
        \\def f(e: E) -> i16
        \\  if let E.A(n) = e when n > 0
        \\    return n
        \\  end
        \\  return 0
        \\end
    );
}

test "typecheck: while let binds the pattern in the loop body" {
    try expectClean(
        \\enum E
        \\  case A(x: i16)
        \\  case B
        \\end
        \\
        \\def f(e: E) -> i16
        \\  let acc: i16 = 0
        \\  while let E.A(v) = e
        \\    return v
        \\  end
        \\  return acc
        \\end
    );
}

test "typecheck: match payload binder carries the variant's field type" {
    // `n` binds the `i16` payload, so returning it where `str` is
    // expected is a mismatch (the binder isn't left untyped).
    try expectCode(
        \\enum E
        \\  case A(x: i16)
        \\  case B
        \\end
        \\def f(e: E) -> str
        \\  match e
        \\    case E.A(n) => return n
        \\    case E.B => return "x"
        \\  end
        \\end
    , "E_TYPE_MISMATCH");
}

test "typecheck: payload binder typed for an inline-constructor scrutinee" {
    // The scrutinee `E.A(1)` surfaces no inferred type, so the enum is
    // recovered from the arm path — `n` is still typed `i16`.
    try expectCode(
        \\enum E
        \\  case A(x: i16)
        \\  case B
        \\end
        \\def main()
        \\  match E.A(1)
        \\    case E.A(n) =>
        \\      let bad: str = n
        \\      print bad
        \\    case E.B => print 0
        \\  end
        \\end
    , "E_TYPE_MISMATCH");
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

// ---------- slice 3: bidirectional integer-literal inference ----------

test "typecheck: let x: u8 = 0 pins the literal to u8" {
    try expectClean("let x: u8 = 0");
}

test "typecheck: let x: u8 = 255 accepts the boundary value" {
    try expectClean("let x: u8 = 255");
}

test "typecheck: let x: u8 = 256 errors with E_TYPE_MISMATCH (out of range)" {
    try expectCode("let x: u8 = 256", "E_TYPE_MISMATCH");
}

test "typecheck: let x: i8 = -128 accepts the boundary value" {
    try expectClean("let x: i8 = -128");
}

test "typecheck: let x: u16 = 65535 accepts" {
    try expectClean("let x: u16 = 65535");
}

test "typecheck: array-repeat with u8 elem pins literal" {
    try expectClean(
        \\let buf: [u8; 64] = [0; 64]
    );
}

// ---------- slice 3: binary operator type rules ----------

test "typecheck: i16 + i16 accepts" {
    try expectClean(
        \\let a: i16 = 1
        \\let b: i16 = a + 2
    );
}

test "typecheck: u8 + u8 with bidirectional hint accepts" {
    try expectClean(
        \\let a: u8 = 1
        \\let b: u8 = a + 2
    );
}

test "typecheck: str + str accepts (concatenation)" {
    try expectClean(
        \\let a: str = "hello"
        \\let b: str = a + " world"
    );
}

test "typecheck: 1 + true errors (mixed numeric / bool)" {
    try expectCode(
        \\let x = 1 + true
    , "E_TYPE_MISMATCH");
}

test "typecheck: i16 + str errors (incompatible numeric / str)" {
    try expectCode(
        \\let a: i16 = 1
        \\let b: str = "x"
        \\let c = a + b
    , "E_TYPE_MISMATCH");
}

test "typecheck: comparison returns bool" {
    try expectClean(
        \\let a: i16 = 1
        \\let b: bool = a < 5
    );
}

test "typecheck: and / or require bool operands" {
    try expectCode(
        \\let x = 1 and 2
    , "E_TYPE_MISMATCH");
}

test "typecheck: bitwise & on integer accepts" {
    try expectClean(
        \\let a: u8 = $FF
        \\let b: u8 = a & $0F
    );
}

test "typecheck: bitwise & on fixed errors" {
    try expectCode(
        \\let a: fixed = 1.5
        \\let b = a & a
    , "E_TYPE_MISMATCH");
}

test "typecheck: fixed + fixed accepts" {
    try expectClean(
        \\let a: fixed = 1.5
        \\let b: fixed = a + 2.0
    );
}

test "typecheck: bool literals with `and` produce bool" {
    try expectClean(
        \\let x: bool = true and false
    );
}

test "typecheck: unary minus on int literal accepts" {
    try expectClean(
        \\let x: i16 = -1
    );
}

test "typecheck: compound `+=` with wrong rhs type errors" {
    try expectCode(
        \\let x: i16 = 0
        \\x += "one"
    , "E_TYPE_MISMATCH");
}

test "typecheck: class-to-class `as` cast errors with E_CAST_INVALID" {
    try expectCode(
        \\class A
        \\  let n: i16
        \\end
        \\class B
        \\  let n: i16
        \\end
        \\
        \\let a: A = A()
        \\let b = a as B
    , "E_CAST_INVALID");
}

test "typecheck: shift << on integer accepts" {
    try expectClean(
        \\let a: u8 = 1
        \\let b: u8 = a << 2
    );
}

// ---------- slice 3: unary operator type rules ----------

test "typecheck: -i16 accepts (numeric negation)" {
    try expectClean(
        \\let a: i16 = 5
        \\let b: i16 = -a
    );
}

test "typecheck: -true errors (negation on non-numeric)" {
    try expectCode("let x = -true", "E_TYPE_MISMATCH");
}

test "typecheck: not bool accepts" {
    try expectClean(
        \\let a: bool = true
        \\let b: bool = not a
    );
}

test "typecheck: not int errors" {
    try expectCode("let x = not 5", "E_TYPE_MISMATCH");
}

test "typecheck: ~int accepts" {
    try expectClean(
        \\let a: u8 = $FF
        \\let b: u8 = ~a
    );
}

test "typecheck: ~bool errors" {
    try expectCode("let x = ~true", "E_TYPE_MISMATCH");
}

// ---------- slice 3: cast `as T` validation (§3.5.1) ----------

test "typecheck: int as u8 accepts" {
    try expectClean(
        \\let a: i16 = 100
        \\let b: u8 = a as u8
    );
}

test "typecheck: bool as u8 accepts" {
    try expectClean(
        \\let a: bool = true
        \\let b: u8 = a as u8
    );
}

test "typecheck: u8 as char accepts (no-op)" {
    try expectClean(
        \\let a: u8 = 65
        \\let b: char = a as char
    );
}

test "typecheck: int as fixed accepts" {
    try expectClean(
        \\let a: i16 = 5
        \\let b: fixed = a as fixed
    );
}

test "typecheck: str as u8 errors with E_CAST_INVALID" {
    try expectCode(
        \\let s: str = "hi"
        \\let x = s as u8
    , "E_CAST_INVALID");
}

// ---------- slice 3: function call checking ----------

test "typecheck: correct arity + arg types accepts" {
    try expectClean(
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
        \\
        \\let r = add(1, 2)
    );
}

test "typecheck: too many args errors with E_TYPE_ARG_COUNT" {
    try expectCode(
        \\def f(a: i16) -> i16
        \\  return a
        \\end
        \\
        \\let r = f(1, 2)
    , "E_TYPE_ARG_COUNT");
}

test "typecheck: too few args errors with E_TYPE_ARG_COUNT" {
    try expectCode(
        \\def f(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
        \\
        \\let r = f(1)
    , "E_TYPE_ARG_COUNT");
}

test "typecheck: wrong arg type errors with E_TYPE_MISMATCH" {
    try expectCode(
        \\def f(a: i16) -> i16
        \\  return a
        \\end
        \\
        \\let r = f("hi")
    , "E_TYPE_MISMATCH");
}

test "typecheck: arg int literal pins to param type" {
    try expectClean(
        \\def take_u8(x: u8) -> u8
        \\  return x
        \\end
        \\
        \\let r = take_u8(200)
    );
}

test "typecheck: calling a non-function errors" {
    try expectCode(
        \\let x: i16 = 5
        \\let r = x(1)
    , "E_TYPE_MISMATCH");
}

// ---------- slice 3: assignment checking ----------

test "typecheck: assign matching type accepts" {
    try expectClean(
        \\let x: i16 = 0
        \\x = 5
    );
}

test "typecheck: assign mismatched type errors" {
    try expectCode(
        \\let x: i16 = 0
        \\x = "hi"
    , "E_TYPE_MISMATCH");
}

test "typecheck: assign LHS literal errors (not a place)" {
    // Parser may accept `1 = 5`; the typechecker rejects it.
    try expectCode(
        \\let x = 0
        \\(x + 1) = 5
    , "E_TYPE_MISMATCH");
}

test "typecheck: compound op= pins rhs to lhs type" {
    try expectClean(
        \\let x: u8 = 1
        \\x += 2
    );
}

test "typecheck: ++ on integer accepts" {
    try expectClean(
        \\let x: i16 = 0
        \\x++
    );
}

test "typecheck: ++ on bool errors" {
    try expectCode(
        \\let x: bool = true
        \\x++
    , "E_TYPE_MISMATCH");
}

// ---------- slice 3: return-type checking ----------

test "typecheck: return value matches declared ret type" {
    try expectClean(
        \\def f() -> u8
        \\  return 0
        \\end
    );
}

test "typecheck: return value mismatched ret type errors" {
    try expectCode(
        \\def f() -> u8
        \\  return "hi"
        \\end
    , "E_TYPE_MISMATCH");
}

// ---------- slice 4: nullable validation (§3.4.1) ----------

test "typecheck: str? accepts (str is pointer-like)" {
    try expectClean(
        \\let s: str? = nil
    );
}

test "typecheck: class? accepts" {
    try expectClean(
        \\class Player
        \\  let hp: i16
        \\end
        \\
        \\let p: Player? = nil
    );
}

test "typecheck: i16? errors with E_NULL_NON_POINTER" {
    try expectCode(
        \\let x: i16? = nil
    , "E_NULL_NON_POINTER");
}

test "typecheck: bool? errors with E_NULL_NON_POINTER" {
    try expectCode(
        \\let x: bool? = nil
    , "E_NULL_NON_POINTER");
}

test "typecheck: fixed? errors with E_NULL_NON_POINTER" {
    try expectCode(
        \\let x: fixed? = nil
    , "E_NULL_NON_POINTER");
}

test "typecheck: struct? errors (structs are by-value)" {
    try expectCode(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\let s: Stats? = nil
    , "E_NULL_NON_POINTER");
}

// ---------- slice 4: nullable deref + flow analysis ----------

test "typecheck: direct deref on nullable errors with E_NULL_DEREF" {
    try expectCode(
        \\let s: str? = nil
        \\let n = s.len
    , "E_NULL_DEREF");
}

test "typecheck: deref inside `if x != nil` arm accepts" {
    try expectClean(
        \\let s: str? = nil
        \\if s != nil
        \\  let n = s.len
        \\end
    );
}

test "typecheck: deref inside `if nil != x` arm accepts (commutative)" {
    try expectClean(
        \\let s: str? = nil
        \\if nil != s
        \\  let n = s.len
        \\end
    );
}

test "typecheck: deref inside `if x == nil` else arm accepts" {
    try expectClean(
        \\let s: str? = nil
        \\if s == nil
        \\  let x = 0
        \\else
        \\  let n = s.len
        \\end
    );
}

test "typecheck: deref after `if x == nil then return end` accepts (fall-through)" {
    try expectClean(
        \\def f(s: str?)
        \\  if s == nil
        \\    return
        \\  end
        \\  let n = s.len
        \\end
    );
}

test "typecheck: method call on nullable errors with E_NULL_DEREF" {
    try expectCode(
        \\class Player
        \\  let hp: i16
        \\
        \\  def greet(self)
        \\    print "hi"
        \\  end
        \\end
        \\
        \\let p: Player? = nil
        \\p.greet()
    , "E_NULL_DEREF");
}

// ---------- slice 4: nil → non-nullable ----------

test "typecheck: nil to non-nullable param errors with E_NULL_NIL_TO_NONNULL" {
    try expectCode(
        \\def f(s: str)
        \\  print s
        \\end
        \\
        \\f(nil)
    , "E_NULL_NIL_TO_NONNULL");
}

test "typecheck: nil to a `&T` reference errors with E_REF_NULLABLE" {
    try expectCode(
        \\def f(p: &i16)
        \\  print p
        \\end
        \\
        \\f(nil)
    , "E_REF_NULLABLE");
}

test "typecheck: `let x: str = nil` errors with E_NULL_NIL_TO_NONNULL" {
    try expectCode(
        \\let x: str = nil
    , "E_NULL_NIL_TO_NONNULL");
}

// ---------- slice 4: reference rules (§3.4.4) ----------

test "typecheck: &local accepts (ident is a place)" {
    try expectClean(
        \\let x: i16 = 5
        \\let r = &x
    );
}

test "typecheck: &(a + b) errors with E_REF_TEMPORARY" {
    try expectCode(
        \\let a: i16 = 1
        \\let b: i16 = 2
        \\let r = &(a + b)
    , "E_REF_TEMPORARY");
}

test "typecheck: &foo() errors with E_REF_TEMPORARY" {
    try expectCode(
        \\def foo() -> i16
        \\  return 0
        \\end
        \\
        \\let r = &foo()
    , "E_REF_TEMPORARY");
}

test "typecheck: && double-reference errors with E_REF_DOUBLE" {
    try expectCode(
        \\let x: i16 = 0
        \\let r = &x
        \\let rr = &r
    , "E_REF_DOUBLE");
}

// ---------- slice 4: super resolution (§6) ----------

test "typecheck: super inside method of class with extends accepts" {
    try expectClean(
        \\class Entity
        \\  let hp: i16
        \\end
        \\
        \\class Player extends Entity
        \\  def greet(self)
        \\    let s = super
        \\  end
        \\end
    );
}

test "typecheck: super outside any class errors" {
    try expectCode(
        \\let x = super
    , "E_UNDEFINED_SYMBOL");
}

test "typecheck: super inside a class with no extends errors" {
    try expectCode(
        \\class Player
        \\  let hp: i16
        \\
        \\  def greet(self)
        \\    let s = super
        \\  end
        \\end
    , "E_UNDEFINED_SYMBOL");
}

// ---------- slice 5: match exhaustiveness (§4.8) ----------

test "typecheck: exhaustive match on enum accepts" {
    try expectClean(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\  case Key(name: str, count: u8)
        \\end
        \\
        \\let it: Item = Item.Sword
        \\match it
        \\  case Item.Sword => let x = 0
        \\  case Item.Potion(_) => let x = 1
        \\  case Item.Key(_, _) => let x = 2
        \\end
    );
}

test "typecheck: non-exhaustive match errors with E_MATCH_NON_EXHAUSTIVE" {
    try expectCode(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\
        \\let it: Item = Item.Sword
        \\match it
        \\  case Item.Sword => let x = 0
        \\end
    , "E_MATCH_NON_EXHAUSTIVE");
}

test "typecheck: wildcard arm satisfies exhaustiveness" {
    try expectClean(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\
        \\let it: Item = Item.Sword
        \\match it
        \\  case Item.Sword => let x = 0
        \\  case _ => let x = 1
        \\end
    );
}

test "typecheck: bare ident arm satisfies exhaustiveness (binding catch-all)" {
    try expectClean(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\
        \\let it: Item = Item.Sword
        \\match it
        \\  case anything => let x = 0
        \\end
    );
}

test "typecheck: duplicate variant arm errors with E_MATCH_UNREACHABLE_ARM" {
    try expectCode(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\
        \\let it: Item = Item.Sword
        \\match it
        \\  case Item.Sword => let x = 0
        \\  case Item.Sword => let x = 1
        \\  case _ => let x = 2
        \\end
    , "E_MATCH_UNREACHABLE_ARM");
}

test "typecheck: arm after wildcard errors with E_MATCH_UNREACHABLE_ARM" {
    try expectCode(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\end
        \\
        \\let it: Item = Item.Sword
        \\match it
        \\  case _ => let x = 0
        \\  case Item.Sword => let x = 1
        \\end
    , "E_MATCH_UNREACHABLE_ARM");
}

test "typecheck: or-pattern contributes each alternative to coverage" {
    try expectClean(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\  case Key(name: str, count: u8)
        \\end
        \\
        \\let it: Item = Item.Sword
        \\match it
        \\  case Item.Sword | Item.Potion(_) => let x = 0
        \\  case Item.Key(_, _) => let x = 1
        \\end
    );
}

test "typecheck: match on non-enum, non-bool scrutinee skips exhaustiveness" {
    // i16 has no closed value set; the typechecker must not invent
    // missing-value diagnostics for arbitrary primitives. bool is
    // the lone exception — its two-value coverage is tracked.
    try expectClean(
        \\let n: i16 = 0
        \\match n
        \\  case 0 => let x = 0
        \\  case _ => let x = 1
        \\end
    );
}

test "typecheck: exhaustive bool match (true + false) accepts" {
    try expectClean(
        \\let flag: bool = true
        \\match flag
        \\  case true => let x = 0
        \\  case false => let x = 1
        \\end
    );
}

test "typecheck: bool match missing `false` errors with E_MATCH_NON_EXHAUSTIVE" {
    try expectCode(
        \\let flag: bool = true
        \\match flag
        \\  case true => let x = 0
        \\end
    , "E_MATCH_NON_EXHAUSTIVE");
}

test "typecheck: bool match missing `true` errors with E_MATCH_NON_EXHAUSTIVE" {
    try expectCode(
        \\let flag: bool = true
        \\match flag
        \\  case false => let x = 0
        \\end
    , "E_MATCH_NON_EXHAUSTIVE");
}

test "typecheck: bool match with trailing wildcard accepts" {
    try expectClean(
        \\let flag: bool = true
        \\match flag
        \\  case true => let x = 0
        \\  case _ => let x = 1
        \\end
    );
}

test "typecheck: redundant `true` bool arm errors with E_MATCH_UNREACHABLE_ARM" {
    try expectCode(
        \\let flag: bool = true
        \\match flag
        \\  case true => let x = 0
        \\  case true => let x = 1
        \\  case false => let x = 2
        \\end
    , "E_MATCH_UNREACHABLE_ARM");
}

test "typecheck: wildcard after exhaustive bool coverage errors with E_MATCH_UNREACHABLE_ARM" {
    // Both `true` and `false` are already handled by the time the
    // wildcard arm is reached — that arm cannot fire.
    try expectCode(
        \\let flag: bool = true
        \\match flag
        \\  case true => let x = 0
        \\  case false => let x = 1
        \\  case _ => let x = 2
        \\end
    , "E_MATCH_UNREACHABLE_ARM");
}

// ---------- slice 5: reference stack lifetime (§3.4.4) ----------

test "typecheck: return &local errors with E_REF_STACK_LIFETIME" {
    try expectCode(
        \\def bad() -> &i16
        \\  let x: i16 = 0
        \\  return &x
        \\end
    , "E_REF_STACK_LIFETIME");
}

test "typecheck: return &param errors (params count as locals)" {
    try expectCode(
        \\def bad(x: i16) -> &i16
        \\  return &x
        \\end
    , "E_REF_STACK_LIFETIME");
}

test "typecheck: return &module_static accepts" {
    try expectClean(
        \\let static_x: i16 = 0
        \\
        \\def ok() -> &i16
        \\  return &static_x
        \\end
    );
}

// ---------- slice 6: struct field resolution ----------

test "typecheck: struct field access infers field type" {
    try expectClean(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\let s = Stats { hp: 0 }
        \\let n: i16 = s.hp
    );
}

test "typecheck: struct unknown field errors with E_TYPE_UNDEFINED_FIELD" {
    try expectCode(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\let s = Stats { hp: 0 }
        \\let x = s.bogus
    , "E_TYPE_UNDEFINED_FIELD");
}

test "typecheck: struct literal with all fields accepts" {
    try expectClean(
        \\struct Stats
        \\  hp: i16
        \\  mp: i16
        \\end
        \\
        \\let s = Stats { hp: 10, mp: 5 }
    );
}

test "typecheck: struct literal missing field errors with E_TYPE_MISSING_FIELD" {
    try expectCode(
        \\struct Stats
        \\  hp: i16
        \\  mp: i16
        \\end
        \\
        \\let s = Stats { hp: 10 }
    , "E_TYPE_MISSING_FIELD");
}

test "typecheck: struct literal unknown field errors with E_TYPE_UNDEFINED_FIELD" {
    try expectCode(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\let s = Stats { hp: 0, foo: 1 }
    , "E_TYPE_UNDEFINED_FIELD");
}

test "typecheck: struct literal field type mismatch errors" {
    try expectCode(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\let s = Stats { hp: "hi" }
    , "E_TYPE_MISMATCH");
}

// ---------- slice 6: class field + method resolution ----------

test "typecheck: class field access infers field type" {
    try expectClean(
        \\class Player
        \\  let hp: i16
        \\end
        \\
        \\let p: Player = Player { hp: 0 }
        \\let n: i16 = p.hp
    );
}

test "typecheck: class method call accepts" {
    try expectClean(
        \\class Player
        \\  let hp: i16
        \\
        \\  def greet(self)
        \\    print "hi"
        \\  end
        \\end
        \\
        \\let p: Player = Player { hp: 0 }
        \\p.greet()
    );
}

test "typecheck: unknown method errors with E_TYPE_UNDEFINED_METHOD" {
    try expectCode(
        \\class Player
        \\  let hp: i16
        \\
        \\  def greet(self)
        \\    print "hi"
        \\  end
        \\end
        \\
        \\let p: Player = Player { hp: 0 }
        \\p.bogus()
    , "E_TYPE_UNDEFINED_METHOD");
}

test "typecheck: method-call argcount mismatch errors with E_TYPE_ARG_COUNT" {
    try expectCode(
        \\class Player
        \\  let hp: i16
        \\
        \\  def heal(self, amount: i16)
        \\    self.hp += amount
        \\  end
        \\end
        \\
        \\let p: Player = Player { hp: 0 }
        \\p.heal(10, 20)
    , "E_TYPE_ARG_COUNT");
}

test "typecheck: self.field resolves inside method body" {
    try expectClean(
        \\class Player
        \\  let hp: i16
        \\
        \\  def get_hp(self) -> i16
        \\    return self.hp
        \\  end
        \\end
    );
}

test "typecheck: class constructor call returns the class type" {
    try expectClean(
        \\class Player
        \\  let hp: i16
        \\
        \\  def init(self, hp: i16)
        \\    self.hp = hp
        \\  end
        \\
        \\  def greet(self)
        \\    print "hi"
        \\  end
        \\end
        \\
        \\let p = Player(0)
        \\p.greet()
    );
}

test "typecheck: nullary class constructor accepts" {
    try expectClean(
        \\class Empty
        \\  let n: i16
        \\end
        \\
        \\let e = Empty()
    );
}

test "typecheck: super.method() resolves through parent class" {
    try expectClean(
        \\class Entity
        \\  let hp: i16
        \\
        \\  def take_damage(self, n: i16)
        \\    self.hp -= n
        \\  end
        \\end
        \\
        \\class Player extends Entity
        \\  let mp: i16
        \\
        \\  def take_damage(self, n: i16)
        \\    super.take_damage(n)
        \\  end
        \\end
    );
}

test "typecheck: class with extends — inherited field resolves" {
    try expectClean(
        \\class Entity
        \\  let hp: i16
        \\end
        \\
        \\class Player extends Entity
        \\  let mp: i16
        \\
        \\  def total(self) -> i16
        \\    return self.hp + self.mp
        \\  end
        \\end
    );
}

// ---------- slice 6: multi-return tuple destructuring + flow ----------

test "typecheck: tuple destructure types each binding from init slots" {
    try expectClean(
        \\def parse() -> (i16, str?)
        \\  return (0, nil)
        \\end
        \\
        \\let (n, err) = parse()
        \\let m: i16 = n
    );
}

test "typecheck: tuple destructure arity mismatch errors with E_TYPE_TUPLE_ARITY" {
    try expectCode(
        \\def f() -> (i16, str?)
        \\  return (0, nil)
        \\end
        \\
        \\let (a, b, c) = f()
    , "E_TYPE_TUPLE_ARITY");
}

test "typecheck: multi-return bail propagates non-nil to sibling slot" {
    // After `if err != nil return end`, the value slot `p` becomes
    // statically non-nil so `p.greet()` doesn't trigger E_NULL_DEREF.
    try expectClean(
        \\class Player
        \\  let hp: i16
        \\
        \\  def greet(self)
        \\    print "hi"
        \\  end
        \\end
        \\
        \\def make_player() -> (Player?, str?)
        \\  return (nil, "boom")
        \\end
        \\
        \\def use_it()
        \\  let (p, err) = make_player()
        \\  if err != nil
        \\    return
        \\  end
        \\  p.greet()
        \\end
    );
}

// ---------- @no_capture enforcement (§3.7.2) ----------

test "typecheck: @no_capture rejects closure that mutates captured binding" {
    try expectCode(
        \\@no_capture
        \\def f()
        \\  let n: i16 = 0
        \\  let inc = lambda ()
        \\    n = n + 1
        \\  end
        \\end
    , "E_ANN_CAPTURE_VIOLATION");
}

test "typecheck: @no_capture accepts closure with read-only capture" {
    try expectClean(
        \\@no_capture
        \\def f()
        \\  let n: i16 = 0
        \\  let read = || n
        \\end
    );
}

test "typecheck: @no_capture accepts closure with no capture at all" {
    try expectClean(
        \\@no_capture
        \\def f()
        \\  let g = || 42
        \\end
    );
}

test "typecheck: @no_capture rejects compound op= on captured binding" {
    try expectCode(
        \\@no_capture
        \\def f()
        \\  let n: i16 = 0
        \\  let bump = lambda ()
        \\    n += 1
        \\  end
        \\end
    , "E_ANN_CAPTURE_VIOLATION");
}

test "typecheck: @no_capture rejects `++` on captured binding" {
    try expectCode(
        \\@no_capture
        \\def f()
        \\  let n: i16 = 0
        \\  let tick = lambda ()
        \\    n++
        \\  end
        \\end
    , "E_ANN_CAPTURE_VIOLATION");
}

test "typecheck: closure mutating its own local accepts" {
    try expectClean(
        \\@no_capture
        \\def f()
        \\  let g = lambda ()
        \\    let inner: i16 = 0
        \\    inner = inner + 1
        \\  end
        \\end
    );
}

test "typecheck: without @no_capture, mutating capture compiles" {
    try expectClean(
        \\def f()
        \\  let n: i16 = 0
        \\  let inc = lambda ()
        \\    n = n + 1
        \\  end
        \\end
    );
}

// ---------- char literal typing ----------

test "typecheck: char literal infers as `char` primitive" {
    try expectClean(
        \\let c: char = 'A'
    );
}

test "typecheck: char literal accepts `u8` annotation (char ↔ u8 no-op per §2.5)" {
    try expectClean(
        \\let c: u8 = 'A'
    );
}

test "typecheck: char ↔ u8 explicit cast accepts" {
    try expectClean(
        \\let c: char = 'A'
        \\let b: u8 = c as u8
    );
}

// ---------- E_CAST_PRECISION_LOSS (§3.5.1, narrowing warning) ----------

/// Assert at least one diagnostic with `code` AND severity fires.
fn expectCodeAndSeverity(
    source: []const u8,
    code: []const u8,
    severity: gero.lang.Severity,
) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    for (checked.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, code) and d.severity == severity) return;
    }
    std.debug.print("missing {s} `{s}` for `{s}`; got:\n", .{ @tagName(severity), code, source });
    for (checked.diagnostics) |d| {
        std.debug.print("  - [{s}] {s}: {s}\n", .{ @tagName(d.severity), d.code, d.message });
    }
    return error.MissingDiagnosticCode;
}

test "typecheck: let with narrowing init emits E_CAST_PRECISION_LOSS warning" {
    try expectCodeAndSeverity(
        \\def main()
        \\  let a: i16 = 0
        \\  let b: u8 = a
        \\end
    , "E_CAST_PRECISION_LOSS", .warning);
}

test "typecheck: explicit `as` cast suppresses the narrowing warning" {
    try expectClean(
        \\def main()
        \\  let a: i16 = 0
        \\  let b: u8 = a as u8
        \\end
    );
}

test "typecheck: widening init (u8 → i16) accepts without warning" {
    try expectClean(
        \\def main()
        \\  let a: u8 = 0
        \\  let b: i16 = a
        \\end
    );
}

test "typecheck: assignment with narrowing RHS emits the warning" {
    try expectCodeAndSeverity(
        \\def main()
        \\  let a: i16 = 0
        \\  let b: u8 = 0
        \\  b = a
        \\end
    , "E_CAST_PRECISION_LOSS", .warning);
}

test "typecheck: call arg narrowing emits the warning" {
    try expectCodeAndSeverity(
        \\def take(b: u8) end
        \\
        \\def main()
        \\  let a: i16 = 0
        \\  take(a)
        \\end
    , "E_CAST_PRECISION_LOSS", .warning);
}

test "typecheck: return value narrowing emits the warning" {
    try expectCodeAndSeverity(
        \\def shrink(a: i16) -> u8
        \\  return a
        \\end
    , "E_CAST_PRECISION_LOSS", .warning);
}

test "typecheck: sign-flip at same width (i16 → u16) emits the warning" {
    try expectCodeAndSeverity(
        \\def main()
        \\  let a: i16 = 0
        \\  let b: u16 = a
        \\end
    , "E_CAST_PRECISION_LOSS", .warning);
}

test "typecheck: narrowing class-or-string mismatch stays a hard E_TYPE_MISMATCH" {
    // Non-integer mismatches don't get the friendlier narrowing
    // treatment — they're outright type errors.
    try expectCode(
        \\def main()
        \\  let b: u8 = "hi"
        \\end
    , "E_TYPE_MISMATCH");
}

test "typecheck: narrowing through `char` slot (i16 → char) emits the warning" {
    // `char` is u8-equivalent — narrowing i16 → char loses the
    // upper byte just like narrowing i16 → u8 does.
    try expectCodeAndSeverity(
        \\def main()
        \\  let a: i16 = 0
        \\  let c: char = a
        \\end
    , "E_CAST_PRECISION_LOSS", .warning);
}

// ---------- slice 7: annotation validation (§3.7) ----------

test "typecheck: unknown annotation errors with E_ANN_UNKNOWN" {
    try expectCode(
        \\@bogus
        \\let x: i16 = 0
    , "E_ANN_UNKNOWN");
}

test "typecheck: @inline on a let errors with E_ANN_BAD_TARGET" {
    try expectCode(
        \\@inline
        \\let x: i16 = 0
    , "E_ANN_BAD_TARGET");
}

test "typecheck: @addr on a def errors with E_ANN_BAD_TARGET" {
    try expectCode(
        \\@addr $FE40
        \\def f() end
    , "E_ANN_BAD_TARGET");
}

test "typecheck: @bank with non-int arg errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@bank "five"
        \\def f() end
    , "E_ANN_BAD_ARG");
}

test "typecheck: @align(3) (non-power-of-two) errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@align(3)
        \\let x: i16 = 0
    , "E_ANN_BAD_ARG");
}

test "typecheck: @align(16) accepts (power of two)" {
    try expectClean(
        \\@align(16)
        \\let x: i16 = 0
    );
}

test "typecheck: @final + @override on same decl errors with E_ANN_CONFLICT" {
    try expectCode(
        \\class Parent
        \\  def foo(self) end
        \\end
        \\
        \\class Child extends Parent
        \\  @final
        \\  @override
        \\  def foo(self) end
        \\end
    , "E_ANN_CONFLICT");
}

test "typecheck: @bank 5 on def accepts" {
    try expectClean(
        \\@bank 5
        \\def town_intro() -> str
        \\  return "Welcome"
        \\end
    );
}

test "typecheck: @addr + @volatile on let accepts" {
    try expectClean(
        \\@addr $FE40
        \\@volatile
        \\let DISPCTL: u8 = 0
    );
}

test "typecheck: @inline with arg errors with E_ANN_BAD_ARG" {
    try expectCode(
        \\@inline 5
        \\def f() end
    , "E_ANN_BAD_ARG");
}

test "typecheck: @inline + @cold on same def accepts (functionally redundant, not conflicting per spec)" {
    try expectClean(
        \\@inline
        \\@cold
        \\def f() end
    );
}

// ---------- slice 7: bake validation (§3.8) ----------

test "typecheck: simple bake def accepts" {
    try expectClean(
        \\bake def make() -> i16
        \\  return 42
        \\end
    );
}

test "typecheck: bake def returning Vec errors with E_BAKE_NON_BAKEABLE_VALUE" {
    try expectCode(
        \\bake def make() -> Vec(i16)
        \\  return nil
        \\end
    , "E_BAKE_NON_BAKEABLE_VALUE");
}

test "typecheck: `defer return` is rejected with E_DEFER_CONTROL_FLOW" {
    try expectCode(
        \\def main()
        \\  defer return
        \\  print 1
        \\end
    , "E_DEFER_CONTROL_FLOW");
}

test "typecheck: `defer break` is rejected with E_DEFER_CONTROL_FLOW" {
    try expectCode(
        \\def main()
        \\  while true
        \\    defer break
        \\  end
        \\end
    , "E_DEFER_CONTROL_FLOW");
}

test "typecheck: `defer continue` is rejected with E_DEFER_CONTROL_FLOW" {
    try expectCode(
        \\def main()
        \\  while true
        \\    defer continue
        \\  end
        \\end
    , "E_DEFER_CONTROL_FLOW");
}

test "typecheck: `defer defer` is rejected with E_DEFER_NESTED" {
    try expectCode(
        \\def main()
        \\  defer defer print 1
        \\end
    , "E_DEFER_NESTED");
}

test "typecheck: bake def with asm inside errors with E_BAKE_ASM_INSIDE" {
    try expectCode(
        \\bake def f() -> i16
        \\  asm "noop"
        \\  return 0
        \\end
    , "E_BAKE_ASM_INSIDE");
}

test "typecheck: bake def reading MMIO errors with E_BAKE_MMIO_ACCESS" {
    try expectCode(
        \\@addr $FE40
        \\@volatile
        \\let DISPCTL: u8 = 0
        \\
        \\bake def read_disp() -> u8
        \\  return DISPCTL
        \\end
    , "E_BAKE_MMIO_ACCESS");
}

test "typecheck: bake def writing MMIO errors with E_BAKE_MMIO_ACCESS" {
    try expectCode(
        \\@addr $FE40
        \\@volatile
        \\let DISPCTL: u8 = 0
        \\
        \\bake def write_disp() -> u8
        \\  DISPCTL = $42
        \\  return 0
        \\end
    , "E_BAKE_MMIO_ACCESS");
}

test "typecheck: bake def calling non-bake fn errors with E_BAKE_FORBIDDEN_CALL" {
    try expectCode(
        \\def runtime_helper() -> i16
        \\  return 5
        \\end
        \\
        \\bake def make() -> i16
        \\  return runtime_helper()
        \\end
    , "E_BAKE_FORBIDDEN_CALL");
}

test "typecheck: bake def calling another bake fn accepts" {
    try expectClean(
        \\bake def helper() -> i16
        \\  return 5
        \\end
        \\
        \\bake def make() -> i16
        \\  return helper()
        \\end
    );
}

// ---------- slice 7: variadic call validation (§4.6.2) ----------

test "typecheck: variadic call with homogeneous args accepts" {
    try expectClean(
        \\def log(args: ...)
        \\end
        \\
        \\log(1, 2, 3)
    );
}

test "typecheck: variadic call with mixed types errors with E_VAR_HETEROGENEOUS" {
    try expectCode(
        \\def log(args: ...)
        \\end
        \\
        \\log(1, 2, "hi")
    , "E_VAR_HETEROGENEOUS");
}

test "typecheck: variadic call with leading fixed param + homogeneous variadic accepts" {
    try expectClean(
        \\def log(label: str, vals: ...)
        \\end
        \\
        \\log("nums", 1, 2, 3)
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

// ---------- OOP annotation enforcement (§3.7.6) ----------

test "typecheck: @final class rejects extends" {
    try expectCode(
        \\@final
        \\class Sealed
        \\end
        \\
        \\class Sub extends Sealed
        \\end
    , "E_CLASS_FINAL_EXTENDS");
}

test "typecheck: @final method rejects override in subclass" {
    try expectCode(
        \\class Base
        \\  @final
        \\  def tick(self) end
        \\end
        \\
        \\class Child extends Base
        \\  def tick(self) end
        \\end
    , "E_METHOD_FINAL_OVERRIDE");
}

test "typecheck: @override without matching parent fails" {
    try expectCode(
        \\class Base
        \\end
        \\
        \\class Child extends Base
        \\  @override
        \\  def ghost(self) end
        \\end
    , "E_OVERRIDE_NO_PARENT");
}

test "typecheck: @override matching parent passes" {
    try expectClean(
        \\class Base
        \\  def tick(self) end
        \\end
        \\
        \\class Child extends Base
        \\  @override
        \\  def tick(self) end
        \\end
    );
}

test "typecheck: @abstract class rejects direct instantiation" {
    try expectCode(
        \\@abstract
        \\class Shape
        \\end
        \\
        \\def main()
        \\  let s = Shape()
        \\end
    , "E_CLASS_ABSTRACT_INSTANTIATE");
}

test "typecheck: class with @abstract method is implicitly abstract" {
    try expectCode(
        \\class Drawable
        \\  @abstract
        \\  def draw(self)
        \\end
        \\
        \\def main()
        \\  let d = Drawable()
        \\end
    , "E_CLASS_ABSTRACT_INSTANTIATE");
}

test "typecheck: concrete subclass must implement abstract method" {
    try expectCode(
        \\class Drawable
        \\  @abstract
        \\  def draw(self)
        \\end
        \\
        \\class Sprite extends Drawable
        \\end
    , "E_ABSTRACT_NOT_IMPLEMENTED");
}

test "typecheck: concrete subclass implementing abstract method passes" {
    try expectClean(
        \\class Drawable
        \\  @abstract
        \\  def draw(self)
        \\end
        \\
        \\class Sprite extends Drawable
        \\  @override
        \\  def draw(self) end
        \\end
    );
}

test "typecheck: @private field rejected from outside the class" {
    try expectCode(
        \\class Player
        \\  @private
        \\  let _hp: i16
        \\end
        \\
        \\def main()
        \\  let p = Player()
        \\  let h: i16 = p._hp
        \\end
    , "E_PRIVATE_ACCESS");
}

test "typecheck: @private method rejected from outside the class" {
    try expectCode(
        \\class Player
        \\  @private
        \\  def secret(self) end
        \\end
        \\
        \\def main()
        \\  let p = Player()
        \\  p.secret()
        \\end
    , "E_PRIVATE_ACCESS");
}

test "typecheck: @private parent field not visible from subclass method body" {
    // Spec §3.7.6: `@private` is class-scoped, not inheritance-scoped —
    // a subclass walking `self._hp` lands at Base as the owning class,
    // current_class_name is `Child`, so visibility is denied.
    try expectCode(
        \\class Base
        \\  @private
        \\  let _hp: i16
        \\end
        \\
        \\class Child extends Base
        \\  def poke(self)
        \\    self._hp = 1
        \\  end
        \\end
    , "E_PRIVATE_ACCESS");
}

test "typecheck: @private member accessed from inside the class is allowed" {
    try expectClean(
        \\class Player
        \\  @private
        \\  let _hp: i16
        \\
        \\  @private
        \\  def secret(self) end
        \\
        \\  def update(self)
        \\    self._hp = 10
        \\    self.secret()
        \\  end
        \\end
    );
}

// ---------- bake annotation conflicts (§3.8) ----------

test "typecheck: `bake def @cold` rejects with E_ANN_CONFLICT" {
    try expectCode(
        \\@cold
        \\bake def cold_table() -> i16
        \\  return 0
        \\end
    , "E_ANN_CONFLICT");
}

test "typecheck: `bake def @inline` rejects with E_ANN_CONFLICT" {
    try expectCode(
        \\@inline
        \\bake def inline_table() -> i16
        \\  return 0
        \\end
    , "E_ANN_CONFLICT");
}

test "typecheck: `bake def @bank 5` rejects with E_ANN_CONFLICT" {
    try expectCode(
        \\@bank 5
        \\bake def banked_table() -> i16
        \\  return 0
        \\end
    , "E_ANN_CONFLICT");
}

test "typecheck: plain `bake def` without conflicting annotations is clean" {
    try expectClean(
        \\bake def fine() -> i16
        \\  return 42
        \\end
    );
}

test "typecheck: @static method with `self` param is rejected" {
    try expectCode(
        \\class Util
        \\  @static
        \\  def from_origin(self) end
        \\end
    , "E_STATIC_HAS_SELF");
}

// ---------- "did you mean…?" suggestions (#257) ----------

/// Assert the named diagnostic fires with a `help:` block
/// containing the suggestion. Verifies both that the code matches
/// AND that the rendered help string mentions the candidate name.
fn expectSuggestion(source: []const u8, code: []const u8, candidate: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    for (checked.diagnostics) |d| {
        if (!std.mem.eql(u8, d.code, code)) continue;
        const help = d.help orelse continue;
        if (std.mem.indexOf(u8, help, candidate) != null) return;
    }
    std.debug.print("missing {s} with help mentioning `{s}` for `{s}`; got:\n", .{ code, candidate, source });
    for (checked.diagnostics) |d| {
        const help_str = d.help orelse "<none>";
        std.debug.print("  - {s}: {s}  help=`{s}`\n", .{ d.code, d.message, help_str });
    }
    return error.MissingSuggestion;
}

/// Assert that NO diagnostic of the given code carries a `help:`
/// block — used to verify "no candidate within distance 2 → no
/// suggestion" path.
fn expectNoSuggestion(source: []const u8, code: []const u8) !void {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    defer tree.deinit();
    var checked = try gero.lang.typecheck(alloc, source, &tree.program);
    defer checked.deinit();

    var saw_code = false;
    for (checked.diagnostics) |d| {
        if (!std.mem.eql(u8, d.code, code)) continue;
        saw_code = true;
        if (d.help != null) {
            std.debug.print("unexpected help on {s} for `{s}`: `{s}`\n", .{ code, source, d.help.? });
            return error.UnexpectedSuggestion;
        }
    }
    try std.testing.expect(saw_code);
}

test "typecheck/suggest: undefined ident with a close-spelling local" {
    try expectSuggestion(
        \\def main()
        \\  let helo: i16 = 0
        \\  let x: i16 = helllo
        \\end
    , "E_UNDEFINED_SYMBOL", "helo");
}

test "typecheck/suggest: no candidate within distance 2 → no help" {
    try expectNoSuggestion(
        \\def main()
        \\  let aaaa: i16 = 0
        \\  let x: i16 = zzzzzz
        \\end
    , "E_UNDEFINED_SYMBOL");
}

test "typecheck/suggest: undefined struct field surfaces sibling name" {
    try expectSuggestion(
        \\struct Stats
        \\  hp: i16
        \\  mp: i16
        \\end
        \\
        \\def main()
        \\  let s: Stats = Stats { hp: 10, mp: 5 }
        \\  let n: i16 = s.hpp
        \\end
    , "E_TYPE_UNDEFINED_FIELD", "hp");
}

test "typecheck/suggest: undefined class field — walks the inheritance chain" {
    try expectSuggestion(
        \\class Entity
        \\  let health: i16
        \\end
        \\
        \\class Player extends Entity end
        \\
        \\def main()
        \\  let p = Player()
        \\  let n: i16 = p.helath
        \\end
    , "E_TYPE_UNDEFINED_FIELD", "health");
}

test "typecheck/suggest: undefined class method surfaces sibling name" {
    try expectSuggestion(
        \\class Player
        \\  def attack(self) end
        \\end
        \\
        \\def main()
        \\  let p = Player()
        \\  p.attaack()
        \\end
    , "E_TYPE_UNDEFINED_METHOD", "attack");
}

test "typecheck/suggest: undefined type in annotation suggests a registered type" {
    try expectSuggestion(
        \\class Player end
        \\
        \\def main()
        \\  let p: Playr = Player()
        \\end
    , "E_TYPE_UNDEFINED", "Player");
}

test "typecheck/suggest: undefined type in struct literal suggests a registered type" {
    try expectSuggestion(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\def main()
        \\  let s = Stahts { hp: 1 }
        \\end
    , "E_TYPE_UNDEFINED", "Stats");
}

test "typecheck/suggest: primitive type typo (i17 → i16) surfaces the primitive" {
    try expectSuggestion(
        \\def main()
        \\  let x: i17 = 0
        \\end
    , "E_TYPE_UNDEFINED", "i16");
}

test "typecheck/suggest: unknown mem.X member surfaces the closest stdlib name" {
    try expectSuggestion(
        \\use mem
        \\def main()
        \\  let v: u8 = mem.read_u17($2100)
        \\end
    , "E_TYPE_UNDEFINED_METHOD", "read_u16");
}

test "typecheck/is: class form on matching subclass — clean" {
    try expectClean(
        \\class Animal
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\class Dog extends Animal
        \\  def init(self)
        \\    super.init()
        \\  end
        \\end
        \\def report(a: Animal)
        \\  if a is Dog
        \\    print "ok"
        \\  end
        \\end
        \\def main()
        \\  let d = Dog()
        \\  report(d)
        \\end
    );
}

test "typecheck/is: `Dog is Dog` is statically true — W_DEAD_TEST" {
    try expectCode(
        \\class Dog
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\def main()
        \\  let d = Dog()
        \\  if d is Dog
        \\    print "yes"
        \\  end
        \\end
    , "W_DEAD_TEST");
}

test "typecheck/is: unrelated class is statically false — W_DEAD_TEST" {
    try expectCode(
        \\class Dog
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\class Bird
        \\  let w: u8
        \\  def init(self)
        \\    self.w = 0
        \\  end
        \\end
        \\def main()
        \\  let d = Dog()
        \\  if d is Bird
        \\    print "no"
        \\  end
        \\end
    , "W_DEAD_TEST");
}

test "typecheck/is: struct receiver rejects with E_TYPE_IS_NON_DYNAMIC" {
    try expectCode(
        \\struct Stats
        \\  hp: i16
        \\  mp: i16
        \\end
        \\class Dog
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\def main()
        \\  let s = Stats { hp: 1, mp: 2 }
        \\  if s is Dog
        \\    print "x"
        \\  end
        \\end
    , "E_TYPE_IS_NON_DYNAMIC");
}

test "typecheck/sizeof: primitive widths resolve to u16" {
    try expectClean(
        \\const A: u16 = sizeof(i16)
        \\const B: u16 = sizeof(i8)
        \\const C: u16 = sizeof([i16; 8])
    );
}

test "typecheck/sizeof: unknown type emits E_TYPE_UNDEFINED" {
    try expectCode("const X = sizeof(NotAType)", "E_TYPE_UNDEFINED");
}

test "typecheck/panic: takes exactly 1 arg" {
    try expectCode(
        \\def main()
        \\  panic()
        \\end
    , "E_ASSERT_ARG_COUNT");
}

test "typecheck/unreachable: takes no args" {
    try expectCode(
        \\def main()
        \\  unreachable("nope")
        \\end
    , "E_ASSERT_ARG_COUNT");
}

test "typecheck/todo: accepts 0 or 1 arg" {
    try expectClean(
        \\def main()
        \\  todo()
        \\end
    );
    try expectClean(
        \\def main()
        \\  todo("audio")
        \\end
    );
}

test "typecheck/is: `as binding` brings the binding into the arm body" {
    try expectClean(
        \\class Animal
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\class Dog extends Animal
        \\  let bark_count: u8
        \\  def init(self)
        \\    super.init()
        \\    self.bark_count = 3
        \\  end
        \\end
        \\def report(a: Animal)
        \\  if a is Dog as d
        \\    print d.bark_count
        \\  end
        \\end
        \\def main()
        \\  let d = Dog()
        \\  report(d)
        \\end
    );
}

test "typecheck/is: `as binding` is not visible after the arm" {
    try expectCode(
        \\class Animal
        \\  let k: u8
        \\  def init(self)
        \\    self.k = 0
        \\  end
        \\end
        \\class Dog extends Animal
        \\  def init(self)
        \\    super.init()
        \\  end
        \\end
        \\def report(a: Animal)
        \\  if a is Dog as d
        \\    print "ok"
        \\  end
        \\  print d.k
        \\end
    , "E_UNDEFINED_SYMBOL");
}

test "typecheck/shadow: `def panic` is rejected" {
    try expectCode(
        \\def panic(m: str)
        \\  print m
        \\end
    , "E_BUILTIN_SHADOW");
}

test "typecheck/shadow: `let assert` is rejected" {
    try expectCode(
        \\def main()
        \\  let assert = 10
        \\end
    , "E_BUILTIN_SHADOW");
}
