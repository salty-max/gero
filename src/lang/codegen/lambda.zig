const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const codegen_mod = @import("../codegen.zig");

const Emitter = codegen_mod.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;
const Type = types.Type;

/// Per-capture type, keyed by capture name — recorded at the
/// free-variable's reference site so the closure-creation site knows
/// whether a capture is an inline aggregate (struct / array / tuple /
/// Vec / scalar optional) that must be captured by pointer rather than
/// by word value.
const CaptureTypes = std.StringHashMapUnmanaged(*const Type);

/// `true` when `ty` is an inline aggregate — it lives as contiguous
/// bytes in its owner's frame and an expression of this type evaluates
/// to a base address (so a capture must propagate that address, not a
/// word). A class / enum / pointer-optional is word-sized and captured
/// by value like a scalar.
pub fn isInlineAggregateType(self: *const Emitter, ty: *const Type) bool {
    return switch (ty.*) {
        .named => |n| self.struct_decls.contains(n.name),
        .array, .tuple, .vec => true,
        .optional => |inner| codegen_mod.Emitter.isScalarOptional(inner),
        else => false,
    };
}

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
    /// Type of each capture, keyed by name — drives by-pointer capture
    /// of inline aggregates (a name absent here is a word-sized value).
    capture_types: CaptureTypes,
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

    // Drop captures that name a module-level callable / type. The free-var
    // walk flags any out-of-scope ident, but a free function / class / enum
    // / struct is globally addressable — the lambda body resolves it
    // directly, so it must not consume an env slot.
    for (info.lambdas.items) |*li| {
        var kept: std.ArrayListUnmanaged([]const u8) = .empty;
        for (li.captures.items) |cap| {
            if (isModuleName(self, cap)) continue;
            try kept.append(self.arena, cap);
        }
        li.captures = kept;
    }

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
                // `self` is immutable and points to a heap object that
                // outlives the frame, so a by-value pointer copy is always
                // correct — never promote it (an escaping method closure
                // would otherwise heap-cell a stable pointer).
                if (std.mem.eql(u8, cap, "self")) continue;
                if (shouldPromote(self, li, cap, &mutated, &escaping_captures)) {
                    try info.promoted.put(self.arena, cap, {});
                }
            }
        }
    }

    self.fn_closure_info = info;
}

/// Whether a captured binding needs a heap upvalue (§4.7.2). A scalar
/// promotes when mutated OR captured by an escaping closure (the value
/// must outlive the frame). An inline aggregate promotes ONLY when
/// mutated — a read-only aggregate is heap-copied at capture, which is
/// already escape-safe, so escape alone keeps it by-copy.
fn shouldPromote(
    self: *const Emitter,
    li: LambdaInfo,
    cap: []const u8,
    mutated: *const std.StringHashMapUnmanaged(void),
    escaping: *const std.StringHashMapUnmanaged(void),
) bool {
    if (mutated.contains(cap)) return true;
    const is_agg = if (li.capture_types.get(cap)) |ty| isInlineAggregateType(self, ty) else false;
    return !is_agg and escaping.contains(cap);
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
    try isa.movImmToReg(self, 2, Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(Sys.alloc);
    // acu = cell pointer; store it in the local slot.
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, slot_ofs);
    // Seed the cell with the init value when present.
    if (init) |init_expr| {
        try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = cell ptr
        try isa.pushReg(self, Reg.r1);
        try self.emitExpr(init_expr); // acu = init value
        try isa.popReg(self, Reg.r1);
        try cellStore(self, Reg.r1, Reg.acu);
    }
}

/// Promote a captured param to a heap cell at fn entry. A param
/// arrives in its frame slot by value (no `let`), so the slot has no
/// cell yet — allocate one, seed it with the incoming value, and store
/// the cell pointer back into the slot. Afterward every promotion-aware
/// path (ident load / assign / capture source) treats the param exactly
/// like a promoted local.
pub fn emitPromoteParam(self: *Emitter, slot_ofs: i8) !void {
    // Save the incoming value before the alloc clobbers acu.
    try isa.movRegOffsetToReg(self, Reg.fp, slot_ofs, Reg.r1);
    try isa.pushReg(self, Reg.r1);
    try isa.movImmToReg(self, 2, Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(Sys.alloc);
    // acu = cell pointer; store it in the param slot.
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, slot_ofs);
    // Seed the cell with the saved value.
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = cell ptr
    try isa.popReg(self, Reg.r2); // r2 = incoming value
    try cellStore(self, Reg.r1, Reg.r2);
}

/// Promote an inline aggregate binding to a shared heap upvalue: move
/// its just-materialized inline bytes at `[fp+slot]` to the heap and
/// park the pointer in the slot's first word. Shared by the promoted
/// aggregate `let` and the captured-aggregate param entry.
pub fn emitPromoteAggregate(self: *Emitter, slot: i8, width: u16) !void {
    try emitHeapCopyFromFrame(self, slot, width);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, slot);
}

/// Type recorded for a captured binding (from any lambda in this fn that
/// captures it), or null when the name isn't captured / wasn't typed.
pub fn capturedType(self: *const Emitter, name: []const u8) ?*const Type {
    for (self.fn_closure_info.lambdas.items) |li| {
        if (li.capture_types.get(name)) |ty| return ty;
    }
    return null;
}

/// Read a promoted local: load cell pointer from slot, then deref.
pub fn emitPromotedIdentLoad(self: *Emitter, slot_ofs: i8) !void {
    try isa.movRegOffsetToReg(self, Reg.fp, slot_ofs, Reg.r1);
    try cellLoad(self, Reg.r1, Reg.acu);
}

/// Write a promoted local: evaluate value into acu, push, load
/// the cell pointer, deref-write.
pub fn emitPromotedAssign(self: *Emitter, slot_ofs: i8, value: *const ast.Expr) !void {
    try self.emitExpr(value);
    try isa.pushReg(self, Reg.acu);
    try isa.movRegOffsetToReg(self, Reg.fp, slot_ofs, Reg.r1);
    try isa.popReg(self, Reg.r2);
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
    try isa.movImmToReg(self, tuple_size, Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(Sys.alloc);
    // acu = tuple ptr; stash in r1 for the populate phase.
    try isa.movRegToReg(self, Reg.acu, Reg.r1);

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
        try isa.pushReg(self, Reg.r1); // preserve tuple ptr
        try emitCaptureSource(self, cap, li.capture_types.get(cap));
        try isa.popReg(self, Reg.r1);
        // acu = capture value (cell ptr if promoted, value otherwise)
        try emitWordStoreAtOffset(self, Reg.r1, slot_offset, Reg.acu);
    }

    // Result: tuple ptr in acu.
    try isa.movRegToReg(self, Reg.r1, Reg.acu);
}

/// Load a capture's source value into `acu` at closure-creation
/// time. The slot semantics are deliberately "raw" — for a
/// promoted binding that's the cell pointer (so the inner
/// closure shares state with the parent), for a non-promoted
/// binding that's the value (re-copied into the new closure).
/// An inline aggregate captured read-only is heap-copied here so the
/// env holds a private base pointer (value semantics, escape-safe); a
/// promoted aggregate's slot already holds its shared heap pointer, so
/// the raw read propagates it. The lookup order — captures → locals →
/// params → globals — lets nested closures chain: a closure created
/// INSIDE another lambda's body reads its captures from the enclosing
/// env rather than a stack slot that doesn't exist at this scope.
fn emitCaptureSource(self: *Emitter, name: []const u8, cap_ty: ?*const Type) !void {
    if (self.captures.get(name)) |slot| {
        // Inside an enclosing lambda — re-read this slot raw
        // from our own env to populate the inner closure's slot.
        // For promoted (cell-pointer) captures the pointer
        // propagates as-is (shared state); for an aggregate the
        // slot holds the base pointer, also propagated as-is.
        try loadEnvPtr(self, Reg.r1);
        try emitWordLoadAtOffset(self, Reg.r1, slot.env_offset, Reg.acu);
        return;
    }
    // A read-only inline aggregate (not promoted) lives as bytes in the
    // frame — heap-copy it so the closure owns a private base pointer.
    const is_agg = if (cap_ty) |ty| isInlineAggregateType(self, ty) else false;
    if (is_agg and !self.fn_closure_info.promoted.contains(name)) {
        if (self.locals.get(name)) |ofs| return emitHeapCopyFromFrame(self, ofs, self.widthOfType(cap_ty.?));
        if (self.params.get(name)) |ofs| return emitHeapCopyFromFrame(self, ofs, self.widthOfType(cap_ty.?));
    }
    if (self.locals.get(name)) |ofs| {
        try isa.movRegOffsetToReg(self, Reg.fp, ofs, Reg.acu);
        return;
    }
    if (self.params.get(name)) |ofs| {
        try isa.movRegOffsetToReg(self, Reg.fp, ofs, Reg.acu);
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

/// Heap-copy a `width`-byte inline aggregate at `[fp + base_ofs]` into a
/// fresh heap block; leave the block pointer in `acu`. Word-strided over
/// the (2-aligned) slot, so no byte ops are needed.
fn emitHeapCopyFromFrame(self: *Emitter, base_ofs: i8, width: u16) !void {
    const aligned: u16 = width + (width & 1); // round up to a whole word
    try isa.movImmToReg(self, aligned, Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(Sys.alloc); // acu = dest pointer
    try isa.pushReg(self, Reg.acu); // save the result pointer across the copy
    try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = dest cursor
    try isa.movRegToReg(self, Reg.fp, Reg.r1);
    if (base_ofs < 0) {
        // @as: widen i8 → i16 so the negate is safe at the i8 minimum.
        const w: i16 = base_ofs;
        // @as: |base_ofs| ≤ 128 → fits u16.
        try isa.subImmFromReg(self, @intCast(-w), Reg.r1);
    } else if (base_ofs > 0) {
        // @as: positive i8 → u16.
        try isa.addImmToReg(self, @intCast(base_ofs), Reg.r1);
    }
    var remaining = aligned;
    while (remaining >= 2) : (remaining -= 2) {
        try isa.movRegOffsetToReg(self, Reg.r1, 0, Reg.acu);
        try isa.movRegToRegOffset(self, Reg.acu, Reg.r2, 0);
        try isa.addImmToReg(self, 2, Reg.r1);
        try isa.addImmToReg(self, 2, Reg.r2);
    }
    try isa.popReg(self, Reg.acu); // acu = dest pointer (the result)
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
    // A lambda body has its own return contract — don't let the
    // enclosing fn's sret state leak in. The closure-call path passes
    // no sret destination, so a struct `return` here surfaces a clean
    // unsupported error rather than copying through the parent's buffer.
    const saved_ret_struct = self.current_ret_struct;
    const saved_inline_ret = self.inline_ret_struct;
    const saved_overflow = self.frame_overflow;
    self.locals = .{};
    self.params = .{};
    self.frame_bytes = 0;
    self.frame_overflow = false;
    self.is_entry = false;
    self.current_ret_struct = null;
    self.inline_ret_struct = null;
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
        self.frame_overflow = saved_overflow;
        self.is_entry = saved_entry;
        self.current_bank = saved_bank;
        self.current_ret_struct = saved_ret_struct;
        self.inline_ret_struct = saved_inline_ret;
        self.fn_closure_info.promoted = saved_promoted;
        self.fn_closure_info.closure_bindings = saved_closure_bindings;
    }

    const dup_label = try self.arena.dupe(u8, li.label);
    const ref: codegen_mod.CodeRef = .{ .bank = null, .offset = try self.currentOffset() };
    try self.fn_addresses.put(self.arena, dup_label, ref);

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
        // An inline aggregate is captured by pointer (the env slot holds
        // its base), so the body loads the pointer directly — never the
        // cell double-deref a promoted scalar needs.
        const is_aggregate = if (li.capture_types.get(cap)) |ty| isInlineAggregateType(self, ty) else false;
        try captures_map.put(self.arena, cap, .{
            .env_offset = offset,
            .is_cell = promoted_in_parent and !is_aggregate,
            .is_aggregate = is_aggregate,
        });
    }
    const saved_captures = self.captures;
    self.captures = captures_map;
    defer self.captures = saved_captures;

    // Reserve local slots up front (lambda body uses locals like
    // any other fn).
    const frame_bytes = self.countFrameBytes(lambda.body);
    if (frame_bytes > 0) {
        // An over-127 frame is caught by `reserveFrameSlot` as the body
        // emits (→ frame-too-large); this clamp only keeps the narrowing
        // from panicking on a huge frame.
        // @as: clamp the frame estimate into u16 before the narrowing cast.
        const reserve_bytes: u16 = @intCast(@min(frame_bytes, @as(usize, std.math.maxInt(u16))));
        try isa.subImmFromReg(self, reserve_bytes, Reg.sp);
    }

    try self.pushBlock();
    for (lambda.body) |stmt| try self.emitStatement(stmt);
    try self.popBlockWithDefers();

    try self.emitByte(Op.ret_op);

    if (self.frame_overflow) {
        try self.diagFatal(lambda.span, "E_CODEGEN_FRAME_TOO_LARGE", "lambda frame exceeds the 127-byte limit on fp-relative addressing");
    }
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
    /// `true` when the capture is an inline aggregate. The env slot
    /// holds the aggregate's base pointer (a heap copy for a read-only
    /// capture, the shared promoted buffer for a mutated one), so the
    /// body reads the pointer directly — one load, never a cell deref.
    is_aggregate: bool,
};

/// Load env_ptr from `[fp + 4]` into `dst` — used by capture
/// loads / stores inside the lambda body.
fn loadEnvPtr(self: *Emitter, dst: u8) !void {
    try isa.movRegOffsetToReg(self, Reg.fp, 4, dst);
}

/// Read a captured binding from inside the lambda body.
/// Non-cell: `acu = [env_ptr + N]`. Cell: `acu = [[env_ptr + N]]`.
pub fn emitCaptureLoad(self: *Emitter, slot: CaptureSlot) !void {
    try loadEnvPtr(self, Reg.r1);
    try emitWordLoadAtOffset(self, Reg.r1, slot.env_offset, Reg.acu);
    if (slot.is_cell) {
        try isa.movRegToReg(self, Reg.acu, Reg.r1);
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
    try isa.pushReg(self, Reg.acu);
    try loadEnvPtr(self, Reg.r1);
    try emitWordLoadAtOffset(self, Reg.r1, slot.env_offset, Reg.r1);
    try isa.popReg(self, Reg.r2);
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
    try isa.movRegToReg(self, Reg.acu, Reg.r1);

    // Load fn_ptr from [r1 + 0] into r3.
    try emitWordLoadAtOffset(self, Reg.r1, 0, Reg.r3);

    // Push user args right-to-left, preserving r1 + r3.
    var i: usize = c.args.len;
    while (i > 0) {
        i -= 1;
        try isa.pushReg(self, Reg.r1);
        try isa.pushReg(self, Reg.r3);
        try self.emitExpr(c.args[i]);
        try isa.popReg(self, Reg.r3);
        try isa.popReg(self, Reg.r1);
        try isa.pushReg(self, Reg.acu);
    }

    // Push env_ptr (the closure itself) as the hidden first arg.
    try isa.pushReg(self, Reg.r1);

    try self.emitByte(Op.call_reg);
    try self.emitByte(Reg.r3);

    // @as: widen usize args.len to u16 — practical method arity caps well below 32k.
    const drop_bytes: u16 = 2 + @as(u16, @intCast(c.args.len * 2));
    try isa.addImmToReg(self, drop_bytes, Reg.sp);
}

/// Patch every recorded lambda-fn-ptr placeholder with the
/// resolved address from `fn_addresses`. Runs after
/// `emitLambdaBodies` so each label has a known address.
pub fn patchLambdaSlots(self: *Emitter) !void {
    for (self.lambda_patches.items) |p| {
        const addr = if (self.fn_addresses.get(p.label)) |r| r.addr() else 0;
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
        .for_stmt => |fs| {
            try findLambdasInExpr(self, fs.iter, def, info);
            if (fs.step) |step_e| try findLambdasInExpr(self, step_e, def, info);
            for (fs.body) |inner| try findLambdasInStatement(self, inner, def, info);
        },
        .repeat_stmt => |rs| {
            for (rs.body) |inner| try findLambdasInStatement(self, inner, def, info);
            try findLambdasInExpr(self, rs.cond, def, info);
        },
        .match_stmt => |ms| {
            try findLambdasInExpr(self, ms.scrutinee, def, info);
            for (ms.arms) |arm| {
                if (arm.guard) |g| try findLambdasInExpr(self, g, def, info);
                for (arm.body) |inner| try findLambdasInStatement(self, inner, def, info);
            }
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
            var cap_types: CaptureTypes = .{};
            try collectFreeVars(self, &l, &captures, &cap_types, def);
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
                .capture_types = cap_types,
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
        .tuple_index => |ti| try findLambdasInExpr(self, ti.receiver, def, info),
        .index => |ix| {
            try findLambdasInExpr(self, ix.receiver, def, info);
            try findLambdasInExpr(self, ix.index, def, info);
        },
        .range => |r| {
            try findLambdasInExpr(self, r.start, def, info);
            try findLambdasInExpr(self, r.end, def, info);
        },
        .is_test => |it| try findLambdasInExpr(self, it.lhs, def, info),
        .ref_of => |r| try findLambdasInExpr(self, r.inner, def, info),
        .cast => |c| try findLambdasInExpr(self, c.inner, def, info),
        .str_lit => |sl| for (sl.parts) |part| switch (part) {
            .interp => |ip| try findLambdasInExpr(self, ip.expr, def, info),
            .lit => {},
        },
        .list_lit => |ll| for (ll.elems) |el| try findLambdasInExpr(self, el, def, info),
        .list_repeat => |lr| {
            try findLambdasInExpr(self, lr.value, def, info);
            try findLambdasInExpr(self, lr.count, def, info);
        },
        .struct_lit => |stl| for (stl.fields) |f| try findLambdasInExpr(self, f.value, def, info),
        .tuple_lit => |tl| for (tl.elems) |el| try findLambdasInExpr(self, el, def, info),
        .do_expr => |de| for (de.body) |inner| try findLambdasInStatement(self, inner, def, info),
        .if_expr => |ie| {
            for (ie.arms) |arm| {
                if (arm.cond) |c| try findLambdasInExpr(self, c, def, info);
                if (arm.let_expr) |le| try findLambdasInExpr(self, le, def, info);
                if (arm.let_guard) |lg| try findLambdasInExpr(self, lg, def, info);
                for (arm.body) |inner| try findLambdasInStatement(self, inner, def, info);
            }
            if (ie.else_body) |eb| for (eb) |inner| try findLambdasInStatement(self, inner, def, info);
        },
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
const Scope = std.StringHashMapUnmanaged(void);
const CollectError = error{OutOfMemory};

/// Free variables of `lambda` — names its body reads that resolve to an
/// ENCLOSING binding (captures). A single scoped pass: the lambda's own
/// params seed a base scope; statements add their bindings as they're
/// walked (so a `let` is invisible to its own init and to earlier
/// statements), and each nested block (do / for / if / while / match /
/// repeat) walks in a CHILD scope so its locals shadow correctly and
/// don't leak. An ident not bound in the active scope is a capture.
fn collectFreeVars(
    self: *Emitter,
    lambda: *const ast.LambdaExpr,
    captures: *std.ArrayListUnmanaged([]const u8),
    cap_types: *CaptureTypes,
    def: *const ast.DefDecl,
) CollectError!void {
    var scope: Scope = .{};
    for (lambda.params) |p| try scope.put(self.arena, self.source[p.name.start..p.name.end], {});
    try captureWalkBody(self, lambda.body, &scope, captures, cap_types, def);
}

fn cloneScope(self: *Emitter, scope: *const Scope) CollectError!Scope {
    var c: Scope = .{};
    var it = scope.iterator();
    while (it.next()) |e| try c.put(self.arena, e.key_ptr.*, {});
    return c;
}

/// Add every name a pattern binds (`let`-binder, `match` / `if let` arm)
/// into `scope`.
fn capturePatternBinders(self: *Emitter, p: *const ast.Pattern, scope: *Scope) CollectError!void {
    switch (p.*) {
        .ident => |i| try scope.put(self.arena, self.source[i.name.start..i.name.end], {}),
        .tuple_pattern => |t| for (t.elems) |e| try capturePatternBinders(self, e, scope),
        .variant_pattern => |v| for (v.args) |a| try capturePatternBinders(self, a, scope),
        .struct_pattern => |st| for (st.fields) |f| try capturePatternBinders(self, f.sub, scope),
        .or_pattern => |o| for (o.alts) |a| try capturePatternBinders(self, a, scope),
        else => {},
    }
}

fn captureWalkBody(self: *Emitter, body: []const ast.Statement, scope: *Scope, captures: *std.ArrayListUnmanaged([]const u8), cap_types: *CaptureTypes, def: *const ast.DefDecl) CollectError!void {
    for (body) |s| try captureWalkStmt(self, s, scope, captures, cap_types, def);
}

/// Walk `child_body` in a fresh child scope so its bindings shadow + don't
/// leak. `seed`, if non-null, is a pattern whose binders enter the child
/// scope first (loop / match / if-let binders).
fn captureWalkChild(self: *Emitter, child_body: []const ast.Statement, scope: *const Scope, seed: ?*const ast.Pattern, loop_var: ?ast.Span, captures: *std.ArrayListUnmanaged([]const u8), cap_types: *CaptureTypes, def: *const ast.DefDecl) CollectError!void {
    var child = try cloneScope(self, scope);
    if (loop_var) |lv| try child.put(self.arena, self.source[lv.start..lv.end], {});
    if (seed) |p| try capturePatternBinders(self, p, &child);
    try captureWalkBody(self, child_body, &child, captures, cap_types, def);
}

fn captureWalkStmt(self: *Emitter, s: ast.Statement, scope: *Scope, captures: *std.ArrayListUnmanaged([]const u8), cap_types: *CaptureTypes, def: *const ast.DefDecl) CollectError!void {
    switch (s) {
        .let_decl => |d| {
            if (d.init) |init_expr| try captureWalkExpr(self, init_expr, scope, captures, cap_types, def);
            try capturePatternBinders(self, d.pattern, scope);
        },
        .const_decl => |d| {
            try captureWalkExpr(self, d.init, scope, captures, cap_types, def);
            try scope.put(self.arena, self.source[d.name.start..d.name.end], {});
        },
        .assign => |a| {
            try captureWalkExpr(self, a.target, scope, captures, cap_types, def);
            try captureWalkExpr(self, a.value, scope, captures, cap_types, def);
        },
        .inc_dec => |id| try captureWalkExpr(self, id.target, scope, captures, cap_types, def),
        .return_stmt => |rs| if (rs.value) |v| try captureWalkExpr(self, v, scope, captures, cap_types, def),
        .expr_stmt => |es| try captureWalkExpr(self, es.expr, scope, captures, cap_types, def),
        .discard => |d| try captureWalkExpr(self, d.expr, scope, captures, cap_types, def),
        .print_stmt => |ps| for (ps.args) |a| try captureWalkExpr(self, a, scope, captures, cap_types, def),
        .block => |b| try captureWalkChild(self, b.body, scope, null, null, captures, cap_types, def),
        .if_stmt => |is_| {
            for (is_.arms) |arm| {
                if (arm.cond) |c| try captureWalkExpr(self, c, scope, captures, cap_types, def);
                if (arm.let_expr) |le| try captureWalkExpr(self, le, scope, captures, cap_types, def);
                try captureWalkArm(self, arm.body, scope, arm.let_pattern, arm.let_guard, captures, cap_types, def);
            }
            if (is_.else_body) |eb| try captureWalkChild(self, eb, scope, null, null, captures, cap_types, def);
        },
        .while_stmt => |ws| {
            if (ws.cond) |c| try captureWalkExpr(self, c, scope, captures, cap_types, def);
            if (ws.let_expr) |le| try captureWalkExpr(self, le, scope, captures, cap_types, def);
            try captureWalkArm(self, ws.body, scope, ws.let_pattern, ws.let_guard, captures, cap_types, def);
        },
        .for_stmt => |fs| {
            try captureWalkExpr(self, fs.iter, scope, captures, cap_types, def);
            if (fs.step) |step_e| try captureWalkExpr(self, step_e, scope, captures, cap_types, def);
            try captureWalkChild(self, fs.body, scope, null, fs.binding, captures, cap_types, def);
        },
        .repeat_stmt => |rs| {
            // `repeat … until cond`: the cond runs after the body, in its scope.
            var child = try cloneScope(self, scope);
            try captureWalkBody(self, rs.body, &child, captures, cap_types, def);
            try captureWalkExpr(self, rs.cond, &child, captures, cap_types, def);
        },
        .match_stmt => |ms| {
            try captureWalkExpr(self, ms.scrutinee, scope, captures, cap_types, def);
            for (ms.arms) |arm| try captureWalkArm(self, arm.body, scope, arm.pattern, arm.guard, captures, cap_types, def);
        },
        else => {},
    }
}

/// An arm body with optional pattern binders + a guard, all in a child scope.
fn captureWalkArm(self: *Emitter, body: []const ast.Statement, scope: *const Scope, pat: ?*const ast.Pattern, guard: ?*const ast.Expr, captures: *std.ArrayListUnmanaged([]const u8), cap_types: *CaptureTypes, def: *const ast.DefDecl) CollectError!void {
    var child = try cloneScope(self, scope);
    if (pat) |p| try capturePatternBinders(self, p, &child);
    if (guard) |g| try captureWalkExpr(self, g, &child, captures, cap_types, def);
    try captureWalkBody(self, body, &child, captures, cap_types, def);
}

fn captureWalkExpr(self: *Emitter, e: *const ast.Expr, scope: *const Scope, captures: *std.ArrayListUnmanaged([]const u8), cap_types: *CaptureTypes, def: *const ast.DefDecl) CollectError!void {
    switch (e.*) {
        .ident => |i| {
            const name = self.source[i.span.start..i.span.end];
            if (scope.contains(name)) return;
            if (self.typeOf(e)) |ty| try cap_types.put(self.arena, name, ty);
            for (captures.items) |existing| if (std.mem.eql(u8, existing, name)) return;
            try captures.append(self.arena, name);
        },
        // `self` inside a method-defined lambda is a capture: the lambda
        // body is a separate def, so it reads the enclosing method's
        // receiver from its env, not from an `fp+4` it doesn't own.
        .self_expr => |se| {
            const name = self.source[se.span.start..se.span.end];
            if (scope.contains(name)) return;
            if (self.typeOf(e)) |ty| try cap_types.put(self.arena, name, ty);
            for (captures.items) |existing| if (std.mem.eql(u8, existing, name)) return;
            try captures.append(self.arena, name);
        },
        .paren => |p| try captureWalkExpr(self, p.inner, scope, captures, cap_types, def),
        .unary => |u| try captureWalkExpr(self, u.operand, scope, captures, cap_types, def),
        .binary => |b| {
            try captureWalkExpr(self, b.lhs, scope, captures, cap_types, def);
            try captureWalkExpr(self, b.rhs, scope, captures, cap_types, def);
        },
        .range => |r| {
            try captureWalkExpr(self, r.start, scope, captures, cap_types, def);
            try captureWalkExpr(self, r.end, scope, captures, cap_types, def);
        },
        .call => |c| {
            try captureWalkExpr(self, c.callee, scope, captures, cap_types, def);
            for (c.args) |a| try captureWalkExpr(self, a, scope, captures, cap_types, def);
        },
        .method_call => |m| {
            try captureWalkExpr(self, m.receiver, scope, captures, cap_types, def);
            for (m.args) |a| try captureWalkExpr(self, a, scope, captures, cap_types, def);
        },
        .field => |f| try captureWalkExpr(self, f.receiver, scope, captures, cap_types, def),
        .tuple_index => |ti| try captureWalkExpr(self, ti.receiver, scope, captures, cap_types, def),
        .index => |ix| {
            try captureWalkExpr(self, ix.receiver, scope, captures, cap_types, def);
            try captureWalkExpr(self, ix.index, scope, captures, cap_types, def);
        },
        .is_test => |it| try captureWalkExpr(self, it.lhs, scope, captures, cap_types, def),
        .ref_of => |r| try captureWalkExpr(self, r.inner, scope, captures, cap_types, def),
        .cast => |c| try captureWalkExpr(self, c.inner, scope, captures, cap_types, def),
        .str_lit => |sl| for (sl.parts) |part| switch (part) {
            .interp => |ip| try captureWalkExpr(self, ip.expr, scope, captures, cap_types, def),
            .lit => {},
        },
        .list_lit => |ll| for (ll.elems) |el| try captureWalkExpr(self, el, scope, captures, cap_types, def),
        .list_repeat => |lr| {
            try captureWalkExpr(self, lr.value, scope, captures, cap_types, def);
            try captureWalkExpr(self, lr.count, scope, captures, cap_types, def);
        },
        .struct_lit => |stl| for (stl.fields) |f| try captureWalkExpr(self, f.value, scope, captures, cap_types, def),
        .tuple_lit => |tl| for (tl.elems) |el| try captureWalkExpr(self, el, scope, captures, cap_types, def),
        // `do` / `if` value blocks open a nested scope.
        .do_expr => |de| try captureWalkChild(self, de.body, scope, null, null, captures, cap_types, def),
        .if_expr => |ie| {
            for (ie.arms) |arm| {
                if (arm.cond) |c| try captureWalkExpr(self, c, scope, captures, cap_types, def);
                if (arm.let_expr) |le| try captureWalkExpr(self, le, scope, captures, cap_types, def);
                try captureWalkArm(self, arm.body, scope, arm.let_pattern, arm.let_guard, captures, cap_types, def);
            }
            if (ie.else_body) |eb| try captureWalkChild(self, eb, scope, null, null, captures, cap_types, def);
        },
        // Nested lambda — names IT captures from outside its own params +
        // locals that ALSO aren't bound in THIS scope are transitively
        // captures of this lambda (we re-read them from our env at the
        // inner closure's creation).
        .lambda => {
            var inner_captures: std.ArrayListUnmanaged([]const u8) = .empty;
            var inner_types: CaptureTypes = .{};
            try collectFreeVars(self, &e.lambda, &inner_captures, &inner_types, def);
            for (inner_captures.items) |inner_cap| {
                if (scope.contains(inner_cap)) continue;
                for (captures.items) |existing| {
                    if (std.mem.eql(u8, existing, inner_cap)) break;
                } else {
                    try captures.append(self.arena, inner_cap);
                    if (inner_types.get(inner_cap)) |ty| try cap_types.put(self.arena, inner_cap, ty);
                }
            }
        },
        else => {},
    }
}

/// The root ident of an assignment target — peels `.field` / `.index` /
/// `.tuple_index` down to the base binding (null for a `self` / non-ident
/// base).
fn rootIdent(e: *const ast.Expr) ?*const ast.Expr {
    return switch (e.*) {
        .ident => e,
        .field => |f| rootIdent(f.receiver),
        .index => |ix| rootIdent(ix.receiver),
        .tuple_index => |ti| rootIdent(ti.receiver),
        else => null,
    };
}

/// Record what an assignment mutates. A bare `x = …` mutates the binding
/// `x`. A `x.field = …` / `x[i] = …` mutates the aggregate `x` IN PLACE,
/// so its root counts as mutated — but only for an inline aggregate (a
/// class field write goes through a shared pointer and needs no
/// promotion).
fn markAssignTarget(self: *Emitter, target: *const ast.Expr, mutated: *std.StringHashMapUnmanaged(void)) void {
    if (target.* == .ident) {
        mutated.put(self.arena, self.source[target.ident.span.start..target.ident.span.end], {}) catch return;
        return;
    }
    const root = rootIdent(target) orelse return;
    const ty = self.typeOf(root) orelse return;
    if (!isInlineAggregateType(self, ty)) return;
    mutated.put(self.arena, self.source[root.ident.span.start..root.ident.span.end], {}) catch return;
}

fn collectMutatedInStatement(
    self: *Emitter,
    s: ast.Statement,
    mutated: *std.StringHashMapUnmanaged(void),
) void {
    switch (s) {
        .assign => |a| markAssignTarget(self, a.target, mutated),
        .inc_dec => |id| markAssignTarget(self, id.target, mutated),
        .block => |b| for (b.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .if_stmt => |is_| {
            for (is_.arms) |arm| for (arm.body) |inner| collectMutatedInStatement(self, inner, mutated);
            if (is_.else_body) |eb| for (eb) |inner| collectMutatedInStatement(self, inner, mutated);
        },
        .while_stmt => |ws| for (ws.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .for_stmt => |fs| for (fs.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .repeat_stmt => |rs| for (rs.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .match_stmt => |ms| for (ms.arms) |arm| for (arm.body) |inner| collectMutatedInStatement(self, inner, mutated),
        .return_stmt => |rs| if (rs.value) |v| collectMutatedInExpr(self, v, mutated),
        .expr_stmt => |es| collectMutatedInExpr(self, es.expr, mutated),
        .print_stmt => |ps| for (ps.args) |a| collectMutatedInExpr(self, a, mutated),
        // A `let`/`const` whose init is (or contains) a lambda: descend so
        // a binding mutated inside that closure body counts as mutated.
        .let_decl => |d| if (d.init) |init_expr| collectMutatedInExpr(self, init_expr, mutated),
        .const_decl => |d| collectMutatedInExpr(self, d.init, mutated),
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
    } else if (e.* == .do_expr) {
        // A `do … end` value block (common as a lambda body) runs
        // statements — its assignments count.
        for (e.do_expr.body) |stmt| collectMutatedInStatement(self, stmt, mutated);
    } else if (e.* == .if_expr) {
        for (e.if_expr.arms) |arm| for (arm.body) |stmt| collectMutatedInStatement(self, stmt, mutated);
        if (e.if_expr.else_body) |eb| for (eb) |stmt| collectMutatedInStatement(self, stmt, mutated);
    } else if (e.* == .method_call) {
        // A method takes `self` by pointer and may mutate an inline
        // aggregate receiver in place (`v.push(…)` grows a Vec header), so
        // conservatively count its root as mutated — a read-only method
        // just over-shares the buffer, which is harmless.
        if (rootIdent(e.method_call.receiver)) |root| {
            if (self.typeOf(root)) |ty| if (isInlineAggregateType(self, ty)) {
                mutated.put(self.arena, self.source[root.ident.span.start..root.ident.span.end], {}) catch {};
            };
        }
        for (e.method_call.args) |a| collectMutatedInExpr(self, a, mutated);
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
        .match_stmt => |ms| for (ms.arms) |arm| for (arm.body) |inner| collectEscapingCaptures(self, inner, info, out),
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

/// `true` when `name` resolves to a module-level callable or type — a
/// free function, class, enum, or struct. These are globally addressable
/// (a lambda body reaches them directly), so they are never captured.
fn isModuleName(self: *const Emitter, name: []const u8) bool {
    return self.fn_banks.contains(name) or
        self.class_decls.contains(name) or
        self.enum_decls.contains(name) or
        self.struct_decls.contains(name);
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
        try isa.movRegOffsetToReg(self, base, @as(i8, @intCast(offset)), dst);
        return;
    }
    try isa.movRegToReg(self, base, Reg.r2);
    try isa.addImmToReg(self, offset, Reg.r2);
    try isa.movRegOffsetToReg(self, Reg.r2, 0, dst);
}

fn emitWordStoreAtOffset(self: *Emitter, base: u8, offset: u16, src: u8) !void {
    if (offset <= 127) {
        // @as: offset fits i8 (≤127); the cast is a no-op for the value range.
        try isa.movRegToRegOffset(self, src, base, @as(i8, @intCast(offset)));
        return;
    }
    try isa.movRegToReg(self, base, Reg.r3);
    try isa.addImmToReg(self, offset, Reg.r3);
    try isa.movRegToRegOffset(self, src, Reg.r3, 0);
}
