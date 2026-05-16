/// Gero-lang typechecker — entry point and AST walker scaffolding.
///
/// This slice ships the bones: every statement and expression in the
/// AST has a walker arm that visits its children without yet emitting
/// any type-level diagnostic. Subsequent slices fill in resolution,
/// inference, type checking, and the spec's semantic rules.
///
/// Diagnostics flow through the same `core.ParseError` shape as the
/// parser until the diagnostic renderer from #226 lands.
///
/// Per `docs/gero-lang.md` and `docs/lang-diagnostics.md`.
const std = @import("std");
const knit = @import("knit");
const core = knit.core;

const ast = @import("ast.zig");
const types = @import("types.zig");
const scope_mod = @import("scope.zig");
const Scope = scope_mod.Scope;

/// What a successful (or partial) typecheck produces. `diagnostics`
/// is non-empty when one or more rules fired; the program is still
/// returned so downstream passes can do best-effort work where
/// possible. The arena that allocated all the `*Type` nodes is owned
/// by `CheckedProgram` and freed via `deinit`.
pub const CheckedProgram = struct {
    /// The input AST — unchanged by typechecking. The typechecker
    /// owns no part of it; the parser arena still backs every
    /// `Span` and child pointer.
    program: *const ast.Program,
    /// Diagnostics produced during the walk. Empty on a clean pass.
    diagnostics: []core.ParseError,
    /// Arena holding every `*Type` allocation the walker made.
    type_arena: std.heap.ArenaAllocator,
    /// Allocator the diagnostics slice was carved from.
    allocator: std.mem.Allocator,

    /// Release the diagnostics slice and the `*Type` arena.
    pub fn deinit(self: *CheckedProgram) void {
        self.allocator.free(self.diagnostics);
        self.type_arena.deinit();
    }

    /// `true` when at least one `error`-severity diagnostic fired.
    pub fn hasErrors(self: CheckedProgram) bool {
        for (self.diagnostics) |d| if (d.severity == .fatal) return true;
        return false;
    }
};

/// Walk `program` through the typechecker. The scaffolding pass
/// only visits — no rules emit yet — so a well-formed parse tree
/// always returns an empty diagnostic list.
pub fn typecheck(
    allocator: std.mem.Allocator,
    source: []const u8,
    program: *const ast.Program,
) !CheckedProgram {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var diagnostics: std.ArrayList(core.ParseError) = .empty;
    errdefer diagnostics.deinit(allocator);

    var module_scope: Scope = .init(arena.allocator(), null);
    // No `defer module_scope.deinit()` — the arena releases the
    // map's storage when `CheckedProgram.deinit` runs.

    var checker: Checker = .{
        .allocator = allocator,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
        .module_scope = &module_scope,
    };

    for (program.statements) |stmt| {
        try checker.walkStatement(stmt);
    }

    return .{
        .program = program,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .type_arena = arena,
        .allocator = allocator,
    };
}

/// Walker state. Holds the current scope (mutable as nested blocks
/// push and pop), the source buffer for span resolution, and the
/// allocator for diagnostic + type allocations.
const Checker = struct {
    allocator: std.mem.Allocator,
    /// Arena used for `*Type` allocations and the scope tree.
    arena: std.mem.Allocator,
    source: []const u8,
    diagnostics: *std.ArrayList(core.ParseError),
    /// Currently-active scope. Each block / function entry sets
    /// this to a fresh child and restores on exit.
    module_scope: *Scope,

    /// Mutually recursive walker fns need an explicit error set —
    /// Zig's inferred sets would deadlock the dependency graph.
    const WalkError = error{OutOfMemory};

    // ---------- statement walker ----------

    fn walkStatement(self: *Checker, s: ast.Statement) WalkError!void {
        switch (s) {
            .let_decl => |d| {
                if (d.init) |e| try self.walkExpr(e);
            },
            .const_decl => |d| try self.walkExpr(d.init),
            .assign => |a| {
                try self.walkExpr(a.target);
                try self.walkExpr(a.value);
            },
            .inc_dec => |id| try self.walkExpr(id.target),
            .discard => |d| try self.walkExpr(d.expr),
            .expr_stmt => |es| try self.walkExpr(es.expr),
            .block => |b| try self.walkStatements(b.body),
            .if_stmt => |is_| {
                for (is_.arms) |arm| {
                    if (arm.cond) |c| try self.walkExpr(c);
                    if (arm.let_expr) |e| try self.walkExpr(e);
                    if (arm.let_guard) |g| try self.walkExpr(g);
                    try self.walkStatements(arm.body);
                }
                if (is_.else_body) |eb| try self.walkStatements(eb);
            },
            .while_stmt => |ws| {
                if (ws.cond) |c| try self.walkExpr(c);
                if (ws.let_expr) |e| try self.walkExpr(e);
                if (ws.let_guard) |g| try self.walkExpr(g);
                try self.walkStatements(ws.body);
            },
            .for_stmt => |fs| {
                try self.walkExpr(fs.iter);
                if (fs.step) |st| try self.walkExpr(st);
                try self.walkStatements(fs.body);
            },
            .repeat_stmt => |rs| {
                try self.walkStatements(rs.body);
                try self.walkExpr(rs.cond);
            },
            .match_stmt => |ms| {
                try self.walkExpr(ms.scrutinee);
                for (ms.arms) |arm| {
                    if (arm.guard) |g| try self.walkExpr(g);
                    try self.walkStatements(arm.body);
                }
            },
            .return_stmt => |rs| if (rs.value) |v| try self.walkExpr(v),
            .break_stmt, .continue_stmt => {},
            .print_stmt => |ps| for (ps.args) |a| try self.walkExpr(a),
            .def_decl => |d| try self.walkStatements(d.body),
            .class_decl => |c| {
                for (c.fields) |f| if (f.init) |init_| try self.walkExpr(init_);
                for (c.methods) |m| try self.walkStatements(m.body);
            },
            .struct_decl, .enum_decl, .use_decl, .local_decl => {},
            .asm_stmt => {},
            .defer_stmt => |ds| try self.walkStatement(ds.body.*),
            .unknown => {},
        }
    }

    fn walkStatements(self: *Checker, body: []const ast.Statement) WalkError!void {
        for (body) |s| try self.walkStatement(s);
    }

    // ---------- expression walker ----------

    fn walkExpr(self: *Checker, e: *const ast.Expr) WalkError!void {
        switch (e.*) {
            .int_lit, .fixed_lit, .bool_lit, .nil_lit, .char_lit, .ident, .self_expr, .super_expr => {},
            .str_lit => |s| for (s.parts) |part| switch (part) {
                .lit => {},
                .interp => |ip| try self.walkExpr(ip.expr),
            },
            .paren => |p| try self.walkExpr(p.inner),
            .unary => |u| try self.walkExpr(u.operand),
            .binary => |b| {
                try self.walkExpr(b.lhs);
                try self.walkExpr(b.rhs);
            },
            .range => |r| {
                try self.walkExpr(r.start);
                try self.walkExpr(r.end);
            },
            .call => |c| {
                try self.walkExpr(c.callee);
                for (c.args) |a| try self.walkExpr(a);
            },
            .method_call => |m| {
                try self.walkExpr(m.receiver);
                for (m.args) |a| try self.walkExpr(a);
            },
            .field => |f| try self.walkExpr(f.receiver),
            .index => |ix| {
                try self.walkExpr(ix.receiver);
                try self.walkExpr(ix.index);
            },
            .do_expr => |d| try self.walkStatements(d.body),
            .if_expr => |ie| {
                for (ie.arms) |arm| {
                    if (arm.cond) |c| try self.walkExpr(c);
                    if (arm.let_expr) |le| try self.walkExpr(le);
                    if (arm.let_guard) |g| try self.walkExpr(g);
                    try self.walkStatements(arm.body);
                }
                if (ie.else_body) |eb| try self.walkStatements(eb);
            },
            .lambda => |l| try self.walkStatements(l.body),
            .list_lit => |ll| for (ll.elems) |x| try self.walkExpr(x),
            .list_repeat => |lr| {
                try self.walkExpr(lr.value);
                try self.walkExpr(lr.count);
            },
            .struct_lit => |sl| for (sl.fields) |f| try self.walkExpr(f.value),
            .tuple_lit => |tl| for (tl.elems) |x| try self.walkExpr(x),
            .is_test => |it| try self.walkExpr(it.lhs),
            .cast => |c| try self.walkExpr(c.inner),
            .ref_of => |r| try self.walkExpr(r.inner),
        }
    }
};
