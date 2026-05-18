/// Expression lowering — `emitExpr` and every per-shape helper
/// it dispatches into. Results land in `acu`. Sub-modules
/// (`mem_builtin`, `strings`, etc.) call back into `emitExpr`
/// through the `Emitter` method dispatch.
const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const archive = @import("archive.zig");
const class = @import("class.zig");
const lambda = @import("lambda.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const CallPatch = codegen.CallPatch;

const EmitError = error{OutOfMemory};

/// Lower one expression — result lands in `acu`. The main
/// dispatch switch; per-shape helpers below.
pub fn emitExpr(self: *Emitter, e: *const ast.Expr) EmitError!void {
    switch (e.*) {
        .int_lit => |lit| {
            // @as: truncate i32 → i16; safety: typechecker already verified the literal fits in the target primitive's width.
            const trimmed: i16 = @truncate(lit.value);
            // safety: i16 → u16 bit pattern; the two's-complement encoding is preserved.
            const v: u16 = @bitCast(trimmed);
            try self.movImmToReg(v, Reg.acu);
        },
        .fixed_lit => |lit| {
            // Q8.8 — the parser pre-encodes the value as `int *
            // 256 + round(frac * 256)`. The low 16 bits are the
            // canonical bit pattern.
            // @as: i32 → i16; spec §3.3 pins fixed-point to Q8.8 (i16-shaped).
            const trimmed: i16 = @truncate(lit.value);
            // safety: i16 → u16 bit pattern preserved (two's complement).
            const v: u16 = @bitCast(trimmed);
            try self.movImmToReg(v, Reg.acu);
        },
        .str_lit => |sl| try self.emitStrLitExpr(sl),
        .bool_lit => |b| {
            const v: u16 = if (b.value) 1 else 0;
            try self.movImmToReg(v, Reg.acu);
        },
        .nil_lit => try self.movImmToReg(0, Reg.acu),
        .char_lit => |c| try self.movImmToReg(c.value, Reg.acu),
        .paren => |p| try emitExpr(self, p.inner),
        .ident => |i| {
            const name = self.source[i.span.start..i.span.end];
            // Lookup order: captures (lambda body) → locals → params
            // → globals. Captures take precedence so they shadow any
            // same-named local that might also exist in the body.
            if (self.captures.get(name)) |slot| {
                try lambda.emitCaptureLoad(self, slot);
                return;
            }
            if (self.locals.get(name)) |ofs| {
                // Promoted bindings live as heap cells — the slot
                // holds the cell pointer; deref to get the value.
                if (lambda.isPromoted(self, name)) {
                    try lambda.emitPromotedIdentLoad(self, ofs);
                    return;
                }
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
            try self.unsupported(i.span, "ident not in current frame");
        },
        .unary => |u| try emitUnary(self, u),
        .binary => |b| try emitBinary(self, b),
        .call => |c| try emitCall(self, c),
        .method_call => |m| try emitMethodCall(self, m, e),
        .field => |f| try emitFieldExpr(self, f, e),
        .self_expr => |se| {
            // `self` inside a method body lives at fp+4 (the first
            // implicit param). Outside a method it's a typecheck
            // error — the codegen falls through to "unsupported".
            if (self.params.get("self")) |ofs| {
                try self.movRegOffsetToReg(Reg.fp, ofs, Reg.acu);
            } else {
                try self.unsupported(se.span, "`self` used outside a method body");
            }
        },
        .super_expr => |se| {
            // Bare `super` is never a valid value — it must be
            // followed by `.method(...)` or `.field`. Both shapes
            // intercept before they reach this fallthrough arm.
            try self.unsupported(se.span, "`super` must be followed by `.method(...)` or `.field`");
        },
        .lambda => |l| try lambda.emitLambdaExpr(self, l, e),
        .is_test => |it| try emitIsTest(self, it),
        .ref_of => |r| try self.emitAddrOf(r.inner),
        .cast => |c| try emitExpr(self, c.inner), // same-width primitives share a bit pattern, so the cast is a no-op
        else => try self.unsupported(e.span(), "this expression form"),
    }
}

/// Discard-context evaluation: evaluate for side effects and
/// throw away the result.
pub fn emitExprDiscard(self: *Emitter, e: *const ast.Expr) !void {
    try emitExpr(self, e);
}

/// Lower an `EnumName.Variant` field expression — a nullary
/// enum-variant constructor. Loads the variant's tag byte into
/// `acu`. Field access on non-enum receivers is not yet
/// supported.
pub fn emitFieldExpr(self: *Emitter, f: ast.FieldExpr, e: *const ast.Expr) !void {
    // `super.field` — read parent-side shadowed slot.
    if (f.receiver.* == .super_expr) {
        if (self.current_class_name) |cname| {
            const fname = self.source[f.field.start..f.field.end];
            try class.emitSuperFieldLoad(self, cname, fname, f.span);
            return;
        }
        try self.unsupported(f.span, "`super.field` used outside a method body");
        return;
    }
    // Class-typed receiver — `obj.field` instance load.
    if (self.classNameOf(f.receiver)) |cname| {
        const fname = self.source[f.field.start..f.field.end];
        try class.emitFieldLoad(self, f.receiver, cname, fname, f.span);
        return;
    }
    if (f.receiver.* == .ident) {
        const recv_name = self.source[f.receiver.ident.span.start..f.receiver.ident.span.end];
        if (self.enum_decls.get(recv_name)) |ed| {
            const variant_name = self.source[f.field.start..f.field.end];
            const tag = self.variantTag(recv_name, variant_name) orelse {
                try self.diagFatal(f.span, "E_CODEGEN_UNDEFINED_VARIANT", "codegen: unknown enum variant");
                return;
            };
            // A bare `Item.Potion` reference at expression
            // position (without a call) requires the payload to
            // be empty — payload-bearing constructors come
            // through the `CallExpr` path with field-callee.
            for (ed.variants) |v| {
                if (std.mem.eql(u8, self.source[v.name.start..v.name.end], variant_name)) {
                    if (v.payload.len != 0) {
                        try self.unsupported(f.span, "payload-bearing enum-variant constructors");
                        return;
                    }
                }
            }
            try self.movImmToReg(tag, Reg.acu);
            return;
        }
    }
    try self.unsupported(e.span(), "non-enum field access");
}

/// Lower `expr is EnumName.Variant`. Evaluates `expr` into
/// `acu`, compares against the variant's tag, materializes a
/// `0` / `1` bool.
pub fn emitIsTest(self: *Emitter, it: ast.IsTestExpr) !void {
    const path = self.source[it.variant_path.start..it.variant_path.end];
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse {
        try self.diagFatal(it.span, "E_CODEGEN_BAD_VARIANT_PATH", "codegen: `is` rhs must be `EnumName.Variant`");
        return;
    };
    const enum_name = path[0..dot];
    const variant_name = path[dot + 1 ..];
    const tag = self.variantTag(enum_name, variant_name) orelse {
        try self.diagFatal(it.span, "E_CODEGEN_UNDEFINED_VARIANT", "codegen: unknown enum variant in `is` test");
        return;
    };
    try emitExpr(self, it.lhs);
    try self.cmpRegImm(Reg.acu, tag);
    try materializeBoolFromFlags(self, .eq);
}

/// Lower a unary prefix expression.
pub fn emitUnary(self: *Emitter, u: ast.UnaryExpr) !void {
    try emitExpr(self, u.operand);
    switch (u.op) {
        .neg => try self.negReg(Reg.acu),
        .bit_not => try self.notRegOp(Reg.acu),
        .log_not => {
            // acu = (acu == 0) ? 1 : 0
            try self.cmpRegImm(Reg.acu, 0);
            try materializeBoolFromFlags(self, .eq);
        },
    }
}

/// Lower a binary infix expression. Short-circuit operators
/// (`and`, `or`) take a separate path so the RHS isn't always
/// evaluated. Comparison ops materialize a `0` / `1` in `acu`.
/// Fixed-point `*` / `/` get a Q8.8 scaling tail per ISA §5.4.1.
pub fn emitBinary(self: *Emitter, b: ast.BinaryExpr) !void {
    switch (b.op) {
        .log_and, .log_or => {
            try emitShortCircuitBool(self, b);
            return;
        },
        else => {},
    }

    const fixed_op = self.isPrimitiveType(b.lhs, .fixed) and
        self.isPrimitiveType(b.rhs, .fixed) and
        (b.op == .mul or b.op == .div);

    // Standard stack-machine pattern: eval RHS, push, eval LHS,
    // pop RHS into r1, apply op (acu = acu OP r1).
    try emitExpr(self, b.rhs);
    try self.pushReg(Reg.acu);
    try emitExpr(self, b.lhs);
    try self.popReg(Reg.r1);
    switch (b.op) {
        .add => try self.addRegToAcu(Reg.r1),
        .sub => try self.subRegFromAcu(Reg.r1),
        .mul => {
            // `mul src, dst` writes low(product) → dst AND
            // high(product) → acu. If dst == acu the high half
            // clobbers the low half — so we land the result in
            // `r2`, then move it back to acu.
            try self.movRegToReg(Reg.acu, Reg.r2);
            try self.mulRegReg(Reg.r1, Reg.r2);
            if (fixed_op) {
                // Q8.8 * Q8.8 — the conceptual Q16.16 product
                // straddles acu:r2 (acu = high half, r2 = low
                // half). The Q8.8 result is bits 8..23 of that
                // 32-bit value: `acu (high << 8) | (r2 unsigned
                // >> 8)`. ISA §5.4.1 — products whose real
                // magnitude exceeds 127.99… wrap silently
                // because the result no longer fits in 16 bits.
                try self.shrRegImm(Reg.r2, 8);
                try self.shlRegImm(Reg.acu, 8);
                try self.orRegReg(Reg.acu, Reg.r2);
            } else {
                // Integer mul — drop the high half.
                try self.movRegToReg(Reg.r2, Reg.acu);
            }
        },
        .div => {
            if (fixed_op) {
                // Q8.8 / Q8.8 — scale the dividend up by 2^8
                // before the signed divide so the quotient lands
                // back in Q8.8. The 24-bit pre-shifted dividend
                // straddles acu:r2:
                //   r2  = acu << 8           (low half)
                //   acu = acu >>arith 8      (sign-extended top byte)
                // Then `divs r1, r2` performs the 32÷16 signed
                // divide and the quotient ends up in r2.
                try self.movRegToReg(Reg.acu, Reg.r2);
                try self.shlRegImm(Reg.r2, 8); // r2 = lhs << 8 (low)
                try self.asrRegImm(Reg.acu, 8); // acu = lhs >>a 8 (high)
                try self.divsRegReg(Reg.r1, Reg.r2);
                try self.movRegToReg(Reg.r2, Reg.acu);
            } else {
                // Signed 32÷16 divide. Dividend lives in acu:dst
                // (high:low); the dividend is assumed to fit in
                // 16 bits — sign-extension is not yet emitted.
                try self.movRegToReg(Reg.acu, Reg.r2); // r2 = low half
                try self.movImmToReg(0, Reg.acu); // high half = 0
                try self.divsRegReg(Reg.r1, Reg.r2); // r2 = quotient, acu = remainder
                try self.movRegToReg(Reg.r2, Reg.acu);
            }
        },
        .mod => {
            // Same divs pattern as `div`, but keep `acu` (the
            // remainder is exactly what `mod` wants).
            try self.movRegToReg(Reg.acu, Reg.r2); // r2 = low half
            try self.movImmToReg(0, Reg.acu); // high half = 0
            try self.divsRegReg(Reg.r1, Reg.r2); // r2 = quotient, acu = remainder
        },
        .bit_and => try self.andRegReg(Reg.acu, Reg.r1),
        .bit_or => try self.orRegReg(Reg.acu, Reg.r1),
        .bit_xor => try self.xorRegReg(Reg.acu, Reg.r1),
        .shl => try self.shlRegReg(Reg.acu, Reg.r1),
        .shr => try self.shrRegReg(Reg.acu, Reg.r1),
        .eq, .neq, .lt, .lte, .gt, .gte => {
            try self.cmpRegReg(Reg.acu, Reg.r1);
            try materializeBoolFromFlags(self, b.op);
        },
        // allow-strict: handled by the short-circuit branch above; emitBinary never falls through here for these ops.
        .log_and, .log_or => unreachable,
    }
}

/// Drive a flag-setting comparison for a control-flow condition.
/// Top-level comparisons + short-circuit ops drive `cmp` directly
/// without materializing the 0 / 1 first; other shapes fall back
/// to "evaluate to acu, cmp acu, 0".
pub fn emitCondBranch(self: *Emitter, e: *const ast.Expr) !void {
    if (e.* == .binary) {
        const b = e.binary;
        switch (b.op) {
            .eq, .neq, .lt, .lte, .gt, .gte => {
                // Eval LHS into acu, eval RHS into r1, cmp acu, r1.
                try emitExpr(self, b.rhs);
                try self.pushReg(Reg.acu);
                try emitExpr(self, b.lhs);
                try self.popReg(Reg.r1);
                try self.cmpRegReg(Reg.acu, Reg.r1);
                try materializeBoolFromFlags(self, b.op);
                try self.cmpRegImm(Reg.acu, 0);
                return;
            },
            .log_and, .log_or => {
                try emitShortCircuitBool(self, b);
                try self.cmpRegImm(Reg.acu, 0);
                return;
            },
            else => {},
        }
    }
    if (e.* == .unary and e.unary.op == .log_not) {
        try emitExpr(self, e.unary.operand);
        try self.cmpRegImm(Reg.acu, 0);
        try materializeBoolFromFlags(self, .eq);
        try self.cmpRegImm(Reg.acu, 0);
        return;
    }
    // Generic path — evaluate to acu, then test against 0.
    try emitExpr(self, e);
    try self.cmpRegImm(Reg.acu, 0);
}

/// Materialize a 0 / 1 boolean in `acu` from the current flag
/// state set by a preceding `cmp`. Picks the right conditional
/// jump per comparison kind.
pub fn materializeBoolFromFlags(self: *Emitter, op: ast.BinaryOp) !void {
    const taken_op: u8 = switch (op) {
        .eq => Op.jeq_addr,
        .neq => Op.jne_addr,
        .lt => Op.jlt_addr,
        .lte => Op.jle_addr,
        .gt => Op.jgt_addr,
        .gte => Op.jge_addr,
        // allow-strict: callers filter to comparison ops before invoking this helper.
        else => unreachable,
    };
    // Pattern:
    //   <prior cmp>
    //   jXX true_label
    //   mov 0, acu
    //   jmp end
    // true_label:
    //   mov 1, acu
    // end:
    const true_patch = try self.emitJumpPlaceholder(taken_op);
    try self.movImmToReg(0, Reg.acu);
    const end_patch = try self.emitJumpPlaceholder(Op.jmp_addr);
    const true_offset = try self.currentOffset();
    try self.movImmToReg(1, Reg.acu);
    const end_offset = try self.currentOffset();
    try self.patchJumpTo(true_patch, true_offset);
    try self.patchJumpTo(end_patch, end_offset);
}

/// Lower a short-circuiting `and` / `or` into a chain of
/// conditional jumps that leaves a 0 / 1 in `acu`.
pub fn emitShortCircuitBool(self: *Emitter, b: ast.BinaryExpr) !void {
    switch (b.op) {
        .log_and => {
            // acu = lhs; if acu == 0 -> short-circuit false.
            try emitExpr(self, b.lhs);
            try self.cmpRegImm(Reg.acu, 0);
            const short_patch = try self.emitJumpPlaceholder(Op.jeq_addr);
            try emitExpr(self, b.rhs);
            try self.cmpRegImm(Reg.acu, 0);
            try materializeBoolFromFlags(self, .neq);
            const end_patch = try self.emitJumpPlaceholder(Op.jmp_addr);
            const short_offset = try self.currentOffset();
            try self.movImmToReg(0, Reg.acu);
            const end_offset = try self.currentOffset();
            try self.patchJumpTo(short_patch, short_offset);
            try self.patchJumpTo(end_patch, end_offset);
        },
        .log_or => {
            try emitExpr(self, b.lhs);
            try self.cmpRegImm(Reg.acu, 0);
            const short_patch = try self.emitJumpPlaceholder(Op.jne_addr);
            try emitExpr(self, b.rhs);
            try self.cmpRegImm(Reg.acu, 0);
            try materializeBoolFromFlags(self, .neq);
            const end_patch = try self.emitJumpPlaceholder(Op.jmp_addr);
            const short_offset = try self.currentOffset();
            try self.movImmToReg(1, Reg.acu);
            const end_offset = try self.currentOffset();
            try self.patchJumpTo(short_patch, short_offset);
            try self.patchJumpTo(end_patch, end_offset);
        },
        // allow-strict: caller filters to log_and / log_or before invoking this helper.
        else => unreachable,
    }
}

/// Lower a `receiver.method(args)` expression. The stdlib
/// `mem.X(...)` shape dispatches through the builtin lookup;
/// other receivers (class instance method calls) are not yet
/// supported.
pub fn emitMethodCall(self: *Emitter, m: ast.MethodCallExpr, e: *const ast.Expr) !void {
    // `super.method(args)` — direct call to parent's method,
    // bypassing the vtable.
    if (m.receiver.* == .super_expr) {
        if (self.current_class_name) |cname| {
            const mname = self.source[m.method.start..m.method.end];
            try class.emitSuperMethodCall(self, cname, mname, m.args, m.span);
            return;
        }
        try self.unsupported(m.span, "`super.method` used outside a method body");
        return;
    }
    // Class-typed receiver — vtable dispatch.
    if (self.classNameOf(m.receiver)) |cname| {
        const mname = self.source[m.method.start..m.method.end];
        try class.emitMethodDispatch(self, m.receiver, cname, mname, m.args, m.span);
        return;
    }
    if (m.receiver.* == .ident) {
        const recv = self.source[m.receiver.ident.span.start..m.receiver.ident.span.end];
        if (std.mem.eql(u8, recv, "mem")) {
            // Build a synthetic `FieldExpr` + `CallExpr` shape so
            // the existing mem dispatch can flow through without
            // duplicating the per-builtin emit code.
            const synth_field: ast.FieldExpr = .{
                .receiver = m.receiver,
                .field = m.method,
                .span = m.span,
            };
            const synth_call: ast.CallExpr = .{
                .callee = m.receiver, // unused by emitMemCall
                .args = m.args,
                .span = m.span,
            };
            try self.emitMemCall(synth_field, synth_call);
            return;
        }
    }
    try self.unsupported(e.span(), "method calls on non-stdlib receivers");
}

/// Lower `callee(args...)` per the free-fn calling convention:
///
///   - Push args right-to-left (so callee sees param 0 at
///     `[fp + 4]`, param 1 at `[fp + 6]`, ...).
///   - `call <addr>` — the VM enters: push fp, push ret_ip,
///     fp ← sp, ip ← target.
///   - On return, `add <N*2>, sp` to drop the args. The
///     callee's return value lives in `acu`.
///
/// Compiler-known stdlib builtins (`mem.X`) intercept on the
/// way in. Closure invocations and fn-pointer calls are not
/// yet supported.
pub fn emitCall(self: *Emitter, c: ast.CallExpr) !void {
    // Class constructor call — `ClassName(args)` allocates an
    // instance, writes the vtable pointer, and runs `init` if
    // declared. The instance address lands in `acu`.
    if (c.callee.* == .ident) {
        const callee_name = self.source[c.callee.ident.span.start..c.callee.ident.span.end];
        if (class.isClassName(self, callee_name)) {
            try class.emitConstructor(self, callee_name, c);
            return;
        }
        // Closure call — `f(args)` where `f` is a let-binding
        // initialized from a lambda OR a binding whose inferred
        // type is a function (covers `let c = make_counter()`
        // where make_counter returns a closure). Dispatch through
        // the tuple's fn_ptr instead of the free-fn path.
        if (lambda.isClosureBinding(self, callee_name) or lambda.isClosureByType(self, c.callee)) {
            try lambda.emitClosureCall(self, c.callee, c);
            return;
        }
        // `@inline` call — splice the callee body in place rather
        // than emit a `call addr`. No standalone def emits for
        // the callee (see `emitProgram`).
        if (self.inline_defs.get(callee_name)) |callee_decl| {
            try self.emitInlineCall(callee_decl, c);
            return;
        }
    }
    if (c.callee.* == .field) {
        const fe = c.callee.field;
        if (fe.receiver.* == .ident) {
            const recv = self.source[fe.receiver.ident.span.start..fe.receiver.ident.span.end];
            if (std.mem.eql(u8, recv, "mem")) {
                try self.emitMemCall(fe, c);
                return;
            }
        }
    }
    if (c.callee.* != .ident) {
        try self.unsupported(c.span, "non-ident callee");
        return;
    }
    const callee_name = self.source[c.callee.ident.span.start..c.callee.ident.span.end];
    const dup = try self.arena.dupe(u8, callee_name);

    // Decide direct call vs trampoline by comparing the
    // caller's bank with the target's. The pre-pass populated
    // `fn_banks` so this resolves without needing the address.
    const target_bank: ?u8 = self.fn_banks.get(callee_name) orelse null;
    const cross_bank = !archive.banksEqual(self.current_bank, target_bank);

    // Push args right-to-left (caller-cleans-up).
    var i: usize = c.args.len;
    while (i > 0) {
        i -= 1;
        try emitExpr(self, c.args[i]);
        try self.pushReg(Reg.acu);
    }

    if (cross_bank) {
        // Trampoline path:
        //   mov <target_addr>, r1   ; patched at end
        //   mov <target_bank>,  r2  ; literal at emit time
        //   call __call_bank        ; patched at end
        try self.emitByte(Op.mov_imm16_reg);
        const addr_patch_offset = try self.currentOffset();
        try self.emitU16Le(0); // placeholder
        try self.emitByte(Reg.r1);
        const target_bank_byte: u8 = target_bank orelse 0;
        try self.movImmToReg(target_bank_byte, Reg.r2);
        try self.emitByte(Op.call_addr);
        const tramp_patch_offset = try self.currentOffset();
        try self.emitU16Le(0);

        try self.call_patches.append(self.allocator, .{
            .bank = self.current_bank,
            .code_offset = addr_patch_offset,
            .target = .{ .fn_name = dup },
            .span = c.span,
        });
        try self.call_patches.append(self.allocator, .{
            .bank = self.current_bank,
            .code_offset = tramp_patch_offset,
            .target = .trampoline,
            .span = c.span,
        });
    } else {
        // Direct same-bank call.
        try self.emitByte(Op.call_addr);
        const patch_offset = try self.currentOffset();
        try self.emitU16Le(0); // placeholder
        try self.call_patches.append(self.allocator, .{
            .bank = self.current_bank,
            .code_offset = patch_offset,
            .target = .{ .fn_name = dup },
            .span = c.span,
        });
    }

    // `@noreturn` callees don't resume by contract — omit the
    // post-call stack-cleanup so the cold path is one ADD shorter.
    // The args we pushed leak on the stack, which is fine: control
    // never returns to use that space.
    const skip_cleanup = self.noreturn_defs.contains(callee_name);
    if (c.args.len > 0 and !skip_cleanup) {
        // @as: each arg is one 16-bit word; arg count capped by parser.
        const drop_bytes: u16 = @intCast(c.args.len * 2);
        try self.addImmToReg(drop_bytes, Reg.sp);
    }
}
