/// Control-flow lowering — `if` / `while` / `for` / `repeat` /
/// `match` / `break` / `continue` / `defer` / `do…end`. Owns the
/// block + loop stack helpers that drive defer-emission at every
/// exit path and label-resolution for nested loop jumps.
const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const pattern = @import("pattern.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
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
    try self.pushReg(Reg.acu);
    var i = stmts.len;
    while (i > 0) {
        i -= 1;
        try self.emitStatement(stmts[i].*);
    }
    try self.popReg(Reg.acu);
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
        try end_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jmp_addr));
        const after_body = try self.currentOffset();
        try self.patchJumpTo(skip_body_patch, after_body);
    }

    if (is_.else_body) |eb| try emitScopedBody(self, eb);

    const end_offset = try self.currentOffset();
    for (end_patches.items) |p| try self.patchJumpTo(p, end_offset);
}

/// Emit the test for one if-arm and return the offset of the
/// "skip body" jump patch — the caller resolves it to the byte
/// right after the body.
fn emitIfArmTest(self: *Emitter, arm: ast.IfArm) !usize {
    if (arm.cond) |c| {
        try self.emitCondBranch(c);
        return try self.emitJumpPlaceholder(Op.jeq_addr);
    }
    // `if let pat = expr [when guard]` — ident-binder form.
    const pat = arm.let_pattern.?.*;
    const expr = arm.let_expr.?;
    try self.emitExpr(expr);
    switch (pat) {
        .ident => |id| {
            const name = self.source[id.name.start..id.name.end];
            const dup = try self.arena.dupe(u8, name);
            const ofs = try self.allocLocal(dup);
            try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
            if (arm.let_guard) |g| {
                try self.emitExpr(g);
                try self.cmpRegImm(Reg.acu, 0);
                return try self.emitJumpPlaceholder(Op.jeq_addr);
            }
            // No guard — ident binder always matches; emit a
            // never-taken skip for symmetry with the cond arm.
            try self.movImmToReg(1, Reg.r1);
            try self.cmpRegImm(Reg.r1, 0);
            return try self.emitJumpPlaceholder(Op.jeq_addr);
        },
        else => {
            try self.unsupported(arm.span, "`if let` patterns other than a bare ident");
            return try self.emitJumpPlaceholder(Op.jeq_addr);
        },
    }
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
        break :blk try self.emitJumpPlaceholder(Op.jeq_addr);
    } else blk: {
        const pat = ws.let_pattern.?.*;
        try self.emitExpr(ws.let_expr.?);
        switch (pat) {
            .ident => |id| {
                const name = self.source[id.name.start..id.name.end];
                const dup = try self.arena.dupe(u8, name);
                const ofs = try self.allocLocal(dup);
                try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
                if (ws.let_guard) |g| {
                    try self.emitExpr(g);
                    try self.cmpRegImm(Reg.acu, 0);
                    break :blk try self.emitJumpPlaceholder(Op.jeq_addr);
                }
                try self.movImmToReg(1, Reg.r1);
                try self.cmpRegImm(Reg.r1, 0);
                break :blk try self.emitJumpPlaceholder(Op.jeq_addr);
            },
            else => {
                try self.unsupported(ws.span, "`while let` patterns other than a bare ident");
                break :blk try self.emitJumpPlaceholder(Op.jeq_addr);
            },
        }
    };

    for (ws.body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);

    try self.emitJumpBack(cond_offset);

    const exit_offset = try self.currentOffset();
    try self.patchJumpTo(exit_on_false_patch, exit_offset);

    var frame = self.loop_stack.pop().?;
    for (frame.break_patches.items) |p| try self.patchJumpTo(p, exit_offset);
    for (frame.continue_patches.items) |p| try self.patchJumpTo(p, cond_offset);
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
    for (frame.break_patches.items) |p| try self.patchJumpTo(p, exit_offset);
    for (frame.continue_patches.items) |p| try self.patchJumpTo(p, test_offset);
    frame.break_patches.deinit(self.allocator);
    frame.continue_patches.deinit(self.allocator);
}

/// Lower `for x in start..end [step S] body end` — the range
/// special case per spec §4.5.3. User-defined iterables
/// (`next(self) -> T?`) are not yet supported.
pub fn emitForStmt(self: *Emitter, fs: ast.ForStmt) !void {
    if (fs.iter.* != .range) {
        try self.unsupported(fs.span, "`for` over non-range iterables");
        return;
    }
    const range = fs.iter.range;
    const inclusive = range.inclusive;
    const step_expr = fs.step;
    const binding_name = self.source[fs.binding.start..fs.binding.end];

    // Allocate slots: the loop variable + a hidden `end` slot.
    const dup_name = try self.arena.dupe(u8, binding_name);
    const var_ofs = try self.allocLocal(dup_name);
    const end_ofs = try self.allocLocal(try self.arena.dupe(u8, "\x00__for_end"));

    try self.emitExpr(range.start);
    try self.movRegToRegOffset(Reg.acu, Reg.fp, var_ofs);
    try self.emitExpr(range.end);
    try self.movRegToRegOffset(Reg.acu, Reg.fp, end_ofs);

    const label_str: ?[]const u8 = if (fs.label) |s|
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

    // Top-of-loop: load `current`, load `end`, compare. Exit
    // when current > end (inclusive) or current >= end (exclusive).
    const test_offset = try self.currentOffset();
    try self.movRegOffsetToReg(Reg.fp, var_ofs, Reg.acu);
    try self.movRegOffsetToReg(Reg.fp, end_ofs, Reg.r1);
    try self.cmpRegReg(Reg.acu, Reg.r1);
    const exit_patch = if (inclusive)
        try self.emitJumpPlaceholder(Op.jgt_addr)
    else
        try self.emitJumpPlaceholder(Op.jge_addr);

    for (fs.body) |s| try self.emitStatement(s);
    try popBlockWithDefers(self);

    // `continue` target — the step-and-back-edge.
    const continue_offset = try self.currentOffset();
    try self.movRegOffsetToReg(Reg.fp, var_ofs, Reg.acu);
    if (step_expr) |se| {
        if (se.* == .int_lit) {
            // @as: parser stores int_lit as i32; range steps fit i16 per spec §4.5.1.
            const step_i16: i16 = @truncate(se.int_lit.value);
            // safety: i16 → u16 keeps the two's-complement bit pattern for negative steps.
            const step_val: u16 = @bitCast(step_i16);
            try self.addImmToReg(step_val, Reg.acu);
        } else {
            try self.pushReg(Reg.acu);
            try self.emitExpr(se);
            try self.movRegToReg(Reg.acu, Reg.r1);
            try self.popReg(Reg.acu);
            try self.addRegToAcu(Reg.r1);
        }
    } else {
        try self.addImmToReg(1, Reg.acu);
    }
    try self.movRegToRegOffset(Reg.acu, Reg.fp, var_ofs);
    try self.emitJumpBack(test_offset);

    const exit_offset = try self.currentOffset();
    try self.patchJumpTo(exit_patch, exit_offset);

    var frame = self.loop_stack.pop().?;
    for (frame.break_patches.items) |p| try self.patchJumpTo(p, exit_offset);
    for (frame.continue_patches.items) |p| try self.patchJumpTo(p, continue_offset);
    frame.break_patches.deinit(self.allocator);
    frame.continue_patches.deinit(self.allocator);
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
    const patch = try self.emitJumpPlaceholder(Op.jmp_addr);
    switch (kind) {
        .break_ => try frame.break_patches.append(self.allocator, patch),
        .continue_ => try frame.continue_patches.append(self.allocator, patch),
    }
}

// ---------- match ----------

/// Lower `match scrutinee case … end` as a sequential cmp +
/// branch decision tree. OR-patterns collapse onto one shared
/// body label; range patterns emit a single low+high cmp pair;
/// `when` guards run after the pattern bind.
pub fn emitMatchStmt(self: *Emitter, ms: ast.MatchStmt) !void {
    // Bind the scrutinee to a slot so subsequent arms can re-test
    // it without re-evaluating side effects. Skip the bind if the
    // source already wrote an ident — direct loads stay cheap.
    const scrutinee_ofs: i8 = blk: {
        switch (ms.scrutinee.*) {
            .ident => break :blk 0,
            else => {
                try self.emitExpr(ms.scrutinee);
                const ofs = try self.allocLocal(try self.arena.dupe(u8, "\x00__match"));
                try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
                break :blk ofs;
            },
        }
    };
    const scrutinee_is_ident = ms.scrutinee.* == .ident;

    var end_patches: std.ArrayList(usize) = .empty;
    defer end_patches.deinit(self.allocator);

    for (ms.arms) |arm| {
        if (scrutinee_is_ident) {
            try self.emitExpr(ms.scrutinee);
        } else {
            try self.movRegOffsetToReg(Reg.fp, scrutinee_ofs, Reg.acu);
        }

        var skip_patches: std.ArrayList(usize) = .empty;
        defer skip_patches.deinit(self.allocator);
        try pattern.emitPatternTest(self, arm.pattern.*, scrutinee_ofs, scrutinee_is_ident, &skip_patches);

        if (arm.guard) |g| {
            try self.emitExpr(g);
            try self.cmpRegImm(Reg.acu, 0);
            try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jeq_addr));
        }

        try emitScopedBody(self, arm.body);
        try end_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jmp_addr));

        const after_arm = try self.currentOffset();
        for (skip_patches.items) |p| try self.patchJumpTo(p, after_arm);
    }

    const end_offset = try self.currentOffset();
    for (end_patches.items) |p| try self.patchJumpTo(p, end_offset);
}
