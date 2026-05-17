/// Specs for `typecheck/flow` — the heterogeneous bag of helpers
/// for flow-sensitive inference and decl resolution. Pure helpers
/// over plain AST / type values (`bodyAlwaysExits`, `namedNameOf`)
/// get direct unit calls; the Checker-dependent helpers
/// (`identName`, `findStructField`, `findClassField`) ride the
/// E2E surface, observing their effects through the diagnostics
/// they enable / suppress.
const std = @import("std");
const gero = @import("gero");

const flow = gero.lang.typechecker.flow;
const ast = gero.lang.ast;
const types = gero.lang.types;

const alloc = std.testing.allocator;

// ---------- E2E helpers ----------

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
        for (checked.diagnostics) |d| std.debug.print("  - {s}: {s}\n", .{ d.code, d.message });
    }
    try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.len);
}

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
    std.debug.print("missing diagnostic `{s}` for `{s}`; got:\n", .{ code, source });
    for (checked.diagnostics) |d| {
        std.debug.print("  - {s}: {s}\n", .{ d.code, d.message });
    }
    return error.MissingDiagnosticCode;
}

// ---------- module reachability ----------

test "typecheck/flow: module compiles through the barrel" {
    _ = flow;
}

// ---------- bodyAlwaysExits (pure over AST) ----------

test "typecheck/flow: bodyAlwaysExits returns false for empty body" {
    const empty: []const ast.Statement = &.{};
    try std.testing.expect(!flow.bodyAlwaysExits(empty));
}

test "typecheck/flow: bodyAlwaysExits returns true when last statement is return" {
    const stmts = [_]ast.Statement{
        .{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 6 } } },
    };
    try std.testing.expect(flow.bodyAlwaysExits(&stmts));
}

test "typecheck/flow: bodyAlwaysExits returns true when last statement is break" {
    const stmts = [_]ast.Statement{
        .{ .break_stmt = .{ .label = null, .span = .{ .start = 0, .end = 5 } } },
    };
    try std.testing.expect(flow.bodyAlwaysExits(&stmts));
}

test "typecheck/flow: bodyAlwaysExits returns true when last statement is continue" {
    const stmts = [_]ast.Statement{
        .{ .continue_stmt = .{ .label = null, .span = .{ .start = 0, .end = 8 } } },
    };
    try std.testing.expect(flow.bodyAlwaysExits(&stmts));
}

test "typecheck/flow: bodyAlwaysExits returns false when last statement is non-exit" {
    // Statement-expr (a fallthrough) — last statement isn't a flow
    // terminator, so body doesn't exit.
    var dummy_ident = ast.Expr{ .ident = .{ .span = .{ .start = 0, .end = 1 } } };
    const stmts = [_]ast.Statement{
        .{ .expr_stmt = .{ .expr = &dummy_ident, .span = .{ .start = 0, .end = 1 } } },
    };
    try std.testing.expect(!flow.bodyAlwaysExits(&stmts));
}

test "typecheck/flow: bodyAlwaysExits inspects only the last statement" {
    // Earlier statements that exit don't matter — only the tail counts.
    // A body that returns at index 0 then runs a non-exit statement is
    // dead-code, but bodyAlwaysExits reports false because the tail is
    // not an exit.
    var dummy_ident = ast.Expr{ .ident = .{ .span = .{ .start = 0, .end = 1 } } };
    const stmts = [_]ast.Statement{
        .{ .return_stmt = .{ .value = null, .span = .{ .start = 0, .end = 6 } } },
        .{ .expr_stmt = .{ .expr = &dummy_ident, .span = .{ .start = 0, .end = 1 } } },
    };
    try std.testing.expect(!flow.bodyAlwaysExits(&stmts));
}

// ---------- bodyAlwaysExits (observable E2E effect) ----------

test "typecheck/flow: deref after `if x == nil then return end` accepts (bodyAlwaysExits=true on if-body)" {
    // The fall-through detector consults bodyAlwaysExits on the
    // if-body to decide whether the deref past the if is reachable
    // with `s` proven non-nil.
    try expectClean(
        \\def f(s: str?)
        \\  if s == nil
        \\    return
        \\  end
        \\  let n = s.len
        \\end
    );
}

test "typecheck/flow: deref after `if x == nil` with no exit errors with E_NULL_DEREF" {
    // bodyAlwaysExits=false ⇒ control may fall through with `s` still
    // possibly nil ⇒ the post-if deref must reject.
    try expectCode(
        \\def f(s: str?)
        \\  if s == nil
        \\    let x = 0
        \\  end
        \\  let n = s.len
        \\end
    , "E_NULL_DEREF");
}

// ---------- namedNameOf (pure over types.Type) ----------

test "typecheck/flow: namedNameOf returns the lexeme for a named type" {
    const t = types.Type{ .named = .{ .name = "Player", .span = .{ .start = 0, .end = 6 } } };
    try std.testing.expectEqualStrings("Player", flow.namedNameOf(t).?);
}

test "typecheck/flow: namedNameOf returns null for non-named types" {
    try std.testing.expect(flow.namedNameOf(.{ .primitive = .i16 }) == null);

    const inner = try types.mkPrimitive(alloc, .u8);
    defer alloc.destroy(inner);
    try std.testing.expect(flow.namedNameOf(.{ .vec = inner }) == null);
    try std.testing.expect(flow.namedNameOf(.{ .reference = inner }) == null);
    try std.testing.expect(flow.namedNameOf(.{ .optional = inner }) == null);
    try std.testing.expect(flow.namedNameOf(.{ .array = .{ .elem = inner, .len = 4 } }) == null);
}

// ---------- identName (observable through nil-check pattern) ----------

test "typecheck/flow: identName matches bare ident — `if x == nil then return end` proves x non-nil" {
    // identName must extract `s` from the bare-ident lhs of `s == nil`
    // for the nil-narrowing flow analysis to register. If it returned
    // null here, the post-if deref would error.
    try expectClean(
        \\def f(s: str?)
        \\  if s == nil
        \\    return
        \\  end
        \\  print s.len
        \\end
    );
}

test "typecheck/flow: identName unwraps `paren` — `(s) == nil` still narrows" {
    // The paren-unwrap branch of identName must let `(s)` flow through.
    try expectClean(
        \\def f(s: str?)
        \\  if (s) == nil
        \\    return
        \\  end
        \\  print s.len
        \\end
    );
}

// ---------- findStructField (observable through field access + literal) ----------

test "typecheck/flow: findStructField hit — `s.hp` on known field accepts" {
    try expectClean(
        \\struct Stats
        \\  hp: i16
        \\  mp: i16
        \\end
        \\
        \\let s = Stats { hp: 10, mp: 5 }
        \\let x = s.hp
    );
}

test "typecheck/flow: findStructField miss on field access errors with E_TYPE_UNDEFINED_FIELD" {
    try expectCode(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\let s = Stats { hp: 0 }
        \\let x = s.bogus
    , "E_TYPE_UNDEFINED_FIELD");
}

test "typecheck/flow: findStructField miss on struct literal field errors with E_TYPE_UNDEFINED_FIELD" {
    // The struct-literal path also walks findStructField to validate
    // each key — a typo there must surface.
    try expectCode(
        \\struct Stats
        \\  hp: i16
        \\end
        \\
        \\let s = Stats { hp: 0, foo: 1 }
    , "E_TYPE_UNDEFINED_FIELD");
}

// ---------- findClassField (observable via self.<field> resolution) ----------

test "typecheck/flow: findClassField hit on own field accepts" {
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

test "typecheck/flow: findClassField walks the inheritance chain — inherited field resolves" {
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

test "typecheck/flow: findClassField miss on unknown field errors with E_TYPE_UNDEFINED_FIELD" {
    try expectCode(
        \\class Player
        \\  let hp: i16
        \\
        \\  def bad(self) -> i16
        \\    return self.bogus
        \\  end
        \\end
    , "E_TYPE_UNDEFINED_FIELD");
}

test "typecheck/flow: findClassField miss after walking the chain errors with E_TYPE_UNDEFINED_FIELD" {
    // Field exists on neither the class nor its parent — recursion
    // terminates with null, surfaces as undefined-field.
    try expectCode(
        \\class Entity
        \\  let hp: i16
        \\end
        \\
        \\class Player extends Entity
        \\  let mp: i16
        \\
        \\  def bad(self) -> i16
        \\    return self.bogus
        \\  end
        \\end
    , "E_TYPE_UNDEFINED_FIELD");
}
