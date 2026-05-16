const std = @import("std");
const gero = @import("gero");

const ast = gero.lang.ast;
const alloc = std.testing.allocator;

// ---------- helpers ----------

fn parseSource(source: []const u8) !gero.lang.ParseTree {
    var stream = try gero.lang.tokenize(alloc, source);
    defer stream.deinit();
    return gero.lang.parse(alloc, source, stream);
}

/// Parse `source`, assert no diagnostics were raised, and return the
/// `ParseTree`. Caller owns the tree (`tree.deinit()`).
fn parseClean(source: []const u8) !gero.lang.ParseTree {
    var tree = try parseSource(source);
    if (tree.errors.len != 0) {
        std.debug.print("unexpected errors parsing `{s}`:\n", .{source});
        for (tree.errors) |e| std.debug.print("  - {s}\n", .{e.message});
        tree.deinit();
        return error.UnexpectedDiagnostics;
    }
    return tree;
}

// ---------- empty input + smoke ----------

test "parse: empty source produces empty program" {
    var tree = try parseClean("");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.program.statements.len);
}

test "parse: whitespace-only source produces empty program" {
    var tree = try parseClean("\n\n   \t  \n");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.program.statements.len);
}

// ---------- let / const ----------

test "parse: let binding with init" {
    var tree = try parseClean("let x = 42");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 1), tree.program.statements.len);
    const s = tree.program.statements[0];
    try std.testing.expect(s == .let_decl);
    try std.testing.expect(s.let_decl.init != null);
    try std.testing.expect(s.let_decl.pattern.* == .ident);
}

test "parse: let with type annotation" {
    var tree = try parseClean("let x: i16 = 0");
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s.let_decl.type_ann != null);
    try std.testing.expect(s.let_decl.type_ann.?.* == .named);
}

test "parse: let with no init (typed declaration)" {
    var tree = try parseClean("let x: i16");
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s.let_decl.init == null);
}

test "parse: const declaration" {
    var tree = try parseClean("const MAX = 100");
    defer tree.deinit();
    try std.testing.expect(tree.program.statements[0] == .const_decl);
}

test "parse: local let" {
    var tree = try parseClean("local let x = 0");
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s.let_decl.is_local);
}

// ---------- assignment forms ----------

test "parse: plain assign" {
    var tree = try parseClean("x = 1");
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s == .assign);
    try std.testing.expectEqual(ast.AssignOp.set, s.assign.op);
}

test "parse: compound add-assign" {
    var tree = try parseClean("x += 1");
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expectEqual(ast.AssignOp.add_set, s.assign.op);
}

test "parse: every compound-assign operator" {
    const cases = [_]struct { src: []const u8, op: ast.AssignOp }{
        .{ .src = "x = 1", .op = .set },
        .{ .src = "x += 1", .op = .add_set },
        .{ .src = "x -= 1", .op = .sub_set },
        .{ .src = "x *= 1", .op = .mul_set },
        .{ .src = "x /= 1", .op = .div_set },
        .{ .src = "x %= 1", .op = .mod_set },
        .{ .src = "x &= 1", .op = .bit_and_set },
        .{ .src = "x |= 1", .op = .bit_or_set },
        .{ .src = "x ^= 1", .op = .bit_xor_set },
        .{ .src = "x <<= 1", .op = .shl_set },
        .{ .src = "x >>= 1", .op = .shr_set },
    };
    for (cases) |c| {
        var tree = try parseClean(c.src);
        defer tree.deinit();
        try std.testing.expectEqual(c.op, tree.program.statements[0].assign.op);
    }
}

test "parse: x++ and x-- statements" {
    var tree = try parseClean("x++\ny--");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 2), tree.program.statements.len);
    try std.testing.expect(tree.program.statements[0].inc_dec.inc);
    try std.testing.expect(!tree.program.statements[1].inc_dec.inc);
}

test "parse: discard `_ = expr`" {
    var tree = try parseClean("_ = call()");
    defer tree.deinit();
    try std.testing.expect(tree.program.statements[0] == .discard);
}

// ---------- expression precedence (§3.3) ----------

test "parse: `a + b * c` binds * tighter than +" {
    var tree = try parseClean("let x = a + b * c");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.add, init.binary.op);
    try std.testing.expect(init.binary.rhs.* == .binary);
    try std.testing.expectEqual(ast.BinaryOp.mul, init.binary.rhs.binary.op);
}

test "parse: comparison binds looser than bitwise" {
    var tree = try parseClean("let x = a | b == c");
    defer tree.deinit();
    // Expected: (a | b) == c — `|` is tighter than `==`.
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expectEqual(ast.BinaryOp.eq, init.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.bit_or, init.binary.lhs.binary.op);
}

test "parse: `and` binds looser than comparison" {
    var tree = try parseClean("let x = a < b and c > d");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expectEqual(ast.BinaryOp.log_and, init.binary.op);
}

test "parse: `or` binds looser than `and`" {
    var tree = try parseClean("let x = a and b or c");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expectEqual(ast.BinaryOp.log_or, init.binary.op);
    try std.testing.expectEqual(ast.BinaryOp.log_and, init.binary.lhs.binary.op);
}

test "parse: unary minus binds tighter than mul" {
    var tree = try parseClean("let x = -a * b");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expectEqual(ast.BinaryOp.mul, init.binary.op);
    try std.testing.expect(init.binary.lhs.* == .unary);
}

test "parse: `not` is unary, binds tighter than `and`" {
    var tree = try parseClean("let x = not a and b");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expectEqual(ast.BinaryOp.log_and, init.binary.op);
    try std.testing.expect(init.binary.lhs.* == .unary);
    try std.testing.expectEqual(ast.UnaryOp.log_not, init.binary.lhs.unary.op);
}

test "parse: bitwise NOT (`~`) is unary" {
    var tree = try parseClean("let x = ~mask & 0xFF");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expectEqual(ast.BinaryOp.bit_and, init.binary.op);
    try std.testing.expectEqual(ast.UnaryOp.bit_not, init.binary.lhs.unary.op);
}

test "parse: parens override precedence" {
    var tree = try parseClean("let x = (a + b) * c");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expectEqual(ast.BinaryOp.mul, init.binary.op);
    try std.testing.expect(init.binary.lhs.* == .paren);
}

test "parse: range expression `0..10` is a Range node" {
    var tree = try parseClean("let r = 0..10");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .range);
    try std.testing.expect(!init.range.inclusive);
}

test "parse: inclusive range `0..=10`" {
    var tree = try parseClean("let r = 0..=10");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .range);
    try std.testing.expect(init.range.inclusive);
}

test "parse: `is` test produces an is_test node" {
    var tree = try parseClean("let r = item is Item.Sword");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .is_test);
}

// ---------- postfix call / index / field ----------

test "parse: function call" {
    var tree = try parseClean("let r = foo(1, 2)");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .call);
    try std.testing.expectEqual(@as(usize, 2), init.call.args.len);
}

test "parse: method call chain" {
    var tree = try parseClean("let r = obj.foo().bar(1)");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .method_call);
    try std.testing.expectEqual(@as(usize, 1), init.method_call.args.len);
}

test "parse: field access" {
    var tree = try parseClean("let r = obj.x");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .field);
}

test "parse: index access" {
    var tree = try parseClean("let r = arr[i]");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .index);
}

// ---------- literals ----------

test "parse: bool literal" {
    var tree = try parseClean("let x = true");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .bool_lit);
    try std.testing.expect(init.bool_lit.value);
}

test "parse: nil literal" {
    var tree = try parseClean("let x = nil");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .nil_lit);
}

test "parse: string literal" {
    var tree = try parseClean("let x = \"hello\"");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .str_lit);
}

test "parse: string with interpolation" {
    var tree = try parseClean("let x = \"hi $(name)!\"");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .str_lit);
    // Expect at least one interp part.
    var has_interp = false;
    for (init.str_lit.parts) |p| switch (p) {
        .interp => has_interp = true,
        else => {},
    };
    try std.testing.expect(has_interp);
}

test "parse: list literal" {
    var tree = try parseClean("let x = [1, 2, 3]");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .list_lit);
    try std.testing.expectEqual(@as(usize, 3), init.list_lit.elems.len);
}

test "parse: tuple literal" {
    var tree = try parseClean("let x = (1, 2)");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .tuple_lit);
}

test "parse: struct literal" {
    var tree = try parseClean("let s = Stats { hp: 100, mp: 30 }");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .struct_lit);
    try std.testing.expectEqual(@as(usize, 2), init.struct_lit.fields.len);
}

// ---------- functions ----------

test "parse: simple def" {
    var tree = try parseClean(
        \\def add(a: i16, b: i16) -> i16
        \\  return a + b
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s == .def_decl);
    try std.testing.expectEqual(@as(usize, 2), s.def_decl.params.len);
    try std.testing.expect(s.def_decl.ret_type != null);
}

test "parse: def with no return type" {
    var tree = try parseClean(
        \\def greet(name)
        \\  print name
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s.def_decl.ret_type == null);
}

test "parse: def with no parameters" {
    var tree = try parseClean(
        \\def init()
        \\  return
        \\end
    );
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 0), tree.program.statements[0].def_decl.params.len);
}

test "parse: lambda expression" {
    var tree = try parseClean(
        \\let square = lambda (x: i16) -> i16
        \\  return x * x
        \\end
    );
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .lambda);
}

// ---------- control flow ----------

test "parse: if/then/end" {
    var tree = try parseClean(
        \\if x > 0 then
        \\  print x
        \\end
    );
    defer tree.deinit();
    try std.testing.expect(tree.program.statements[0] == .if_stmt);
    try std.testing.expectEqual(@as(usize, 1), tree.program.statements[0].if_stmt.arms.len);
}

test "parse: if/elif/else chain" {
    var tree = try parseClean(
        \\if x > 0 then
        \\  print "pos"
        \\elif x == 0 then
        \\  print "zero"
        \\else
        \\  print "neg"
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].if_stmt;
    try std.testing.expectEqual(@as(usize, 2), s.arms.len);
    try std.testing.expect(s.else_body != null);
}

test "parse: `if let` pattern binding" {
    var tree = try parseClean(
        \\if let Item.Potion(n) = item then
        \\  drink(n)
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].if_stmt;
    try std.testing.expectEqual(@as(usize, 1), s.arms.len);
    try std.testing.expect(s.arms[0].cond == null);
    try std.testing.expect(s.arms[0].let_pattern != null);
    try std.testing.expect(s.arms[0].let_expr != null);
}

test "parse: `if let` with `when` guard" {
    var tree = try parseClean(
        \\if let Event.Click(x, y) = e when x < 128 then
        \\  hit(x, y)
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].if_stmt;
    try std.testing.expect(s.arms[0].let_guard != null);
}

test "parse: while loop" {
    var tree = try parseClean(
        \\while i < 10 do
        \\  i = i + 1
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s == .while_stmt);
    try std.testing.expect(s.while_stmt.cond != null);
}

test "parse: for-in with range" {
    var tree = try parseClean(
        \\for i in 0..10 do
        \\  print i
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s == .for_stmt);
    try std.testing.expect(s.for_stmt.iter.* == .range);
}

test "parse: for-in with step" {
    var tree = try parseClean(
        \\for i in 0..=100 step 5 do
        \\  print i
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].for_stmt;
    try std.testing.expect(s.step != null);
}

test "parse: do-end as statement" {
    var tree = try parseClean(
        \\do
        \\  let x = 1
        \\  print x
        \\end
    );
    defer tree.deinit();
    try std.testing.expect(tree.program.statements[0] == .block);
}

test "parse: do-end as expression in let init" {
    var tree = try parseClean(
        \\let area = do
        \\  let w = 4
        \\  let h = 5
        \\  w * h
        \\end
    );
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .do_expr);
}

test "parse: return with value" {
    var tree = try parseClean(
        \\def f()
        \\  return 42
        \\end
    );
    defer tree.deinit();
    const body = tree.program.statements[0].def_decl.body;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expect(body[0] == .return_stmt);
    try std.testing.expect(body[0].return_stmt.value != null);
}

test "parse: bare return" {
    var tree = try parseClean(
        \\def f()
        \\  return
        \\end
    );
    defer tree.deinit();
    const body = tree.program.statements[0].def_decl.body;
    try std.testing.expect(body[0].return_stmt.value == null);
}

test "parse: break + continue" {
    var tree = try parseClean(
        \\while true do
        \\  break
        \\  continue
        \\end
    );
    defer tree.deinit();
    const body = tree.program.statements[0].while_stmt.body;
    try std.testing.expect(body[0] == .break_stmt);
    try std.testing.expect(body[1] == .continue_stmt);
}

test "parse: print statement" {
    var tree = try parseClean("print \"hi\"");
    defer tree.deinit();
    try std.testing.expect(tree.program.statements[0] == .print_stmt);
}

test "parse: print with multiple args" {
    var tree = try parseClean("print x, y, z");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 3), tree.program.statements[0].print_stmt.args.len);
}

// ---------- match ----------

test "parse: match statement with multiple arms" {
    var tree = try parseClean(
        \\match item
        \\  case Item.Sword then
        \\    print "sword"
        \\  case Item.Potion(n) then
        \\    print n
        \\  case _ then
        \\    print "?"
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].match_stmt;
    try std.testing.expectEqual(@as(usize, 3), s.arms.len);
}

test "parse: match arm with `when` guard" {
    var tree = try parseClean(
        \\match item
        \\  case Item.Potion(n) when n > 50 then
        \\    print "big"
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].match_stmt;
    try std.testing.expect(s.arms[0].guard != null);
}

test "parse: or-pattern" {
    var tree = try parseClean(
        \\match x
        \\  case 1 | 2 | 3 then
        \\    print "small"
        \\end
    );
    defer tree.deinit();
    const arm0 = tree.program.statements[0].match_stmt.arms[0];
    try std.testing.expect(arm0.pattern.* == .or_pattern);
    try std.testing.expectEqual(@as(usize, 3), arm0.pattern.or_pattern.alts.len);
}

test "parse: range pattern" {
    var tree = try parseClean(
        \\match x
        \\  case 0..=15 then
        \\    print "small"
        \\end
    );
    defer tree.deinit();
    const arm0 = tree.program.statements[0].match_stmt.arms[0];
    try std.testing.expect(arm0.pattern.* == .range_pattern);
}

test "parse: tuple pattern" {
    var tree = try parseClean(
        \\match p
        \\  case (a, b) then
        \\    print a
        \\end
    );
    defer tree.deinit();
    const arm0 = tree.program.statements[0].match_stmt.arms[0];
    try std.testing.expect(arm0.pattern.* == .tuple_pattern);
}

test "parse: struct pattern with shorthand" {
    var tree = try parseClean(
        \\match p
        \\  case Player { hp, mp } then
        \\    print hp
        \\end
    );
    defer tree.deinit();
    const arm0 = tree.program.statements[0].match_stmt.arms[0];
    try std.testing.expect(arm0.pattern.* == .struct_pattern);
    try std.testing.expectEqual(@as(usize, 2), arm0.pattern.struct_pattern.fields.len);
}

test "parse: variant pattern with binding" {
    var tree = try parseClean(
        \\match e
        \\  case Event.KeyDown(k) then
        \\    print k
        \\end
    );
    defer tree.deinit();
    const arm0 = tree.program.statements[0].match_stmt.arms[0];
    try std.testing.expect(arm0.pattern.* == .variant_pattern);
    try std.testing.expectEqual(@as(usize, 1), arm0.pattern.variant_pattern.args.len);
}

// ---------- struct / class / enum ----------

test "parse: struct declaration" {
    var tree = try parseClean(
        \\struct Stats
        \\  hp: i16
        \\  mp: i16
        \\  atk: u8
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s == .struct_decl);
    try std.testing.expectEqual(@as(usize, 3), s.struct_decl.fields.len);
}

test "parse: class with fields + method" {
    var tree = try parseClean(
        \\class Player
        \\  let hp: i16
        \\  let mp: i16
        \\  def init(self)
        \\    self.hp = 100
        \\    self.mp = 50
        \\  end
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0];
    try std.testing.expect(s == .class_decl);
    try std.testing.expectEqual(@as(usize, 2), s.class_decl.fields.len);
    try std.testing.expectEqual(@as(usize, 1), s.class_decl.methods.len);
}

test "parse: class with extends" {
    var tree = try parseClean(
        \\class Hero extends Player
        \\  let weapon: str
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].class_decl;
    try std.testing.expect(s.extends != null);
}

test "parse: enum declaration with nullary + payload variants" {
    var tree = try parseClean(
        \\enum Item
        \\  case Sword
        \\  case Potion(amount: i16)
        \\  case Key(name: str, count: u8)
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].enum_decl;
    try std.testing.expectEqual(@as(usize, 3), s.variants.len);
    try std.testing.expectEqual(@as(usize, 0), s.variants[0].payload.len);
    try std.testing.expectEqual(@as(usize, 1), s.variants[1].payload.len);
    try std.testing.expectEqual(@as(usize, 2), s.variants[2].payload.len);
}

// ---------- annotations ----------

test "parse: marker annotation attaches to def" {
    var tree = try parseClean(
        \\@inline
        \\def f(x: i16) -> i16
        \\  return x
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].def_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
    try std.testing.expectEqual(@as(usize, 0), s.annotations[0].args.len);
}

test "parse: parameterized `@bank N` attaches to def" {
    var tree = try parseClean(
        \\@bank 5
        \\def boss() -> i16
        \\  return 0
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].def_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
    try std.testing.expectEqual(@as(usize, 1), s.annotations[0].args.len);
}

test "parse: multiple annotations stack on a single decl" {
    var tree = try parseClean(
        \\@inline
        \\@final
        \\def fast()
        \\  return
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].def_decl;
    try std.testing.expectEqual(@as(usize, 2), s.annotations.len);
}

test "parse: `@interrupt N` parses on def" {
    var tree = try parseClean(
        \\@interrupt 0x06
        \\def on_vblank()
        \\  return
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].def_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
}

test "parse: annotation in parens form" {
    var tree = try parseClean(
        \\@bank(5)
        \\def m()
        \\  return
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].def_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
    try std.testing.expectEqual(@as(usize, 1), s.annotations[0].args.len);
}

test "parse: annotation attaches to class" {
    var tree = try parseClean(
        \\@final
        \\class Boss
        \\  let hp: i16
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].class_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
}

test "parse: annotation attaches to class field + method" {
    var tree = try parseClean(
        \\class Player
        \\  @private
        \\  let _hp: i16
        \\  @override
        \\  def update(self)
        \\    return
        \\  end
        \\end
    );
    defer tree.deinit();
    const c = tree.program.statements[0].class_decl;
    try std.testing.expectEqual(@as(usize, 1), c.fields[0].annotations.len);
    try std.testing.expectEqual(@as(usize, 1), c.methods[0].annotations.len);
}

// ---------- imports ----------

test "parse: bare `use module`" {
    var tree = try parseClean("use math");
    defer tree.deinit();
    const s = tree.program.statements[0].use_decl;
    try std.testing.expectEqual(@as(usize, 0), s.items.len);
    try std.testing.expect(s.alias == null);
}

test "parse: `use module as alias`" {
    var tree = try parseClean("use math as m");
    defer tree.deinit();
    const s = tree.program.statements[0].use_decl;
    try std.testing.expect(s.alias != null);
}

test "parse: `use name from module`" {
    var tree = try parseClean("use abs from math");
    defer tree.deinit();
    const s = tree.program.statements[0].use_decl;
    try std.testing.expectEqual(@as(usize, 1), s.items.len);
}

test "parse: `use a, b as bb, c from module`" {
    var tree = try parseClean("use a, b as bb, c from math");
    defer tree.deinit();
    const s = tree.program.statements[0].use_decl;
    try std.testing.expectEqual(@as(usize, 3), s.items.len);
    try std.testing.expect(s.items[1].alias != null);
}

test "parse: `use \"./relative\"` quoted-path" {
    var tree = try parseClean("use \"./physics\"");
    defer tree.deinit();
    const s = tree.program.statements[0].use_decl;
    try std.testing.expect(s.quoted_path);
}

// ---------- type annotations ----------

test "parse: nullable type" {
    var tree = try parseClean("let s: str? = nil");
    defer tree.deinit();
    const t = tree.program.statements[0].let_decl.type_ann.?;
    try std.testing.expect(t.* == .nullable);
}

test "parse: array type" {
    var tree = try parseClean("let buf: [u8; 64]");
    defer tree.deinit();
    const t = tree.program.statements[0].let_decl.type_ann.?;
    try std.testing.expect(t.* == .array);
}

test "parse: Vec(T)" {
    var tree = try parseClean("let v: Vec(i16)");
    defer tree.deinit();
    const t = tree.program.statements[0].let_decl.type_ann.?;
    try std.testing.expect(t.* == .vec);
}

test "parse: tuple type" {
    var tree = try parseClean("let p: (i16, str)");
    defer tree.deinit();
    const t = tree.program.statements[0].let_decl.type_ann.?;
    try std.testing.expect(t.* == .tuple);
}

test "parse: function type" {
    var tree = try parseClean("let op: fn(i16, i16) -> i16");
    defer tree.deinit();
    const t = tree.program.statements[0].let_decl.type_ann.?;
    try std.testing.expect(t.* == .fn_type);
}

// ---------- error recovery ----------

test "parse: unterminated let surfaces a diagnostic and recovers" {
    var tree = try parseSource("let = 1\nlet y = 2");
    defer tree.deinit();
    try std.testing.expect(tree.errors.len > 0);
    // The valid `let y = 2` line should still parse after recovery.
    var saw_y = false;
    for (tree.program.statements) |s| switch (s) {
        .let_decl => saw_y = true,
        else => {},
    };
    try std.testing.expect(saw_y);
}

test "parse: $-hex literal lexes as int_lit" {
    var tree = try parseClean("let x = $FF");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .int_lit);
    try std.testing.expectEqual(@as(i32, 0xFF), init.int_lit.value);
}

test "parse: @addr $FE40 captures the literal arg" {
    var tree = try parseClean(
        \\@addr $FE40
        \\let DISPCTL: u8 = 0
    );
    defer tree.deinit();
    const s = tree.program.statements[0].let_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
    try std.testing.expectEqual(@as(usize, 1), s.annotations[0].args.len);
    const arg = s.annotations[0].args[0];
    try std.testing.expect(arg.* == .int_lit);
    try std.testing.expectEqual(@as(i32, 0xFE40), arg.int_lit.value);
}

test "parse: fixed-point literal 1.5 encodes as Q8.8 0x0180" {
    var tree = try parseClean("let v: fixed = 1.5");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .fixed_lit);
    try std.testing.expectEqual(@as(i32, 0x0180), init.fixed_lit.value);
}

test "parse: fixed-point literal 0.125 encodes as Q8.8 0x0020" {
    var tree = try parseClean("let v: fixed = 0.125");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .fixed_lit);
    try std.testing.expectEqual(@as(i32, 0x0020), init.fixed_lit.value);
}

test "parse: fixed-point literal 3.14159 encodes as 0x0324 (rounded)" {
    var tree = try parseClean("const PI: fixed = 3.14159");
    defer tree.deinit();
    const init = tree.program.statements[0].const_decl.init;
    try std.testing.expect(init.* == .fixed_lit);
    try std.testing.expectEqual(@as(i32, 0x0324), init.fixed_lit.value);
}

test "parse: `1.foo()` parses as int.method, not fixed_lit" {
    var tree = try parseClean("let x = 1.foo()");
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .method_call);
    try std.testing.expect(init.method_call.receiver.* == .int_lit);
    try std.testing.expectEqual(@as(i32, 1), init.method_call.receiver.int_lit.value);
}

test "parse: @zero_page on let global" {
    var tree = try parseClean(
        \\@zero_page
        \\let cursor_pos: u16 = 0
    );
    defer tree.deinit();
    const s = tree.program.statements[0].let_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
}

test "parse: @addr with hex arg on let global" {
    var tree = try parseClean(
        \\@addr 0xFE40
        \\let DISPCTL: u8 = 0
    );
    defer tree.deinit();
    const s = tree.program.statements[0].let_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
    try std.testing.expectEqual(@as(usize, 1), s.annotations[0].args.len);
}

test "parse: @bank N on const global" {
    var tree = try parseClean(
        \\@bank 5
        \\const TOWN_INTRO = "Welcome to Mistwood..."
    );
    defer tree.deinit();
    const s = tree.program.statements[0].const_decl;
    try std.testing.expectEqual(@as(usize, 1), s.annotations.len);
}

test "parse: multi-line call args" {
    var tree = try parseClean(
        \\let r = foo(
        \\  1,
        \\  2,
        \\  3,
        \\)
    );
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .call);
    try std.testing.expectEqual(@as(usize, 3), init.call.args.len);
}

test "parse: multi-line param list on def" {
    var tree = try parseClean(
        \\def damage(
        \\  attacker: Stats,
        \\  target: Stats,
        \\  weapon: Weapon,
        \\) -> i16
        \\  return 0
        \\end
    );
    defer tree.deinit();
    const s = tree.program.statements[0].def_decl;
    try std.testing.expectEqual(@as(usize, 3), s.params.len);
}

test "parse: multi-line method call args" {
    var tree = try parseClean(
        \\let r = obj.method(
        \\  a,
        \\  b
        \\)
    );
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .method_call);
    try std.testing.expectEqual(@as(usize, 2), init.method_call.args.len);
}

test "parse: leading-dot continues a method chain across newlines" {
    var tree = try parseClean(
        \\let damaged = monsters
        \\  .filter(alive)
        \\  .map(deal_damage)
        \\  .filter(still_alive)
    );
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 1), tree.program.statements.len);
    const init = tree.program.statements[0].let_decl.init.?;
    // Outer call is `.filter(still_alive)` — the last link in the
    // chain. Inner receiver is itself a chain.
    try std.testing.expect(init.* == .method_call);
    try std.testing.expect(init.method_call.receiver.* == .method_call);
}

test "parse: leading-dot threads through field + index + call" {
    var tree = try parseClean(
        \\let x = obj
        \\  .field
        \\  .method(1)
        \\  .items[0]
    );
    defer tree.deinit();
    const init = tree.program.statements[0].let_decl.init.?;
    try std.testing.expect(init.* == .index);
}

test "parse: @abstract def parses without a body" {
    var tree = try parseClean(
        \\class Entity
        \\  @abstract
        \\  def update(self)
        \\
        \\  def position(self) -> (i16, i16)
        \\    return (0, 0)
        \\  end
        \\end
    );
    defer tree.deinit();
    const c = tree.program.statements[0].class_decl;
    try std.testing.expectEqual(@as(usize, 2), c.methods.len);
    try std.testing.expectEqual(@as(usize, 0), c.methods[0].body.len);
    try std.testing.expectEqual(@as(usize, 1), c.methods[0].annotations.len);
    try std.testing.expect(c.methods[1].body.len > 0);
}

test "parse: @abstract def with return type, still no body" {
    var tree = try parseClean(
        \\class Stream
        \\  @abstract
        \\  def next(self) -> i16?
        \\end
    );
    defer tree.deinit();
    const m = tree.program.statements[0].class_decl.methods[0];
    try std.testing.expectEqual(@as(usize, 0), m.body.len);
    try std.testing.expect(m.ret_type != null);
}

test "parse: @asm(\"...\") as a top-level statement" {
    var tree = try parseClean("@asm(\"swap r1, r2\")");
    defer tree.deinit();
    try std.testing.expectEqual(@as(usize, 1), tree.program.statements.len);
    try std.testing.expect(tree.program.statements[0] == .asm_stmt);
}

test "parse: @asm(\"...\") inside a function body" {
    var tree = try parseClean(
        \\def fast_swap(a: u16, b: u16)
        \\  @asm("swap {a}, {b}")
        \\end
    );
    defer tree.deinit();
    const body = tree.program.statements[0].def_decl.body;
    try std.testing.expectEqual(@as(usize, 1), body.len);
    try std.testing.expect(body[0] == .asm_stmt);
}

test "parse: @asm without a string arg surfaces a diagnostic" {
    var tree = try parseSource("@asm(42)");
    defer tree.deinit();
    try std.testing.expect(tree.errors.len > 0);
}

test "parse: dangling annotation at EOF surfaces a diagnostic" {
    var tree = try parseSource("@final\n");
    defer tree.deinit();
    try std.testing.expect(tree.errors.len > 0);
}
