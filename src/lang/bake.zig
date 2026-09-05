const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const diag_mod = @import("diagnostic.zig");

const Diagnostic = diag_mod.Diagnostic;

/// Default AST-walk step budget per `bake` invocation. One step
/// is one walked statement or evaluated expression.
pub const default_budget: u32 = 100_000_000;

/// One bake-time value (spec §3.8). Strings reference interned
/// source bytes the codegen later writes into the data segment.
/// `Vec(T)`, classes, references, and fn pointers are rejected
/// by the typechecker before this runs.
pub const BakeValue = union(enum) {
    /// 16-bit integer (sign interpretation comes from the binding).
    int_: u16,
    /// Q8.8 fixed-point (same bit layout as runtime `fixed`).
    fixed_: u16,
    /// Boolean.
    bool_: bool,
    /// Unit value.
    nil_,
    /// 8-bit byte (`u8` / `i8` / `char`).
    byte: u8,
    /// String literal (borrowed from interned source bytes).
    str: []const u8,
    /// Fixed-length array.
    array: []const BakeValue,
    /// Heterogeneous tuple.
    tuple: []const BakeValue,
    /// POD struct.
    struct_: []const Field,

    /// One field of a `struct_` value.
    pub const Field = struct {
        name: []const u8,
        value: BakeValue,
    };
};

/// Errors the bake driver can return. Semantic violations land
/// in `Result.diagnostics`; only host failures propagate here.
pub const BakeError = error{OutOfMemory};

/// Outcome of one `bake` evaluation. `value` is `null` on
/// failure; the caller skips the codegen path in that case.
/// `diag_arena` backs every `Diagnostic.message` — call
/// `deinit(alloc)` to release both the arena and the slice.
pub const Result = struct {
    value: ?BakeValue,
    diagnostics: []const Diagnostic,
    diag_arena: std.heap.ArenaAllocator,

    /// Release the diagnostics slice + the diag-message arena.
    /// Pass the same allocator that was handed to `evaluateDo` /
    /// `evaluateDef` so the slice frees through its owner.
    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.diagnostics);
        self.diag_arena.deinit();
    }
};

/// Knobs for one interpreter run. The codegen plumbs `budget`
/// through from `CompileOptions` so tests can lower it without
/// touching the global default.
pub const Options = struct {
    budget: u32 = default_budget,
    /// Map of `bake def` names → AST nodes available for
    /// in-bake calls. `null` (default) disables call dispatch;
    /// any `call_expr` against an ident callee then faults with
    /// `E_BAKE_FORBIDDEN_CALL`. The codegen wires the program's
    /// `bake def` registry through this slot.
    bake_defs: ?*const std.StringHashMap(*const ast.DefDecl) = null,
    /// The typechecker's inferred expression types, threaded so
    /// compile-time `math.*` picks signed vs unsigned exactly like the
    /// runtime lowering (the bake evaluator is otherwise typeless).
    /// `null` disables `math.*` dispatch (calls then fault).
    expr_types: ?*const std.AutoHashMapUnmanaged(*const ast.Expr, *const types.Type) = null,
};

/// Evaluate a `bake do … end` block against an empty initial
/// scope. The block's value is the value of its last expression
/// (or `nil` when the body has no trailing expression).
pub fn evaluateDo(
    allocator: std.mem.Allocator,
    source: []const u8,
    do: *const ast.DoExpr,
    opts: Options,
) BakeError!Result {
    var ev = try Evaluator.init(allocator, source, opts);
    defer ev.deinit();

    const value = ev.runBlock(do.body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Fault => null,
    };
    return ev.finalize(value);
}

/// Evaluate a `bake def name(…) -> T body end` invocation.
/// `args` binds in declaration order. The body runs against a
/// fresh scope; a `return expr` stops the walk and produces the
/// returned value.
pub fn evaluateDef(
    allocator: std.mem.Allocator,
    source: []const u8,
    decl: *const ast.DefDecl,
    args: []const BakeValue,
    opts: Options,
) BakeError!Result {
    var ev = try Evaluator.init(allocator, source, opts);
    defer ev.deinit();

    const value = ev.runDefCall(decl, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Fault => null,
    };
    return ev.finalize(value);
}

// ---------- internal evaluator ----------

const StepError = error{ OutOfMemory, Fault };

/// Signal propagated by `runBlock` when control flow exits the
/// loop body. The loop driver intercepts it; non-loop blocks
/// surface it as a fault (the typechecker rejects bare `break`
/// / `continue` outside a loop too).
const LoopSignal = enum { none, break_, continue_ };

/// One lexical scope inside the bake interpreter — `let` and
/// `const` bindings, params, induction variables for `for` loops.
const Scope = std.StringHashMapUnmanaged(BakeValue);

const Evaluator = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    scopes: std.ArrayList(Scope),
    diagnostics: std.ArrayList(Diagnostic),
    diag_arena: std.heap.ArenaAllocator,
    budget_remaining: u32,
    /// Map of in-scope `bake def` declarations. Lookup is by
    /// callee ident; `null` means no calls allowed (every call
    /// site faults with `E_BAKE_FORBIDDEN_CALL`).
    bake_defs: ?*const std.StringHashMap(*const ast.DefDecl),
    /// Typechecker expression types — drives `math.*` signedness.
    expr_types: ?*const std.AutoHashMapUnmanaged(*const ast.Expr, *const types.Type),
    /// `rng()` LFSR state, lazily seeded on first use (mirrors the
    /// runtime's zero-page cell) so a bake sequence is deterministic.
    rng_state: u16,
    /// Set when a `return` statement fires inside the running
    /// body. `runBlock` propagates the value upward; the
    /// outermost block transparently surfaces it.
    return_value: ?BakeValue,
    /// `break` / `continue` flag — set by the matching statement
    /// and cleared by the enclosing loop driver. Labeled loops
    /// aren't supported yet inside bake; the typechecker hasn't
    /// surfaced a use case past the spec example set.
    loop_signal: LoopSignal,

    fn init(
        allocator: std.mem.Allocator,
        source: []const u8,
        opts: Options,
    ) BakeError!Evaluator {
        var ev: Evaluator = .{
            .allocator = allocator,
            .source = source,
            .scopes = .empty,
            .diagnostics = .empty,
            .diag_arena = std.heap.ArenaAllocator.init(allocator),
            .budget_remaining = opts.budget,
            .bake_defs = opts.bake_defs,
            .expr_types = opts.expr_types,
            .rng_state = 0,
            .return_value = null,
            .loop_signal = .none,
        };
        try ev.scopes.append(allocator, .{});
        return ev;
    }

    fn deinit(self: *Evaluator) void {
        for (self.scopes.items) |*s| s.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
        // `diagnostics` slice + `diag_arena` belong to the
        // returned `Result` after `finalize`.
    }

    fn finalize(self: *Evaluator, value: ?BakeValue) BakeError!Result {
        return .{
            .value = value,
            .diagnostics = try self.diagnostics.toOwnedSlice(self.allocator),
            .diag_arena = self.diag_arena,
        };
    }

    fn pushScope(self: *Evaluator) void {
        // allow-strict: arena failures already surface through `init` budget; this path is hit only during nested-block walks and inherits the same allocator contract.
        self.scopes.append(self.allocator, .{}) catch unreachable;
    }

    fn popScope(self: *Evaluator) void {
        var s = self.scopes.pop().?;
        s.deinit(self.allocator);
    }

    fn bind(self: *Evaluator, name: []const u8, value: BakeValue) BakeError!void {
        var top = &self.scopes.items[self.scopes.items.len - 1];
        try top.put(self.allocator, name, value);
    }

    fn lookup(self: *Evaluator, name: []const u8) ?BakeValue {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name)) |v| return v;
        }
        return null;
    }

    fn assignLocal(self: *Evaluator, name: []const u8, value: BakeValue) BakeError!bool {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const slot = self.scopes.items[i].getPtr(name);
            if (slot != null) {
                slot.?.* = value;
                return true;
            }
        }
        return false;
    }

    fn lexeme(self: *const Evaluator, span: ast.Span) []const u8 {
        return self.source[span.start..span.end];
    }

    fn tickBudget(self: *Evaluator, span: ast.Span) StepError!void {
        if (self.budget_remaining == 0) {
            try self.diagFatal(span, "E_BAKE_BUDGET_EXCEEDED", "bake instruction budget exhausted — loop or recursion may be unbounded");
            return error.Fault;
        }
        self.budget_remaining -= 1;
    }

    fn diagFatal(
        self: *Evaluator,
        span: ast.Span,
        code: []const u8,
        message: []const u8,
    ) BakeError!void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .fatal,
            .code = code,
            .message = message,
            .span = span,
        });
    }

    /// Format-allocated variant for diagnostics that need
    /// interpolation. Caller passes the format string + args; we
    /// dupe the result onto the diagnostic arena (the caller's
    /// `allocator`, since the interpreter's diagnostics outlive
    /// it via `finalize`).
    fn diagFmt(
        self: *Evaluator,
        span: ast.Span,
        code: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) BakeError!void {
        const msg = try std.fmt.allocPrint(self.diag_arena.allocator(), fmt, args);
        try self.diagnostics.append(self.allocator, .{
            .severity = .fatal,
            .code = code,
            .message = msg,
            .span = span,
        });
    }

    /// Walk a statement list returning the value of the final
    /// expression statement (or `nil` for empty / non-expression
    /// tails). A `return` inside `body` short-circuits and
    /// surfaces its payload as the block's value.
    fn runBlock(self: *Evaluator, body: []const ast.Statement) StepError!BakeValue {
        var last: BakeValue = .nil_;
        for (body) |stmt| {
            try self.tickBudget(stmt.span());
            switch (stmt) {
                .let_decl => |d| try self.runLet(d),
                .const_decl => |d| try self.runConst(d),
                .return_stmt => |r| {
                    const v: BakeValue = if (r.value) |e| try self.evalExpr(e) else .nil_;
                    self.return_value = v;
                    return v;
                },
                .expr_stmt => |s| last = try self.evalExpr(s.expr),
                .assign => |a| try self.runAssign(a),
                .discard => |d| {
                    _ = try self.evalExpr(d.expr);
                },
                .if_stmt => |s| try self.runIfChain(s.arms, s.else_body),
                .while_stmt => |s| try self.runWhile(s),
                .for_stmt => |s| try self.runFor(s),
                .repeat_stmt => |s| try self.runRepeat(s),
                .break_stmt => self.loop_signal = .break_,
                .continue_stmt => self.loop_signal = .continue_,
                .block => |s| {
                    self.pushScope();
                    defer self.popScope();
                    last = try self.runBlock(s.body);
                },
                else => {
                    try self.diagFmt(stmt.span(), "E_BAKE_UNSUPPORTED", "bake interpreter does not yet support `{s}` statements", .{@tagName(stmt)});
                    return error.Fault;
                },
            }
            if (self.return_value != null or self.loop_signal != .none) return last;
        }
        return last;
    }

    fn runIfChain(self: *Evaluator, arms: []const ast.IfArm, else_body: ?[]const ast.Statement) StepError!void {
        for (arms) |arm| {
            // `if let` shapes aren't a bake idiom yet — the
            // typechecker's nullable rule rejects integer-optional
            // bindings, the main use case for `if let`. Plain
            // `cond` form is the supported shape.
            if (arm.cond == null) {
                try self.diagFatal(arm.span, "E_BAKE_UNSUPPORTED", "bake interpreter does not yet support `if let …` arms");
                return error.Fault;
            }
            const cond_val = try self.evalExpr(arm.cond.?);
            if (cond_val != .bool_) {
                try self.diagFatal(arm.span, "E_BAKE_TYPE", "bake: `if` condition must be `bool`");
                return error.Fault;
            }
            if (cond_val.bool_) {
                self.pushScope();
                defer self.popScope();
                _ = try self.runBlock(arm.body);
                return;
            }
        }
        if (else_body) |eb| {
            self.pushScope();
            defer self.popScope();
            _ = try self.runBlock(eb);
        }
    }

    fn runWhile(self: *Evaluator, s: ast.WhileStmt) StepError!void {
        if (s.cond == null) {
            try self.diagFatal(s.span, "E_BAKE_UNSUPPORTED", "bake interpreter does not yet support `while let …` loops");
            return error.Fault;
        }
        while (true) {
            try self.tickBudget(s.span);
            const cond_val = try self.evalExpr(s.cond.?);
            if (cond_val != .bool_) {
                try self.diagFatal(s.span, "E_BAKE_TYPE", "bake: `while` condition must be `bool`");
                return error.Fault;
            }
            if (!cond_val.bool_) return;
            self.pushScope();
            _ = try self.runBlock(s.body);
            self.popScope();
            if (self.return_value != null) return;
            if (self.loop_signal == .break_) {
                self.loop_signal = .none;
                return;
            }
            self.loop_signal = .none; // continue resets to fall-through
        }
    }

    fn runRepeat(self: *Evaluator, s: ast.RepeatStmt) StepError!void {
        while (true) {
            try self.tickBudget(s.span);
            self.pushScope();
            _ = try self.runBlock(s.body);
            self.popScope();
            if (self.return_value != null) return;
            if (self.loop_signal == .break_) {
                self.loop_signal = .none;
                return;
            }
            self.loop_signal = .none;
            const cond_val = try self.evalExpr(s.cond);
            if (cond_val != .bool_) {
                try self.diagFatal(s.span, "E_BAKE_TYPE", "bake: `repeat … until` condition must be `bool`");
                return error.Fault;
            }
            if (cond_val.bool_) return;
        }
    }

    fn runFor(self: *Evaluator, s: ast.ForStmt) StepError!void {
        // Only range iterators are supported in this slice;
        // array / Vec / iterator-protocol iteration lands with
        // aggregate codegen (commit 5+).
        if (s.iter.* != .range) {
            try self.diagFatal(s.span, "E_BAKE_UNSUPPORTED", "bake `for` only supports range iterators (`start..end` / `start..=end`) at this slice");
            return error.Fault;
        }
        const range = s.iter.range;
        const start = try self.evalExpr(range.start);
        const end = try self.evalExpr(range.end);
        if (start != .int_ or end != .int_) {
            try self.diagFatal(s.span, "E_BAKE_TYPE", "bake: range bounds must be integer");
            return error.Fault;
        }
        // safety: reinterpret u16 → i16 for the signed range bound.
        const start_i16: i16 = @bitCast(start.int_);
        // @as: widen i16 → i32 so the step loop holds large bounds.
        const start_signed: i32 = @as(i32, start_i16);
        // safety: same i16 reinterpret for the end bound.
        const end_i16: i16 = @bitCast(end.int_);
        // @as: widen i16 → i32 to match the start range.
        const end_signed: i32 = @as(i32, end_i16);
        const step_value: i32 = if (s.step) |st| step_blk: {
            const v = try self.evalExpr(st);
            if (v != .int_) {
                try self.diagFatal(s.span, "E_BAKE_TYPE", "bake: `step` value must be integer");
                return error.Fault;
            }
            // safety: signed reinterpret for the step value.
            const step_i16: i16 = @bitCast(v.int_);
            // @as: widen i16 → i32 to match start / end.
            break :step_blk @as(i32, step_i16);
        } else 1;
        if (step_value == 0) {
            try self.diagFatal(s.span, "E_BAKE_TYPE", "bake: `for` step cannot be zero");
            return error.Fault;
        }

        const name = self.lexeme(s.binding);
        var i: i32 = start_signed;
        while ((step_value > 0 and (if (range.inclusive) i <= end_signed else i < end_signed)) or
            (step_value < 0 and (if (range.inclusive) i >= end_signed else i > end_signed)))
        {
            try self.tickBudget(s.span);
            self.pushScope();
            // safety: i fits in i16 inside the loop range; truncate back to runtime width.
            const i16_val: i16 = @truncate(i);
            // safety: signed → unsigned bit reinterpret for storage.
            try self.bind(name, .{ .int_ = @bitCast(i16_val) });
            _ = try self.runBlock(s.body);
            self.popScope();
            if (self.return_value != null) return;
            if (self.loop_signal == .break_) {
                self.loop_signal = .none;
                return;
            }
            self.loop_signal = .none;
            i += step_value;
        }
    }

    fn runLet(self: *Evaluator, d: ast.LetDecl) StepError!void {
        const init_expr = d.init orelse {
            // Uninit `let x: T` binds `nil_` until the first assign.
            try self.bindFromPattern(d.pattern, .nil_, d.span);
            return;
        };
        const value = try self.evalExpr(init_expr);
        try self.bindFromPattern(d.pattern, value, d.span);
    }

    fn runConst(self: *Evaluator, d: ast.ConstDecl) StepError!void {
        const value = try self.evalExpr(d.init);
        try self.bind(self.lexeme(d.name), value);
    }

    fn bindFromPattern(self: *Evaluator, pat: *const ast.Pattern, value: BakeValue, span: ast.Span) StepError!void {
        switch (pat.*) {
            .ident => |i| try self.bind(self.lexeme(i.name), value),
            else => {
                try self.diagFmt(span, "E_BAKE_UNSUPPORTED", "bake interpreter only supports ident patterns in `let` (got `{s}`)", .{@tagName(pat.*)});
                return error.Fault;
            },
        }
    }

    fn runAssign(self: *Evaluator, a: ast.AssignStmt) StepError!void {
        // Ident target — direct binding update.
        if (a.target.* == .ident) {
            const value = try self.evalExpr(a.value);
            const name = self.lexeme(a.target.ident.span);
            const ok = try self.assignLocal(name, value);
            if (!ok) {
                try self.diagFmt(a.span, "E_UNDEFINED_SYMBOL", "bake: `{s}` is not bound in any enclosing scope", .{name});
                return error.Fault;
            }
            return;
        }
        // Indexed assignment — `arr[i] = v`. Walks back to the
        // ident at the array root and rebuilds the slice with
        // the new slot. BakeValues are copy-on-write internally
        // (the typecheck arena owns the array storage), so a fresh
        // slice is cheap; this keeps lookups by reference safe.
        if (a.target.* == .index) {
            try self.runIndexedAssign(a);
            return;
        }
        // Field-target assignment surfaces as a similar rebuild,
        // but bake bodies don't yet emit class / struct mutation
        // — the typechecker keeps that out of the in-bake scope.
        try self.diagFatal(a.span, "E_BAKE_UNSUPPORTED", "bake `=` only supports ident or `a[i]` targets at this slice");
        return error.Fault;
    }

    /// `arr[i] = v` rebuild path. Resolves the root ident, copies
    /// the array (or tuple) backing, swaps the slot, and writes the
    /// rebuilt value back to the scope. Multi-level (`a[i][j] = v`)
    /// nests recursively.
    fn runIndexedAssign(self: *Evaluator, a: ast.AssignStmt) StepError!void {
        const ix = a.target.index;
        const idx_val = try self.evalExpr(ix.index);
        if (idx_val != .int_) {
            try self.diagFatal(a.span, "E_BAKE_TYPE", "bake: index must be an integer");
            return error.Fault;
        }
        // safety: reinterpret as i16 so negative indices fault.
        const idx_signed: i16 = @bitCast(idx_val.int_);
        if (idx_signed < 0) {
            try self.diagFatal(a.span, "E_BAKE_INDEX_OUT_OF_BOUNDS", "bake: negative index");
            return error.Fault;
        }
        const idx: usize = @intCast(idx_signed);
        const new_value = try self.evalExpr(a.value);

        // Walk the receiver chain — only `ident[…] = v` lands as a
        // direct rebuild at this slice; nested receivers (`a[i][j]
        // = v`) would need a recursive zipper and aren't exercised
        // by the spec's lookup-table examples yet.
        if (ix.receiver.* != .ident) {
            try self.diagFatal(a.span, "E_BAKE_UNSUPPORTED", "bake `a[i] = v` only supports an ident receiver at this slice");
            return error.Fault;
        }
        const root_name = self.lexeme(ix.receiver.ident.span);
        const current = self.lookup(root_name) orelse {
            try self.diagFmt(a.span, "E_UNDEFINED_SYMBOL", "bake: `{s}` is not bound", .{root_name});
            return error.Fault;
        };
        const rebuilt = try self.rebuildAtIndex(current, idx, new_value, a.span);
        _ = try self.assignLocal(root_name, rebuilt);
    }

    fn rebuildAtIndex(self: *Evaluator, agg: BakeValue, idx: usize, new_value: BakeValue, span: ast.Span) StepError!BakeValue {
        return switch (agg) {
            .array => |xs| blk: {
                if (idx >= xs.len) {
                    try self.diagFatal(span, "E_BAKE_INDEX_OUT_OF_BOUNDS", "bake: array index out of bounds");
                    break :blk error.Fault;
                }
                const out = try self.diag_arena.allocator().alloc(BakeValue, xs.len);
                @memcpy(out, xs);
                out[idx] = new_value;
                break :blk .{ .array = out };
            },
            .tuple => |xs| blk: {
                if (idx >= xs.len) {
                    try self.diagFatal(span, "E_BAKE_INDEX_OUT_OF_BOUNDS", "bake: tuple index out of bounds");
                    break :blk error.Fault;
                }
                const out = try self.diag_arena.allocator().alloc(BakeValue, xs.len);
                @memcpy(out, xs);
                out[idx] = new_value;
                break :blk .{ .tuple = out };
            },
            else => blk: {
                try self.diagFatal(span, "E_BAKE_TYPE", "bake: indexed assign requires an array or tuple receiver");
                break :blk error.Fault;
            },
        };
    }

    // ---------- expressions ----------

    fn evalExpr(self: *Evaluator, e: *const ast.Expr) StepError!BakeValue {
        try self.tickBudget(e.span());
        return switch (e.*) {
            .int_lit => |l| blk: {
                // @as: parser stores int_lit as i32; truncate to i16 then reinterpret as u16 for storage.
                const truncated: i16 = @truncate(l.value);
                // safety: signed → unsigned bit reinterpret matches the runtime register layout.
                break :blk .{ .int_ = @bitCast(truncated) };
            },
            .fixed_lit => |l| blk: {
                // @as: same i32 → i16 truncate for the Q8.8 literal.
                const truncated: i16 = @truncate(l.value);
                // safety: signed → unsigned bit reinterpret.
                break :blk .{ .fixed_ = @bitCast(truncated) };
            },
            .bool_lit => |l| .{ .bool_ = l.value },
            .char_lit => |l| .{ .byte = l.value },
            .nil_lit => .nil_,
            .ident => |i| blk: {
                const name = self.lexeme(i.span);
                if (self.lookup(name)) |v| break :blk v;
                try self.diagFmt(i.span, "E_UNDEFINED_SYMBOL", "bake: `{s}` is not bound", .{name});
                return error.Fault;
            },
            .paren => |p| try self.evalExpr(p.inner),
            .unary => |u| try self.evalUnary(u),
            .binary => |b| try self.evalBinary(b),
            .do_expr => |d| try self.runDoExpr(d),
            .if_expr => |ie| try self.runIfExpr(ie),
            .list_lit => |ll| try self.evalListLit(ll),
            .list_repeat => |lr| try self.evalListRepeat(lr),
            .tuple_lit => |tl| try self.evalTupleLit(tl),
            .struct_lit => |sl| try self.evalStructLit(sl),
            .index => |ix| try self.evalIndex(ix),
            .field => |f| try self.evalField(f),
            .str_lit => |sl| try self.evalStrLit(sl),
            .call => |c| try self.evalCall(c),
            .method_call => |m| try self.evalMethodBake(m),
            else => {
                try self.diagFmt(e.span(), "E_BAKE_UNSUPPORTED", "bake interpreter does not yet support `{s}` expressions", .{@tagName(e.*)});
                return error.Fault;
            },
        };
    }

    /// A string literal (§3.8 — `str` is a bakeable output type).
    /// The value borrows the literal's raw source bytes; escape
    /// decoding happens where the bytes are interned, so a baked
    /// string and a runtime one resolve identically.
    ///
    /// A single literal run is the whole string in the common case.
    /// Adjacent runs only appear around an interpolation, which the
    /// evaluator has no formatter for.
    fn evalStrLit(self: *Evaluator, sl: ast.StrLitExpr) StepError!BakeValue {
        for (sl.parts) |p| {
            if (p == .interp) {
                try self.diagFatal(
                    p.interp.span,
                    "E_BAKE_UNSUPPORTED",
                    "bake: `$(…)` interpolation has no compile-time formatter — build the string at runtime, or bake the interpolated values and format them there",
                );
                return error.Fault;
            }
        }
        if (sl.parts.len == 0) return .{ .str = "" };
        const first = sl.parts[0].lit.span;
        const last = sl.parts[sl.parts.len - 1].lit.span;
        return .{ .str = self.source[first.start..last.end] };
    }

    fn runDoExpr(self: *Evaluator, d: ast.DoExpr) StepError!BakeValue {
        self.pushScope();
        defer self.popScope();
        return try self.runBlock(d.body);
    }

    /// Expression form of `if … then … [elif] [else] end`. The
    /// taken arm's block produces the value; an absent `else`
    /// with all-false arms surfaces `nil_` (matching the
    /// statement form's behavior).
    fn runIfExpr(self: *Evaluator, ie: ast.IfExpr) StepError!BakeValue {
        for (ie.arms) |arm| {
            if (arm.cond == null) {
                try self.diagFatal(arm.span, "E_BAKE_UNSUPPORTED", "bake interpreter does not yet support `if let …` arms");
                return error.Fault;
            }
            const cond_val = try self.evalExpr(arm.cond.?);
            if (cond_val != .bool_) {
                try self.diagFatal(arm.span, "E_BAKE_TYPE", "bake: `if` condition must be `bool`");
                return error.Fault;
            }
            if (cond_val.bool_) {
                self.pushScope();
                defer self.popScope();
                return try self.runBlock(arm.body);
            }
        }
        if (ie.else_body) |eb| {
            self.pushScope();
            defer self.popScope();
            return try self.runBlock(eb);
        }
        return .nil_;
    }

    fn evalUnary(self: *Evaluator, u: ast.UnaryExpr) StepError!BakeValue {
        const v = try self.evalExpr(u.operand);
        return switch (u.op) {
            .neg => switch (v) {
                // safety: two's-complement wrap is the runtime semantics; the bit pattern after `0 -% x` matches the runtime `neg` opcode.
                .int_ => |x| .{ .int_ = 0 -% x },
                // safety: same bit-wise negation for Q8.8.
                .fixed_ => |x| .{ .fixed_ = 0 -% x },
                else => {
                    try self.diagFatal(u.span, "E_BAKE_TYPE", "bake: unary `-` requires int or fixed");
                    return error.Fault;
                },
            },
            .log_not => switch (v) {
                .bool_ => |x| .{ .bool_ = !x },
                else => {
                    try self.diagFatal(u.span, "E_BAKE_TYPE", "bake: unary `not` requires bool");
                    return error.Fault;
                },
            },
            .bit_not => switch (v) {
                .int_ => |x| .{ .int_ = ~x },
                .byte => |x| .{ .byte = ~x },
                else => {
                    try self.diagFatal(u.span, "E_BAKE_TYPE", "bake: unary `~` requires integer");
                    return error.Fault;
                },
            },
        };
    }

    fn evalBinary(self: *Evaluator, b: ast.BinaryExpr) StepError!BakeValue {
        // Short-circuit logical ops — the rhs is only evaluated
        // when the lhs doesn't decide the result.
        switch (b.op) {
            .log_and => {
                const lhs = try self.expectBool(b.lhs, b.span);
                if (!lhs) return .{ .bool_ = false };
                return .{ .bool_ = try self.expectBool(b.rhs, b.span) };
            },
            .log_or => {
                const lhs = try self.expectBool(b.lhs, b.span);
                if (lhs) return .{ .bool_ = true };
                return .{ .bool_ = try self.expectBool(b.rhs, b.span) };
            },
            else => {},
        }

        const lhs = try self.evalExpr(b.lhs);
        const rhs = try self.evalExpr(b.rhs);

        // Comparison arms first — they accept every primitive
        // shape that's `eql`-comparable, no integer-only restrictions.
        switch (b.op) {
            .eq => return .{ .bool_ = bakeEql(lhs, rhs) },
            .neq => return .{ .bool_ = !bakeEql(lhs, rhs) },
            .lt, .lte, .gt, .gte => return try self.evalOrderingOp(b.op, lhs, rhs, b.span),
            else => {},
        }

        // Numeric arms — int + fixed, with int-int / fixed-fixed
        // separation per spec §4.2.1 (no implicit cross-shape mix).
        if (lhs == .int_ and rhs == .int_) return try self.evalIntArith(b.op, lhs.int_, rhs.int_, b.span);
        if (lhs == .fixed_ and rhs == .fixed_) return try self.evalFixedArith(b.op, lhs.fixed_, rhs.fixed_, b.span);
        try self.diagFatal(b.span, "E_BAKE_TYPE", "bake: binary op requires same-shape numeric operands (mixed `int`/`fixed` needs an explicit cast)");
        return error.Fault;
    }

    fn expectBool(self: *Evaluator, e: *const ast.Expr, span: ast.Span) StepError!bool {
        const v = try self.evalExpr(e);
        return switch (v) {
            .bool_ => |x| x,
            else => {
                try self.diagFatal(span, "E_BAKE_TYPE", "bake: expected `bool` operand");
                return error.Fault;
            },
        };
    }

    fn evalIntArith(self: *Evaluator, op: ast.BinaryOp, a: u16, c: u16, span: ast.Span) StepError!BakeValue {
        return switch (op) {
            .add => .{ .int_ = a +% c },
            .sub => .{ .int_ = a -% c },
            .mul => .{ .int_ = a *% c },
            .div, .mod => blk: {
                if (c == 0) {
                    try self.diagFatal(span, "E_BAKE_DIV_BY_ZERO", "bake: integer divide / modulo by zero");
                    return error.Fault;
                }
                // safety: signed division — reinterpret both sides as i16 so the result matches `divs`'s runtime semantics.
                const sa: i16 = @bitCast(a);
                // safety: same for the divisor.
                const sc: i16 = @bitCast(c);
                const q: i16 = @divTrunc(sa, sc);
                const r: i16 = @rem(sa, sc);
                // safety: signed → unsigned bit reinterpret for the storage cell.
                const q_u: u16 = @bitCast(q);
                // safety: same for the remainder.
                const r_u: u16 = @bitCast(r);
                break :blk if (op == .div) .{ .int_ = q_u } else .{ .int_ = r_u };
            },
            // safety: shift count masked to the low 4 bits so a >16 shift doesn't UB the host.
            .shl => .{ .int_ = a << @truncate(c & 0x0F) },
            .shr => .{ .int_ = a >> @truncate(c & 0x0F) },
            .bit_and => .{ .int_ = a & c },
            .bit_or => .{ .int_ = a | c },
            .bit_xor => .{ .int_ = a ^ c },
            else => {
                try self.diagFatal(span, "E_BAKE_TYPE", "bake: operator not valid for integer operands");
                return error.Fault;
            },
        };
    }

    fn evalFixedArith(self: *Evaluator, op: ast.BinaryOp, a: u16, c: u16, span: ast.Span) StepError!BakeValue {
        return switch (op) {
            // safety: Q8.8 add / sub align without rescaling.
            .add => .{ .fixed_ = a +% c },
            .sub => .{ .fixed_ = a -% c },
            .mul => blk: {
                // safety: unsigned → signed bit reinterpret for the Q8.8 multiplicand.
                const sa_i16: i16 = @bitCast(a);
                // @as: widen i16 → i32 so the product can hold the full Q16.16 result.
                const sa: i32 = @as(i32, sa_i16);
                // safety: same reinterpret for the multiplier.
                const sc_i16: i16 = @bitCast(c);
                // @as: widen i16 → i32 for the wide product.
                const sc: i32 = @as(i32, sc_i16);
                const wide: i32 = sa * sc;
                // safety: shift-right by 8 to renormalize Q8.8 product; truncate the renormalized i32 back to i16.
                const shifted: i16 = @truncate(wide >> 8);
                // safety: signed → unsigned bit reinterpret for the storage cell.
                break :blk .{ .fixed_ = @bitCast(shifted) };
            },
            .div => blk: {
                if (c == 0) {
                    try self.diagFatal(span, "E_BAKE_DIV_BY_ZERO", "bake: fixed-point divide by zero");
                    return error.Fault;
                }
                // safety: u16 → i16 reinterpret for the signed dividend.
                const sa_i16: i16 = @bitCast(a);
                // @as: widen i16 → i32 so `sa << 8` doesn't lose the high bits.
                const sa: i32 = @as(i32, sa_i16);
                // safety: u16 → i16 reinterpret for the divisor.
                const sc_i16: i16 = @bitCast(c);
                // @as: widen i16 → i32 to match the pre-scaled dividend.
                const sc: i32 = @as(i32, sc_i16);
                const wide: i32 = (sa << 8);
                // safety: truncating the i32 quotient back to i16 mirrors the runtime `divs` semantics.
                const q: i16 = @truncate(@divTrunc(wide, sc));
                // safety: signed → unsigned bit reinterpret for the storage cell.
                break :blk .{ .fixed_ = @bitCast(q) };
            },
            else => {
                try self.diagFatal(span, "E_BAKE_TYPE", "bake: operator not valid for fixed-point operands (only `+ - * /`)");
                return error.Fault;
            },
        };
    }

    fn evalOrderingOp(self: *Evaluator, op: ast.BinaryOp, lhs: BakeValue, rhs: BakeValue, span: ast.Span) StepError!BakeValue {
        const order: std.math.Order = switch (lhs) {
            .int_ => |x| switch (rhs) {
                .int_ => |y| blk: {
                    // safety: u16 → i16 reinterpret for the signed compare.
                    const xi: i16 = @bitCast(x);
                    // safety: same reinterpret for the rhs.
                    const yi: i16 = @bitCast(y);
                    break :blk std.math.order(xi, yi);
                },
                else => return self.orderMismatch(span),
            },
            .fixed_ => |x| switch (rhs) {
                .fixed_ => |y| blk: {
                    // safety: u16 → i16 reinterpret for Q8.8 ordering.
                    const xi: i16 = @bitCast(x);
                    // safety: same reinterpret for the Q8.8 rhs.
                    const yi: i16 = @bitCast(y);
                    break :blk std.math.order(xi, yi);
                },
                else => return self.orderMismatch(span),
            },
            .byte => |x| switch (rhs) {
                .byte => |y| std.math.order(x, y),
                else => return self.orderMismatch(span),
            },
            else => return self.orderMismatch(span),
        };
        const r: bool = switch (op) {
            .lt => order == .lt,
            .lte => order != .gt,
            .gt => order == .gt,
            .gte => order != .lt,
            // allow-strict: only the four ordering ops route into this fn.
            else => unreachable,
        };
        return .{ .bool_ = r };
    }

    fn orderMismatch(self: *Evaluator, span: ast.Span) StepError!BakeValue {
        try self.diagFatal(span, "E_BAKE_TYPE", "bake: ordering compare requires same-shape numeric operands");
        return error.Fault;
    }

    // ---------- aggregates ----------

    fn evalListLit(self: *Evaluator, ll: ast.ListLit) StepError!BakeValue {
        const out = try self.diag_arena.allocator().alloc(BakeValue, ll.elems.len);
        for (ll.elems, 0..) |e, i| out[i] = try self.evalExpr(e);
        return .{ .array = out };
    }

    fn evalListRepeat(self: *Evaluator, lr: ast.ListRepeatLit) StepError!BakeValue {
        const count_val = try self.evalExpr(lr.count);
        if (count_val != .int_) {
            try self.diagFatal(lr.span, "E_BAKE_TYPE", "bake: array-repeat count must be an integer");
            return error.Fault;
        }
        // safety: reinterpret as i16 so negatives surface as a fault instead of wrapping to a huge length.
        const count_signed: i16 = @bitCast(count_val.int_);
        if (count_signed < 0) {
            try self.diagFatal(lr.span, "E_BAKE_TYPE", "bake: array-repeat count must be non-negative");
            return error.Fault;
        }
        const n: usize = @intCast(count_signed);
        const proto = try self.evalExpr(lr.value);
        const out = try self.diag_arena.allocator().alloc(BakeValue, n);
        for (out) |*slot| slot.* = proto;
        return .{ .array = out };
    }

    fn evalTupleLit(self: *Evaluator, tl: ast.TupleLit) StepError!BakeValue {
        const out = try self.diag_arena.allocator().alloc(BakeValue, tl.elems.len);
        for (tl.elems, 0..) |e, i| out[i] = try self.evalExpr(e);
        return .{ .tuple = out };
    }

    fn evalStructLit(self: *Evaluator, sl: ast.StructLit) StepError!BakeValue {
        const out = try self.diag_arena.allocator().alloc(BakeValue.Field, sl.fields.len);
        for (sl.fields, 0..) |lf, i| {
            const v = try self.evalExpr(lf.value);
            out[i] = .{ .name = self.lexeme(lf.name), .value = v };
        }
        return .{ .struct_ = out };
    }

    fn evalIndex(self: *Evaluator, ix: ast.IndexExpr) StepError!BakeValue {
        const recv = try self.evalExpr(ix.receiver);
        const idx_val = try self.evalExpr(ix.index);
        if (idx_val != .int_) {
            try self.diagFatal(ix.span, "E_BAKE_TYPE", "bake: index must be an integer");
            return error.Fault;
        }
        // safety: reinterpret as i16 so negative indices fault rather than wrapping.
        const idx_signed: i16 = @bitCast(idx_val.int_);
        if (idx_signed < 0) {
            try self.diagFatal(ix.span, "E_BAKE_INDEX_OUT_OF_BOUNDS", "bake: negative index");
            return error.Fault;
        }
        const idx: usize = @intCast(idx_signed);
        return switch (recv) {
            .array => |xs| if (idx >= xs.len) blk: {
                try self.diagFatal(ix.span, "E_BAKE_INDEX_OUT_OF_BOUNDS", "bake: array index out of bounds");
                break :blk error.Fault;
            } else xs[idx],
            .tuple => |xs| if (idx >= xs.len) blk: {
                try self.diagFatal(ix.span, "E_BAKE_INDEX_OUT_OF_BOUNDS", "bake: tuple index out of bounds");
                break :blk error.Fault;
            } else xs[idx],
            else => blk: {
                try self.diagFatal(ix.span, "E_BAKE_TYPE", "bake: `[…]` requires an array or tuple receiver");
                break :blk error.Fault;
            },
        };
    }

    fn evalField(self: *Evaluator, f: ast.FieldExpr) StepError!BakeValue {
        const recv = try self.evalExpr(f.receiver);
        const name = self.lexeme(f.field);
        return switch (recv) {
            .struct_ => |flds| blk: {
                for (flds) |fld| {
                    if (std.mem.eql(u8, fld.name, name)) break :blk fld.value;
                }
                try self.diagFmt(f.span, "E_BAKE_UNDEFINED_FIELD", "bake: struct has no field `{s}`", .{name});
                break :blk error.Fault;
            },
            else => blk: {
                try self.diagFatal(f.span, "E_BAKE_TYPE", "bake: `.field` requires a struct receiver");
                break :blk error.Fault;
            },
        };
    }

    /// Dispatch a `call_expr` to a bake def lookup. The
    /// typechecker has already rejected non-`bake` callees with
    /// `E_BAKE_FORBIDDEN_CALL`; this defensively re-checks here.
    /// Stdlib allowlist is empty in this PR — `math.*` joins via
    /// the follow-up issue #284.
    fn evalCall(self: *Evaluator, c: ast.CallExpr) StepError!BakeValue {
        // `math.fn(args)` in field-callee form — compile-time math.
        if (c.callee.* == .field and c.callee.field.receiver.* == .ident and
            std.mem.eql(u8, self.lexeme(c.callee.field.receiver.ident.span), "math"))
        {
            return self.evalMathBuiltin(c.callee.field.field, c.args, c.span);
        }
        if (c.callee.* != .ident) {
            try self.diagFatal(c.span, "E_BAKE_UNSUPPORTED", "bake: only ident callees are supported (no method dispatch / closures)");
            return error.Fault;
        }
        const name = self.lexeme(c.callee.ident.span);
        const defs = self.bake_defs orelse {
            try self.diagFmt(c.span, "E_BAKE_FORBIDDEN_CALL", "bake: call to `{s}` — no bake-def registry available in this context", .{name});
            return error.Fault;
        };
        const decl = defs.get(name) orelse {
            try self.diagFmt(c.span, "E_BAKE_FORBIDDEN_CALL", "bake: `{s}` is not a `bake def`", .{name});
            return error.Fault;
        };

        // Evaluate args left-to-right into a scratch slice so the
        // callee's parameter scope binds against fully-resolved
        // BakeValues.
        const arg_buf = try self.diag_arena.allocator().alloc(BakeValue, c.args.len);
        for (c.args, 0..) |a, i| arg_buf[i] = try self.evalExpr(a);
        return try self.runDefCall(decl, arg_buf);
    }

    /// Push a fresh scope, bind parameters, walk the def body.
    /// Shared between the public `evaluateDef` entry point and
    /// in-bake `evalCall` dispatch — both want the same arg
    /// binding + return-value reset semantics.
    fn runDefCall(self: *Evaluator, decl: *const ast.DefDecl, args: []const BakeValue) StepError!BakeValue {
        if (args.len != decl.params.len) {
            try self.diagFmt(decl.name, "E_BAKE_ARG_COUNT", "bake: argument count mismatch on `{s}` (expected {d}, got {d})", .{ self.lexeme(decl.name), decl.params.len, args.len });
            return error.Fault;
        }
        // Save / restore the return-value slot so a callee's
        // `return` doesn't escape to the caller's body.
        const saved_return = self.return_value;
        self.return_value = null;
        defer self.return_value = saved_return;

        self.pushScope();
        defer self.popScope();
        for (decl.params, args) |p, v| try self.bind(self.lexeme(p.name), v);

        const tail = try self.runBlock(decl.body);
        return self.return_value orelse tail;
    }

    /// `recv.fn(args)` in method form. Only `math` is evaluable at bake
    /// time; `mem` / `bank` / `test` are runtime-only and fault.
    fn evalMethodBake(self: *Evaluator, m: ast.MethodCallExpr) StepError!BakeValue {
        if (m.receiver.* == .ident and std.mem.eql(u8, self.lexeme(m.receiver.ident.span), "math")) {
            return self.evalMathBuiltin(m.method, m.args, m.span);
        }
        try self.diagFatal(m.span, "E_BAKE_UNSUPPORTED", "bake: only `math.*` calls are evaluable at compile time");
        return error.Fault;
    }

    /// Operand signedness for the polymorphic helpers, from the
    /// threaded expression types (mirrors `math_builtin.argKind`).
    fn argKindBake(self: *Evaluator, e: *const ast.Expr) BakeKind {
        const t = if (self.expr_types) |m| m.get(e) else null;
        if (t == null or t.?.* != .primitive) return .signed;
        return switch (t.?.primitive) {
            .u16, .u8 => .unsigned,
            .fixed => .fixed,
            else => .signed,
        };
    }

    /// Compile-time `math.*`. Mirrors the runtime lowering's integer
    /// arithmetic exactly, so a bake-generated table matches the runtime.
    fn evalMathBuiltin(self: *Evaluator, name_span: ast.Span, args: []const *ast.Expr, span: ast.Span) StepError!BakeValue {
        const name = self.lexeme(name_span);
        if (std.mem.eql(u8, name, "rng")) {
            if (self.rng_state == 0) self.rng_state = 0xACE1;
            const lsb = self.rng_state & 1;
            self.rng_state >>= 1;
            if (lsb == 1) self.rng_state ^= 0xB400;
            return .{ .int_ = self.rng_state };
        }
        var raw: [3]u16 = .{ 0, 0, 0 };
        var arg0_fixed = false;
        for (args, 0..) |a, i| {
            const v = try self.evalExpr(a);
            const x: u16 = switch (v) {
                .int_ => |n| n,
                .fixed_ => |n| n,
                .byte => |n| n,
                else => 0,
            };
            if (i < 3) raw[i] = x;
            if (i == 0) arg0_fixed = v == .fixed_;
        }
        const kind: BakeKind = if (args.len > 0) self.argKindBake(args[0]) else .signed;
        var is_fixed = arg0_fixed;
        const result: u16 = b: {
            if (std.mem.eql(u8, name, "abs")) break :b bakeAbs(raw[0], kind);
            if (std.mem.eql(u8, name, "min")) break :b bakeMinMax(raw[0], raw[1], kind, true);
            if (std.mem.eql(u8, name, "max")) break :b bakeMinMax(raw[0], raw[1], kind, false);
            if (std.mem.eql(u8, name, "clamp")) break :b bakeMinMax(bakeMinMax(raw[0], raw[2], kind, true), raw[1], kind, false);
            if (std.mem.eql(u8, name, "wrap_add")) break :b raw[0] +% raw[1];
            if (std.mem.eql(u8, name, "wrap_sub")) break :b raw[0] -% raw[1];
            if (std.mem.eql(u8, name, "wrap_mul")) break :b bakeWrapMul(raw[0], raw[1], kind);
            if (std.mem.eql(u8, name, "sat_add")) break :b bakeSat(raw[0], raw[1], kind, .add);
            if (std.mem.eql(u8, name, "sat_sub")) break :b bakeSat(raw[0], raw[1], kind, .sub);
            if (std.mem.eql(u8, name, "sat_mul")) break :b bakeSat(raw[0], raw[1], kind, .mul);
            if (std.mem.eql(u8, name, "fixed_sin")) {
                is_fixed = true;
                break :b bakeFixedSin(raw[0]);
            }
            if (std.mem.eql(u8, name, "sqrt_fixed")) {
                is_fixed = true;
                break :b bakeSqrtFixed(raw[0]);
            }
            try self.diagFmt(span, "E_BAKE_UNSUPPORTED", "bake: `math.{s}` is not evaluable at compile time", .{name});
            return error.Fault;
        };
        return if (is_fixed) .{ .fixed_ = result } else .{ .int_ = result };
    }
};

/// Operand signedness for compile-time `math.*` (mirrors the runtime).
const BakeKind = enum { signed, unsigned, fixed };
const BakeSatOp = enum { add, sub, mul };

/// Reinterpret a u16 storage slot as its signed value.
fn sI16(raw: u16) i16 {
    // safety: u16 → i16 bit reinterpret; storage layout is shared.
    return @bitCast(raw);
}

/// Reinterpret a signed value back into u16 storage.
fn uBits(v: i16) u16 {
    // safety: i16 → u16 bit reinterpret back into storage.
    return @bitCast(v);
}

fn bakeAbs(raw: u16, kind: BakeKind) u16 {
    if (kind == .unsigned) return raw;
    return if (sI16(raw) < 0) 0 -% raw else raw; // wrapping negate (matches `neg`)
}

fn bakeMinMax(a: u16, b: u16, kind: BakeKind, want_min: bool) u16 {
    const a_lt_b = if (kind == .unsigned) a < b else sI16(a) < sI16(b);
    if (want_min) return if (a_lt_b) a else b;
    return if (a_lt_b) b else a;
}

fn bakeWrapMul(a: u16, b: u16, kind: BakeKind) u16 {
    if (kind != .fixed) return a *% b; // low 16 bits (signed + unsigned share them)
    const ai: i32 = sI16(a);
    const bi: i32 = sI16(b);
    const shifted: i32 = (ai * bi) >> 8; // Q8.8: drop the fractional byte
    // @as: keep the low 16 bits (product bits 8..23) as the wrapped result.
    const lo: i16 = @truncate(shifted);
    return uBits(lo);
}

fn bakeSat(a: u16, b: u16, kind: BakeKind, op: BakeSatOp) u16 {
    if (kind == .unsigned) {
        const av: i64 = a;
        const bv: i64 = b;
        const r: i64 = switch (op) {
            .add => av + bv,
            .sub => av - bv,
            .mul => av * bv,
        };
        if (r > 0xFFFF) return 0xFFFF;
        if (r < 0) return 0;
        // @as: clamped to [0, 0xFFFF] above.
        return @intCast(r);
    }
    const av: i64 = sI16(a);
    const bv: i64 = sI16(b);
    const r: i64 = switch (op) {
        .add => av + bv,
        .sub => av - bv,
        .mul => av * bv,
    };
    if (r > 32767) return 0x7FFF;
    if (r < -32768) return 0x8000;
    // @as: clamped to the i16 range above.
    const r16: i16 = @intCast(r);
    return uBits(r16);
}

/// Bhaskara I sine, identical to the runtime lowering (§5.3).
fn bakeFixedSin(deg_raw: u16) u16 {
    const deg: i32 = sI16(deg_raw);
    var x: i32 = @mod(deg, 360);
    var negate = false;
    if (x >= 180) {
        negate = true;
        x -= 180;
    }
    const prod: i32 = x * (180 - x);
    const den: i32 = @divFloor(40500 - prod, 2);
    var result: i32 = @divTrunc(512 * prod, den);
    if (negate) result = -result;
    // @as: |result| ≤ 256, fits i16.
    const r16: i16 = @intCast(result);
    return uBits(r16);
}

/// Bit-by-bit Q8.8 square root, identical to the runtime lowering.
fn bakeSqrtFixed(x_raw: u16) u16 {
    if (sI16(x_raw) <= 0) return 0;
    const xw: u32 = x_raw;
    const n: u32 = xw << 8;
    var r: u32 = 0;
    var bit: u32 = 2048;
    while (bit != 0) : (bit >>= 1) {
        const cand = r | bit;
        if (cand * cand <= n) r = cand;
    }
    // @as: result < 4096, fits u16.
    return @intCast(r);
}

/// Byte width of a serialized `BakeValue`. Mirrors the runtime
/// layout (`widthOfTypeAnn`) with aggregate sizes summed.
pub fn widthOf(v: BakeValue) usize {
    return switch (v) {
        .int_, .fixed_ => 2,
        .bool_, .byte, .nil_ => 1,
        .str => 2, // a pointer into the interned string pool
        .array => |xs| if (xs.len == 0) 0 else widthOf(xs[0]) * xs.len,
        .tuple => |xs| blk: {
            var total: usize = 0;
            for (xs) |elem| total += widthOf(elem);
            break :blk total;
        },
        .struct_ => |flds| blk: {
            var total: usize = 0;
            for (flds) |f| total += widthOf(f.value);
            break :blk total;
        },
    };
}

/// Where a `str` landed inside a serialized value: the byte offset
/// of its 2-byte pointer slot, and the literal's bytes. The caller
/// interns the bytes and writes the resolved address into the slot,
/// since pool addresses aren't known while the value serializes.
pub const StrSlot = struct {
    offset: usize,
    bytes: []const u8,
};

/// Serialize a `BakeValue` into little-endian bytes per the
/// runtime layout (ISA §5). Writes into `out` starting at index
/// 0 and returns the number of bytes written. Caller sizes `out`
/// via `widthOf` first.
///
/// Every `str` reached — including one nested in a struct, array,
/// or tuple — appends a `StrSlot` to `str_slots` and leaves its
/// pointer slot zeroed for the caller to patch.
pub fn serialize(
    v: BakeValue,
    out: []u8,
    str_slots: *std.ArrayList(StrSlot),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!usize {
    return serializeAt(v, out, 0, str_slots, allocator);
}

/// `serialize`'s recursive half. `base` is the offset of `out[0]`
/// within the whole value, so a nested `str` records where its
/// pointer sits in the finished buffer rather than in its subslice.
fn serializeAt(
    v: BakeValue,
    out: []u8,
    base: usize,
    str_slots: *std.ArrayList(StrSlot),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!usize {
    return switch (v) {
        .int_ => |x| writeLeU16(out, x),
        .fixed_ => |x| writeLeU16(out, x),
        .byte => |x| writeLeU8(out, x),
        .bool_ => |x| writeLeU8(out, if (x) 1 else 0),
        .nil_ => writeLeU8(out, 0),
        .str => |bytes| blk: {
            try str_slots.append(allocator, .{ .offset = base, .bytes = bytes });
            break :blk writeLeU16(out, 0);
        },
        .array => |xs| try writeSlice(xs, out, base, str_slots, allocator),
        .tuple => |xs| try writeSlice(xs, out, base, str_slots, allocator),
        .struct_ => |flds| blk: {
            var off: usize = 0;
            for (flds) |f| off += try serializeAt(f.value, out[off..], base + off, str_slots, allocator);
            break :blk off;
        },
    };
}

fn writeLeU16(out: []u8, v: u16) usize {
    // safety: u16 → two LE bytes; truncate is bit-mask, no loss.
    out[0] = @truncate(v & 0xFF);
    // safety: high byte of the u16.
    out[1] = @truncate(v >> 8);
    return 2;
}

fn writeLeU8(out: []u8, v: u8) usize {
    out[0] = v;
    return 1;
}

fn writeSlice(
    xs: []const BakeValue,
    out: []u8,
    base: usize,
    str_slots: *std.ArrayList(StrSlot),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!usize {
    var off: usize = 0;
    for (xs) |v| off += try serializeAt(v, out[off..], base + off, str_slots, allocator);
    return off;
}

/// Convert a literal expression to a `BakeValue`. Returns `null`
/// for non-literal shapes.
pub fn literalAsBakeValue(source: []const u8, e: *const ast.Expr) ?BakeValue {
    _ = source;
    return switch (e.*) {
        .int_lit => |l| blk: {
            // @as: parser stores int_lit as i32; truncate to runtime i16.
            const truncated: i16 = @truncate(l.value);
            // safety: signed → unsigned bit reinterpret for storage.
            break :blk .{ .int_ = @bitCast(truncated) };
        },
        .fixed_lit => |l| blk: {
            // @as: same i32 → i16 truncate for Q8.8 storage.
            const truncated: i16 = @truncate(l.value);
            // safety: signed → unsigned bit reinterpret.
            break :blk .{ .fixed_ = @bitCast(truncated) };
        },
        .bool_lit => |l| .{ .bool_ = l.value },
        .char_lit => |l| .{ .byte = l.value },
        .nil_lit => .nil_,
        else => null,
    };
}

/// Deep-clone a `BakeValue` onto `arena`. Used to migrate values
/// off the evaluator's diag arena onto the codegen's.
pub fn cloneBakeValue(arena: std.mem.Allocator, v: BakeValue) BakeError!BakeValue {
    return switch (v) {
        .int_, .fixed_, .bool_, .nil_, .byte => v,
        .str => |s| .{ .str = try arena.dupe(u8, s) },
        .array => |xs| blk: {
            const out = try arena.alloc(BakeValue, xs.len);
            for (xs, 0..) |elem, i| out[i] = try cloneBakeValue(arena, elem);
            break :blk .{ .array = out };
        },
        .tuple => |xs| blk: {
            const out = try arena.alloc(BakeValue, xs.len);
            for (xs, 0..) |elem, i| out[i] = try cloneBakeValue(arena, elem);
            break :blk .{ .tuple = out };
        },
        .struct_ => |flds| blk: {
            const out = try arena.alloc(BakeValue.Field, flds.len);
            for (flds, 0..) |f, i| out[i] = .{
                .name = try arena.dupe(u8, f.name),
                .value = try cloneBakeValue(arena, f.value),
            };
            break :blk .{ .struct_ = out };
        },
    };
}

fn bakeEql(a: BakeValue, b: BakeValue) bool {
    return switch (a) {
        .int_ => |x| b == .int_ and b.int_ == x,
        .fixed_ => |x| b == .fixed_ and b.fixed_ == x,
        .bool_ => |x| b == .bool_ and b.bool_ == x,
        .nil_ => b == .nil_,
        .byte => |x| b == .byte and b.byte == x,
        .str => |x| b == .str and std.mem.eql(u8, x, b.str),
        // Aggregate equality is not exercised by the language's
        // `==` arms today; bake matches that behavior.
        .array, .tuple, .struct_ => false,
    };
}
