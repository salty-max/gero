const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const archive = @import("archive.zig");
const assert_builtin = @import("assert.zig");
const diverge_builtin = @import("diverge.zig");
const stdlib = @import("stdlib.zig");
const class = @import("class.zig");
const value_struct = @import("value_struct.zig");
const vec_builtin = @import("vec_builtin.zig");
const str_builtin = @import("str_builtin.zig");
const variadic = @import("variadic.zig");
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
            // A struct- / tuple- / array- / Vec- / scalar-optional-typed
            // binding evaluates to its base address — inline aggregates
            // (incl. the 6-byte Vec header + the 4-byte `{present, value}`
            // optional) are addressed in place, not loaded as a word. But a
            // `&T` reference to such an aggregate holds a POINTER to it: its
            // base is the pointer VALUE in the slot, so fall through to the
            // word-load tail (one deref, mirroring `class.emitInstancePtr`).
            const is_reference = if (self.typeOf(e)) |t| t.* == .reference else false;
            if (!is_reference and (self.structNameOf(e) != null or self.tupleElemsOf(e) != null or
                self.arrayInfoOf(e) != null or vec_builtin.elemOf(self, e) != null or
                self.scalarOptionalElemOf(e) != null))
            {
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
        .tuple_index => |ti| try emitTupleIndexExpr(self, ti),
        .index => |ix| try emitIndexExpr(self, ix),
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
    // Allocate the `[tag | payload]` slot first and park its pointer on
    // the stack — argument evaluation can clobber every register, so the
    // pointer is reloaded from `[sp]` for each field store.
    try isa.movImmToReg(self, self.enumSlotSize(ed), Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(opcodes.Sys.alloc);
    try isa.pushReg(self, Reg.acu); // [sp] = slot pointer

    // Tag byte at offset 0.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1);
    try isa.movImmToReg(self, tag, Reg.r2);
    try class.emitByteStoreAtOffset(self, Reg.r1, 0, Reg.r2);

    for (args, 0..) |arg, i| {
        const ofs = self.variantFieldOffset(variant, i);
        const ann = variant.payload[i].type_ann.*;
        if (self.structNameOfTypeAnn(ann) != null or ann == .tuple or ann == .array) {
            // Aggregate payload — materialize it inline into the slot
            // field (a literal lands in place, a value is copied) so the
            // enum owns the bytes (value semantics; no dangling temp).
            try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1);
            try isa.movRegToReg(self, Reg.r1, Reg.acu);
            if (ofs > 0) try isa.addImmToReg(self, ofs, Reg.acu);
            const ty = (try self.typeAnnToType(ann)) orelse {
                try self.unsupported(arg.span(), "enum payload of this type");
                continue;
            };
            try value_struct.emitAggregateStoreInto(self, arg, ty, Reg.acu);
        } else {
            try emitExpr(self, arg); // acu = scalar value / pointer
            try isa.movRegToReg(self, Reg.acu, Reg.r2);
            try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1);
            if (self.widthOfTypeAnn(ann) == 1) {
                try class.emitByteStoreAtOffset(self, Reg.r1, ofs, Reg.r2);
            } else {
                try class.emitWordStoreAtOffset(self, Reg.r1, ofs, Reg.r2);
            }
        }
    }

    // Result is the slot pointer.
    try isa.popReg(self, Reg.acu);
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
    // str property (`s.len`).
    if (str_builtin.isStr(self, f.receiver)) {
        const fname = self.source[f.field.start..f.field.end];
        if (std.mem.eql(u8, fname, "len")) {
            try str_builtin.emitLen(self, f.receiver);
            return;
        }
    }
    try self.unsupported(e.span(), "non-enum field access");
}

/// Lower a `tuple.N` element access — evaluate the receiver to its base
/// address, then load element `N` (an aggregate element leaves its
/// inline address in `acu`, a scalar its value).
fn emitTupleIndexExpr(self: *Emitter, ti: ast.TupleIndexExpr) !void {
    // `args.N` inside a variadic body reads a word-strided block (each
    // vararg was pushed as a full word), not the byte-packed tuple
    // layout — intercept before the generic path (§4.6.2).
    if (variadic.isArgsForward(self, ti.receiver)) {
        try variadic.emitArgsIndex(self, ti.receiver, ti.index);
        return;
    }
    const elems = self.tupleElemsOf(ti.receiver) orelse {
        try self.unsupported(ti.span, "tuple element access on a non-tuple value");
        return;
    };
    try emitExpr(self, ti.receiver); // acu = tuple base address
    try value_struct.emitTupleElemLoad(self, elems, ti.index);
}

/// Lower an array index read `arr[i]` — resolve the element at
/// `base + i*elem_width`. A constant index folds to a fixed offset
/// (the typechecker already bounds-checked it); a runtime index is
/// bounds-trapped (debug) then scaled. A scalar element loads its
/// word/byte; an aggregate element leaves its address (see `emitArrayElem`).
fn emitIndexExpr(self: *Emitter, ix: ast.IndexExpr) !void {
    // `v[i]` on a Vec — sugar for `v.at(i)` (bounds-trapped element load).
    if (vec_builtin.elemOf(self, ix.receiver)) |elem| {
        try vec_builtin.emitIndexLoad(self, ix.receiver, ix.index, elem);
        return;
    }
    const info = self.arrayInfoOf(ix.receiver) orelse {
        try self.unsupported(ix.span, "indexing a non-array value");
        return;
    };
    if (ix.index.* == .int_lit) {
        try emitExpr(self, ix.receiver); // acu = base address
        try isa.movRegToReg(self, Reg.acu, Reg.r1);
        // @as: const index × elem_width within the (≤127-byte) array.
        const offset: u16 = @intCast(ix.index.int_lit.value * info.elem_width);
        try emitArrayElem(self, Reg.r1, offset, info);
        return;
    }
    try value_struct.emitIndexAddr(self, ix, info); // acu = element address
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try emitArrayElem(self, Reg.r1, 0, info);
}

/// Resolve array element `[base + offset]`: load a scalar element into
/// `acu` (sign-extending an `i8`); for an aggregate element leave its base
/// address in `acu` — an aggregate value *is* an address, so `.field` /
/// `.N` / further indexing resolve against it without a deref.
fn emitArrayElem(self: *Emitter, base: u8, offset: u16, info: codegen.Emitter.ArrayInfo) !void {
    switch (self.arrayElemKindOf(info.elem)) {
        .scalar => {
            if (info.elem_width == 1) {
                try class.emitByteLoadAtOffset(self, base, offset, Reg.acu);
                if (info.signed_byte) try isa.signExtendByte(self, Reg.acu);
            } else {
                try class.emitWordLoadAtOffset(self, base, offset, Reg.acu);
            }
        },
        else => {
            try isa.movRegToReg(self, base, Reg.acu);
            if (offset != 0) try isa.addImmToReg(self, offset, Reg.acu);
        },
    }
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

/// `true` for a `str` ordering comparison (`< <= > >=`) — lexicographic
/// per §3.2.1, distinct from the `==` / `!=` content path.
fn isStrOrdering(self: *Emitter, b: ast.BinaryExpr) bool {
    return switch (b.op) {
        .lt, .lte, .gt, .gte => isStrComparison(self, b),
        else => false,
    };
}

/// The enum decl when a comparison's operands are a payload-carrying
/// enum, else `null`. Such a value is a `[tag|payload]` slot pointer, so
/// `==` must compare the slots, not the pointers. Payload-free enums are
/// bare tags and compare correctly via the plain register `cmp`.
fn payloadEnumComparison(self: *Emitter, b: ast.BinaryExpr) ?*const ast.EnumDecl {
    const ed = self.enumDeclForExpr(b.lhs) orelse self.enumDeclForExpr(b.rhs) orelse return null;
    return if (self.enumHasPayload(ed)) ed else null;
}

/// Lower a binary infix expression. Short-circuit operators
/// (`and`, `or`) take a separate path so the RHS isn't always
/// evaluated. Comparison ops materialize a `0` / `1` in `acu`.
/// Fixed-point `*` / `/` get a Q8.8 scaling tail per ISA §5.4.1.
/// When `b` is `<scalar optional> == nil` / `!= nil`, the scalar-optional
/// operand and its inner type, else `null`. The optional must be the
/// scalar (`{present, value}`) form; pointer optionals compare as a word.
fn scalarOptionalNilCompare(self: *Emitter, b: ast.BinaryExpr) ?*const ast.Expr {
    if (b.op != .eq and b.op != .neq) return null;
    if (b.rhs.* == .nil_lit and self.scalarOptionalElemOf(b.lhs) != null) return b.lhs;
    if (b.lhs.* == .nil_lit and self.scalarOptionalElemOf(b.rhs) != null) return b.rhs;
    return null;
}

/// Leave `1`/`0` in `acu` for `<scalar optional> == nil` (`negate` =>
/// `!= nil`) — testing the `present` tag rather than the header address.
fn emitScalarOptionalNilCompare(self: *Emitter, opt_expr: *const ast.Expr, negate: bool) error{OutOfMemory}!void {
    try emitExpr(self, opt_expr); // acu = optional header address
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try class.emitWordLoadAtOffset(self, Reg.r1, codegen.Emitter.opt_present_ofs, Reg.acu); // acu = present
    try isa.cmpRegImm(self, Reg.acu, 0);
    const absent = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try isa.movImmToReg(self, if (negate) 1 else 0, Reg.acu); // present → `!= nil`
    const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, absent, try self.currentOffset());
    try isa.movImmToReg(self, if (negate) 0 else 1, Reg.acu); // absent → `== nil`
    try isa.patchJumpTo(self, done, try self.currentOffset());
}

/// Lower a binary expression, leaving the result in `acu`. Handles the
/// value-aggregate comparison special cases (struct / tuple / scalar-
/// optional `==` / `!=`) before the scalar arithmetic / comparison path.
pub fn emitBinary(self: *Emitter, b: ast.BinaryExpr) !void {
    // A scalar optional compared to `nil` — test the `present` tag (the
    // header evaluates to an address, so a plain `cmp` would never be nil).
    if (scalarOptionalNilCompare(self, b)) |opt_expr| {
        try emitScalarOptionalNilCompare(self, opt_expr, b.op == .neq);
        return;
    }
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

    // A tuple operand compares element-wise (§3.4); ordering is undefined.
    if (self.tupleElemsOf(b.lhs) orelse self.tupleElemsOf(b.rhs)) |elems| {
        switch (b.op) {
            .eq, .neq => {
                if (!value_struct.tupleEqSupported(self, elems)) {
                    try self.unsupported(b.span, "tuple `==` with a nullable / array / `Vec` element");
                    return;
                }
                try value_struct.emitTupleEquality(self, b.lhs, b.rhs, elems, b.op == .neq);
                return;
            },
            else => {
                try self.unsupported(b.span, "ordering comparison on tuples — only `==` and `!=` are defined");
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
            // `str + str` allocates a fresh buffer and concatenates
            // (§3.2.1) — acu / r1 hold the lhs / rhs pointers. (Typecheck
            // guarantees both sides are `str` when either is.)
            if (self.isPrimitiveType(b.lhs, .str)) {
                try strings.emitStrConcat(self, Reg.acu, Reg.r1);
                return;
            }
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
            // `str` ordering is lexicographic (§3.2.1): strcmp the bytes,
            // then map the sign to the relation. acu / r1 = lhs / rhs ptrs.
            if (isStrOrdering(self, b)) {
                try isa.movRegToReg(self, Reg.acu, Reg.r2);
                try strings.emitStrCmp(self, Reg.r2, Reg.r1);
                try isa.cmpRegImm(self, Reg.acu, 0);
                try materializeBoolFromFlags(self, b.op);
                return;
            }
            // Payload-carrying enum: compare the two slots by value (tag,
            // then per-variant payload), not the pointers — acu / r1 hold
            // the lhs / rhs slot addresses.
            if (b.op == .eq or b.op == .neq) {
                if (payloadEnumComparison(self, b)) |ed| {
                    if (!value_struct.enumEqSupported(self, ed)) {
                        try self.unsupported(b.span, "`==` on an enum with a recursive or non-comparable payload");
                        return;
                    }
                    try value_struct.emitEnumEqual(self, ed, Reg.acu, Reg.r1, b.op == .neq);
                    return;
                }
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
                // A scalar optional vs `nil` — test the `present` tag, then
                // compare the 0/1 to 0 so the branch consumes its flags.
                if (scalarOptionalNilCompare(self, b)) |opt_expr| {
                    try emitScalarOptionalNilCompare(self, opt_expr, b.op == .neq);
                    try isa.cmpRegImm(self, Reg.acu, 0);
                    return;
                }
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
                // Tuple compare element-wise; the 0/1 it leaves in acu is
                // tested against 0 so the branch consumes its flags.
                if (self.tupleElemsOf(b.lhs) orelse self.tupleElemsOf(b.rhs)) |elems| {
                    switch (b.op) {
                        .eq, .neq => {
                            if (!value_struct.tupleEqSupported(self, elems)) {
                                try self.unsupported(b.span, "tuple `==` with a nullable / array / `Vec` element");
                                return;
                            }
                            try value_struct.emitTupleEquality(self, b.lhs, b.rhs, elems, b.op == .neq);
                            try isa.cmpRegImm(self, Reg.acu, 0);
                            return;
                        },
                        else => {
                            try self.unsupported(b.span, "ordering comparison on tuples — only `==` and `!=` are defined");
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
                // `str` ordering (§3.2.1): strcmp, then the 0/1 it
                // materializes is tested against 0 like any cond.
                if (isStrOrdering(self, b)) {
                    try isa.movRegToReg(self, Reg.acu, Reg.r2);
                    try strings.emitStrCmp(self, Reg.r2, Reg.r1);
                    try isa.cmpRegImm(self, Reg.acu, 0);
                    try materializeBoolFromFlags(self, b.op);
                    try isa.cmpRegImm(self, Reg.acu, 0);
                    return;
                }
                // Payload-carrying enum: slot compare by value, then test
                // the 0/1 against 0 so the branch consumes its flags.
                if (b.op == .eq or b.op == .neq) {
                    if (payloadEnumComparison(self, b)) |ed| {
                        if (!value_struct.enumEqSupported(self, ed)) {
                            try self.unsupported(b.span, "`==` on an enum with a recursive or non-comparable payload");
                            return;
                        }
                        try value_struct.emitEnumEqual(self, ed, Reg.acu, Reg.r1, b.op == .neq);
                        try isa.cmpRegImm(self, Reg.acu, 0);
                        return;
                    }
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
    // Vec-typed receiver — builtin method (`v.push` / `v.len` / `v.at` / …).
    if (vec_builtin.elemOf(self, m.receiver)) |elem| {
        const mname = self.source[m.method.start..m.method.end];
        try vec_builtin.emitMethod(self, m.receiver, mname, m.args, elem);
        return;
    }
    // str-typed receiver — builtin method (`s.at` / `s.cmp`).
    if (str_builtin.isStr(self, m.receiver)) {
        const mname = self.source[m.method.start..m.method.end];
        try str_builtin.emitMethod(self, m.receiver, mname, m.args);
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
        if (stdlib.isModule(recv)) {
            const synth_field: ast.FieldExpr = .{
                .receiver = m.receiver,
                .field = m.method,
                .span = m.span,
            };
            const synth_call: ast.CallExpr = .{
                .callee = m.receiver,
                .args = m.args,
                .span = m.span,
            };
            try stdlib.emitCall(self, recv, synth_field, synth_call);
            return;
        }
        // `str.format(fmt, args)` — str module function.
        if (std.mem.eql(u8, recv, "str") and std.mem.eql(u8, self.source[m.method.start..m.method.end], "format")) {
            try str_builtin.emitFormat(self, m.args[0], m.args[1..]);
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
            if (stdlib.isModule(recv)) {
                try stdlib.emitCall(self, recv, fe, c);
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
    // A variadic call targets the `name$N` specialization for this
    // site's arity; metadata (bank, return shape) stays keyed by the
    // bare name, shared across specializations (§4.6.2).
    const dup = if (self.variadic_decls.get(callee_name)) |decl| blk: {
        // @as: arity = total args − fixed params; non-negative (the
        // typechecker enforces the fixed-arg minimum) and frame-bounded.
        const arity: u16 = @intCast(c.args.len - (decl.params.len - 1));
        break :blk try variadic.label(self, callee_name, arity);
    } else try self.arena.dupe(u8, callee_name);

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
    const returns_tuple = self.fn_ret_tuple.contains(callee_name);
    const returns_scalar_opt = self.fn_ret_scalar_opt.contains(callee_name);
    if (returns_struct or returns_tuple or returns_scalar_opt) {
        // Invariant: an aggregate-returning callee implies the program
        // reserved an sret scratch slot in every frame (struct / tuple /
        // scalar-optional returns share it).
        const sofs = self.sret_scratch_ofs.?;
        try isa.movRegToReg(self, Reg.fp, Reg.acu);
        if (sofs < 0) try isa.subImmFromReg(self, @intCast(-sofs), Reg.acu);
        try isa.pushReg(self, Reg.acu);
    }

    // Push args right-to-left (caller-cleans-up). A struct or tuple arg
    // is passed by value — its (2-aligned) width copied onto the stack. A
    // `&T` reference arg is a 2-byte pointer (the `*Of` helpers peel the
    // reference, so it must be excluded from the by-value paths).
    var i: usize = c.args.len;
    while (i > 0) {
        i -= 1;
        const arg = c.args[i];
        if (!self.isReferenceArg(arg)) {
            if (self.argStructName(arg)) |sname| {
                try value_struct.pushArg(self, arg, sname);
                continue;
            }
            if (self.tupleElemsOf(arg)) |elems| {
                try value_struct.pushTupleArg(self, arg, elems);
                continue;
            }
            if (self.arrayInfoOf(arg)) |info| {
                try value_struct.pushArrayArg(self, arg, info.elem, info.count);
                continue;
            }
            if (vec_builtin.elemOf(self, arg) != null) {
                try vec_builtin.pushVecArg(self, arg);
                continue;
            }
        }
        try emitExpr(self, arg);
        try isa.pushReg(self, Reg.acu);
    }

    if (cross_bank) {
        // Trampoline path:
        //   push <target_bank>   ; literal at emit time
        //   push <target_addr>   ; patched at end
        //   call __call_bank     ; patched at end
        // The target rides the stack (atomic immediate pushes), not a
        // register, so no value is live across an interruptible
        // boundary; `__call_bank` pops both. Bank is pushed first so
        // the address lands on top and is popped first.
        const target_bank_byte: u8 = target_bank orelse 0;
        try isa.pushImm16(self, target_bank_byte);
        try self.emitByte(Op.push_imm16);
        const addr_patch_offset = try self.currentOffset();
        try self.emitU16Le(0); // target-address placeholder
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
        var drop_bytes: u16 = if (returns_struct or returns_tuple) 2 else 0; // hidden sret pointer
        for (c.args) |a| {
            if (self.argStructName(a)) |sname| {
                drop_bytes += self.structSlotWidth(sname);
            } else if (self.tupleElemsOf(a)) |elems| {
                drop_bytes += self.tupleSlotWidth(elems);
            } else {
                drop_bytes += 2; // one 16-bit word per scalar arg
            }
        }
        if (drop_bytes > 0) try isa.addImmToReg(self, drop_bytes, Reg.sp);
    }
}
