const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const archive = @import("archive.zig");
const assert_builtin = @import("assert.zig");
const diverge_builtin = @import("diverge.zig");
const class = @import("class.zig");
const value_struct = @import("value_struct.zig");
const strings = @import("strings.zig");
const lambda = @import("lambda.zig");
const overflow = @import("overflow.zig");

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
            try isa.movImmToReg(self, v, Reg.acu);
        },
        .fixed_lit => |lit| {
            // Q8.8 — the parser pre-encodes the value as `int *
            // 256 + round(frac * 256)`. The low 16 bits are the
            // canonical bit pattern.
            // @as: i32 → i16; spec §3.3 pins fixed-point to Q8.8 (i16-shaped).
            const trimmed: i16 = @truncate(lit.value);
            // safety: i16 → u16 bit pattern preserved (two's complement).
            const v: u16 = @bitCast(trimmed);
            try isa.movImmToReg(self, v, Reg.acu);
        },
        .str_lit => |sl| try self.emitStrLitExpr(sl),
        .bool_lit => |b| {
            const v: u16 = if (b.value) 1 else 0;
            try isa.movImmToReg(self, v, Reg.acu);
        },
        .nil_lit => try isa.movImmToReg(self, 0, Reg.acu),
        .char_lit => |c| try isa.movImmToReg(self, c.value, Reg.acu),
        .paren => |p| try emitExpr(self, p.inner),
        .ident => |i| {
            // A struct-typed binding evaluates to its base address —
            // struct values are addressed inline, not loaded as a word.
            if (self.structNameOf(e) != null) {
                try self.emitAddrOf(e);
                return;
            }
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
                try isa.movRegOffsetToReg(self, Reg.fp, ofs, Reg.acu);
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
        .sizeof => |s| try isa.movImmToReg(self, self.widthOfTypeAnn(s.type_ann.*), Reg.acu),
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
/// Construct a payload-carrying enum value: bump-allocate a
/// `[tag | payload]` slot, write the tag byte, then each payload
/// field at its offset. Leaves the slot pointer in `acu`. `args` is
/// the constructor's call arguments — empty for a nullary variant of
/// an otherwise payload-carrying enum (which still needs a slot).
pub fn emitEnumConstruct(
    self: *Emitter,
    ed: *const ast.EnumDecl,
    variant: ast.EnumVariant,
    tag: u8,
    args: []const *ast.Expr,
) !void {
    // Evaluate the payload args onto the stack first (no frame slot —
    // an uncounted local would overlap the prologue's reservation).
    for (args) |arg| {
        try emitExpr(self, arg);
        try isa.pushReg(self, Reg.acu);
    }

    // Allocate the slot; `acu` → pointer, kept in `r1` across the
    // stores below.
    try isa.movImmToReg(self, self.enumSlotSize(ed), Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(opcodes.Sys.alloc);
    try isa.movRegToReg(self, Reg.acu, Reg.r1);

    // Tag byte at offset 0.
    try isa.movImmToReg(self, tag, Reg.r2);
    try class.emitByteStoreAtOffset(self, Reg.r1, 0, Reg.r2);

    // Pop the args in reverse (stack is LIFO) and store each at its
    // field offset.
    var i = args.len;
    while (i > 0) {
        i -= 1;
        try isa.popReg(self, Reg.r2);
        const ofs = self.variantFieldOffset(variant, i);
        if (self.widthOfTypeAnn(variant.payload[i].type_ann.*) == 1) {
            try class.emitByteStoreAtOffset(self, Reg.r1, ofs, Reg.r2);
        } else {
            try class.emitWordStoreAtOffset(self, Reg.r1, ofs, Reg.r2);
        }
    }

    // Result is the slot pointer.
    try isa.movRegToReg(self, Reg.r1, Reg.acu);
}

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
    // Struct-typed receiver — evaluate the receiver to its base
    // address, then load the field (or compute the nested address).
    if (self.structNameOf(f.receiver)) |sname| {
        const fname = self.source[f.field.start..f.field.end];
        try emitExpr(self, f.receiver);
        try value_struct.emitFieldLoad(self, sname, fname);
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
            for (ed.variants) |v| {
                if (!std.mem.eql(u8, self.source[v.name.start..v.name.end], variant_name)) continue;
                if (v.payload.len != 0) {
                    // A bare `Item.Potion` (no call) is a constructor
                    // value with no args — payload construction comes
                    // through the call path instead.
                    try self.unsupported(f.span, "payload-bearing enum-variant constructors");
                    return;
                }
                // A payload-carrying enum is uniformly a slot, so even
                // a nullary variant allocates one; a payload-free enum
                // stays a bare register tag.
                if (self.enumHasPayload(ed)) {
                    try emitEnumConstruct(self, ed, v, tag, &.{});
                } else {
                    try isa.movImmToReg(self, tag, Reg.acu);
                }
                return;
            }
            try isa.movImmToReg(self, tag, Reg.acu);
            return;
        }
    }
    try self.unsupported(e.span(), "non-enum field access");
}

/// Lower an `is` test. Two shapes:
/// - `expr is Enum.Variant` — compares the tag in `acu` against
///   the variant's compile-time tag.
/// - `expr is ClassName` — loads the instance's vtable pointer
///   and compares against the (patch-resolved) address of
///   `ClassName`'s vtable.
pub fn emitIsTest(self: *Emitter, it: ast.IsTestExpr) !void {
    switch (it.kind) {
        .variant => |path_span| {
            const path = self.source[path_span.start..path_span.end];
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
            // A payload-carrying enum is a slot pointer — read the tag
            // byte from `[ptr]` before comparing.
            if (self.enum_decls.get(enum_name)) |ed| if (self.enumHasPayload(ed)) {
                try isa.movRegToReg(self, Reg.acu, Reg.r1);
                try class.emitByteLoadAtOffset(self, Reg.r1, 0, Reg.acu);
            };
            try isa.cmpRegImm(self, Reg.acu, tag);
            try materializeBoolFromFlags(self, .eq);
        },
        .class_type => |probe| {
            const class_name = self.source[probe.class_name.start..probe.class_name.end];
            // Eval receiver → acu = instance pointer.
            try emitExpr(self, it.lhs);
            // Load vtable pointer (first word of instance) into r1.
            try self.emitByte(Op.mov_ptr_to_reg);
            try self.emitByte(Reg.r1); // dst
            try self.emitByte(Reg.acu); // ptr
            // `cmp r1, <vtable_addr>` — the imm16 slot is patched
            // by `class.patchVtableSlots` after `emitVtables` runs.
            try self.emitByte(Op.cmp_reg_imm16);
            try self.emitByte(Reg.r1);
            const patch_offset = try self.currentOffset();
            try self.emitU16Le(0);
            try self.vtable_patches.append(self.allocator, .{
                .bank = self.current_bank,
                .code_offset = patch_offset,
                .class_name = try self.arena.dupe(u8, class_name),
            });
            try materializeBoolFromFlags(self, .eq);
        },
    }
}

/// Lower a unary prefix expression.
pub fn emitUnary(self: *Emitter, u: ast.UnaryExpr) !void {
    try emitExpr(self, u.operand);
    switch (u.op) {
        .neg => try isa.negReg(self, Reg.acu),
        .bit_not => try isa.notRegOp(self, Reg.acu),
        .log_not => {
            // acu = (acu == 0) ? 1 : 0
            try isa.cmpRegImm(self, Reg.acu, 0);
            try materializeBoolFromFlags(self, .eq);
        },
    }
}

/// `true` when either operand of a comparison is a `str` — its `==` /
/// `!=` is content-based (§3.2.1) rather than a pointer compare.
fn isStrComparison(self: *Emitter, b: ast.BinaryExpr) bool {
    return self.isPrimitiveType(b.lhs, .str) or self.isPrimitiveType(b.rhs, .str);
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

    // A struct operand evaluates to its base address, so a plain `cmp`
    // would compare addresses, not fields. `==`/`!=` lower to a
    // structural (byte-wise) comparison (§3.4); ordering operators are
    // undefined on structs.
    if (self.structNameOf(b.lhs) orelse self.structNameOf(b.rhs)) |sname| {
        switch (b.op) {
            .eq, .neq => {
                if (!value_struct.eqSupported(self, sname)) {
                    try self.unsupported(b.span, "struct `==` not yet supported for a struct with an array, tuple, `Vec`, payload-carrying enum, or nullable field");
                    return;
                }
                try value_struct.emitEquality(self, b.lhs, b.rhs, sname, b.op == .neq);
                return;
            },
            else => {
                try self.unsupported(b.span, "ordering comparison on structs — only `==` and `!=` are defined");
                return;
            },
        }
    }

    const fixed_op = self.isPrimitiveType(b.lhs, .fixed) and
        self.isPrimitiveType(b.rhs, .fixed) and
        (b.op == .mul or b.op == .div);

    // Per spec §4.2.1, plain `+` / `-` / `*` on integer types trap
    // on overflow in debug builds and wrap in release. The check
    // is emitted after the ALU op so the V / C flags reflect the
    // result. Fixed-point ops keep their wrap-only semantics
    // (ISA §5.4.1).
    const lhs_ty = self.typeOf(b.lhs);
    const rhs_ty = self.typeOf(b.rhs);
    const integer_arith = !fixed_op and overflow.isIntegerArith(lhs_ty) and overflow.isIntegerArith(rhs_ty) and
        (b.op == .add or b.op == .sub or b.op == .mul);
    const signedness = overflow.signednessOf(lhs_ty);

    // Standard stack-machine pattern: eval RHS, push, eval LHS,
    // pop RHS into r1, apply op (acu = acu OP r1).
    try emitExpr(self, b.rhs);
    try isa.pushReg(self, Reg.acu);
    try emitExpr(self, b.lhs);
    try isa.popReg(self, Reg.r1);
    switch (b.op) {
        .add => {
            try isa.addRegToAcu(self, Reg.r1);
            if (integer_arith) try overflow.emitOverflowTrap(self, signedness);
        },
        .sub => {
            try isa.subRegFromAcu(self, Reg.r1);
            if (integer_arith) try overflow.emitOverflowTrap(self, signedness);
        },
        .mul => {
            // `mul src, dst` writes low(product) → dst AND
            // high(product) → acu. If dst == acu the high half
            // clobbers the low half — so we land the result in
            // `r2`, then move it back to acu. Signed `*` routes
            // through `muls` so the V flag matches `i16` overflow
            // (`mul`'s V means `high != 0`, which false-positives
            // on legitimate negative products).
            try isa.movRegToReg(self, Reg.acu, Reg.r2);
            if (integer_arith and signedness == .signed and self.optimize == .debug) {
                try isa.mulsRegReg(self, Reg.r1, Reg.r2);
            } else {
                try isa.mulRegReg(self, Reg.r1, Reg.r2);
            }
            if (fixed_op) {
                // Q8.8 * Q8.8 — the conceptual Q16.16 product
                // straddles acu:r2 (acu = high half, r2 = low
                // half). The Q8.8 result is bits 8..23 of that
                // 32-bit value: `acu (high << 8) | (r2 unsigned
                // >> 8)`. ISA §5.4.1 — products whose real
                // magnitude exceeds 127.99… wrap silently
                // because the result no longer fits in 16 bits.
                try isa.shrRegImm(self, Reg.r2, 8);
                try isa.shlRegImm(self, Reg.acu, 8);
                try isa.orRegReg(self, Reg.acu, Reg.r2);
            } else {
                // Integer mul — drop the high half. `mov` doesn't
                // touch flags, so the V/C set by the mul op above
                // are still live for the overflow check below.
                try isa.movRegToReg(self, Reg.r2, Reg.acu);
            }
            if (integer_arith) try overflow.emitOverflowTrap(self, signedness);
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
                try isa.movRegToReg(self, Reg.acu, Reg.r2);
                try isa.shlRegImm(self, Reg.r2, 8); // r2 = lhs << 8 (low)
                try isa.asrRegImm(self, Reg.acu, 8); // acu = lhs >>a 8 (high)
                try isa.divsRegReg(self, Reg.r1, Reg.r2);
                try isa.movRegToReg(self, Reg.r2, Reg.acu);
            } else {
                // Signed 32÷16 divide. Dividend lives in acu:dst
                // (high:low); the dividend is assumed to fit in
                // 16 bits — sign-extension is not yet emitted.
                try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = low half
                try isa.movImmToReg(self, 0, Reg.acu); // high half = 0
                try isa.divsRegReg(self, Reg.r1, Reg.r2); // r2 = quotient, acu = remainder
                try isa.movRegToReg(self, Reg.r2, Reg.acu);
            }
        },
        .mod => {
            // Same divs pattern as `div`, but keep `acu` (the
            // remainder is exactly what `mod` wants).
            try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = low half
            try isa.movImmToReg(self, 0, Reg.acu); // high half = 0
            try isa.divsRegReg(self, Reg.r1, Reg.r2); // r2 = quotient, acu = remainder
        },
        .bit_and => try isa.andRegReg(self, Reg.acu, Reg.r1),
        .bit_or => try isa.orRegReg(self, Reg.acu, Reg.r1),
        .bit_xor => try isa.xorRegReg(self, Reg.acu, Reg.r1),
        .shl => try isa.shlRegReg(self, Reg.acu, Reg.r1),
        .shr => try isa.shrRegReg(self, Reg.acu, Reg.r1),
        .eq, .neq, .lt, .lte, .gt, .gte => {
            // `str` equality is content-based (§3.2.1), not pointer
            // identity — acu / r1 hold the two string pointers.
            if ((b.op == .eq or b.op == .neq) and isStrComparison(self, b)) {
                try isa.movRegToReg(self, Reg.acu, Reg.r2);
                try strings.emitContentEq(self, Reg.r1, Reg.r2, b.op == .neq);
                return;
            }
            try isa.cmpRegReg(self, Reg.acu, Reg.r1);
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
                // A struct operand compares structurally (byte-wise);
                // the resulting 0/1 in acu is then tested against 0 so
                // the branch consumes its flags like any scalar cond.
                // Ordering operators are undefined on structs.
                if (self.structNameOf(b.lhs) orelse self.structNameOf(b.rhs)) |sname| {
                    switch (b.op) {
                        .eq, .neq => {
                            if (!value_struct.eqSupported(self, sname)) {
                                try self.unsupported(b.span, "struct `==` not yet supported for a struct with an array, tuple, `Vec`, payload-carrying enum, or nullable field");
                                return;
                            }
                            try value_struct.emitEquality(self, b.lhs, b.rhs, sname, b.op == .neq);
                            try isa.cmpRegImm(self, Reg.acu, 0);
                            return;
                        },
                        else => {
                            try self.unsupported(b.span, "ordering comparison on structs — only `==` and `!=` are defined");
                            return;
                        },
                    }
                }
                // Eval LHS into acu, eval RHS into r1, cmp acu, r1.
                try emitExpr(self, b.rhs);
                try isa.pushReg(self, Reg.acu);
                try emitExpr(self, b.lhs);
                try isa.popReg(self, Reg.r1);
                // `str` equality compares content (§3.2.1); the 0/1 it
                // leaves in acu is then tested against 0 like any cond.
                if ((b.op == .eq or b.op == .neq) and isStrComparison(self, b)) {
                    try isa.movRegToReg(self, Reg.acu, Reg.r2);
                    try strings.emitContentEq(self, Reg.r1, Reg.r2, b.op == .neq);
                    try isa.cmpRegImm(self, Reg.acu, 0);
                    return;
                }
                try isa.cmpRegReg(self, Reg.acu, Reg.r1);
                try materializeBoolFromFlags(self, b.op);
                try isa.cmpRegImm(self, Reg.acu, 0);
                return;
            },
            .log_and, .log_or => {
                try emitShortCircuitBool(self, b);
                try isa.cmpRegImm(self, Reg.acu, 0);
                return;
            },
            else => {},
        }
    }
    if (e.* == .unary and e.unary.op == .log_not) {
        try emitExpr(self, e.unary.operand);
        try isa.cmpRegImm(self, Reg.acu, 0);
        try materializeBoolFromFlags(self, .eq);
        try isa.cmpRegImm(self, Reg.acu, 0);
        return;
    }
    // Generic path — evaluate to acu, then test against 0.
    try emitExpr(self, e);
    try isa.cmpRegImm(self, Reg.acu, 0);
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
    const true_patch = try isa.emitJumpPlaceholder(self, taken_op);
    try isa.movImmToReg(self, 0, Reg.acu);
    const end_patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    const true_offset = try self.currentOffset();
    try isa.movImmToReg(self, 1, Reg.acu);
    const end_offset = try self.currentOffset();
    try isa.patchJumpTo(self, true_patch, true_offset);
    try isa.patchJumpTo(self, end_patch, end_offset);
}

/// Lower a short-circuiting `and` / `or` into a chain of
/// conditional jumps that leaves a 0 / 1 in `acu`.
pub fn emitShortCircuitBool(self: *Emitter, b: ast.BinaryExpr) !void {
    switch (b.op) {
        .log_and => {
            // acu = lhs; if acu == 0 -> short-circuit false.
            try emitExpr(self, b.lhs);
            try isa.cmpRegImm(self, Reg.acu, 0);
            const short_patch = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
            try emitExpr(self, b.rhs);
            try isa.cmpRegImm(self, Reg.acu, 0);
            try materializeBoolFromFlags(self, .neq);
            const end_patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
            const short_offset = try self.currentOffset();
            try isa.movImmToReg(self, 0, Reg.acu);
            const end_offset = try self.currentOffset();
            try isa.patchJumpTo(self, short_patch, short_offset);
            try isa.patchJumpTo(self, end_patch, end_offset);
        },
        .log_or => {
            try emitExpr(self, b.lhs);
            try isa.cmpRegImm(self, Reg.acu, 0);
            const short_patch = try isa.emitJumpPlaceholder(self, Op.jne_addr);
            try emitExpr(self, b.rhs);
            try isa.cmpRegImm(self, Reg.acu, 0);
            try materializeBoolFromFlags(self, .neq);
            const end_patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
            const short_offset = try self.currentOffset();
            try isa.movImmToReg(self, 1, Reg.acu);
            const end_offset = try self.currentOffset();
            try isa.patchJumpTo(self, short_patch, short_offset);
            try isa.patchJumpTo(self, end_patch, end_offset);
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
        // Payload-variant constructor — `Enum.Variant(args)` parses as
        // a method call on the enum name.
        if (self.enum_decls.get(recv)) |ed| {
            const variant_name = self.source[m.method.start..m.method.end];
            if (self.variantTag(recv, variant_name)) |tag| {
                for (ed.variants) |v| {
                    if (!std.mem.eql(u8, self.source[v.name.start..v.name.end], variant_name)) continue;
                    try emitEnumConstruct(self, ed, v, tag, m.args);
                    return;
                }
            }
        }
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
        // `assert` / `debug_assert` always-in-scope builtins
        // (§5.3) intercept before the free-fn path — they have no
        // top-level def behind them.
        if (assert_builtin.isAssertBuiltin(callee_name)) {
            try assert_builtin.emitAssertCall(self, c, callee_name);
            return;
        }
        if (diverge_builtin.isDivergeBuiltin(callee_name)) {
            try diverge_builtin.emitDivergeCall(self, c, callee_name);
            return;
        }
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
            // Payload-variant constructor — `Enum.Variant(args)`.
            if (self.enum_decls.get(recv)) |ed| {
                const variant_name = self.source[fe.field.start..fe.field.end];
                if (self.variantTag(recv, variant_name)) |tag| {
                    for (ed.variants) |v| {
                        if (!std.mem.eql(u8, self.source[v.name.start..v.name.end], variant_name)) continue;
                        try emitEnumConstruct(self, ed, v, tag, c.args);
                        return;
                    }
                }
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

    // A struct-returning callee takes a hidden sret destination pointer
    // pushed first (it sits just above the user args). Point it at this
    // frame's scratch buffer; the callee copies its result there and
    // returns the pointer in `acu`.
    const returns_struct = self.fn_ret_struct.contains(callee_name);
    if (returns_struct) {
        // Invariant: a struct-returning callee implies the program has a
        // struct return type, so every frame reserved a scratch slot.
        const sofs = self.sret_scratch_ofs.?;
        try isa.movRegToReg(self, Reg.fp, Reg.acu);
        if (sofs < 0) try isa.subImmFromReg(self, @intCast(-sofs), Reg.acu);
        try isa.pushReg(self, Reg.acu);
    }

    // Push args right-to-left (caller-cleans-up). A struct arg is
    // passed by value — its (2-aligned) width copied onto the stack.
    var i: usize = c.args.len;
    while (i > 0) {
        i -= 1;
        if (self.argStructName(c.args[i])) |sname| {
            try value_struct.pushArg(self, c.args[i], sname);
        } else {
            try emitExpr(self, c.args[i]);
            try isa.pushReg(self, Reg.acu);
        }
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
        try isa.movImmToReg(self, target_bank_byte, Reg.r2);
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
    if (!skip_cleanup) {
        var drop_bytes: u16 = if (returns_struct) 2 else 0; // hidden sret pointer
        for (c.args) |a| {
            if (self.argStructName(a)) |sname| {
                drop_bytes += self.structSlotWidth(sname);
            } else {
                drop_bytes += 2; // one 16-bit word per scalar arg
            }
        }
        if (drop_bytes > 0) try isa.addImmToReg(self, drop_bytes, Reg.sp);
    }
}
