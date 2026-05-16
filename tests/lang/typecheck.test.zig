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

test "typecheck: match on non-enum scrutinee skips exhaustiveness" {
    // i16 has no variant list; the typechecker must not invent
    // missing-variant diagnostics for primitive scrutinees.
    try expectClean(
        \\let n: i16 = 0
        \\match n
        \\  case 0 => let x = 0
        \\  case _ => let x = 1
        \\end
    );
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
