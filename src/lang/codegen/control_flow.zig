const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const pattern = @import("pattern.zig");
const destructure = @import("destructure.zig");
const class = @import("class.zig");
const value_struct = @import("value_struct.zig");
const vec_builtin = @import("vec_builtin.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Type = types.Type;
const LoopFrame = codegen.LoopFrame;

/// Walk `body` inside a fresh block scope. The common helper for
/// any statement-list with its own defer lifetime (do-blocks, if
/// arm bodies, loop bodies, match-arm bodies).
pub fn emitScopedBody(self: *Emitter, body: []const ast.Statement) error{OutOfMemory}!void {
    try pushBlock(self);
    for (body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);
}

/// Lower a `do…end` block at statement position — opens a
/// fresh scope, walks the body, fires the block's defers on
/// fall-through.
pub fn emitBlockStmt(self: *Emitter, b: ast.BlockStmt) !void {
    try emitScopedBody(self, b.body);
}

/// Register a `defer body` on the innermost active block. The
/// typechecker has already rejected the forbidden body shapes
/// (`defer return / break / continue / defer`).
pub fn emitDeferStmt(self: *Emitter, ds: ast.DeferStmt) !void {
    if (self.block_stack.items.len == 0) {
        try self.diagFatal(ds.span, "E_CODEGEN_DEFER_NO_BLOCK", "codegen: `defer` outside a block — likely a frontend bug");
        return;
    }
    const top = self.block_stack.items.len - 1;
    try self.block_stack.items[top].defers.append(self.allocator, ds.body);
}

// ---------- block + defer helpers ----------

/// Open a fresh lexical block on top of `block_stack`.
pub fn pushBlock(self: *Emitter) !void {
    try self.block_stack.append(self.allocator, .{ .defers = .empty });
}

/// Close the innermost block, emitting its registered `defer`
/// statements inline in LIFO order before discarding the block.
pub fn popBlockWithDefers(self: *Emitter) !void {
    const top = self.block_stack.items.len - 1;
    const block = &self.block_stack.items[top];
    try emitDefersLifo(self, block.defers.items);
    var popped = self.block_stack.pop().?;
    popped.defers.deinit(self.allocator);
}

/// Emit `stmts` in LIFO order, preserving `acu` across the
/// cleanup sequence (so a `return value` keeps its value visible
/// to the caller after defers run).
pub fn emitDefersLifo(self: *Emitter, stmts: []const *const ast.Statement) !void {
    if (stmts.len == 0) return;
    try isa.pushReg(self, Reg.acu);
    var i = stmts.len;
    while (i > 0) {
        i -= 1;
        try self.emitStatement(stmts[i].*);
    }
    try isa.popReg(self, Reg.acu);
}

/// Emit every active block's defers in LIFO order from the
/// innermost outward — used on the `return` path.
pub fn unwindAllDefersForReturn(self: *Emitter) !void {
    var bi = self.block_stack.items.len;
    while (bi > 0) {
        bi -= 1;
        try emitDefersLifo(self, self.block_stack.items[bi].defers.items);
    }
}

/// Emit defers for every block in `[body_block_idx .. top]`
/// inclusive — the range to unwind on `break` / `continue` for
/// the loop whose body opens at `body_block_idx`.
pub fn unwindDefersDownTo(self: *Emitter, body_block_idx: usize) !void {
    var bi = self.block_stack.items.len;
    while (bi > body_block_idx) {
        bi -= 1;
        try emitDefersLifo(self, self.block_stack.items[bi].defers.items);
    }
}

/// Walk the loop stack from innermost outward looking for the
/// frame targeted by a `break` / `continue`. Unlabeled jumps
/// match the innermost frame; labeled jumps match by string
/// equality.
pub fn findLoopFrame(self: *Emitter, label_span: ?ast.Span) ?*LoopFrame {
    if (self.loop_stack.items.len == 0) return null;
    const want_label: ?[]const u8 = if (label_span) |s|
        self.source[s.start..s.end]
    else
        null;
    var i = self.loop_stack.items.len;
    while (i > 0) {
        i -= 1;
        const f = &self.loop_stack.items[i];
        if (want_label) |w| {
            if (f.label) |fl| if (std.mem.eql(u8, fl, w)) return f;
        } else {
            return f; // innermost
        }
    }
    return null;
}

// ---------- if ----------

/// Lower `if cond1 then ... elif cond2 then ... else ... end`.
/// Each arm emits its condition test (jumping over the body on
/// false), then the body, then a forward jump over every later
/// arm. The forward jumps collapse at the end of the if chain
/// onto one shared `end` label.
pub fn emitIfStmt(self: *Emitter, is_: ast.IfStmt) !void {
    var end_patches: std.ArrayList(usize) = .empty;
    defer end_patches.deinit(self.allocator);

    for (is_.arms) |arm| {
        const skip_body_patch = try emitIfArmTest(self, arm);
        try emitScopedBody(self, arm.body);
        try end_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));
        const after_body = try self.currentOffset();
        try isa.patchJumpTo(self, skip_body_patch, after_body);
    }

    if (is_.else_body) |eb| try emitScopedBody(self, eb);

    const end_offset = try self.currentOffset();
    for (end_patches.items) |p| try isa.patchJumpTo(self, p, end_offset);
}

/// Lower `if expr is ClassName as h ...`. Evaluates the receiver
/// once, parks the instance pointer in a fresh local bound to
/// `h`, then compares the vtable pointer. The local stays live
/// for the arm body so `h.method()` resolves cleanly.
fn emitIsClassBindingTest(
    self: *Emitter,
    cond: *const ast.Expr,
    probe: ast.IsTestExpr.ClassTypeProbe,
) !usize {
    const class_name = self.source[probe.class_name.start..probe.class_name.end];
    const bind_lex = self.source[probe.binding.?.start..probe.binding.?.end];
    const bind_dup = try self.arena.dupe(u8, bind_lex);
    const ofs = try self.allocLocal(bind_dup);
    // Eval receiver → acu = instance ptr; persist into the local
    // so the arm body's reference to `h` reads the same address.
    try self.emitExpr(cond.is_test.lhs);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
    // Load vtable ptr into r1.
    try self.emitByte(Op.mov_ptr_to_reg);
    try self.emitByte(Reg.r1);
    try self.emitByte(Reg.acu);
    // `cmp r1, <vtable_addr>` — patched after `emitVtables`.
    try self.emitByte(Op.cmp_reg_imm16);
    try self.emitByte(Reg.r1);
    const patch_offset = try self.currentOffset();
    try self.emitU16Le(0);
    try self.vtable_patches.append(self.allocator, .{
        .bank = self.current_bank,
        .code_offset = patch_offset,
        .class_name = try self.arena.dupe(u8, class_name),
    });
    return try isa.emitJumpPlaceholder(self, Op.jne_addr);
}

/// Emit the test for one if-arm and return the offset of the
/// "skip body" jump patch — the caller resolves it to the byte
/// right after the body.
fn emitIfArmTest(self: *Emitter, arm: ast.IfArm) !usize {
    if (arm.cond) |c| {
        if (c.* == .is_test) if (c.is_test.classBinding()) |probe| {
            return try emitIsClassBindingTest(self, c, probe);
        };
        try self.emitCondBranch(c);
        return try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    }
    // `if let pat = expr [when guard]`. An optional scrutinee unwraps
    // (§3.4.1) — route it (even a bare ident) through the matcher.
    const expr = arm.let_expr.?;
    const is_optional = if (self.typeOf(expr)) |t| t.* == .optional else false;
    if (is_optional or arm.let_pattern.?.* != .ident) {
        return try emitLetPatternTest(self, arm.let_pattern.?, expr, arm.let_guard);
    }
    switch (arm.let_pattern.?.*) {
        .ident => |id| {
            try self.emitExpr(expr);
            const name = self.source[id.name.start..id.name.end];
            const dup = try self.arena.dupe(u8, name);
            const ofs = try self.allocLocal(dup);
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
            if (arm.let_guard) |g| {
                try self.emitExpr(g);
                try isa.cmpRegImm(self, Reg.acu, 0);
                return try isa.emitJumpPlaceholder(self, Op.jeq_addr);
            }
            // No guard — ident binder always matches; emit a
            // never-taken skip for symmetry with the cond arm.
            try isa.movImmToReg(self, 1, Reg.r1);
            try isa.cmpRegImm(self, Reg.r1, 0);
            return try isa.emitJumpPlaceholder(self, Op.jeq_addr);
        },
        else => return try emitLetPatternTest(self, arm.let_pattern.?, expr, arm.let_guard),
    }
}

/// Lower a non-ident `if let` / `while let` head: materialize the
/// scrutinee, run the destructuring matcher (+ optional `when` guard),
/// and funnel every mismatch into a single "skip body" jump — returned
/// for the caller to resolve to the else-arm / loop-exit. The matched
/// path jumps over that skip into the body.
fn emitLetPatternTest(self: *Emitter, pat: *const ast.Pattern, expr: *const ast.Expr, guard: ?*const ast.Expr) !usize {
    const ty = self.typeOf(expr);
    const slot = try destructure.materializeScrutinee(self, expr, ty);
    var skip: std.ArrayList(usize) = .empty;
    defer skip.deinit(self.allocator);
    try destructure.emitMatchPattern(self, pat, slot, ty, &skip);
    if (guard) |g| {
        try self.emitExpr(g);
        try isa.cmpRegImm(self, Reg.acu, 0);
        try skip.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
    }
    const body_jump = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    const skip_here = try self.currentOffset();
    for (skip.items) |p| try isa.patchJumpTo(self, p, skip_here);
    const combined = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, body_jump, try self.currentOffset());
    return combined;
}

// ---------- while / repeat / for ----------

/// Lower `while cond ... end`. Standard top-test loop:
/// continue-target sits at the cond test, exit-target at the
/// byte after the back-edge. `while let` is supported for the
/// ident-binder form per spec §4.5.2.
pub fn emitWhileStmt(self: *Emitter, ws: ast.WhileStmt) !void {
    const cond_offset = try self.currentOffset();
    const label_str: ?[]const u8 = if (ws.label) |s|
        try self.arena.dupe(u8, self.source[s.start..s.end])
    else
        null;

    try pushBlock(self);
    const body_block_idx = self.block_stack.items.len - 1;
    try self.loop_stack.append(self.allocator, .{
        .label = label_str,
        .body_block_idx = body_block_idx,
        .break_patches = .empty,
        .continue_patches = .empty,
    });

    const exit_on_false_patch = if (ws.cond) |c| blk: {
        try self.emitCondBranch(c);
        break :blk try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    } else blk: {
        // An optional scrutinee unwraps (§3.4.1) — route it (even a bare
        // ident) through the matcher.
        const is_optional = if (self.typeOf(ws.let_expr.?)) |t| t.* == .optional else false;
        if (is_optional or ws.let_pattern.?.* != .ident) {
            break :blk try emitLetPatternTest(self, ws.let_pattern.?, ws.let_expr.?, ws.let_guard);
        }
        switch (ws.let_pattern.?.*) {
            .ident => |id| {
                try self.emitExpr(ws.let_expr.?);
                const name = self.source[id.name.start..id.name.end];
                const dup = try self.arena.dupe(u8, name);
                const ofs = try self.allocLocal(dup);
                try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
                if (ws.let_guard) |g| {
                    try self.emitExpr(g);
                    try isa.cmpRegImm(self, Reg.acu, 0);
                    break :blk try isa.emitJumpPlaceholder(self, Op.jeq_addr);
                }
                try isa.movImmToReg(self, 1, Reg.r1);
                try isa.cmpRegImm(self, Reg.r1, 0);
                break :blk try isa.emitJumpPlaceholder(self, Op.jeq_addr);
            },
            else => break :blk try emitLetPatternTest(self, ws.let_pattern.?, ws.let_expr.?, ws.let_guard),
        }
    };

    for (ws.body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);

    try isa.emitJumpBack(self, cond_offset);

    const exit_offset = try self.currentOffset();
    try isa.patchJumpTo(self, exit_on_false_patch, exit_offset);

    var frame = self.loop_stack.pop().?;
    for (frame.break_patches.items) |p| try isa.patchJumpTo(self, p, exit_offset);
    for (frame.continue_patches.items) |p| try isa.patchJumpTo(self, p, cond_offset);
    frame.break_patches.deinit(self.allocator);
    frame.continue_patches.deinit(self.allocator);
}

/// Lower `repeat body until cond`. Bottom-test loop: the body
/// runs at least once; `cond` is tested after the body and the
/// loop exits when `cond` is truthy.
pub fn emitRepeatStmt(self: *Emitter, rs: ast.RepeatStmt) !void {
    const top_offset = try self.currentOffset();
    const label_str: ?[]const u8 = if (rs.label) |s|
        try self.arena.dupe(u8, self.source[s.start..s.end])
    else
        null;

    try pushBlock(self);
    const body_block_idx = self.block_stack.items.len - 1;
    try self.loop_stack.append(self.allocator, .{
        .label = label_str,
        .body_block_idx = body_block_idx,
        .break_patches = .empty,
        .continue_patches = .empty,
    });

    for (rs.body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);

    // `continue` jumps here — the trailing `until` test.
    const test_offset = try self.currentOffset();
    try self.emitCondBranch(rs.cond);
    // Falsy cond → loop back to top; truthy → fall through to exit.
    try self.emitByte(Op.jeq_addr);
    // @as: usize → u16; per-buffer offset stays ≤ 64 KiB.
    const top_in_buffer: u16 = @intCast(top_offset);
    try self.emitU16Le(self.currentBufferBase() +% top_in_buffer);

    const exit_offset = try self.currentOffset();
    var frame = self.loop_stack.pop().?;
    for (frame.break_patches.items) |p| try isa.patchJumpTo(self, p, exit_offset);
    for (frame.continue_patches.items) |p| try isa.patchJumpTo(self, p, test_offset);
    frame.break_patches.deinit(self.allocator);
    frame.continue_patches.deinit(self.allocator);
}

/// Push a loop's block scope + loop frame (shared by the `for` family).
fn enterLoop(self: *Emitter, label_span: ?ast.Span) !void {
    const label_str: ?[]const u8 = if (label_span) |s|
        try self.arena.dupe(u8, self.source[s.start..s.end])
    else
        null;
    try pushBlock(self);
    const body_block_idx = self.block_stack.items.len - 1;
    try self.loop_stack.append(self.allocator, .{
        .label = label_str,
        .body_block_idx = body_block_idx,
        .break_patches = .empty,
        .continue_patches = .empty,
    });
}

/// Pop the innermost loop frame, resolving its `break` jumps to
/// `exit_offset` and `continue` jumps to `continue_offset`.
fn exitLoop(self: *Emitter, exit_offset: usize, continue_offset: usize) !void {
    var frame = self.loop_stack.pop().?;
    for (frame.break_patches.items) |p| try isa.patchJumpTo(self, p, exit_offset);
    for (frame.continue_patches.items) |p| try isa.patchJumpTo(self, p, continue_offset);
    frame.break_patches.deinit(self.allocator);
    frame.continue_patches.deinit(self.allocator);
}

/// `reg = fp + ofs` — the address of a frame slot.
fn frameAddr(self: *Emitter, ofs: i8, reg: u8) !void {
    try isa.movRegToReg(self, Reg.fp, reg);
    if (ofs < 0) {
        // @as: |ofs| ≤ 127 fits u16.
        try isa.subImmFromReg(self, @intCast(-@as(i16, ofs)), reg);
    } else if (ofs > 0) {
        try isa.addImmToReg(self, @intCast(ofs), reg);
    }
}

/// Lower `for x in <iterable> body end` (§4.5.3). Ranges + the built-in
/// iterables (`[T; N]` / `Vec(T)` / `str`) emit direct memory loops; a
/// class with `next(self) -> T?` desugars to the iterator protocol.
pub fn emitForStmt(self: *Emitter, fs: ast.ForStmt) !void {
    if (fs.iter.* == .range) return emitForRange(self, fs);
    const it_ty = self.typeOf(fs.iter) orelse {
        try self.unsupported(fs.span, "`for` over a value of unknown type");
        return;
    };
    switch (it_ty.*) {
        .array => try emitForArray(self, fs),
        .vec => |elem| try emitForVec(self, fs, elem),
        .primitive => |p| if (p == .str)
            try emitForStr(self, fs)
        else
            try self.unsupported(fs.span, "`for` over this value"),
        .named => |n| try emitForIterator(self, fs, n.name),
        else => try self.unsupported(fs.span, "`for` over this value"),
    }
}

/// `for x in start..end [step S]` — the range special case (§4.5.1). No
/// allocation, no iterator object: a hidden `end` slot bounds the
/// iteration variable, which steps by `S` (default 1) each pass.
fn emitForRange(self: *Emitter, fs: ast.ForStmt) !void {
    const range = fs.iter.range;
    const inclusive = range.inclusive;
    const dup_name = try self.arena.dupe(u8, self.source[fs.binding.start..fs.binding.end]);
    const var_ofs = try self.allocLocal(dup_name);
    const end_ofs = try self.allocLocal("\x00__for_end");

    try self.emitExpr(range.start);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, var_ofs);
    try self.emitExpr(range.end);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, end_ofs);

    try enterLoop(self, fs.label);

    // Top-of-loop: load `current`, load `end`, compare. Exit when current
    // > end (inclusive) or current >= end (exclusive).
    const test_offset = try self.currentOffset();
    try isa.movRegOffsetToReg(self, Reg.fp, var_ofs, Reg.acu);
    try isa.movRegOffsetToReg(self, Reg.fp, end_ofs, Reg.r1);
    try isa.cmpRegReg(self, Reg.acu, Reg.r1);
    const exit_patch = if (inclusive)
        try isa.emitJumpPlaceholder(self, Op.jgt_addr)
    else
        try isa.emitJumpPlaceholder(self, Op.jge_addr);

    for (fs.body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);

    // `continue` target — the step-and-back-edge.
    const continue_offset = try self.currentOffset();
    try isa.movRegOffsetToReg(self, Reg.fp, var_ofs, Reg.acu);
    if (fs.step) |se| {
        if (se.* == .int_lit) {
            // @as: parser stores int_lit as i32; range steps fit i16 per spec §4.5.1.
            const step_i16: i16 = @truncate(se.int_lit.value);
            // safety: i16 → u16 keeps the two's-complement bit pattern for negative steps.
            const step_val: u16 = @bitCast(step_i16);
            try isa.addImmToReg(self, step_val, Reg.acu);
        } else {
            try isa.pushReg(self, Reg.acu);
            try self.emitExpr(se);
            try isa.movRegToReg(self, Reg.acu, Reg.r1);
            try isa.popReg(self, Reg.acu);
            try isa.addRegToAcu(self, Reg.r1);
        }
    } else {
        try isa.addImmToReg(self, 1, Reg.acu);
    }
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, var_ofs);
    try isa.emitJumpBack(self, test_offset);

    const exit_offset = try self.currentOffset();
    try isa.patchJumpTo(self, exit_patch, exit_offset);
    try exitLoop(self, exit_offset, continue_offset);
}

/// `for x in arr` (`[T; N]`) — snapshot the base address + the comptime
/// element count into hidden slots, then index `0..count`. An array
/// literal is an rvalue, so it's materialized into a temp slot first; an
/// addressable array (ident / field) yields its base address directly.
fn emitForArray(self: *Emitter, fs: ast.ForStmt) !void {
    const info = self.arrayInfoOf(fs.iter) orelse {
        try self.unsupported(fs.span, "`for` over a non-array value");
        return;
    };
    const base_ofs = try self.allocLocal("\x00__for_base");
    const cnt_ofs = try self.allocLocal("\x00__for_cnt");
    if (fs.iter.* == .list_lit or fs.iter.* == .list_repeat) {
        // @as: array width is bounded by the i8 frame cap.
        const width: u16 = @intCast(@as(u32, info.elem_width) * info.count);
        const arr_ofs = try self.allocLocalSized("\x00__for_lit", width);
        try value_struct.emitArrayInto(self, fs.iter, info.elem, info.count, arr_ofs);
        try frameAddr(self, arr_ofs, Reg.acu);
    } else {
        try self.emitExpr(fs.iter); // an array value is its base address
    }
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, base_ofs);
    // @as: array count ≤ the i8 frame cap.
    try isa.movImmToReg(self, @intCast(info.count), Reg.acu);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, cnt_ofs);
    try emitIndexedBody(self, fs, base_ofs, cnt_ofs, info.elem);
}

/// `for x in v` (`Vec(T)`) — snapshot the heap buffer pointer + length
/// once, then index `0..len`. Mutating the Vec inside the body doesn't
/// reshape the iteration (the bounds are sampled up front).
fn emitForVec(self: *Emitter, fs: ast.ForStmt, elem: *const Type) !void {
    const base_ofs = try self.allocLocal("\x00__for_base");
    const cnt_ofs = try self.allocLocal("\x00__for_cnt");
    try self.emitExpr(fs.iter); // a Vec value is its header address
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try class.emitWordLoadAtOffset(self, Reg.r1, vec_builtin.ptr_ofs, Reg.acu);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, base_ofs);
    try class.emitWordLoadAtOffset(self, Reg.r1, vec_builtin.len_ofs, Reg.acu);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, cnt_ofs);
    try emitIndexedBody(self, fs, base_ofs, cnt_ofs, elem);
}

/// The shared `0..count` index loop for `[T; N]` / `Vec(T)`: `base_ofs`
/// holds the element buffer base, `cnt_ofs` the element count. Each pass
/// loads `base[i]` into the loop var, then steps `i`.
fn emitIndexedBody(self: *Emitter, fs: ast.ForStmt, base_ofs: i8, cnt_ofs: i8, elem: *const Type) !void {
    const ew = self.widthOfType(elem);
    const scalar = switch (self.arrayElemKindOf(elem)) {
        .scalar => true,
        else => false,
    };
    const idx_ofs = try self.allocLocal("\x00__for_i");
    const dup = try self.arena.dupe(u8, self.source[fs.binding.start..fs.binding.end]);
    const x_ofs = if (scalar) try self.allocLocal(dup) else try self.allocLocalSized(dup, self.widthOfType(elem));

    try isa.movImmToReg(self, 0, Reg.acu);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, idx_ofs);

    try enterLoop(self, fs.label);
    const test_offset = try self.currentOffset();
    // Exit when `i >= count` (unsigned: counts span the full u16 range).
    try isa.movRegOffsetToReg(self, Reg.fp, idx_ofs, Reg.acu);
    try isa.movRegOffsetToReg(self, Reg.fp, cnt_ofs, Reg.r1);
    try isa.cmpRegReg(self, Reg.acu, Reg.r1);
    const exit_patch = try isa.emitJumpPlaceholder(self, Op.jcc_addr);

    try emitElementInto(self, base_ofs, idx_ofs, ew, elem, scalar, x_ofs);

    for (fs.body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);

    const continue_offset = try self.currentOffset();
    try isa.movRegOffsetToReg(self, Reg.fp, idx_ofs, Reg.acu);
    try isa.addImmToReg(self, 1, Reg.acu);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, idx_ofs);
    try isa.emitJumpBack(self, test_offset);

    const exit_offset = try self.currentOffset();
    try isa.patchJumpTo(self, exit_patch, exit_offset);
    try exitLoop(self, exit_offset, continue_offset);
}

/// Load element `base[idx]` (width `ew`) into the loop var slot `x_ofs`.
/// A scalar element loads its value (sign-extending `i8`); an aggregate
/// element copies its bytes — the loop var is then address-valued, like
/// any inline-aggregate binding.
fn emitElementInto(self: *Emitter, base_ofs: i8, idx_ofs: i8, ew: u16, elem: *const Type, scalar: bool, x_ofs: i8) !void {
    try isa.movRegOffsetToReg(self, Reg.fp, idx_ofs, Reg.acu);
    try value_struct.scaleIndex(self, Reg.acu, ew); // acu = idx * ew
    try isa.movRegOffsetToReg(self, Reg.fp, base_ofs, Reg.r1);
    try isa.addRegToAcu(self, Reg.r1); // acu = &base[idx]
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = element address
    if (scalar) {
        if (ew == 1) {
            try class.emitByteLoadAtOffset(self, Reg.r1, 0, Reg.acu);
            if (elem.* == .primitive and elem.primitive == .i8) try isa.signExtendByte(self, Reg.acu);
        } else {
            try class.emitWordLoadAtOffset(self, Reg.r1, 0, Reg.acu);
        }
        try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, x_ofs);
    } else {
        try frameAddr(self, x_ofs, Reg.r2);
        try value_struct.copyBytes(self, Reg.r1, Reg.r2, self.widthOfType(elem));
    }
}

/// `for c in s` (`str`) — walk the null-terminated byte buffer: load
/// `[cursor]` into the `char` loop var, stop at the terminator, advance.
fn emitForStr(self: *Emitter, fs: ast.ForStmt) !void {
    const cursor_ofs = try self.allocLocal("\x00__for_cursor");
    const dup = try self.arena.dupe(u8, self.source[fs.binding.start..fs.binding.end]);
    const x_ofs = try self.allocLocal(dup); // the `char` loop var (a word slot)
    try self.emitExpr(fs.iter); // a str value is a pointer to its first byte
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, cursor_ofs);

    try enterLoop(self, fs.label);
    const test_offset = try self.currentOffset();
    try isa.movRegOffsetToReg(self, Reg.fp, cursor_ofs, Reg.r1);
    try class.emitByteLoadAtOffset(self, Reg.r1, 0, Reg.acu); // acu = [cursor] (zero-extended)
    try isa.cmpRegImm(self, Reg.acu, 0);
    const exit_patch = try isa.emitJumpPlaceholder(self, Op.jeq_addr); // null terminator → exit
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, x_ofs);

    for (fs.body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);

    const continue_offset = try self.currentOffset();
    try isa.movRegOffsetToReg(self, Reg.fp, cursor_ofs, Reg.acu);
    try isa.addImmToReg(self, 1, Reg.acu);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, cursor_ofs);
    try isa.emitJumpBack(self, test_offset);

    const exit_offset = try self.currentOffset();
    try isa.patchJumpTo(self, exit_patch, exit_offset);
    try exitLoop(self, exit_offset, continue_offset);
}

/// `for x in it` (a class with `next(self) -> T?`) — the iterator protocol
/// (§4.5.3). Evaluates the iterable once into a hidden slot (iteration is
/// destructive — the instance's own cursor advances), then each pass calls
/// `it.next()`, binds `x` to a present value, and exits on `nil`.
fn emitForIterator(self: *Emitter, fs: ast.ForStmt, class_name: []const u8) !void {
    const ret = (try class.methodReturnType(self, class_name, "next")) orelse {
        try self.unsupported(fs.span, "`for` over a class without a `next(self) -> T?` method");
        return;
    };
    if (ret.* != .optional) {
        try self.unsupported(fs.span, "iterator `next` must return `T?`");
        return;
    }
    const inner = ret.optional;
    const it_ofs = try self.allocLocal("\x00__for_it");
    const v_ofs = try self.allocLocalSized("\x00__for_v", self.widthOfType(ret));
    try class.emitInstancePtr(self, fs.iter);
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, it_ofs);

    try enterLoop(self, fs.label);
    // The `continue` target re-calls `next()`, so the test sits at the top.
    const test_offset = try self.currentOffset();
    try isa.movRegOffsetToReg(self, Reg.fp, it_ofs, Reg.acu); // acu = instance ptr
    try class.emitMethodDispatchOnInstance(self, class_name, "next", &.{}, fs.span);
    if (Emitter.isScalarOptional(inner)) {
        // acu = sret buffer address — copy the 4-byte {present, value}.
        try isa.movRegToReg(self, Reg.acu, Reg.r1);
        try frameAddr(self, v_ofs, Reg.r2);
        try value_struct.copyBytes(self, Reg.r1, Reg.r2, Emitter.opt_scalar_size);
    } else {
        // acu = the nullable pointer (nil = 0) — store the word.
        try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, v_ofs);
    }
    // Unwrap: bind the loop var to a present value; any `nil` skips to exit.
    var skip: std.ArrayList(usize) = .empty;
    defer skip.deinit(self.allocator);
    const x_pat: ast.Pattern = .{ .ident = .{ .name = fs.binding, .span = fs.binding } };
    try destructure.emitMatchPattern(self, &x_pat, v_ofs, ret, &skip);

    for (fs.body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);

    try isa.emitJumpBack(self, test_offset);

    const exit_offset = try self.currentOffset();
    for (skip.items) |p| try isa.patchJumpTo(self, p, exit_offset);
    try exitLoop(self, exit_offset, test_offset);
}

// ---------- break / continue ----------

/// Which forward-patch list a `break` / `continue` jump
/// records its placeholder onto.
pub const LoopJumpKind = enum { break_, continue_ };

/// Lower `break [:label]` / `continue [:label]`. Unwinds every
/// block between the jump site and the target loop, emits the
/// jump placeholder, and records it on the target frame's
/// `break_patches` / `continue_patches`.
pub fn emitLoopJump(self: *Emitter, j: ast.LoopJumpStmt, kind: LoopJumpKind) !void {
    const frame = findLoopFrame(self, j.label) orelse {
        try self.diagFatal(j.span, "E_CODEGEN_LOOP_JUMP_NO_LOOP", "codegen: `break` / `continue` outside an enclosing loop");
        return;
    };
    try unwindDefersDownTo(self, frame.body_block_idx);
    const patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    switch (kind) {
        .break_ => try frame.break_patches.append(self.allocator, patch),
        .continue_ => try frame.continue_patches.append(self.allocator, patch),
    }
}

// ---------- match ----------

/// Lower `match scrutinee case … end`. The fast path is a jump-
/// table indexed by tag byte, used when every arm is a bare
/// variant pattern (with an optional trailing wildcard) on a
/// nullary-payload enum scrutinee, with no guards (spec §4.8.5
/// "Single-arm tag dispatch"). The fallback is a sequential
/// `cmp + branch` decision tree: OR-patterns collapse onto one
/// shared body label, range patterns emit a single low+high cmp
/// pair, `when` guards run after the pattern bind.
pub fn emitMatchStmt(self: *Emitter, ms: ast.MatchStmt) !void {
    if (try tryEmitTagJumpTable(self, ms)) return;
    try emitMatchSequential(self, ms);
}

fn emitMatchSequential(self: *Emitter, ms: ast.MatchStmt) !void {
    // Materialize the scrutinee into a slot once so every arm re-tests it
    // without re-evaluating side effects. The destructuring matcher walks
    // each arm's pattern against that slot — tag tests + payload binders
    // for enums, element binds for tuple / struct patterns, leaf compares
    // for literals / ranges / or-patterns.
    const scrut_ty = self.typeOf(ms.scrutinee);
    const slot = try destructure.materializeScrutinee(self, ms.scrutinee, scrut_ty);

    var end_patches: std.ArrayList(usize) = .empty;
    defer end_patches.deinit(self.allocator);

    for (ms.arms) |arm| {
        var skip_patches: std.ArrayList(usize) = .empty;
        defer skip_patches.deinit(self.allocator);
        // Binders land before the guard so a `when` clause can read them
        // (`case Hit(d) when d > 10`).
        try destructure.emitMatchPattern(self, arm.pattern, slot, scrut_ty, &skip_patches);

        if (arm.guard) |g| {
            try self.emitExpr(g);
            try isa.cmpRegImm(self, Reg.acu, 0);
            try skip_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
        }

        try emitScopedBody(self, arm.body);
        try end_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));

        const after_arm = try self.currentOffset();
        for (skip_patches.items) |p| try isa.patchJumpTo(self, p, after_arm);
    }

    const end_offset = try self.currentOffset();
    for (end_patches.items) |p| try isa.patchJumpTo(self, p, end_offset);
}

/// Detect the spec §4.8.5 "single-arm tag dispatch" shape and,
/// when it matches, emit a jump table indexed by tag byte:
///
/// ```
///   ; acu = tag
///   cmp acu, max_tag                  ; bounds — fall back to default
///   jgt <default_or_end>
///   mov_reg_reg acu → r1
///   shl r1, 1                         ; r1 = 2*tag
///   add r1, acu                       ; acu = 3*tag (3-byte slots)
///   mov_imm16 <table>, r1
///   add r1, acu                       ; acu = table + 3*tag
///   jmp [acu]
/// table:
///   jmp_addr <body_0>                 ; 3 bytes per entry
///   jmp_addr <body_1>
///   …
///   jmp_addr <default_or_end>         ; for unmapped tags
/// body_0:
///   …
/// body_1:
///   …
/// ```
///
/// Returns `true` when the table was emitted; `false` punts to
/// the sequential lowerer. Eligibility (all must hold):
///
/// - Scrutinee's inferred type resolves to a registered enum
/// - Every arm pattern is either a bare nullary `EnumName.Variant`
///   or a `_` / ident wildcard (no payload binders, no OR,
///   no range, no literal)
/// - At most one wildcard arm (the implicit "default")
/// - No arm carries a `when` guard
/// - The enum has ≤ 32 variants (cap table size; matches the
///   ISA's `mul reg, reg` semantics without overflow concerns)
fn tryEmitTagJumpTable(self: *Emitter, ms: ast.MatchStmt) !bool {
    const enum_decl = self.enumDeclForExpr(ms.scrutinee) orelse return false;
    // Payload enums are slot pointers, not bare tags — the jump table
    // indexes on a register tag, so they take the sequential path.
    if (self.enumHasPayload(enum_decl)) return false;
    if (enum_decl.variants.len == 0) return false;
    // Cap table size to keep the dispatch sequence trivial. 32
    // variants × 3 bytes per entry = 96 bytes of table, well
    // inside any sensible spec budget; larger enums fall back to
    // the sequential cmp-chain (which is still O(N)) until the
    // spec promises bigger tables.
    if (enum_decl.variants.len > 32) return false;

    // Variant tag → arm index in `ms.arms`. `null` = unmapped tag
    // (will route to wildcard / end).
    var tag_to_arm: [256]?usize = .{null} ** 256;
    var wildcard_arm: ?usize = null;
    var max_tag: u8 = 0;

    for (ms.arms, 0..) |arm, idx| {
        if (arm.guard != null) return false;
        switch (arm.pattern.*) {
            .variant_pattern => |vp| {
                if (vp.args.len > 0) return false;
                const path = self.source[vp.path.start..vp.path.end];
                const dot = std.mem.indexOfScalar(u8, path, '.') orelse return false;
                const enum_name = path[0..dot];
                const variant_name = path[dot + 1 ..];
                // Mixed-enum patterns can't share one tag table.
                const decl_name = self.source[enum_decl.name.start..enum_decl.name.end];
                if (!std.mem.eql(u8, enum_name, decl_name)) return false;
                const tag = self.variantTag(enum_name, variant_name) orelse return false;
                if (tag_to_arm[tag] != null) return false;
                tag_to_arm[tag] = idx;
                if (tag > max_tag) max_tag = tag;
            },
            .wildcard, .ident => {
                // Repeated wildcards or non-trailing wildcards are
                // dead — let the sequential lowerer handle the
                // diagnostic / shape.
                if (wildcard_arm != null) return false;
                if (idx + 1 != ms.arms.len) return false;
                wildcard_arm = idx;
            },
            else => return false,
        }
    }

    // The exhaustiveness check has already gated absence of a
    // wildcard. Walk every tag 0..max_tag for the table — entries
    // with no matching arm route to the wildcard arm (if any) or
    // to the post-match end (which is unreachable when the typecheck
    // says the match is exhaustive).
    // @as: widen max_tag (u8) to usize before +1 — the +1 can overflow a u8 (255 → 256).
    const table_len: usize = @as(usize, max_tag) + 1;

    // ---- emit dispatch prologue ----
    try self.emitExpr(ms.scrutinee);
    // Bounds: `tag > max_tag` → fall through to default. Even
    // exhaustive matches keep this — a stray u8 value past the
    // last declared variant can still reach here through a cast.
    try isa.cmpRegImm(self, Reg.acu, max_tag);
    const bounds_patch = try isa.emitJumpPlaceholder(self, Op.jgt_addr);

    // acu = 3*tag (each table slot is `jmp_addr <body>`, 3 bytes).
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try isa.shlRegImm(self, Reg.r1, 1); // r1 = 2*tag
    try isa.addRegToAcu(self, Reg.r1); // acu = 3*tag

    // acu = table_base + 3*tag — patched once the table address is known.
    try self.emitByte(Op.mov_imm16_reg);
    const table_base_patch = try self.currentOffset();
    try self.emitU16Le(0);
    try self.emitByte(Reg.r1);
    try isa.addRegToAcu(self, Reg.r1);

    // jmp [acu] — control transfers to the `jmp_addr <body>` at
    // table_base + 3*tag, which then jumps to the actual body.
    try isa.jmpReg(self, Reg.acu);

    // ---- emit table ----
    const table_offset = try self.currentOffset();
    // Patch the dispatch's `mov_imm16` so r1 = table_base. Same
    // 2-byte LE address slot as a forward `jmp` patch.
    try isa.patchJumpTo(self, table_base_patch, table_offset);
    // Slot per tag in 0..=max_tag. Each is a `jmp_addr <body>`
    // placeholder; address slot resolves once the body emits.
    var slot_patches: [256]usize = undefined;
    var t: usize = 0;
    while (t < table_len) : (t += 1) {
        slot_patches[t] = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    }

    // ---- emit arm bodies + collect end-of-match jumps ----
    var arm_offsets: []usize = try self.arena.alloc(usize, ms.arms.len);
    var end_patches: std.ArrayList(usize) = .empty;
    defer end_patches.deinit(self.allocator);

    for (ms.arms, 0..) |arm, idx| {
        arm_offsets[idx] = try self.currentOffset();
        // The wildcard arm shape `ident` binds the scrutinee to a
        // local. The bare `_` form binds nothing. Both reach this
        // body with `acu` still holding the scrutinee value.
        if (arm.pattern.* == .ident) {
            const name = self.source[arm.pattern.ident.name.start..arm.pattern.ident.name.end];
            const dup = try self.arena.dupe(u8, name);
            const ofs = try self.allocLocal(dup);
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
        }
        try emitScopedBody(self, arm.body);
        try end_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));
    }

    // The "default" target is the wildcard arm body when present,
    // otherwise the post-match end. Unmapped table slots and the
    // out-of-range bounds branch both land here.
    const default_offset: usize = if (wildcard_arm) |w| arm_offsets[w] else try self.currentOffset();
    try isa.patchJumpTo(self, bounds_patch, default_offset);

    // Patch each table slot to its arm's body (or default).
    t = 0;
    while (t < table_len) : (t += 1) {
        // safety: tag_to_arm is indexed 0..=255; t ≤ max_tag ≤ 255.
        const target = if (tag_to_arm[@intCast(t)]) |arm_idx| arm_offsets[arm_idx] else default_offset;
        try isa.patchJumpTo(self, slot_patches[t], target);
    }

    // Every arm body terminates with a `jmp end`. Resolve them all
    // to the byte after the match statement.
    const end_offset = try self.currentOffset();
    for (end_patches.items) |p| try isa.patchJumpTo(self, p, end_offset);

    return true;
}
