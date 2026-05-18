/// Closure lowering — lambda body emission, capture analysis,
/// heap-cell promotion for mutated/escaping captures, and the
/// closure invocation path.
///
/// **Value model.** A closure value is a 2-byte pointer to a
/// heap tuple shaped `(fn_ptr: u16, capture_0: u16, capture_1: u16, ...)`.
/// The fn_ptr at offset 0 is the address of the lambda body
/// (emitted as a regular def with a mangled `__lambda_N` label
/// and a hidden first param `env_ptr`).
///
/// **Capture analysis.** For each fn body the codegen emits,
/// `analyzeFn` walks the body looking for:
///   - All `let` / `const` bindings in the parent fn.
///   - All lambda expressions in the body — for each, the set of
///     free identifiers (used in the lambda body but declared in
///     the parent scope).
///   - Whether each captured binding is mutated (assigned anywhere
///     in the parent, or inside another lambda over the same
///     binding).
///   - Whether any lambda escapes (is the operand of a `return`).
///
/// A binding is **promoted** (heap-cell-allocated) when it's
/// captured AND (mutated OR captured by an escaping lambda).
/// Promoted bindings:
///   - Allocate a 2-byte heap cell at `let` time via `sys alloc`.
///   - The cell address lives in the local slot.
///   - Reads / writes go through cell deref / store (one extra
///     indirection vs. a normal local).
///   - Closures over a promoted binding capture the cell pointer
///     (shared state).
///
/// Non-promoted captures get a by-value copy at closure-creation
/// time: the tuple slot holds the captured value, frozen at the
/// moment the lambda expression evaluated.
///
/// **Call site.** `f(args)` where `f` is a closure binding:
///   1. Load closure ptr into `r1`.
///   2. Load fn_ptr from `[r1 + 0]` into `r3`.
///   3. Push user args right-to-left.
///   4. Push `r1` (closure ptr) as hidden first arg.
///   5. `call_reg r3`.
///   6. Drop args (1 + user args, 2 bytes each).
///
/// Inside the lambda body, `env_ptr` is the implicit first param
/// (fp + 4). Captures are loaded from `[env_ptr + 2 + N*2]` —
/// for non-promoted captures that's the value directly; for
/// promoted captures it's the cell pointer, which the body
/// derefs on use.
const std = @import("std");
const ast = @import("../ast.zig");
const opcodes = @import("opcodes.zig");
const codegen_mod = @import("../codegen.zig");

const Emitter = codegen_mod.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// Per-fn analysis result. Built by `analyzeFn` before the body
/// emits; consulted by `emitLetDecl` / `emitIdent` / `emitAssign`
/// to route through the heap-cell path for promoted bindings,
/// and by `emitLambdaExpr` / `emitLambdaBodies` to lay out the
/// closure tuples and emit the bodies.
pub const FnClosureInfo = struct {
    /// Names of let / const / param bindings in this fn that must
    /// live as heap cells.
    promoted: std.StringHashMapUnmanaged(void),
    /// Lambdas encountered in the fn body, including nested ones.
    /// Order is "leaf-first" — a nested lambda registers before
    /// its enclosing lambda (because the enclosing arm recurses
    /// into the body before appending itself). Labels are unique
    /// across the whole def via `next_lambda_id`, not the items
    /// length, so the depth-first registration order doesn't
    /// cause label collisions.
    lambdas: std.ArrayListUnmanaged(LambdaInfo),
    /// Monotonic counter for mangled labels. Incremented at
    /// every `findLambdasInExpr` lambda arm entry — BEFORE the
    /// recursion into the body — so an outer lambda and any
    /// nested ones each get a distinct id even though the outer's
    /// arm captures the id pre-recursion.
    next_lambda_id: u32,
    /// Names of let bindings whose init is a lambda — used at
    /// call sites to detect `f(args)` should dispatch as a
    /// closure call vs a free-fn call.
    closure_bindings: std.StringHashMapUnmanaged(void),
};

/// One lambda discovered during `analyzeFn` — drives both the
/// closure-creation site (which slots get what) and the body
/// emission (the env-relative offsets for each capture).
pub const LambdaInfo = struct {
    /// AST pointer for identity — `emitLambdaExpr` looks up its
    /// own info via this pointer when emitting the closure-
    /// creation code; `emitLambdaBodies` walks the list in order.
    ast_node: *const ast.LambdaExpr,
    /// Mangled label — `__lambda_<fn_name>_<index>`.
    label: []const u8,
    /// Captured binding names in slot order. Slot index N maps to
    /// tuple offset `2 + N*2` (offset 0 is fn_ptr).
    captures: std.ArrayListUnmanaged([]const u8),
    /// Bindings declared inside THIS lambda's body that need a
    /// heap cell — captured-by-some-inner-lambda AND
    /// (mutated OR captured by an escaping inner lambda).
    /// Swapped into `fn_closure_info.promoted` while this body
    /// emits so `emitLetDecl` / `emitAssign` route through the
    /// cell path for the right scope.
    promoted: std.StringHashMapUnmanaged(void),
    /// Bindings declared inside THIS lambda's body whose init is
    /// a lambda — swapped into `fn_closure_info.closure_bindings`
    /// while this body emits so nested `f(args)` dispatches
    /// through the closure-call path.
    closure_bindings: std.StringHashMapUnmanaged(void),
};

/// Walk `def` body, populate `Emitter.fn_closure_info` with the
/// lambda inventory + capture layout + promotion set. Call before
/// emitting the body so the let/ident/assign hooks can consult it.
///
/// `@no_capture` short-circuits promotion entirely:
/// the typechecker has already rejected any capture-and-mutate
/// shape, but a read-only escape could still trigger heap
/// promotion under the regular rules — and a hidden alloc is
/// exactly what `@no_capture` forbids. So inside such a def
/// every capture stays by-value regardless of escape status.
pub fn analyzeFn(self: *Emitter, def: *const ast.DefDecl) !void {
    var info: FnClosureInfo = .{
        .promoted = .{},
        .lambdas = .empty,
        .next_lambda_id = 0,
        .closure_bindings = .{},
    };

    // Collect local binding names + closure-init bindings from the
    // top-level statements of the fn body. (Nested scopes use the
    // same parent locals — gero's frame allocates them all up front.)
    var local_bindings: std.StringHashMapUnmanaged(void) = .{};
    for (def.body) |stmt| collectLocalsFromStatement(self, stmt, &local_bindings, &info) catch {};
    for (def.params) |p| {
        const name = self.source[p.name.start..p.name.end];
        try local_bindings.put(self.arena, name, {});
    }

    // Find every lambda in the body + its captures.
    for (def.body) |stmt| try findLambdasInStatement(self, stmt, def, &info);

    const no_capture = codegen_mod.defHasFlagAnnotation(self.source, def, "no_capture");
    if (!no_capture) {
        // Decide promotion. A binding is promoted if it's captured
        // by some lambda AND (mutated anywhere OR captured by a
        // lambda that escapes).
        var mutated: std.StringHashMapUnmanaged(void) = .{};
        for (def.body) |stmt| collectMutatedInStatement(self, stmt, &mutated);

        var escaping_captures: std.StringHashMapUnmanaged(void) = .{};
        for (def.body) |stmt| collectEscapingCaptures(self, stmt, &info, &escaping_captures);

        for (info.lambdas.items) |li| {
            for (li.captures.items) |cap| {
                if (!local_bindings.contains(cap)) continue;
                if (mutated.contains(cap) or escaping_captures.contains(cap)) {
                    try info.promoted.put(self.arena, cap, {});
                }
            }
        }
    }

    self.fn_closure_info = info;
}

/// Reset the per-fn analysis between defs.
pub fn resetFnInfo(self: *Emitter) void {
    self.fn_closure_info = .{
        .promoted = .{},
        .lambdas = .empty,
        .next_lambda_id = 0,
        .closure_bindings = .{},
    };
}

/// `true` when `name` was promoted to a heap cell in the current fn.
pub fn isPromoted(self: *const Emitter, name: []const u8) bool {
    return self.fn_closure_info.promoted.contains(name);
}

/// `true` when `name` is bound to a closure value in the current
/// fn (drives closure-call dispatch at `name(args)` sites).
pub fn isClosureBinding(self: *const Emitter, name: []const u8) bool {
    return self.fn_closure_info.closure_bindings.contains(name);
}

/// `true` when `e` is an ident bound to a local / param / capture
/// whose inferred type is a function — covers cases where a
/// closure flowed in from a fn's return value (`let c =
/// make_counter()`) or where the ident is a capture re-read from
/// the enclosing env in a nested lambda body. Free-fn idents and
/// class constructors type as function too but dispatch via
/// direct call, so they're excluded.
pub fn isClosureByType(self: *const Emitter, e: *const ast.Expr) bool {
    if (e.* != .ident) return false;
    const name = self.source[e.ident.span.start..e.ident.span.end];
    if (self.fn_addresses.contains(name)) return false;
    if (self.class_decls.contains(name)) return false;
    const has_binding =
        self.locals.contains(name) or
        self.params.contains(name) or
        self.captures.contains(name);
    if (!has_binding) return false;
    const ty = self.typeOf(e) orelse return false;
    return ty.* == .function;
}

// ---------- promotion-aware let / ident / assign helpers ----------

/// Initial value of a promoted local: allocate a 2-byte cell,
/// optionally seed it with the init expression, store the cell
/// pointer in the local slot.
pub fn emitPromotedLetInit(
    self: *Emitter,
    init: ?*const ast.Expr,
    slot_ofs: i8,
) !void {
    // Allocate a 2-byte cell on the heap.
    try self.movImmToReg(2, Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(Sys.alloc);
    // acu = cell pointer; store it in the local slot.
    try self.movRegToRegOffset(Reg.acu, Reg.fp, slot_ofs);
    // Seed the cell with the init value when present.
    if (init) |init_expr| {
        try self.movRegToReg(Reg.acu, Reg.r1); // r1 = cell ptr
        try self.pushReg(Reg.r1);
        try self.emitExpr(init_expr); // acu = init value
        try self.popReg(Reg.r1);
        try cellStore(self, Reg.r1, Reg.acu);
    }
}

/// Read a promoted local: load cell pointer from slot, then deref.
pub fn emitPromotedIdentLoad(self: *Emitter, slot_ofs: i8) !void {
    try self.movRegOffsetToReg(Reg.fp, slot_ofs, Reg.r1);
    try cellLoad(self, Reg.r1, Reg.acu);
}

/// Write a promoted local: evaluate value into acu, push, load
/// the cell pointer, deref-write.
pub fn emitPromotedAssign(self: *Emitter, slot_ofs: i8, value: *const ast.Expr) !void {
    try self.emitExpr(value);
    try self.pushReg(Reg.acu);
    try self.movRegOffsetToReg(Reg.fp, slot_ofs, Reg.r1);
    try self.popReg(Reg.r2);
    try cellStore(self, Reg.r1, Reg.r2);
}

fn cellLoad(self: *Emitter, ptr_reg: u8, dst: u8) !void {
    // mov [ptr], dst (word load via pointer register).
    try self.emitByte(Op.mov_ptr_to_reg);
    try self.emitByte(dst);
    try self.emitByte(ptr_reg);
}

fn cellStore(self: *Emitter, ptr_reg: u8, src: u8) !void {
    // mov src → [ptr] (word store via pointer register).
    try self.emitByte(Op.mov_reg_to_ptr);
    try self.emitByte(ptr_reg);
    try self.emitByte(src);
}

// ---------- lambda expression site ----------

/// Lower a `LambdaExpr` — bump-allocate the tuple, fill it with
/// the fn_ptr + capture slots, leave the tuple pointer in `acu`.
pub fn emitLambdaExpr(self: *Emitter, lambda: ast.LambdaExpr, expr: *const ast.Expr) !void {
    const li = findLambdaInfo(self, expr) orelse {
        try self.diagFatal(lambda.span, "E_CODEGEN_LAMBDA_NOT_ANALYZED", "codegen: internal — lambda missing from analyzeFn pass");
        return;
    };

    // @as: tuple size = 2 (fn_ptr) + 2*N (capture slots). N caps well below 32k by parser limits.
    const tuple_size: u16 = 2 + @as(u16, @intCast(li.captures.items.len * 2));
    try self.movImmToReg(tuple_size, Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(Sys.alloc);
    // acu = tuple ptr; stash in r1 for the populate phase.
    try self.movRegToReg(Reg.acu, Reg.r1);

    // Write fn_ptr at offset 0 — placeholder, patched when the
    // lambda body emits at the end of the fn pass.
    try self.emitByte(Op.mov_imm16_reg);
    const fn_slot = try self.currentOffset();
    try self.emitU16Le(0);
    try self.emitByte(Reg.r2);
    try self.lambda_patches.append(self.allocator, .{
        .bank = self.current_bank,
        .code_offset = fn_slot,
        .label = li.label,
    });
    try self.emitByte(Op.mov_reg_to_ptr);
    try self.emitByte(Reg.r1);
    try self.emitByte(Reg.r2);

    // Populate each capture slot. Capture[N] lives at offset
    // `2 + N*2`. Promoted captures: store the cell pointer.
    // Non-promoted: store the current value.
    for (li.captures.items, 0..) |cap, idx| {
        // @as: idx fits u16 — capture count caps below 32k.
        const slot_offset: u16 = 2 + @as(u16, @intCast(idx)) * 2;
        try self.pushReg(Reg.r1); // preserve tuple ptr
        try emitCaptureSource(self, cap);
        try self.popReg(Reg.r1);
        // acu = capture value (cell ptr if promoted, value otherwise)
        try emitWordStoreAtOffset(self, Reg.r1, slot_offset, Reg.acu);
    }

    // Result: tuple ptr in acu.
    try self.movRegToReg(Reg.r1, Reg.acu);
}

/// Load a capture's source value into `acu` at closure-creation
/// time. The slot semantics are deliberately "raw" — for a
/// promoted binding that's the cell pointer (so the inner
/// closure shares state with the parent), for a non-promoted
/// binding that's the value (re-copied into the new closure).
/// The lookup order — captures → locals → params → globals —
/// lets nested closures chain: a closure created INSIDE another
/// lambda's body reads its captures from the enclosing env
/// rather than a stack slot that doesn't exist at this scope.
fn emitCaptureSource(self: *Emitter, name: []const u8) !void {
    if (self.captures.get(name)) |slot| {
        // Inside an enclosing lambda — re-read this slot raw
        // from our own env to populate the inner closure's slot.
        // For promoted (cell-pointer) captures the pointer
        // propagates as-is (shared state); for by-value captures
        // the value re-copies.
        try loadEnvPtr(self, Reg.r1);
        try emitWordLoadAtOffset(self, Reg.r1, slot.env_offset, Reg.acu);
        return;
    }
    if (self.locals.get(name)) |ofs| {
        try self.movRegOffsetToReg(Reg.fp, ofs, Reg.acu);
        return;
    }
    if (self.params.get(name)) |ofs| {
        try self.movRegOffsetToReg(Reg.fp, ofs, Reg.acu);
        return;
    }
    if (self.globals.get(name)) |g| {
        try self.emitGlobalLoad(g);
        return;
    }
    // Unbound at this point — analyzeFn shouldn't have recorded
    // it as a capture. Defensive fault.
    try self.diagFatal(.{ .start = 0, .end = 0 }, "E_CODEGEN_UNBOUND_CAPTURE", "codegen: lambda captures a name with no current binding");
}

// ---------- lambda body emission ----------

/// Emit each lambda body in the current fn's analysis as a
/// separate def with a mangled label. Hidden first param is
/// `env_ptr` (the closure tuple). Captures are accessed via
/// `env_ptr + 2 + N*2` inside the body.
///
/// Runs at the end of `emitDefWithLabel` so the bodies sit
/// adjacent to the parent fn in the code buffer — call-patches
/// pick up their addresses normally.
pub fn emitLambdaBodies(self: *Emitter, def: *const ast.DefDecl) !void {
    // Snapshot the lambda list — emitting bodies may mutate
    // fn_closure_info if a lambda itself contains lambdas, but
    // for this PR we don't recurse into nested-lambda capture
    // analysis (a known limit; the typechecker's @no_capture
    // already constrains deep nesting in @no_capture defs).
    const lambdas = self.fn_closure_info.lambdas.items;
    _ = def;
    for (lambdas) |li| {
        try emitOneLambdaBody(self, li);
    }
}

fn emitOneLambdaBody(self: *Emitter, li: LambdaInfo) !void {
    const lambda = li.ast_node;

    // Save + restore per-fn state — identical to emitDefWithLabel
    // but with a synthetic param list (env_ptr + user params).
    const saved_locals = self.locals;
    const saved_params = self.params;
    const saved_frame = self.frame_bytes;
    const saved_entry = self.is_entry;
    const saved_bank = self.current_bank;
    const saved_promoted = self.fn_closure_info.promoted;
    const saved_closure_bindings = self.fn_closure_info.closure_bindings;
    self.locals = .{};
    self.params = .{};
    self.frame_bytes = 0;
    self.is_entry = false;
    // Swap the scope-dependent analysis fields to this lambda's
    // own — promoted bindings + closure_bindings differ per
    // scope. The lambdas list stays shared across nested levels
    // (every lambda emits as a flat def at the end of the parent).
    self.fn_closure_info.promoted = li.promoted;
    self.fn_closure_info.closure_bindings = li.closure_bindings;
    defer {
        self.locals = saved_locals;
        self.params = saved_params;
        self.frame_bytes = saved_frame;
        self.is_entry = saved_entry;
        self.current_bank = saved_bank;
        self.fn_closure_info.promoted = saved_promoted;
        self.fn_closure_info.closure_bindings = saved_closure_bindings;
    }

    const dup_label = try self.arena.dupe(u8, li.label);
    // @as: narrow usize code offset to u16; per-buffer offset stays ≤ 64 KiB.
    const code_offset: u16 = @intCast(try self.currentOffset());
    const addr: u16 = codegen_mod.code_base + code_offset;
    try self.fn_addresses.put(self.arena, dup_label, addr);

    // env_ptr is the hidden first param at fp+4. Register it
    // under the synthetic name "__env" so capture loads can
    // reach it.
    try self.params.put(self.arena, "__env", 4);

    // User params follow env_ptr — offsets shift by 2.
    for (lambda.params, 0..) |p, i| {
        const p_name = self.source[p.name.start..p.name.end];
        const dup_p = try self.arena.dupe(u8, p_name);
        // @as: u8 frame index → i8 fp-offset.
        const offset: i8 = @intCast(6 + 2 * @as(i32, @intCast(i)));
        try self.params.put(self.arena, dup_p, offset);
    }

    // Register the captures so emitIdent / emitAssign in the
    // body knows where to find them (env-relative). The new
    // `captures` map on Emitter is consulted before locals/params/
    // globals during ident resolution.
    var captures_map: std.StringHashMapUnmanaged(CaptureSlot) = .{};
    for (li.captures.items, 0..) |cap, idx| {
        // @as: idx fits u16 — capture count caps below 32k.
        const offset: u16 = 2 + @as(u16, @intCast(idx)) * 2;
        // `is_cell` reflects the enclosing scope's view of this
        // capture — promoted in the parent (whichever the parent
        // scope was) means the slot holds a cell pointer, so
        // reads in this body need a deref. We use the
        // pre-swap `saved_promoted` since that's the enclosing
        // scope's promotion set, not this lambda's own.
        const promoted_in_parent = saved_promoted.contains(cap);
        try captures_map.put(self.arena, cap, .{
            .env_offset = offset,
            .is_cell = promoted_in_parent,
        });
    }
    const saved_captures = self.captures;
    self.captures = captures_map;
    defer self.captures = saved_captures;

    // Reserve local slots up front (lambda body uses locals like
    // any other fn).
    const local_count = self.countLocalsInBody(lambda.body);
    if (local_count > 0) {
        // @as: 2 bytes per slot, caps well below u16.
        const reserve_bytes: u16 = @intCast(local_count * 2);
        try self.subImmFromReg(reserve_bytes, Reg.sp);
    }

    try self.pushBlock();
    for (lambda.body) |stmt| try self.emitStatement(stmt);
    try self.popBlockWithDefers();

    try self.emitByte(Op.ret_op);
}

/// One captured binding inside a lambda body — drives the
/// `emitIdent` env-relative load + the assign env-relative cell
/// write.
pub const CaptureSlot = struct {
    /// Offset from env_ptr where the capture lives — for non-cell
    /// captures, this slot holds the captured value directly; for
    /// cell captures (promoted), this slot holds the cell pointer.
    env_offset: u16,
    /// `true` when the parent promoted this binding to a heap
    /// cell. Reads in the lambda body need an extra deref; writes
    /// store back to the cell (visible to other closures + parent).
    is_cell: bool,
};

/// Load env_ptr from `[fp + 4]` into `dst` — used by capture
/// loads / stores inside the lambda body.
fn loadEnvPtr(self: *Emitter, dst: u8) !void {
    try self.movRegOffsetToReg(Reg.fp, 4, dst);
}

/// Read a captured binding from inside the lambda body.
/// Non-cell: `acu = [env_ptr + N]`. Cell: `acu = [[env_ptr + N]]`.
pub fn emitCaptureLoad(self: *Emitter, slot: CaptureSlot) !void {
    try loadEnvPtr(self, Reg.r1);
    try emitWordLoadAtOffset(self, Reg.r1, slot.env_offset, Reg.acu);
    if (slot.is_cell) {
        try self.movRegToReg(Reg.acu, Reg.r1);
        try cellLoad(self, Reg.r1, Reg.acu);
    }
}

/// Write to a captured binding from inside the lambda body.
/// Only valid for cell captures (non-cell ones are by-value
/// snapshots at closure creation — writing them would be
/// invisible to anyone else and is forbidden by the typechecker's
/// @no_capture enforcement in tracked defs).
pub fn emitCaptureStore(self: *Emitter, slot: CaptureSlot, value: *const ast.Expr) !void {
    if (!slot.is_cell) {
        try self.diagFatal(.{ .start = 0, .end = 0 }, "E_CODEGEN_NONPROMOTED_CAPTURE_WRITE", "codegen: write to non-promoted captured binding (analysis bug — should have promoted it)");
        return;
    }
    try self.emitExpr(value);
    try self.pushReg(Reg.acu);
    try loadEnvPtr(self, Reg.r1);
    try emitWordLoadAtOffset(self, Reg.r1, slot.env_offset, Reg.r1);
    try self.popReg(Reg.r2);
    try cellStore(self, Reg.r1, Reg.r2);
}

// ---------- closure call ----------

/// Lower `expr(args)` where `expr` evaluates to a closure value.
/// Loads fn_ptr from the tuple, pushes user args right-to-left,
/// pushes the closure ptr as the hidden first arg, `call_reg`.
pub fn emitClosureCall(
    self: *Emitter,
    callee: *const ast.Expr,
    c: ast.CallExpr,
) !void {
    // Evaluate closure value into r1 (the tuple pointer).
    try self.emitExpr(callee);
    try self.movRegToReg(Reg.acu, Reg.r1);

    // Load fn_ptr from [r1 + 0] into r3.
    try emitWordLoadAtOffset(self, Reg.r1, 0, Reg.r3);

    // Push user args right-to-left, preserving r1 + r3.
    var i: usize = c.args.len;
    while (i > 0) {
        i -= 1;
        try self.pushReg(Reg.r1);
        try self.pushReg(Reg.r3);
        try self.emitExpr(c.args[i]);
        try self.popReg(Reg.r3);
        try self.popReg(Reg.r1);
        try self.pushReg(Reg.acu);
    }

    // Push env_ptr (the closure itself) as the hidden first arg.
    try self.pushReg(Reg.r1);

    try self.emitByte(Op.call_reg);
    try self.emitByte(Reg.r3);

    // @as: widen usize args.len to u16 — practical method arity caps well below 32k.
    const drop_bytes: u16 = 2 + @as(u16, @intCast(c.args.len * 2));
    try self.addImmToReg(drop_bytes, Reg.sp);
}

/// Patch every recorded lambda-fn-ptr placeholder with the
/// resolved address from `fn_addresses`. Runs after
/// `emitLambdaBodies` so each label has a known address.
pub fn patchLambdaSlots(self: *Emitter) !void {
    for (self.lambda_patches.items) |p| {
        const addr = self.fn_addresses.get(p.label) orelse 0;
        const buf: []u8 = if (p.bank) |b|
            if (self.banks.getPtr(b)) |bl| bl.items else continue
        else
            self.code.items;
        if (p.code_offset + 2 > buf.len) continue;
        // safety: addr is u16; the 2-byte slot fits cleanly.
        buf[p.code_offset] = @intCast(addr & 0xFF);
        buf[p.code_offset + 1] = @intCast((addr >> 8) & 0xFF);
    }
}

// ---------- analysis walkers ----------

fn collectLocalsFromStatement(
    self: *Emitter,
    s: ast.Statement,
    locals: *std.StringHashMapUnmanaged(void),
    info: *FnClosureInfo,
) !void {
    switch (s) {
        .let_decl => |d| {
            if (d.pattern.* == .ident) {
                const name = self.source[d.pattern.ident.name.start..d.pattern.ident.name.end];
                try locals.put(self.arena, name, {});
                if (d.init) |init_expr| {
                    if (init_expr.* == .lambda) {
                        try info.closure_bindings.put(self.arena, name, {});
                    }
                }
            }
        },
        .const_decl => |d| {
            const name = self.source[d.name.start..d.name.end];
            try locals.put(self.arena, name, {});
            if (d.init.* == .lambda) {
                try info.closure_bindings.put(self.arena, name, {});
            }
        },
        .block => |b| for (b.body) |inner| try collectLocalsFromStatement(self, inner, locals, info),
        .if_stmt => |is_| {
            for (is_.arms) |arm| for (arm.body) |inner| try collectLocalsFromStatement(self, inner, locals, info);
            if (is_.else_body) |eb| for (eb) |inner| try collectLocalsFromStatement(self, inner, locals, info);
        },
        .while_stmt => |ws| for (ws.body) |inner| try collectLocalsFromStatement(self, inner, locals, info),
        .for_stmt => |fs| for (fs.body) |inner| try collectLocalsFromStatement(self, inner, locals, info),
        .repeat_stmt => |rs| for (rs.body) |inner| try collectLocalsFromStatement(self, inner, locals, info),
        else => {},
    }
}

const FindError = error{OutOfMemory};

fn findLambdasInStatement(
    self: *Emitter,
    s: ast.Statement,
    def: *const ast.DefDecl,
    info: *FnClosureInfo,
) FindError!void {
    switch (s) {
        .let_decl => |d| if (d.init) |init_expr| try findLambdasInExpr(self, init_expr, def, info),
        .const_decl => |d| try findLambdasInExpr(self, d.init, def, info),
        .assign => |a| try findLambdasInExpr(self, a.value, def, info),
        .return_stmt => |rs| if (rs.value) |v| try findLambdasInExpr(self, v, def, info),
        .expr_stmt => |es| try findLambdasInExpr(self, es.expr, def, info),
        .discard => |d| try findLambdasInExpr(self, d.expr, def, info),
        .print_stmt => |ps| for (ps.args) |a| try findLambdasInExpr(self, a, def, info),
        .block => |b| for (b.body) |inner| try findLambdasInStatement(self, inner, def, info),
        .if_stmt => |is_| {
            for (is_.arms) |arm| {
                if (arm.cond) |c| try findLambdasInExpr(self, c, def, info);
                if (arm.let_expr) |le| try findLambdasInExpr(self, le, def, info);
                if (arm.let_guard) |lg| try findLambdasInExpr(self, lg, def, info);
                for (arm.body) |inner| try findLambdasInStatement(self, inner, def, info);
            }
            if (is_.else_body) |eb| for (eb) |inner| try findLambdasInStatement(self, inner, def, info);
        },
        .while_stmt => |ws| {
            if (ws.cond) |c| try findLambdasInExpr(self, c, def, info);
            if (ws.let_expr) |le| try findLambdasInExpr(self, le, def, info);
            if (ws.let_guard) |lg| try findLambdasInExpr(self, lg, def, info);
            for (ws.body) |inner| try findLambdasInStatement(self, inner, def, info);
        },
        .for_stmt => |fs| for (fs.body) |inner| try findLambdasInStatement(self, inner, def, info),
        .repeat_stmt => |rs| {
            for (rs.body) |inner| try findLambdasInStatement(self, inner, def, info);
            try findLambdasInExpr(self, rs.cond, def, info);
        },
        else => {},
    }
}

fn findLambdasInExpr(
    self: *Emitter,
    e: *const ast.Expr,
    def: *const ast.DefDecl,
    info: *FnClosureInfo,
) FindError!void {
    switch (e.*) {
        .lambda => |l| {
            const idx = info.next_lambda_id;
            info.next_lambda_id += 1;
            const fn_name = self.source[def.name.start..def.name.end];
            const label = try std.fmt.allocPrint(self.arena, "__lambda_{s}_{d}", .{ fn_name, idx });
            var captures: std.ArrayListUnmanaged([]const u8) = .empty;
            try collectFreeVars(self, &l, &captures, def);
            // Per-lambda scope analysis: this lambda's own locals,
            // which subset of them get initialized with a nested
            // lambda, and which subset needs a heap cell. Computed
            // here so emitOneLambdaBody can swap them in.
            var local_bindings: std.StringHashMapUnmanaged(void) = .{};
            var scope_closure_bindings: std.StringHashMapUnmanaged(void) = .{};
            try collectLambdaScopeBindings(self, &l, &local_bindings, &scope_closure_bindings);
            // Recurse — register any nested lambdas in the same
            // flat list so emitLambdaBodies emits them all.
            try findLambdasInLambdaBody(self, &l, def, info);
            // Now decide promotion for this lambda's own locals.
            // Mutation walks the body (any assignment in this body
            // or any deeper nested lambda body counts).
            var mutated: std.StringHashMapUnmanaged(void) = .{};
            for (l.body) |stmt| collectMutatedInStatement(self, stmt, &mutated);
            // Escape: nested lambdas in this body that escape via
            // a return in this body's tail.
            var escaping_captures: std.StringHashMapUnmanaged(void) = .{};
            for (l.body) |stmt| collectEscapingCaptures(self, stmt, info, &escaping_captures);
            var promoted: std.StringHashMapUnmanaged(void) = .{};
            for (info.lambdas.items) |child_li| {
                for (child_li.captures.items) |cap| {
                    if (!local_bindings.contains(cap)) continue;
                    if (mutated.contains(cap) or escaping_captures.contains(cap)) {
                        try promoted.put(self.arena, cap, {});
                    }
                }
            }
            try info.lambdas.append(self.arena, .{
                .ast_node = &e.lambda,
                .label = label,
                .captures = captures,
                .promoted = promoted,
                .closure_bindings = scope_closure_bindings,
            });
        },
        .paren => |p| try findLambdasInExpr(self, p.inner, def, info),
        .unary => |u| try findLambdasInExpr(self, u.operand, def, info),
        .binary => |b| {
            try findLambdasInExpr(self, b.lhs, def, info);
            try findLambdasInExpr(self, b.rhs, def, info);
        },
        .call => |c| {
            try findLambdasInExpr(self, c.callee, def, info);
            for (c.args) |a| try findLambdasInExpr(self, a, def, info);
        },
        .method_call => |m| {
            try findLambdasInExpr(self, m.receiver, def, info);
            for (m.args) |a| try findLambdasInExpr(self, a, def, info);
        },
        .field => |f| try findLambdasInExpr(self, f.receiver, def, info),
        .is_test => |it| try findLambdasInExpr(self, it.lhs, def, info),
        .ref_of => |r| try findLambdasInExpr(self, r.inner, def, info),
        .cast => |c| try findLambdasInExpr(self, c.inner, def, info),
        else => {},
    }
}

/// Recurse into a lambda body's statements to register nested
/// lambdas in the shared `info.lambdas` list. Mirrors the
/// statement walker used at def-body level — duplicated rather
/// than parameterized because the def-body walker stays
/// shallower (it doesn't recurse into lambda bodies itself; this
/// helper drives that recursion).
fn findLambdasInLambdaBody(
    self: *Emitter,
    lambda: *const ast.LambdaExpr,
    def: *const ast.DefDecl,
    info: *FnClosureInfo,
) FindError!void {
    for (lambda.body) |stmt| try findLambdasInStatement(self, stmt, def, info);
}

/// Collect this lambda body's own let / const bindings, plus
/// the subset of those whose init expression is itself a lambda
/// (drives the closure-call detection in this lambda's scope).
fn collectLambdaScopeBindings(
    self: *Emitter,
    lambda: *const ast.LambdaExpr,
    locals: *std.StringHashMapUnmanaged(void),
    closure_bindings: *std.StringHashMapUnmanaged(void),
) !void {
    for (lambda.params) |p| {
        const name = self.source[p.name.start..p.name.end];
        try locals.put(self.arena, name, {});
    }
    for (lambda.body) |stmt| try collectScopeStatementBindings(self, stmt, locals, closure_bindings);
}

fn collectScopeStatementBindings(
    self: *Emitter,
    s: ast.Statement,
    locals: *std.StringHashMapUnmanaged(void),
    closure_bindings: *std.StringHashMapUnmanaged(void),
) !void {
    switch (s) {
        .let_decl => |d| {
            if (d.pattern.* == .ident) {
                const name = self.source[d.pattern.ident.name.start..d.pattern.ident.name.end];
                try locals.put(self.arena, name, {});
                if (d.init) |init_expr| {
                    if (init_expr.* == .lambda) {
                        try closure_bindings.put(self.arena, name, {});
                    }
                }
            }
        },
        .const_decl => |d| {
            const name = self.source[d.name.start..d.name.end];
            try locals.put(self.arena, name, {});
            if (d.init.* == .lambda) {
                try closure_bindings.put(self.arena, name, {});
            }
        },
        .block => |b| for (b.body) |inner| try collectScopeStatementBindings(self, inner, locals, closure_bindings),
        .if_stmt => |is_| {
            for (is_.arms) |arm| for (arm.body) |inner| try collectScopeStatementBindings(self, inner, locals, closure_bindings);
            if (is_.else_body) |eb| for (eb) |inner| try collectScopeStatementBindings(self, inner, locals, closure_bindings);
        },
        .while_stmt => |ws| for (ws.body) |inner| try collectScopeStatementBindings(self, inner, locals, closure_bindings),
        .for_stmt => |fs| for (fs.body) |inner| try collectScopeStatementBindings(self, inner, locals, closure_bindings),
        .repeat_stmt => |rs| for (rs.body) |inner| try collectScopeStatementBindings(self, inner, locals, closure_bindings),
        else => {},
    }
}

/// Collect the free idents referenced inside a lambda body —
/// names used but not declared as a lambda param / local. The
/// caller filters against actual parent bindings; this function
/// just returns the candidate names.
fn collectFreeVars(
    self: *Emitter,
    lambda: *const ast.LambdaExpr,
    captures: *std.ArrayListUnmanaged([]const u8),
    def: *const ast.DefDecl,
) !void {
    var lambda_locals: std.StringHashMapUnmanaged(void) = .{};
    for (lambda.params) |p| {
        const name = self.source[p.name.start..p.name.end];
        try lambda_locals.put(self.arena, name, {});
    }
    for (lambda.body) |stmt| try collectLambdaLocalsInStatement(self, stmt, &lambda_locals);
    for (lambda.body) |stmt| try collectIdentsInStatement(self, stmt, &lambda_locals, captures, def);
}

fn collectLambdaLocalsInStatement(
    self: *Emitter,
    s: ast.Statement,
    locals: *std.StringHashMapUnmanaged(void),
) !void {
    switch (s) {
        .let_decl => |d| if (d.pattern.* == .ident) {
            const name = self.source[d.pattern.ident.name.start..d.pattern.ident.name.end];
            try locals.put(self.arena, name, {});
        },
        .const_decl => |d| {
            const name = self.source[d.name.start..d.name.end];
            try locals.put(self.arena, name, {});
        },
        .block => |b| for (b.body) |inner| try collectLambdaLocalsInStatement(self, inner, locals),
        .if_stmt => |is_| {
            for (is_.arms) |arm| for (arm.body) |inner| try collectLambdaLocalsInStatement(self, inner, locals);
            if (is_.else_body) |eb| for (eb) |inner| try collectLambdaLocalsInStatement(self, inner, locals);
        },
        .while_stmt => |ws| for (ws.body) |inner| try collectLambdaLocalsInStatement(self, inner, locals),
        .for_stmt => |fs| for (fs.body) |inner| try collectLambdaLocalsInStatement(self, inner, locals),
        .repeat_stmt => |rs| for (rs.body) |inner| try collectLambdaLocalsInStatement(self, inner, locals),
        else => {},
    }
}

const CollectError = error{OutOfMemory};

fn collectIdentsInStatement(
    self: *Emitter,
    s: ast.Statement,
    locals: *const std.StringHashMapUnmanaged(void),
    captures: *std.ArrayListUnmanaged([]const u8),
    def: *const ast.DefDecl,
) CollectError!void {
    switch (s) {
        .let_decl => |d| if (d.init) |init_expr| try collectIdentsInExpr(self, init_expr, locals, captures, def),
        .const_decl => |d| try collectIdentsInExpr(self, d.init, locals, captures, def),
        .assign => |a| {
            try collectIdentsInExpr(self, a.target, locals, captures, def);
            try collectIdentsInExpr(self, a.value, locals, captures, def);
        },
        .return_stmt => |rs| if (rs.value) |v| try collectIdentsInExpr(self, v, locals, captures, def),
        .expr_stmt => |es| try collectIdentsInExpr(self, es.expr, locals, captures, def),
        .discard => |d| try collectIdentsInExpr(self, d.expr, locals, captures, def),
        .print_stmt => |ps| for (ps.args) |a| try collectIdentsInExpr(self, a, locals, captures, def),
        .block => |b| for (b.body) |inner| try collectIdentsInStatement(self, inner, locals, captures, def),
        .if_stmt => |is_| {
            for (is_.arms) |arm| {
                if (arm.cond) |c| try collectIdentsInExpr(self, c, locals, captures, def);
                if (arm.let_expr) |le| try collectIdentsInExpr(self, le, locals, captures, def);
                if (arm.let_guard) |lg| try collectIdentsInExpr(self, lg, locals, captures, def);
                for (arm.body) |inner| try collectIdentsInStatement(self, inner, locals, captures, def);
            }
            if (is_.else_body) |eb| for (eb) |inner| try collectIdentsInStatement(self, inner, locals, captures, def);
        },
        .while_stmt => |ws| {
            if (ws.cond) |c| try collectIdentsInExpr(self, c, locals, captures, def);
            if (ws.let_expr) |le| try collectIdentsInExpr(self, le, locals, captures, def);
            if (ws.let_guard) |lg| try collectIdentsInExpr(self, lg, locals, captures, def);
            for (ws.body) |inner| try collectIdentsInStatement(self, inner, locals, captures, def);
        },
        .for_stmt => |fs| for (fs.body) |inner| try collectIdentsInStatement(self, inner, locals, captures, def),
        .repeat_stmt => |rs| {
            for (rs.body) |inner| try collectIdentsInStatement(self, inner, locals, captures, def);
            try collectIdentsInExpr(self, rs.cond, locals, captures, def);
        },
        else => {},
    }
}

fn collectIdentsInExpr(
    self: *Emitter,
    e: *const ast.Expr,
    locals: *const std.StringHashMapUnmanaged(void),
    captures: *std.ArrayListUnmanaged([]const u8),
    def: *const ast.DefDecl,
) CollectError!void {
    switch (e.*) {
        .ident => |i| {
            const name = self.source[i.span.start..i.span.end];
            if (locals.contains(name)) return;
            // Skip ident shapes that don't correspond to a binding
            // (function names typed as call targets, class names,
            // etc.). For PR scope: include only names that match a
            // parent let / param. The caller filters again.
            for (captures.items) |existing| {
                if (std.mem.eql(u8, existing, name)) return;
            }
            try captures.append(self.arena, name);
        },
        .paren => |p| try collectIdentsInExpr(self, p.inner, locals, captures, def),
        .unary => |u| try collectIdentsInExpr(self, u.operand, locals, captures, def),
        .binary => |b| {
            try collectIdentsInExpr(self, b.lhs, locals, captures, def);
            try collectIdentsInExpr(self, b.rhs, locals, captures, def);
        },
        .call => |c| {
            try collectIdentsInExpr(self, c.callee, locals, captures, def);
            for (c.args) |a| try collectIdentsInExpr(self, a, locals, captures, def);
        },
        .method_call => |m| {
            try collectIdentsInExpr(self, m.receiver, locals, captures, def);
            for (m.args) |a| try collectIdentsInExpr(self, a, locals, captures, def);
        },
        .field => |f| try collectIdentsInExpr(self, f.receiver, locals, captures, def),
        .is_test => |it| try collectIdentsInExpr(self, it.lhs, locals, captures, def),
        .ref_of => |r| try collectIdentsInExpr(self, r.inner, locals, captures, def),
        .cast => |c| try collectIdentsInExpr(self, c.inner, locals, captures, def),
        // Nested lambda — any name the inner lambda captures from
        // OUTSIDE its own param + locals is a free var from the
        // enclosing scope. If that name isn't local to THIS
        // lambda either, it transitively becomes a capture of this
        // lambda too — at closure-creation time we populate the
        // inner closure's slot by re-reading our own env.
        .lambda => |inner| {
            var inner_locals: std.StringHashMapUnmanaged(void) = .{};
            for (inner.params) |p| {
                const name = self.source[p.name.start..p.name.end];
                try inner_locals.put(self.arena, name, {});
            }
            for (inner.body) |stmt| try collectLambdaLocalsInStatement(self, stmt, &inner_locals);
            var inner_captures: std.ArrayListUnmanaged([]const u8) = .empty;
            for (inner.body) |stmt| try collectIdentsInStatement(self, stmt, &inner_locals, &inner_captures, def);
            for (inner_captures.items) |inner_cap| {
                // Skip if local to this lambda's own scope.
                if (locals.contains(inner_cap)) continue;
                // De-dup against captures we've already recorded.
                var seen = false;
                for (captures.items) |existing| {
                    if (std.mem.eql(u8, existing, inner_cap)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) try captures.append(self.arena, inner_cap);
            }
        },
        else => {},
    }
}

fn collectMutatedInStatement(
    self: *Emitter,
    s: ast.Statement,
    mutated: *std.StringHashMapUnmanaged(void),
) void {
    switch (s) {
        .assign => |a| if (a.target.* == .ident) {
            const name = self.source[a.target.ident.span.start..a.target.ident.span.end];
            mutated.put(self.arena, name, {}) catch return;
        },
        .inc_dec => |id| if (id.target.* == .ident) {
            const name = self.source[id.target.ident.span.start..id.target.ident.span.end];
            mutated.put(self.arena, name, {}) catch return;
        },
        .block => |b| for (b.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .if_stmt => |is_| {
            for (is_.arms) |arm| for (arm.body) |inner| collectMutatedInStatement(self, inner, mutated);
            if (is_.else_body) |eb| for (eb) |inner| collectMutatedInStatement(self, inner, mutated);
        },
        .while_stmt => |ws| for (ws.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .for_stmt => |fs| for (fs.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .repeat_stmt => |rs| for (rs.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .return_stmt => |rs| if (rs.value) |v| collectMutatedInExpr(self, v, mutated),
        .expr_stmt => |es| collectMutatedInExpr(self, es.expr, mutated),
        .print_stmt => |ps| for (ps.args) |a| collectMutatedInExpr(self, a, mutated),
        else => {},
    }
}

fn collectMutatedInExpr(
    self: *Emitter,
    e: *const ast.Expr,
    mutated: *std.StringHashMapUnmanaged(void),
) void {
    if (e.* == .lambda) {
        // A lambda body's assignments to captured names mutate
        // the captured binding from the parent's perspective.
        for (e.lambda.body) |stmt| collectMutatedInStatement(self, stmt, mutated);
    } else if (e.* == .binary) {
        collectMutatedInExpr(self, e.binary.lhs, mutated);
        collectMutatedInExpr(self, e.binary.rhs, mutated);
    } else if (e.* == .call) {
        collectMutatedInExpr(self, e.call.callee, mutated);
        for (e.call.args) |a| collectMutatedInExpr(self, a, mutated);
    }
    // Other expr shapes can't mutate a binding by themselves.
}

/// Walk for `return <lambda>` shapes — every binding captured by
/// an escaping lambda needs promotion (its frame is gone by the
/// time the closure runs).
fn collectEscapingCaptures(
    self: *Emitter,
    s: ast.Statement,
    info: *const FnClosureInfo,
    out: *std.StringHashMapUnmanaged(void),
) void {
    switch (s) {
        .return_stmt => |rs| if (rs.value) |v| collectEscapingFromExpr(self, v, info, out),
        .let_decl => |d| if (d.init) |init_expr| collectEscapingFromExpr(self, init_expr, info, out),
        .block => |b| for (b.body) |inner| collectEscapingCaptures(self, inner, info, out),
        .if_stmt => |is_| {
            for (is_.arms) |arm| for (arm.body) |inner| collectEscapingCaptures(self, inner, info, out);
            if (is_.else_body) |eb| for (eb) |inner| collectEscapingCaptures(self, inner, info, out);
        },
        .while_stmt => |ws| for (ws.body) |inner| collectEscapingCaptures(self, inner, info, out),
        .for_stmt => |fs| for (fs.body) |inner| collectEscapingCaptures(self, inner, info, out),
        .repeat_stmt => |rs| for (rs.body) |inner| collectEscapingCaptures(self, inner, info, out),
        else => {},
    }
}

fn collectEscapingFromExpr(
    self: *Emitter,
    e: *const ast.Expr,
    info: *const FnClosureInfo,
    out: *std.StringHashMapUnmanaged(void),
) void {
    if (e.* != .lambda) return;
    for (info.lambdas.items) |li| {
        if (li.ast_node == &e.lambda) {
            for (li.captures.items) |cap| {
                out.put(self.arena, cap, {}) catch return;
            }
            return;
        }
    }
}

fn findLambdaInfo(self: *Emitter, expr: *const ast.Expr) ?*const LambdaInfo {
    if (expr.* != .lambda) return null;
    for (self.fn_closure_info.lambdas.items) |*li| {
        if (li.ast_node == &expr.lambda) return li;
    }
    return null;
}

/// Word load: `mov [base + offset], dst` (i8 offset when ≤127,
/// synthesized widen otherwise). Local copy to avoid a cycle
/// importing class.zig.
fn emitWordLoadAtOffset(self: *Emitter, base: u8, offset: u16, dst: u8) !void {
    if (offset <= 127) {
        // @as: offset fits i8 (≤127); the cast is a no-op for the value range.
        try self.movRegOffsetToReg(base, @as(i8, @intCast(offset)), dst);
        return;
    }
    try self.movRegToReg(base, Reg.r2);
    try self.addImmToReg(offset, Reg.r2);
    try self.movRegOffsetToReg(Reg.r2, 0, dst);
}

fn emitWordStoreAtOffset(self: *Emitter, base: u8, offset: u16, src: u8) !void {
    if (offset <= 127) {
        // @as: offset fits i8 (≤127); the cast is a no-op for the value range.
        try self.movRegToRegOffset(src, base, @as(i8, @intCast(offset)));
        return;
    }
    try self.movRegToReg(base, Reg.r3);
    try self.addImmToReg(offset, Reg.r3);
    try self.movRegToRegOffset(src, Reg.r3, 0);
}
