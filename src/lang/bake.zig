/// Compile-time evaluator for `bake def` / `bake do` bodies per
/// spec §3.8. The typechecker has already enforced the structural
/// restrictions (no MMIO, no asm, no non-bake calls, no Vec /
/// class results); this module runs the post-check AST against a
/// `BakeValue` interpreter and serializes the final value into
/// static-data bytes the codegen interns.
///
/// Restricted on purpose: bake bodies are a strict subset of the
/// runtime. No allocator beyond the arena passed in, no host I/O,
/// no FFI. The interpreter trades runtime efficiency for
/// determinism — `gero check` must produce identical baked bytes
/// across machines and build modes.
const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");
const diag_mod = @import("diagnostic.zig");

const Diagnostic = diag_mod.Diagnostic;

/// Default upper bound on AST-walk steps per `bake` invocation.
/// One step = one statement walked or one expression evaluated;
/// loops bump the counter per iteration body. 100M matches the
/// spec's stated default budget and runs in ~1s on a developer
/// laptop for sane lookup-table builds.
pub const default_budget: u32 = 100_000_000;

/// One value produced by the bake interpreter. The shape mirrors
/// the spec's "bakeable types" list (§3.8): primitive scalars,
/// `[T; N]` arrays, tuples, and POD structs. Strings live in the
/// usual interned pool — they're represented here as the byte
/// slice the codegen later writes into the data segment.
///
/// `Vec(T)`, classes, references, and function pointers are
/// unrepresentable here; the typechecker rejects them via
/// `predicates.isBakeableType` before the interpreter ever runs.
pub const BakeValue = union(enum) {
    /// 16-bit integer. Sign interpretation follows the value's
    /// declared type at the binding / parameter level; the
    /// interpreter stores the bits without committing to either
    /// signed or unsigned semantics until serialization.
    int_: u16,
    /// Q8.8 fixed-point value — same bit layout as the runtime
    /// `fixed` primitive (ISA §5.4.1).
    fixed_: u16,
    /// `bool` — `false = 0`, `true = 1`.
    bool_: bool,
    /// `nil` — the unit value; mostly returned from blocks that
    /// produce no useful result.
    nil_,
    /// 8-bit byte slot used by `u8` / `i8` / `char`.
    byte: u8,
    /// String literal — points at interned source bytes (the
    /// codegen later interns into its string pool).
    str: []const u8,
    /// Fixed-length array — every element shares a single shape.
    array: []const BakeValue,
    /// Heterogeneous tuple — per-slot shapes recorded inline.
    tuple: []const BakeValue,
    /// POD struct — `fields[i].name` is the source-buffer slice,
    /// `fields[i].value` the bound value.
    struct_: []const Field,

    /// One named slot inside a `struct_` value. `name` borrows
    /// from the source buffer; `value` lives on the evaluator's
    /// diag arena until the codegen clones it onto its own.
    pub const Field = struct {
        name: []const u8,
        value: BakeValue,
    };
};

/// Errors the bake driver can return. Semantic violations (budget
/// overrun, unbakeable shape, missing binding) land in the
/// `diagnostics` slice on `Result` — only true host failures
/// propagate through the error union.
pub const BakeError = error{OutOfMemory};

/// Outcome of running the interpreter on one `bake def` /
/// `bake do` site. `value` is `null` when evaluation failed; the
/// caller treats that as a hard stop and skips the codegen path.
///
/// `diag_arena` backs every `Diagnostic.message` string that the
/// evaluator built via formatting — call `deinit(alloc)` once
/// done. The slice itself was allocated through the same `alloc`,
/// so a single deinit releases both.
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
            .call => |c| try self.evalCall(c),
            else => {
                try self.diagFmt(e.span(), "E_BAKE_UNSUPPORTED", "bake interpreter does not yet support `{s}` expressions", .{@tagName(e.*)});
                return error.Fault;
            },
        };
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
};

/// Compute the byte width of a `BakeValue` when serialized into
/// static data. Mirrors the runtime layout the typechecker's
/// `widthOfTypeAnn` would produce for the same shape, with
/// aggregate sizes summed from the actual values. Used by the
/// codegen to allocate the right number of bytes in the data
/// region before writing the serialized blob.
pub fn widthOf(v: BakeValue) usize {
    return switch (v) {
        .int_, .fixed_ => 2,
        .bool_, .byte, .nil_ => 1,
        .str => 2, // interned string pointer (placeholder — codegen interns the bytes).
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

/// Serialize a `BakeValue` into little-endian bytes per the
/// runtime layout (ISA §5). Writes into `out` starting at index
/// 0 and returns the number of bytes written. Caller sizes `out`
/// via `widthOf` first.
pub fn serialize(v: BakeValue, out: []u8) usize {
    return switch (v) {
        .int_ => |x| writeLeU16(out, x),
        .fixed_ => |x| writeLeU16(out, x),
        .byte => |x| writeLeU8(out, x),
        .bool_ => |x| writeLeU8(out, if (x) 1 else 0),
        .nil_ => writeLeU8(out, 0),
        // Strings are pointer-width — the codegen handles
        // pool resolution before the value reaches `serialize`
        // (slice-N+1 follow-up). For now the slot stays zero.
        .str => writeLeU16(out, 0),
        .array => |xs| writeSlice(xs, out),
        .tuple => |xs| writeSlice(xs, out),
        .struct_ => |flds| blk: {
            var off: usize = 0;
            for (flds) |f| off += serialize(f.value, out[off..]);
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

fn writeSlice(xs: []const BakeValue, out: []u8) usize {
    var off: usize = 0;
    for (xs) |v| off += serialize(v, out[off..]);
    return off;
}

/// Best-effort conversion of a literal expression to a
/// `BakeValue` — used by the codegen when a top-level
/// `const X = bake_def(args)` init needs to evaluate `args`
/// without standing up a full evaluator. Returns `null` for any
/// non-literal shape; the caller then emits a clear diagnostic.
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

/// Deep-clone a `BakeValue` into the destination allocator. The
/// interpreter's diag arena owns the temporaries during
/// evaluation; once we return to the codegen we re-allocate
/// onto the codegen's arena so the value survives past
/// `Result.deinit`.
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
