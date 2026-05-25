//! Tests for the bake compile-time evaluator. The scaffolding
//! commit only verifies the module compiles through the barrel
//! and that the stub paths surface their placeholder diagnostic.
//! Behavioral coverage (arithmetic, control flow, aggregates,
//! call dispatch, instruction budget) lands in subsequent
//! commits within this PR.

const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

test "bake: module compiles through the barrel" {
    _ = gero.lang.bake.default_budget;
    _ = gero.lang.bake.BakeValue;
}

test "bake: default budget is 100_000_000 steps per spec §3.8" {
    try std.testing.expectEqual(@as(u32, 100_000_000), gero.lang.bake.default_budget);
}

// ---------- evaluator behavior ----------

/// Parse `source` and return a pointer to the first `bake do …`
/// expression it contains (typically the RHS of `const X = bake
/// do …`). The caller owns the returned `ParseTree`. Used by the
/// arithmetic tests to drive `evaluateDo` against real AST input
/// without standing up a full typecheck.
fn parseFirstBakeDo(source: []const u8) !struct { tree: gero.lang.ParseTree, do: *const gero.lang.ast.DoExpr } {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, source, stream);
    errdefer tree.deinit();
    for (tree.program.statements) |*stmt| {
        if (stmt.* != .const_decl) continue;
        const init_expr = stmt.const_decl.init;
        if (init_expr.* != .do_expr) continue;
        if (!init_expr.do_expr.is_bake) continue;
        return .{ .tree = tree, .do = &init_expr.do_expr };
    }
    return error.NoBakeDoFound;
}

fn evalBakeDoSource(source: []const u8) !gero.lang.bake.Result {
    var parsed = try parseFirstBakeDo(source);
    defer parsed.tree.deinit();
    return gero.lang.bake.evaluateDo(alloc, source, parsed.do, .{});
}

test "bake: empty do block evaluates to nil" {
    var res = try evalBakeDoSource("const X = bake do end");
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
    try std.testing.expect(res.value.? == .nil_);
}

test "bake: int literal evaluates to int_" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  42
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
    try std.testing.expectEqual(@as(u16, 42), res.value.?.int_);
}

test "bake: int arithmetic (1 + 2 * 3)" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  1 + 2 * 3
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 7), res.value.?.int_);
}

test "bake: let-binding + lookup + reassignment" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let x = 5
        \\  x = x + 10
        \\  x
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
    try std.testing.expectEqual(@as(u16, 15), res.value.?.int_);
}

test "bake: const-binding inside bake block" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  const N = 7
        \\  N * 2
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 14), res.value.?.int_);
}

test "bake: short-circuit `and` does not evaluate rhs on false" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  false and (1 / 0 == 0)
        \\end
    );
    defer res.deinit(alloc);
    // `false and …` short-circuits to false; the rhs's divide-by-zero
    // never fires, so no diagnostic.
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
    try std.testing.expectEqual(false, res.value.?.bool_);
}

test "bake: short-circuit `or` returns true without touching rhs" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  true or (1 / 0 == 0)
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), res.diagnostics.len);
    try std.testing.expectEqual(true, res.value.?.bool_);
}

test "bake: divide by zero emits E_BAKE_DIV_BY_ZERO" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  10 / 0
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expect(res.value == null);
    try std.testing.expectEqual(@as(usize, 1), res.diagnostics.len);
    try std.testing.expectEqualStrings("E_BAKE_DIV_BY_ZERO", res.diagnostics[0].code);
}

test "bake: undefined ident emits E_UNDEFINED_SYMBOL" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  helo
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expect(res.value == null);
    try std.testing.expect(res.diagnostics.len >= 1);
    try std.testing.expectEqualStrings("E_UNDEFINED_SYMBOL", res.diagnostics[0].code);
}

test "bake: comparison operators yield bool" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  5 < 10
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(true, res.value.?.bool_);
}

test "bake: unary negation on signed int" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  -7
        \\end
    );
    defer res.deinit(alloc);
    // -7 as i16 = 0xFFF9
    try std.testing.expectEqual(@as(u16, 0xFFF9), res.value.?.int_);
}

test "bake: signed division (-10 / 3)" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  -10 / 3
        \\end
    );
    defer res.deinit(alloc);
    // -10 / 3 = -3 (truncates toward zero) = 0xFFFD
    try std.testing.expectEqual(@as(u16, 0xFFFD), res.value.?.int_);
}

// ---------- control flow ----------

test "bake: `if` chain picks the first true arm" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let r = 0
        \\  if false
        \\    r = 1
        \\  elif true
        \\    r = 2
        \\  else
        \\    r = 3
        \\  end
        \\  r
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 2), res.value.?.int_);
}

test "bake: `while` loop accumulates" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let n = 0
        \\  let i = 0
        \\  while i < 10
        \\    n = n + i
        \\    i = i + 1
        \\  end
        \\  n
        \\end
    );
    defer res.deinit(alloc);
    // 0+1+2+…+9 = 45
    try std.testing.expectEqual(@as(u16, 45), res.value.?.int_);
}

test "bake: `for-in` over an exclusive range" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let n = 0
        \\  for i in 0..5
        \\    n = n + i
        \\  end
        \\  n
        \\end
    );
    defer res.deinit(alloc);
    // 0+1+2+3+4 = 10
    try std.testing.expectEqual(@as(u16, 10), res.value.?.int_);
}

test "bake: `for-in` over an inclusive range" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let n = 0
        \\  for i in 1..=5
        \\    n = n + i
        \\  end
        \\  n
        \\end
    );
    defer res.deinit(alloc);
    // 1+2+3+4+5 = 15
    try std.testing.expectEqual(@as(u16, 15), res.value.?.int_);
}

test "bake: `break` exits the loop early" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let n = 0
        \\  for i in 0..100
        \\    if i > 5
        \\      break
        \\    end
        \\    n = n + i
        \\  end
        \\  n
        \\end
    );
    defer res.deinit(alloc);
    // 0+1+2+3+4+5 = 15
    try std.testing.expectEqual(@as(u16, 15), res.value.?.int_);
}

test "bake: `continue` skips the remainder of the iteration" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let n = 0
        \\  for i in 0..10
        \\    if i == 5
        \\      continue
        \\    end
        \\    n = n + 1
        \\  end
        \\  n
        \\end
    );
    defer res.deinit(alloc);
    // 10 iterations, skip 1 → 9 increments
    try std.testing.expectEqual(@as(u16, 9), res.value.?.int_);
}

test "bake: `repeat … until` runs at least once" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let n = 0
        \\  repeat
        \\    n = n + 1
        \\  until n >= 3
        \\  n
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 3), res.value.?.int_);
}

test "bake: `if` expression returns the taken arm's value" {
    var res = try evalBakeDoSource(
        \\const X = bake do
        \\  let v = if 1 == 1
        \\    42
        \\  else
        \\    0
        \\  end
        \\  v
        \\end
    );
    defer res.deinit(alloc);
    try std.testing.expectEqual(@as(u16, 42), res.value.?.int_);
}

// ---------- instruction budget ----------

test "bake: unbounded loop trips E_BAKE_BUDGET_EXCEEDED" {
    const source =
        \\const X = bake do
        \\  let i = 0
        \\  while true
        \\    i = i + 1
        \\  end
        \\  i
        \\end
    ;
    var parsed = try parseFirstBakeDo(source);
    defer parsed.tree.deinit();
    // Tight budget so the test runs in microseconds.
    var res = try gero.lang.bake.evaluateDo(alloc, source, parsed.do, .{ .budget = 100 });
    defer res.deinit(alloc);
    try std.testing.expect(res.value == null);
    var saw_budget = false;
    for (res.diagnostics) |d| {
        if (std.mem.eql(u8, d.code, "E_BAKE_BUDGET_EXCEEDED")) saw_budget = true;
    }
    try std.testing.expect(saw_budget);
}
