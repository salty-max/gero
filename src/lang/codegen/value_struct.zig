// Codegen for inline value aggregates (§3.4) — structs and tuples. An
// aggregate value lives in its owner's frame as contiguous bytes; an
// aggregate-typed expression evaluates to that base address.
// Construction writes each field/element at its offset (recursing into
// nested struct fields); assignment copies the bytes (value semantics).
// An aggregate argument is passed by value: the caller reserves its
// width on the stack and materializes a copy there (`pushArg` /
// `pushTupleArg`). Tuples reuse the same `Dest` / `copyBytes` plumbing
// but key on the element type list rather than a struct name.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const codegen = @import("../codegen.zig");
const control_flow = @import("control_flow.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const class = @import("class.zig");
const strings = @import("strings.zig");
const overflow = @import("overflow.zig");
const do_expr = @import("do_expr.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

/// Where a materialized struct lands. `frame` is fp-relative (a local
/// or param slot — `ofs` negative for locals, positive for params).
/// `sp` is sp-relative (a freshly reserved stack region for an
/// outgoing argument — `ofs` ≥ 0 from the current `sp`). `indirect` is
/// the buffer pointed to by a frame slot holding an address (`ptr_ofs`)
/// plus a field `delta` — used to write a returned struct into the
/// caller's sret destination. `indirect_sp` is the buffer pointed to by
/// a pointer parked on the stack (`sp_ofs`) plus `delta` — used to
/// materialize an aggregate value straight into a runtime-computed lvalue
/// (an array element / struct field) without a temporary binding.
const Dest = union(enum) {
    frame: i16,
    sp: i16,
    indirect: struct { ptr_ofs: i16, delta: i16 },
    indirect_sp: struct { sp_ofs: i16, delta: i16 },

    /// Shift the destination deeper by `delta` bytes (a nested field).
    fn at(self: Dest, delta: i16) Dest {
        return switch (self) {
            .frame => |o| .{ .frame = o + delta },
            .sp => |o| .{ .sp = o + delta },
            .indirect => |ind| .{ .indirect = .{ .ptr_ofs = ind.ptr_ofs, .delta = ind.delta + delta } },
            .indirect_sp => |ind| .{ .indirect_sp = .{ .sp_ofs = ind.sp_ofs, .delta = ind.delta + delta } },
        };
    }
};

/// `reg = base + ofs` for a destination. The `sp` form re-reads `sp`,
/// `indirect` re-loads its frame pointer slot, and `indirect_sp` re-loads
/// the parked stack pointer — all valid because every field-value
/// expression restores `sp` and leaves the frame slot untouched, so the
/// destination base stays stable across fields.
fn destAddrToReg(self: *Emitter, dest: Dest, reg: u8) !void {
    switch (dest) {
        .frame => |ofs| try frameAddrToReg(self, ofs, reg),
        .sp => |ofs| {
            try isa.movRegToReg(self, Reg.sp, reg);
            if (ofs > 0) try isa.addImmToReg(self, @intCast(ofs), reg);
        },
        .indirect => |ind| {
            try isa.movRegToReg(self, Reg.fp, reg);
            if (ind.ptr_ofs > 0) try isa.addImmToReg(self, @intCast(ind.ptr_ofs), reg);
            try isa.movRegOffsetToReg(self, reg, 0, reg); // reg = stored pointer
            if (ind.delta > 0) try isa.addImmToReg(self, @intCast(ind.delta), reg);
        },
        .indirect_sp => |ind| {
            // safety: the parked pointer sits at a small, in-range sp offset.
            try isa.movRegOffsetToReg(self, Reg.sp, @intCast(ind.sp_ofs), reg); // reg = parked pointer
            if (ind.delta > 0) try isa.addImmToReg(self, @intCast(ind.delta), reg);
        },
    }
}

/// Materialize a value of struct `sname` into the frame slot based at
/// `dest_ofs` (fp-relative). `src` is a struct literal — write each
/// field, recursing into nested struct fields — or another struct
/// value, byte-copied for value semantics.
pub fn emitInto(self: *Emitter, src: *const ast.Expr, sname: []const u8, dest_ofs: i16) error{OutOfMemory}!void {
    try emitIntoDest(self, src, sname, .{ .frame = dest_ofs });
}

/// Pass a struct argument by value: reserve its (2-aligned) width on
/// the stack and materialize a copy there. Mirrors a `pushReg` for a
/// scalar arg — leaves the bytes at `[sp ..]` for the callee's param.
pub fn pushArg(self: *Emitter, arg: *const ast.Expr, sname: []const u8) error{OutOfMemory}!void {
    const w = self.structSlotWidth(sname);
    try isa.subImmFromReg(self, w, Reg.sp);
    try emitIntoDest(self, arg, sname, .{ .sp = 0 });
}

/// Materialize a returned struct into the caller's sret buffer — the
/// address held in the frame slot at `ptr_ofs`. Writing through the
/// stable pointer slot needs no local temp.
pub fn emitIntoSret(self: *Emitter, src: *const ast.Expr, sname: []const u8, ptr_ofs: i16) error{OutOfMemory}!void {
    try emitIntoDest(self, src, sname, .{ .indirect = .{ .ptr_ofs = ptr_ofs, .delta = 0 } });
}

/// Lower a value `if` (§4.4.2) whose branches each materialize an
/// aggregate into `dest`. The branch skeleton is the statement form's;
/// `materialize` is the caller's own into-dest function, applied to
/// each branch's tail expression so struct / tuple / array destinations
/// share one implementation.
fn emitIfChainIntoDest(
    self: *Emitter,
    ie: ast.IfExpr,
    dest: Dest,
    ctx: anytype,
    comptime materialize: fn (*Emitter, *const ast.Expr, @TypeOf(ctx), Dest) error{OutOfMemory}!void,
) error{OutOfMemory}!void {
    var end_patches: std.ArrayList(usize) = .empty;
    defer end_patches.deinit(self.allocator);

    for (ie.arms) |arm| {
        const skip_body = try control_flow.emitIfArmTest(self, arm);
        try emitBranchIntoDest(self, arm.body, ie.span, dest, ctx, materialize);
        try end_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));
        try isa.patchJumpTo(self, skip_body, try self.currentOffset());
    }
    // The checker requires an `else`, so the chain is total.
    if (ie.else_body) |eb| try emitBranchIntoDest(self, eb, ie.span, dest, ctx, materialize);

    const end_offset = try self.currentOffset();
    for (end_patches.items) |patch| try isa.patchJumpTo(self, patch, end_offset);
}

/// One branch of `emitIfChainIntoDest`: scope the body, materialize its
/// tail into `dest`, then close the scope. `span` covers the whole
/// chain, so a branch with no value reports against a real location
/// even when its own body is empty.
fn emitBranchIntoDest(
    self: *Emitter,
    body: []const ast.Statement,
    span: ast.Span,
    dest: Dest,
    ctx: anytype,
    comptime materialize: fn (*Emitter, *const ast.Expr, @TypeOf(ctx), Dest) error{OutOfMemory}!void,
) error{OutOfMemory}!void {
    const p = try do_expr.emitBodyPrefixScoped(self, body);
    switch (p.tail) {
        .expr => |tail| try materialize(self, tail, ctx, dest),
        .if_chain => |nested| try emitIfChainIntoDest(self, nested, dest, ctx, materialize),
        .none => try self.unsupported(span, "this branch of a value `if` must end in an expression"),
    }
    try do_expr.emitSuffix(self, p);
}

fn structTail(self: *Emitter, src: *const ast.Expr, sname: []const u8, dest: Dest) error{OutOfMemory}!void {
    return emitIntoDest(self, src, sname, dest);
}

fn tupleTail(self: *Emitter, src: *const ast.Expr, elems: []const *const types.Type, dest: Dest) error{OutOfMemory}!void {
    return emitTupleIntoDest(self, src, elems, dest);
}

const ArrayShape = struct { elem: *const types.Type, count: u32 };

fn arrayTail(self: *Emitter, src: *const ast.Expr, shape: ArrayShape, dest: Dest) error{OutOfMemory}!void {
    return emitArrayIntoDest(self, src, shape.elem, shape.count, dest);
}

fn emitIntoDest(self: *Emitter, src: *const ast.Expr, sname: []const u8, dest: Dest) error{OutOfMemory}!void {
    if (src.* == .if_expr) return try emitIfChainIntoDest(self, src.if_expr, dest, sname, structTail);
    // A `do … end` value block: run its scoped prefix, then materialize
    // its tail expression into `dest`.
    if (src.* == .do_expr) {
        const p = try do_expr.emitPrefix(self, src.do_expr);
        switch (p.tail) {
            .expr => |tail| try emitIntoDest(self, tail, sname, dest),
            else => try self.unsupported(src.do_expr.span, "`do` value block must end in an expression"),
        }
        try do_expr.emitSuffix(self, p);
        return;
    }
    if (src.* == .struct_lit) {
        try emitLitInto(self, src.struct_lit, sname, dest);
        return;
    }
    // Copy the source struct's bytes into the destination region.
    try self.emitExpr(src); // acu = source base address
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try destAddrToReg(self, dest, Reg.r2);
    try copyBytes(self, Reg.r1, Reg.r2, self.structWidth(sname));
}

// ---- tuple values (§3.4) ----
// A tuple is an anonymous positional aggregate stored inline like a
// struct (contiguous, byte-packed slots). Register-width elements
// (scalar / `str` / enum / class / reference) store their word; a nested
// struct / tuple element lays out inline at its offset (recursing).

/// Materialize a tuple value into the frame slot based at `dest_ofs`
/// (fp-relative).
pub fn emitTupleInto(self: *Emitter, src: *const ast.Expr, elems: []const *const types.Type, dest_ofs: i16) error{OutOfMemory}!void {
    try emitTupleIntoDest(self, src, elems, .{ .frame = dest_ofs });
}

/// Pass a tuple argument by value: reserve its (2-aligned) width on the
/// stack and materialize a copy there.
pub fn pushTupleArg(self: *Emitter, arg: *const ast.Expr, elems: []const *const types.Type) error{OutOfMemory}!void {
    try isa.subImmFromReg(self, self.tupleSlotWidth(elems), Reg.sp);
    try emitTupleIntoDest(self, arg, elems, .{ .sp = 0 });
}

/// Pass a fixed-array argument by value (§3.4): reserve its (2-aligned)
/// width on the stack and materialize a copy there.
pub fn pushArrayArg(self: *Emitter, arg: *const ast.Expr, elem: *const types.Type, count: u32) error{OutOfMemory}!void {
    try isa.subImmFromReg(self, self.arraySlotWidth(elem, count), Reg.sp);
    try emitArrayIntoDest(self, arg, elem, count, .{ .sp = 0 });
}

/// Materialize a returned tuple into the caller's sret buffer.
pub fn emitTupleIntoSret(self: *Emitter, src: *const ast.Expr, elems: []const *const types.Type, ptr_ofs: i16) error{OutOfMemory}!void {
    try emitTupleIntoDest(self, src, elems, .{ .indirect = .{ .ptr_ofs = ptr_ofs, .delta = 0 } });
}

/// Materialize a fixed-array return into the caller's sret buffer,
/// the same convention structs and tuples use.
pub fn emitArrayIntoSret(self: *Emitter, src: *const ast.Expr, elem: *const types.Type, count: u32, ptr_ofs: i16) error{OutOfMemory}!void {
    try emitArrayIntoDest(self, src, elem, count, .{ .indirect = .{ .ptr_ofs = ptr_ofs, .delta = 0 } });
}

fn emitTupleIntoDest(self: *Emitter, src: *const ast.Expr, elems: []const *const types.Type, dest: Dest) error{OutOfMemory}!void {
    if (src.* == .if_expr) return try emitIfChainIntoDest(self, src.if_expr, dest, elems, tupleTail);
    if (src.* == .do_expr) {
        const p = try do_expr.emitPrefix(self, src.do_expr);
        switch (p.tail) {
            .expr => |tail| try emitTupleIntoDest(self, tail, elems, dest),
            else => try self.unsupported(src.do_expr.span, "`do` value block must end in an expression"),
        }
        try do_expr.emitSuffix(self, p);
        return;
    }
    if (src.* == .tuple_lit) {
        for (src.tuple_lit.elems, 0..) |elem, i| {
            // safety: tuple arity ≤ 4 (§3.4) fits u8.
            const info = self.tupleElemInfo(elems, @intCast(i));
            const elem_dest = dest.at(@intCast(info.offset));
            // An aggregate element is laid out inline at its offset
            // (recursing like a nested struct field); a scalar element
            // stores its value/pointer word.
            switch (self.tupleElemAggregate(elems, @intCast(i))) {
                .structure => |sub| try emitIntoDest(self, elem, sub, elem_dest),
                .tuple => |nested| try emitTupleIntoDest(self, elem, nested, elem_dest),
                .scalar => {
                    try self.emitExpr(elem);
                    try isa.movRegToReg(self, Reg.acu, Reg.r2);
                    try destAddrToReg(self, elem_dest, Reg.r1);
                    try storeWidth(self, Reg.r1, info.width, Reg.r2);
                },
            }
        }
        return;
    }
    // A tuple value — byte-copy its contiguous slots into the dest.
    try self.emitExpr(src); // acu = source base address
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try destAddrToReg(self, dest, Reg.r2);
    try copyBytes(self, Reg.r1, Reg.r2, self.tupleWidth(elems));
}

/// Load element `index` of the tuple whose base address is in `acu`,
/// leaving the element value in `acu` (`i8` sign-extends).
pub fn emitTupleElemLoad(self: *Emitter, elems: []const *const types.Type, index: u8) error{OutOfMemory}!void {
    const info = self.tupleElemInfo(elems, index);
    // An aggregate element sits inline — leave its base address in `acu`
    // (a struct / tuple value *is* an address), no deref.
    if (self.tupleElemAggregate(elems, index) != .scalar) {
        if (info.offset != 0) try isa.addImmToReg(self, info.offset, Reg.acu);
        return;
    }
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    if (info.width == 1) {
        try class.emitByteLoadAtOffset(self, Reg.r1, info.offset, Reg.acu);
        if (info.signed_byte) try isa.signExtendByte(self, Reg.acu);
    } else {
        try class.emitWordLoadAtOffset(self, Reg.r1, info.offset, Reg.acu);
    }
}

// ---- array values (§3.4) ----
// `[T; N]` is a homogeneous positional aggregate, inline + contiguous;
// element `i` sits at offset `i * elem_width`. A scalar element stores
// its word/byte; an aggregate element (struct / tuple / nested array)
// lays out inline at its offset, recursing like a nested struct field.
// Element access is in `expr.zig` (load) / `statements.zig` (store).

/// Materialize an array value into the frame slot at `dest_ofs`: a list
/// literal `[a, b, c]` (materialize each element), a repeat `[v; N]`
/// (fill), or another array value (byte-copied for value semantics).
pub fn emitArrayInto(self: *Emitter, src: *const ast.Expr, elem: *const types.Type, count: u32, dest_ofs: i16) error{OutOfMemory}!void {
    try emitArrayIntoDest(self, src, elem, count, .{ .frame = dest_ofs });
}

fn emitArrayIntoDest(self: *Emitter, src: *const ast.Expr, elem: *const types.Type, count: u32, dest: Dest) error{OutOfMemory}!void {
    if (src.* == .if_expr) return try emitIfChainIntoDest(self, src.if_expr, dest, ArrayShape{ .elem = elem, .count = count }, arrayTail);
    if (src.* == .do_expr) {
        const p = try do_expr.emitPrefix(self, src.do_expr);
        switch (p.tail) {
            .expr => |tail| try emitArrayIntoDest(self, tail, elem, count, dest),
            else => try self.unsupported(src.do_expr.span, "`do` value block must end in an expression"),
        }
        try do_expr.emitSuffix(self, p);
        return;
    }
    const ew = self.widthOfType(elem);
    if (src.* == .list_lit) {
        for (src.list_lit.elems, 0..) |e, i| {
            // @as: i*elem_width stays within the 127-byte frame slot.
            try emitElemInto(self, e, elem, dest.at(@intCast(i * ew)));
        }
        return;
    }
    if (src.* == .list_repeat) {
        try emitArrayRepeat(self, src.list_repeat, elem, count, dest);
        return;
    }
    // Another array value — byte-copy its contiguous slots in.
    try self.emitExpr(src); // acu = source base
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try destAddrToReg(self, dest, Reg.r2);
    // @as: total array width ≤ the frame cap.
    try copyBytes(self, Reg.r1, Reg.r2, @intCast(@as(u32, ew) * count));
}

/// Materialize one array element (of element type `elem`) into `dest`.
/// A scalar stores its word/byte; an aggregate recurses into the matching
/// struct / tuple / nested-array layout at the destination.
fn emitElemInto(self: *Emitter, e: *const ast.Expr, elem: *const types.Type, dest: Dest) error{OutOfMemory}!void {
    switch (self.arrayElemKindOf(elem)) {
        .structure => |sname| try emitIntoDest(self, e, sname, dest),
        .tuple => |elems| try emitTupleIntoDest(self, e, elems, dest),
        .array => |sub| try emitArrayIntoDest(self, e, sub.elem, sub.len, dest),
        .scalar => {
            try self.emitExpr(e);
            try isa.movRegToReg(self, Reg.acu, Reg.r2);
            try destAddrToReg(self, dest, Reg.r1);
            try storeWidth(self, Reg.r1, self.widthOfType(elem), Reg.r2);
        },
    }
}

fn emitArrayRepeat(self: *Emitter, lr: ast.ListRepeatLit, elem: *const types.Type, count: u32, dest: Dest) error{OutOfMemory}!void {
    const ew = self.widthOfType(elem);
    switch (self.arrayElemKindOf(elem)) {
        .scalar => {
            // @as: total array width ≤ the frame cap.
            const total: u16 = @intCast(@as(u32, ew) * count);
            // Zero-fill (the common buffer init) collapses to one `bfill`.
            if (lr.value.* == .int_lit and lr.value.int_lit.value == 0) {
                try destAddrToReg(self, dest, Reg.r1);
                try isa.movImmToReg(self, total, Reg.r2);
                try isa.movImmToReg(self, 0, Reg.r3);
                try self.emitByte(Op.bfill);
                try self.emitByte(Reg.r1); // dst
                try self.emitByte(Reg.r2); // len
                try self.emitByte(Reg.r3); // val
                return;
            }
            // Otherwise evaluate the value once and replicate the register.
            try self.emitExpr(lr.value);
            try isa.movRegToReg(self, Reg.acu, Reg.r3); // r3 = value (preserved)
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                // @as: i*elem_width ≤ the frame cap.
                try destAddrToReg(self, dest.at(@intCast(i * ew)), Reg.r1);
                try storeWidth(self, Reg.r1, ew, Reg.r3);
            }
        },
        // An aggregate value is constructed once into slot 0, then its
        // bytes are copied into each remaining slot (single eval, value
        // semantics — matches `let b = a` aggregate copy).
        else => {
            if (count == 0) return;
            try emitElemInto(self, lr.value, elem, dest.at(0));
            var i: u32 = 1;
            while (i < count) : (i += 1) {
                try destAddrToReg(self, dest.at(0), Reg.r1); // src = slot 0
                // @as: i*elem_width ≤ the frame cap.
                try destAddrToReg(self, dest.at(@intCast(i * ew)), Reg.r2); // dst = slot i
                try copyBytes(self, Reg.r1, Reg.r2, ew);
            }
        },
    }
}

/// Scale index register `reg` by `elem_width` so it becomes a byte offset
/// into the array. Power-of-two widths shift in place; others multiply
/// (which clobbers `r1` / `r3` and acu's high half — `reg` must be none
/// of `r1` / `r3`; every call site passes `acu`).
pub fn scaleIndex(self: *Emitter, reg: u8, elem_width: u16) error{OutOfMemory}!void {
    switch (elem_width) {
        0, 1 => {},
        2 => try isa.shlRegImm(self, reg, 1),
        4 => try isa.shlRegImm(self, reg, 2),
        8 => try isa.shlRegImm(self, reg, 3),
        else => {
            // `mul dst, src` writes the product's low half to dst and the
            // high half to acu — so multiply through r1 (never acu) and copy
            // the low half back, leaving the scaled index in reg. Clobbers
            // r1 / r3 / acu-high (all dead at every call site).
            try isa.movRegToReg(self, reg, Reg.r1); // r1 = index
            try isa.movImmToReg(self, elem_width, Reg.r3); // r3 = elem_width
            try isa.mulRegReg(self, Reg.r3, Reg.r1); // r1 = index*elem_width (low half)
            try isa.movRegToReg(self, Reg.r1, reg); // reg = scaled index
        },
    }
}

/// Leave the runtime element address (`base + index * elem_width`) of
/// `ix` in `acu`. Bounds-trapped in debug. Self-balancing on the stack
/// (parks `base` internally), so a caller may keep other values parked
/// below. Clobbers `r1` (base) and `r3` (scale scratch).
pub fn emitIndexAddr(self: *Emitter, ix: ast.IndexExpr, info: codegen.Emitter.ArrayInfo) error{OutOfMemory}!void {
    try self.emitExpr(ix.receiver); // acu = base
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(ix.index); // acu = index
    // @as: array length fits u16.
    try overflow.emitBoundsTrap(self, Reg.acu, @intCast(info.count));
    try scaleIndex(self, Reg.acu, info.elem_width);
    try isa.popReg(self, Reg.r1); // r1 = base
    try isa.addRegToAcu(self, Reg.r1); // acu = base + index*elem_width
}

/// Store an aggregate `rhs` into the destination whose base address is in
/// `addr_reg` (an array element of element type `elem`). The pointer is
/// parked on the stack so a struct / tuple / nested-array literal
/// materializes directly into the slot — and any other aggregate value is
/// byte-copied — without a temporary binding. `elem` must be aggregate
/// (scalar element stores take the word/byte path).
pub fn emitAggregateStoreInto(self: *Emitter, rhs: *const ast.Expr, elem: *const types.Type, addr_reg: u8) error{OutOfMemory}!void {
    try isa.pushReg(self, addr_reg); // [sp + 0] = destination pointer
    const dest = Dest{ .indirect_sp = .{ .sp_ofs = 0, .delta = 0 } };
    switch (self.arrayElemKindOf(elem)) {
        .structure => |sname| try emitIntoDest(self, rhs, sname, dest),
        .tuple => |elems| try emitTupleIntoDest(self, rhs, elems, dest),
        .array => |sub| try emitArrayIntoDest(self, rhs, sub.elem, sub.len, dest),
        // A scalar element never reaches this aggregate store path.
        .scalar => unreachable,
    }
    try isa.addImmToReg(self, 2, Reg.sp); // drop the parked pointer
}

fn emitLitInto(self: *Emitter, sl: ast.StructLit, sname: []const u8, dest: Dest) error{OutOfMemory}!void {
    const sd = self.struct_decls.get(sname).?;
    for (sd.fields) |df| {
        const fname = self.source[df.name.start..df.name.end];
        const info = self.structFieldInfo(sname, fname).?;
        const value = litFieldValue(self, sl, fname) orelse continue;
        // The field sits inline at this fixed offset within the region.
        const field_dest = dest.at(@intCast(info.offset));
        if (info.struct_name) |sub| {
            try emitIntoDest(self, value, sub, field_dest);
        } else if (info.is_tuple) {
            // A tuple field lays out inline; its element types come from
            // the value expression's inferred type.
            const elems = self.tupleElemsOf(value) orelse {
                try self.unsupported(value.span(), "tuple struct field initialized from a non-tuple value");
                continue;
            };
            try emitTupleIntoDest(self, value, elems, field_dest);
        } else {
            try self.emitExpr(value);
            try isa.movRegToReg(self, Reg.acu, Reg.r2);
            try destAddrToReg(self, field_dest, Reg.r1);
            try storeWidth(self, Reg.r1, info.width, Reg.r2);
        }
    }
}

/// Load field `field_name` of struct `sname` given the receiver's base
/// address in `acu`. A scalar field is loaded into `acu`; a nested
/// struct field leaves its address in `acu` (a struct value *is* an
/// address).
pub fn emitFieldLoad(self: *Emitter, sname: []const u8, field_name: []const u8) !void {
    const info = self.structFieldInfo(sname, field_name).?;
    // An aggregate field (nested struct or tuple) is addressed inline.
    if (info.struct_name != null or info.is_tuple) {
        if (info.offset != 0) try isa.addImmToReg(self, info.offset, Reg.acu);
        return;
    }
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    if (info.width == 1) {
        try class.emitByteLoadAtOffset(self, Reg.r1, info.offset, Reg.acu);
        // A signed byte field (`i8`) sign-extends; `u8` / `bool` / `char`
        // stay zero-extended.
        if (info.signed_byte) try isa.signExtendByte(self, Reg.acu);
    } else {
        try class.emitWordLoadAtOffset(self, Reg.r1, info.offset, Reg.acu);
    }
}

/// Store `value` into field `field_name` of the struct addressed by
/// `recv`. An aggregate field (nested struct / tuple) materializes the
/// value directly into the field slot through a stack-parked pointer — a
/// literal lands in place, any other aggregate value is byte-copied — so
/// no temporary binding is needed.
pub fn emitFieldStore(self: *Emitter, recv: *const ast.Expr, sname: []const u8, field_name: []const u8, value: *const ast.Expr) !void {
    const info = self.structFieldInfo(sname, field_name).?;
    if (info.struct_name != null or info.is_tuple) {
        // Compute the field's address and park it, then materialize the
        // value through it — `sp` stays put across the value's fields.
        try self.emitExpr(recv); // acu = receiver base
        if (info.offset != 0) try isa.addImmToReg(self, info.offset, Reg.acu);
        try isa.pushReg(self, Reg.acu); // [sp + 0] = field pointer
        const dest = Dest{ .indirect_sp = .{ .sp_ofs = 0, .delta = 0 } };
        if (info.struct_name) |sub| {
            try emitIntoDest(self, value, sub, dest);
        } else if (self.tupleElemsOf(value)) |elems| {
            try emitTupleIntoDest(self, value, elems, dest);
        } else {
            try self.unsupported(value.span(), "tuple field assigned from a non-tuple value");
        }
        try isa.addImmToReg(self, 2, Reg.sp); // drop the parked pointer
        return;
    }
    // Scalar field — evaluate the value, then store it as a word/byte.
    try self.emitExpr(value);
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(recv);
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try isa.popReg(self, Reg.r2);
    try class_storeAt(self, Reg.r1, info.offset, info.width, Reg.r2);
}

/// Compare two struct operands of type `sname` for structural equality,
/// leaving `1` / `0` in `acu` (`negate` selects `!=`). Field-wise when a
/// field needs it (`str` by content, payload-enum by slot, nested struct
/// recursively), else a flat byte compare.
pub fn emitEquality(self: *Emitter, lhs: *const ast.Expr, rhs: *const ast.Expr, sname: []const u8, negate: bool) error{OutOfMemory}!void {
    // Materialize BOTH operands as distinct by-value copies on the
    // stack. Pushing addresses would alias when both operands share a
    // buffer (e.g. two struct-returning calls reuse the sret scratch);
    // copying also lets struct-literal operands (`p == P{ ... }`) work.
    // The copies stay put (sp stable) so field addresses are `sp + ofs`.
    const wslot = self.structSlotWidth(sname);
    try pushArg(self, rhs, sname); // rhs copy at [sp + wslot ..] after the next push
    try pushArg(self, lhs, sname); // lhs copy at [sp ..]; sp stays put

    if (needsFieldwise(self, sname)) {
        // Per-field dispatch — `str` by content, payload-enum by its
        // dereferenced slot, nested structs recursively. The first
        // mismatch jumps to the not-equal arm; falling through is equal.
        var mismatch_patches: std.ArrayList(usize) = .empty;
        defer mismatch_patches.deinit(self.allocator);
        try emitFieldwiseEq(self, sname, 0, wslot, &mismatch_patches);
        try isa.movImmToReg(self, if (negate) 0 else 1, Reg.acu);
        const end_patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
        const mismatch_target = try self.currentOffset();
        for (mismatch_patches.items) |p| try isa.patchJumpTo(self, p, mismatch_target);
        try isa.movImmToReg(self, if (negate) 1 else 0, Reg.acu);
        try isa.patchJumpTo(self, end_patch, try self.currentOffset());
    } else {
        // Every field is value/pointer-comparable — one byte compare
        // over the packed width.
        try isa.movRegToReg(self, Reg.sp, Reg.r1); // lhs copy base
        try isa.movRegToReg(self, Reg.sp, Reg.r2);
        try isa.addImmToReg(self, wslot, Reg.r2); // rhs copy base
        try emitBytesEqual(self, Reg.r1, Reg.r2, self.structWidth(sname), negate);
    }

    // Drop both stack copies. `acu` (the result) survives the sp bump.
    try isa.addImmToReg(self, 2 * wslot, Reg.sp);
}

/// Compare `width` bytes of two stack slots, appending a mismatch jump
/// per word so the caller's not-equal arm collects them. Mirrors the
/// scalar cases in `emitFieldwiseEq`, for fields wider than a register.
fn emitSlotBytesEq(
    self: *Emitter,
    lhs_off: u16,
    rhs_off: u16,
    width: u16,
    patches: *std.ArrayList(usize),
) error{OutOfMemory}!void {
    var off: u16 = 0;
    while (width - off >= 2) : (off += 2) {
        try class.emitWordLoadAtOffset(self, Reg.sp, lhs_off + off, Reg.acu);
        try class.emitWordLoadAtOffset(self, Reg.sp, rhs_off + off, Reg.r3);
        try isa.cmpRegReg(self, Reg.acu, Reg.r3);
        try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
    }
    if (off < width) {
        try class.emitByteLoadAtOffset(self, Reg.sp, lhs_off + off, Reg.acu);
        try class.emitByteLoadAtOffset(self, Reg.sp, rhs_off + off, Reg.r3);
        try isa.cmpRegReg(self, Reg.acu, Reg.r3);
        try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
    }
}

/// Compare `width` bytes at `[p1]` vs `[p2]` (both pointers, advanced as
/// it walks), leaving `1`/`0` in `acu` (`negate` selects `!=`). Word
/// strides + a trailing byte; `acu` and `r3` are scratch — neither may
/// be passed as `p1`/`p2`. Used for the all-scalar struct byte path.
pub fn emitBytesEqual(self: *Emitter, p1: u8, p2: u8, width: u16, negate: bool) error{OutOfMemory}!void {
    var mismatch_patches: std.ArrayList(usize) = .empty;
    defer mismatch_patches.deinit(self.allocator);
    var remaining = width;
    while (remaining >= 2) : (remaining -= 2) {
        try isa.movRegOffsetToReg(self, p1, 0, Reg.acu);
        try isa.movRegOffsetToReg(self, p2, 0, Reg.r3);
        try isa.cmpRegReg(self, Reg.acu, Reg.r3);
        try mismatch_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        try isa.addImmToReg(self, 2, p1);
        try isa.addImmToReg(self, 2, p2);
    }
    if (remaining == 1) {
        try class.emitByteLoadAtOffset(self, p1, 0, Reg.acu);
        try class.emitByteLoadAtOffset(self, p2, 0, Reg.r3);
        try isa.cmpRegReg(self, Reg.acu, Reg.r3);
        try mismatch_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
    }
    try isa.movImmToReg(self, if (negate) 0 else 1, Reg.acu);
    const end_patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    const mismatch_target = try self.currentOffset();
    for (mismatch_patches.items) |p| try isa.patchJumpTo(self, p, mismatch_target);
    try isa.movImmToReg(self, if (negate) 1 else 0, Reg.acu);
    try isa.patchJumpTo(self, end_patch, try self.currentOffset());
}

// ---- payload-carrying enum equality ----

/// Lower equality of two payload-carrying enum values (`p1` / `p2` hold
/// the `[tag | payload]` slot pointers), leaving `1`/`0` in `acu`
/// (`negate` selects `!=`). Compares the tag, then — for the matching
/// variant — each payload field by its own semantics: `str` by content
/// (§3.2.1), a nested payload enum recursively, every other field by its
/// stored word/byte (value, or pointer identity for `&T` / class). The
/// slot pointers are parked on the stack and reloaded per field, since
/// content compare + recursion churn registers. Caller must have checked
/// `enumEqSupported` (which rejects recursive enums, so this terminates).
pub fn emitEnumEqual(self: *Emitter, ed: *const ast.EnumDecl, p1: u8, p2: u8, negate: bool) error{OutOfMemory}!void {
    try isa.pushReg(self, p1); // lhs slot ptr at [sp + 2]
    try isa.pushReg(self, p2); // rhs slot ptr at [sp + 0]
    const lhs_at: i8 = 2;
    const rhs_at: i8 = 0;

    var ne_patches: std.ArrayList(usize) = .empty; // → not-equal arm
    defer ne_patches.deinit(self.allocator);
    var eq_patches: std.ArrayList(usize) = .empty; // → equal arm
    defer eq_patches.deinit(self.allocator);

    // A differing tag is unequal outright.
    try loadSlotTag(self, lhs_at, Reg.acu);
    try loadSlotTag(self, rhs_at, Reg.r3);
    try isa.cmpRegReg(self, Reg.acu, Reg.r3);
    try ne_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));

    // Tags match: dispatch on the tag and compare that variant's payload.
    // A nullary variant carries no payload, so a tag match already
    // settles it — those fall through to the equal arm.
    for (ed.variants, 0..) |v, ti| {
        if (v.payload.len == 0) continue;
        // @as: variant index fits the u8 tag (§3.6).
        const tag: u16 = @intCast(ti);
        try loadSlotTag(self, lhs_at, Reg.acu);
        try isa.cmpRegImm(self, Reg.acu, tag);
        const skip = try isa.emitJumpPlaceholder(self, Op.jne_addr);
        for (v.payload, 0..) |pf, j| {
            try emitEnumFieldEq(self, pf.type_ann.*, lhs_at, rhs_at, self.variantFieldOffset(v, j), &ne_patches);
        }
        try eq_patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jmp_addr));
        try isa.patchJumpTo(self, skip, try self.currentOffset());
    }

    const eq_target = try self.currentOffset();
    for (eq_patches.items) |p| try isa.patchJumpTo(self, p, eq_target);
    try isa.movImmToReg(self, if (negate) 0 else 1, Reg.acu);
    const end_patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    const ne_target = try self.currentOffset();
    for (ne_patches.items) |p| try isa.patchJumpTo(self, p, ne_target);
    try isa.movImmToReg(self, if (negate) 1 else 0, Reg.acu);
    try isa.patchJumpTo(self, end_patch, try self.currentOffset());

    try isa.addImmToReg(self, 4, Reg.sp); // drop both parked pointers
}

/// Reload the slot pointer parked at `[sp + sp_off]` and load its tag
/// byte (offset 0) into `dst`.
fn loadSlotTag(self: *Emitter, sp_off: i8, dst: u8) error{OutOfMemory}!void {
    try isa.movRegOffsetToReg(self, Reg.sp, sp_off, dst);
    try class.emitByteLoadAtOffset(self, dst, 0, dst);
}

/// Compare one payload field (at `field_off` within the slot) of the two
/// enum values whose slot pointers are parked at `[sp + lhs_at]` /
/// `[sp + rhs_at]`. A mismatch jumps to the not-equal arm via `patches`.
fn emitEnumFieldEq(self: *Emitter, t: ast.TypeAnn, lhs_at: i8, rhs_at: i8, field_off: u16, patches: *std.ArrayList(usize)) error{OutOfMemory}!void {
    if (isStrTypeAnn(self, t)) {
        try loadSlotField(self, lhs_at, field_off, Reg.r1); // lhs str ptr
        try loadSlotField(self, rhs_at, field_off, Reg.r2); // rhs str ptr
        try strings.emitContentEq(self, Reg.r1, Reg.r2, false);
        try isa.cmpRegImm(self, Reg.acu, 0); // acu == 0 → strings differ
        try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
        return;
    }
    if (payloadEnumDecl(self, t)) |inner| {
        try loadSlotField(self, lhs_at, field_off, Reg.r1); // lhs inner slot ptr
        try loadSlotField(self, rhs_at, field_off, Reg.r2); // rhs inner slot ptr
        try emitEnumEqual(self, inner, Reg.r1, Reg.r2, false);
        try isa.cmpRegImm(self, Reg.acu, 0); // acu == 0 → slots differ
        try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
        return;
    }
    // Scalar / `char` / `fixed` / `bool` / payload-free enum tag / `&T` /
    // class — compare the stored word or byte (value or pointer identity).
    const fw = self.widthOfTypeAnn(t);
    try isa.movRegOffsetToReg(self, Reg.sp, lhs_at, Reg.r1);
    if (fw == 1) try class.emitByteLoadAtOffset(self, Reg.r1, field_off, Reg.acu) else try class.emitWordLoadAtOffset(self, Reg.r1, field_off, Reg.acu);
    try isa.movRegOffsetToReg(self, Reg.sp, rhs_at, Reg.r1);
    if (fw == 1) try class.emitByteLoadAtOffset(self, Reg.r1, field_off, Reg.r3) else try class.emitWordLoadAtOffset(self, Reg.r1, field_off, Reg.r3);
    try isa.cmpRegReg(self, Reg.acu, Reg.r3);
    try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
}

/// Reload the slot pointer parked at `[sp + sp_off]` and load the word at
/// `field_off` within it into `dst`.
fn loadSlotField(self: *Emitter, sp_off: i8, field_off: u16, dst: u8) error{OutOfMemory}!void {
    try isa.movRegOffsetToReg(self, Reg.sp, sp_off, dst);
    try class.emitWordLoadAtOffset(self, dst, field_off, dst);
}

/// Whether `==` can be lowered for payload-carrying enum `ed`. Every
/// payload field must be comparable — a scalar / `char` / `fixed` /
/// `bool` / `str` / `&T` / class, or a nested payload enum. Rejected:
/// a struct payload (not a valid slot value) and a recursive enum
/// (`visited` breaks the cycle — structural compare would unroll without
/// bound), plus array / tuple / `Vec` / nullable payloads.
pub fn enumEqSupported(self: *const Emitter, ed: *const ast.EnumDecl) bool {
    var visited: std.ArrayList([]const u8) = .empty;
    defer visited.deinit(self.allocator);
    return enumEqSupportedRec(self, ed, &visited) catch false;
}

fn enumEqSupportedRec(self: *const Emitter, ed: *const ast.EnumDecl, visited: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
    const name = self.source[ed.name.start..ed.name.end];
    for (visited.items) |seen| if (std.mem.eql(u8, seen, name)) return false; // cycle
    try visited.append(self.allocator, name);
    defer _ = visited.pop();
    for (ed.variants) |v| {
        for (v.payload) |pf| {
            if (!try enumFieldEqSupported(self, pf.type_ann.*, visited)) return false;
        }
    }
    return true;
}

fn enumFieldEqSupported(self: *const Emitter, t: ast.TypeAnn, visited: *std.ArrayList([]const u8)) error{OutOfMemory}!bool {
    switch (t) {
        .named => |n| {
            const name = self.source[n.name.start..n.name.end];
            if (self.struct_decls.contains(name)) return false; // not a valid enum-payload slot value
            if (self.enum_decls.get(name)) |inner| {
                if (!self.enumHasPayload(inner)) return true; // bare tag byte
                return enumEqSupportedRec(self, inner, visited);
            }
            return true; // primitive (incl. `str`) or class — value / content / identity
        },
        .reference, .fn_type => return true, // pointer identity
        .nullable, .array, .vec, .tuple => return false,
    }
}

/// Per-field comparison for structs that need it (a `str` or payload-
/// enum field). The lhs copy is at `[sp + lhs_off ..]` and the rhs at
/// `[sp + rhs_off ..]`; `sp` is stable, so each field reads at
/// `sp + base_off + field_off`. `str` compares by content, a payload
/// enum by its dereferenced slot, nested structs recurse, and every
/// other field by its stored word/byte (value or pointer identity).
fn emitFieldwiseEq(self: *Emitter, sname: []const u8, lhs_off: u16, rhs_off: u16, patches: *std.ArrayList(usize)) error{OutOfMemory}!void {
    const sd = self.struct_decls.get(sname).?;
    var fo: u16 = 0;
    for (sd.fields) |f| {
        const fw = self.widthOfTypeAnn(f.type_ann.*);
        if (isStrTypeAnn(self, f.type_ann.*)) {
            // Content compare (§3.2.1): load both pointers, then streq.
            // `sp` survives streq's register churn, so the next field
            // re-addresses from it cleanly. (Checked before the nested-
            // struct case so the `str` classification matches `eqSupported`
            // / `needsFieldwise`.)
            try class.emitWordLoadAtOffset(self, Reg.sp, lhs_off + fo, Reg.r1);
            try class.emitWordLoadAtOffset(self, Reg.sp, rhs_off + fo, Reg.r2);
            try strings.emitContentEq(self, Reg.r1, Reg.r2, false);
            try isa.cmpRegImm(self, Reg.acu, 0); // acu == 0 → strings differ
            try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
        } else if (payloadEnumDecl(self, f.type_ann.*)) |ed| {
            // Payload-carrying enum field stores a slot pointer; compare
            // the two slots by value (tag, then per-variant payload).
            try class.emitWordLoadAtOffset(self, Reg.sp, lhs_off + fo, Reg.r1);
            try class.emitWordLoadAtOffset(self, Reg.sp, rhs_off + fo, Reg.r2);
            try emitEnumEqual(self, ed, Reg.r1, Reg.r2, false);
            try isa.cmpRegImm(self, Reg.acu, 0); // acu == 0 → slots differ
            try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
        } else if (self.structNameOfTypeAnn(f.type_ann.*)) |sub| {
            try emitFieldwiseEq(self, sub, lhs_off + fo, rhs_off + fo, patches);
        } else if (fw == 1) {
            try class.emitByteLoadAtOffset(self, Reg.sp, lhs_off + fo, Reg.acu);
            try class.emitByteLoadAtOffset(self, Reg.sp, rhs_off + fo, Reg.r3);
            try isa.cmpRegReg(self, Reg.acu, Reg.r3);
            try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        } else if (fw > 2) {
            // An array or tuple field is wider than a register; walk its
            // packed bytes rather than comparing only the first word.
            try emitSlotBytesEq(self, lhs_off + fo, rhs_off + fo, fw, patches);
        } else {
            try class.emitWordLoadAtOffset(self, Reg.sp, lhs_off + fo, Reg.acu);
            try class.emitWordLoadAtOffset(self, Reg.sp, rhs_off + fo, Reg.r3);
            try isa.cmpRegReg(self, Reg.acu, Reg.r3);
            try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        }
        fo += fw;
    }
}

/// `true` when `sname` has a field that can't be compared by a flat
/// byte sweep — a `str` (content) or a payload-carrying enum (deref the
/// slot pointer), directly or via a nested struct — forcing the
/// per-field path.
fn needsFieldwise(self: *const Emitter, sname: []const u8) bool {
    const sd = self.struct_decls.get(sname) orelse return false;
    for (sd.fields) |f| {
        if (isStrTypeAnn(self, f.type_ann.*)) return true;
        if (payloadEnumDecl(self, f.type_ann.*) != null) return true;
        if (self.structNameOfTypeAnn(f.type_ann.*)) |sub| {
            if (needsFieldwise(self, sub)) return true;
        }
    }
    return false;
}

fn isStrTypeAnn(self: *const Emitter, t: ast.TypeAnn) bool {
    return t == .named and std.mem.eql(u8, self.source[t.named.name.start..t.named.name.end], "str");
}

/// The enum declaration for a payload-carrying enum type annotation,
/// else `null`. Payload-free enums (a bare tag) compare like any scalar.
fn payloadEnumDecl(self: *const Emitter, t: ast.TypeAnn) ?*const ast.EnumDecl {
    if (t != .named) return null;
    const ed = self.enum_decls.get(self.source[t.named.name.start..t.named.name.end]) orelse return null;
    return if (self.enumHasPayload(ed)) ed else null;
}

/// Whether `==` can be lowered for struct `sname`. Supported field
/// types compare by value (scalars / bool / char / fixed), pointer
/// identity (class / `&T` / fn-ptr — correct per §3.4.2 / §3.4.4),
/// content (`str`, §3.2.1), enum (tag, or `[tag|payload]` slot), or
/// recursively (nested struct). Rejected: array / tuple / `Vec`
/// (element-wise equality not lowered yet) and nullable — those surface
/// a clean diagnostic rather than a silently-wrong compare.
pub fn eqSupported(self: *const Emitter, sname: []const u8) bool {
    const sd = self.struct_decls.get(sname) orelse return false;
    for (sd.fields) |f| {
        if (!fieldEqSupported(self, f.type_ann.*)) return false;
    }
    return true;
}

/// Whether a value of this type compares correctly as raw bytes —
/// false for anything needing content or slot comparison (`str`,
/// payload-carrying enums, nullables, `Vec`) or holding one.
fn bytewiseTypeAnn(self: *const Emitter, t: ast.TypeAnn) bool {
    switch (t) {
        .named => |n| {
            if (isStrTypeAnn(self, t)) return false;
            const name = self.source[n.name.start..n.name.end];
            if (self.struct_decls.contains(name)) {
                return eqSupported(self, name) and !needsFieldwise(self, name);
            }
            if (self.enum_decls.get(name)) |ed| return !self.enumHasPayload(ed);
            return true;
        },
        .reference, .fn_type => return true,
        .array => |a| return bytewiseTypeAnn(self, a.elem.*),
        .tuple => |tp| {
            for (tp.elems) |e| {
                if (!bytewiseTypeAnn(self, e.*)) return false;
            }
            return true;
        },
        .nullable, .vec => return false,
    }
}

fn fieldEqSupported(self: *const Emitter, t: ast.TypeAnn) bool {
    switch (t) {
        .named => |n| {
            const name = self.source[n.name.start..n.name.end];
            if (self.struct_decls.contains(name)) return eqSupported(self, name);
            if (self.enum_decls.get(name)) |ed| {
                // Payload-free enums compare by tag; payload-carrying ones
                // by slot value — which `enumEqSupported` gates (rejecting
                // recursive / struct-payload enums).
                return !self.enumHasPayload(ed) or enumEqSupported(self, ed);
            }
            // Primitive (incl. `str`) or class — value / content /
            // pointer-identity compare, all handled.
            return true;
        },
        .reference, .fn_type => return true, // pointer identity
        // A tuple field compares as its packed bytes, so it is supported
        // exactly when every component is byte-comparable. An array
        // field is not: a struct holding one does not copy its bytes
        // through `emitIntoDest`, so a byte compare would read nothing
        // and answer "equal" — see the struct-with-array-field gap.
        .tuple => |tp| {
            for (tp.elems) |e| {
                if (!bytewiseTypeAnn(self, e.*)) return false;
            }
            return true;
        },
        .array, .nullable, .vec => return false,
    }
}

// ---- tuple equality — mirrors the struct path over the element type
// list; a struct element reuses `emitFieldwiseEq` / `needsFieldwise`. ----

/// Lower `a == b` / `a != b` on tuple operands, leaving `0`/`1` in `acu`
/// (`negate` selects `!=`). Materializes both operands as distinct stack
/// copies (literals + value-aliasing safe), then an all-scalar tuple
/// byte-compares; one with a `str` / payload-enum / aggregate element
/// dispatches per element so those compare by content / value.
pub fn emitTupleEquality(self: *Emitter, lhs: *const ast.Expr, rhs: *const ast.Expr, elems: []const *const types.Type, negate: bool) error{OutOfMemory}!void {
    const wslot = self.tupleSlotWidth(elems);
    try pushTupleArg(self, rhs, elems); // rhs copy at [sp + wslot ..] after the next push
    try pushTupleArg(self, lhs, elems); // lhs copy at [sp ..]

    if (needsFieldwiseTuple(self, elems)) {
        var mismatch_patches: std.ArrayList(usize) = .empty;
        defer mismatch_patches.deinit(self.allocator);
        try emitTupleFieldwiseEq(self, elems, 0, wslot, &mismatch_patches);
        try isa.movImmToReg(self, if (negate) 0 else 1, Reg.acu);
        const end_patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
        const mismatch_target = try self.currentOffset();
        for (mismatch_patches.items) |p| try isa.patchJumpTo(self, p, mismatch_target);
        try isa.movImmToReg(self, if (negate) 1 else 0, Reg.acu);
        try isa.patchJumpTo(self, end_patch, try self.currentOffset());
    } else {
        try isa.movRegToReg(self, Reg.sp, Reg.r1); // lhs copy base
        try isa.movRegToReg(self, Reg.sp, Reg.r2);
        try isa.addImmToReg(self, wslot, Reg.r2); // rhs copy base
        try emitBytesEqual(self, Reg.r1, Reg.r2, self.tupleWidth(elems), negate);
    }

    try isa.addImmToReg(self, 2 * wslot, Reg.sp); // drop both copies
}

/// Per-element compare for a tuple that needs it. The lhs copy is at
/// `[sp + lhs_off ..]`, rhs at `[sp + rhs_off ..]`; `sp` is stable. A
/// struct element reuses the struct field-wise path at the element's
/// offset; a nested tuple recurses; `str` / payload-enum compare by
/// content / value; every other element by its stored word/byte.
fn emitTupleFieldwiseEq(self: *Emitter, elems: []const *const types.Type, lhs_off: u16, rhs_off: u16, patches: *std.ArrayList(usize)) error{OutOfMemory}!void {
    for (elems, 0..) |et, i| {
        // safety: tuple arity ≤ 4 (§3.4) fits u8.
        const eo = self.tupleElemInfo(elems, @intCast(i)).offset;
        switch (self.tupleElemAggregate(elems, @intCast(i))) {
            .structure => |sub| try emitFieldwiseEq(self, sub, lhs_off + eo, rhs_off + eo, patches),
            .tuple => |nested| try emitTupleFieldwiseEq(self, nested, lhs_off + eo, rhs_off + eo, patches),
            .scalar => {
                if (et.* == .primitive and et.primitive == .str) {
                    try class.emitWordLoadAtOffset(self, Reg.sp, lhs_off + eo, Reg.r1);
                    try class.emitWordLoadAtOffset(self, Reg.sp, rhs_off + eo, Reg.r2);
                    try strings.emitContentEq(self, Reg.r1, Reg.r2, false);
                    try isa.cmpRegImm(self, Reg.acu, 0); // acu == 0 → strings differ
                    try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
                } else if (payloadEnumDeclOfType(self, et)) |ed| {
                    try class.emitWordLoadAtOffset(self, Reg.sp, lhs_off + eo, Reg.r1);
                    try class.emitWordLoadAtOffset(self, Reg.sp, rhs_off + eo, Reg.r2);
                    try emitEnumEqual(self, ed, Reg.r1, Reg.r2, false);
                    try isa.cmpRegImm(self, Reg.acu, 0); // acu == 0 → slots differ
                    try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
                } else if (self.widthOfType(et) == 1) {
                    try class.emitByteLoadAtOffset(self, Reg.sp, lhs_off + eo, Reg.acu);
                    try class.emitByteLoadAtOffset(self, Reg.sp, rhs_off + eo, Reg.r3);
                    try isa.cmpRegReg(self, Reg.acu, Reg.r3);
                    try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
                } else {
                    try class.emitWordLoadAtOffset(self, Reg.sp, lhs_off + eo, Reg.acu);
                    try class.emitWordLoadAtOffset(self, Reg.sp, rhs_off + eo, Reg.r3);
                    try isa.cmpRegReg(self, Reg.acu, Reg.r3);
                    try patches.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
                }
            },
        }
    }
}

fn needsFieldwiseTuple(self: *const Emitter, elems: []const *const types.Type) bool {
    for (elems, 0..) |et, i| {
        switch (self.tupleElemAggregate(elems, @intCast(i))) {
            .structure => |sub| if (needsFieldwise(self, sub)) return true,
            .tuple => |nested| if (needsFieldwiseTuple(self, nested)) return true,
            .scalar => {
                if (et.* == .primitive and et.primitive == .str) return true;
                if (payloadEnumDeclOfType(self, et) != null) return true;
            },
        }
    }
    return false;
}

/// Whether `==` can be lowered for a tuple — every element comparable
/// (mirrors `eqSupported`): scalar / `str` / `char` / `fixed` by value or
/// content, class / `&T` by identity, enum by tag/slot, nested struct /
/// tuple recursively. Rejected: nullable / array / `Vec` elements.
/// Whether an array's elements compare correctly as raw bytes — the
/// array path compares the packed block, so an element needing content
/// or slot comparison (`str`, payload enum, nullable, `Vec`) is out.
pub fn arrayEqSupported(self: *const Emitter, elem: *const types.Type) bool {
    const one = [_]*const types.Type{elem};
    return tupleEqSupported(self, &one) and !needsFieldwiseTuple(self, &one);
}

/// Lower `a == b` / `a != b` on array operands, leaving `0`/`1` in
/// `acu` (`negate` selects `!=`).
///
/// Both operands are copied onto the stack before comparing. Pushing
/// their addresses would alias whenever the two share a buffer — two
/// array-returning calls reuse one sret scratch, so `mk(1) == mk(5)`
/// would compare the second result with itself.
/// Whether an operand returns its array through the call-return buffer.
/// Two such operands in one comparison currently collide — the second
/// call overwrites the first result before it is compared.
pub fn arrayEqOperandsCollide(lhs: *const ast.Expr, rhs: *const ast.Expr) bool {
    return returnsViaCallBuffer(lhs) and returnsViaCallBuffer(rhs);
}

fn returnsViaCallBuffer(e: *const ast.Expr) bool {
    return switch (e.*) {
        .call, .method_call => true,
        .paren => |pe| returnsViaCallBuffer(pe.inner),
        else => false,
    };
}

/// Lower `a == b` / `a != b` on array operands, leaving `0`/`1` in
/// `acu` (`negate` selects `!=`). Compares the packed elements, so the
/// caller must have cleared `arrayEqSupported` and
/// `arrayEqOperandsCollide` first.
pub fn emitArrayEquality(
    self: *Emitter,
    lhs: *const ast.Expr,
    rhs: *const ast.Expr,
    elem: *const types.Type,
    count: u32,
    negate: bool,
) error{OutOfMemory}!void {
    // @as: element count is bounded by the frame-capped array width.
    const width = self.widthOfType(elem) *% @as(u16, @intCast(count));
    // Word-align each copy so both bases stay word-addressable.
    const slot = width + (width & 1);

    // Materialize both operands as distinct stack copies, the way the
    // struct path does. Comparing their addresses instead would alias
    // whenever the two share a buffer — two array-returning calls reuse
    // one sret scratch, so `mk(1) == mk(5)` would compare the second
    // result against itself.
    // Both slots are reserved up front so `sp` does not move between
    // the two evaluations — an operand that is itself a call places its
    // return buffer relative to `sp`, and a shifting `sp` would let the
    // second call land on the first result.
    // safety: `slot` is the word-aligned array width, well inside i8 for
    // the frame sizes codegen accepts.
    try isa.subImmFromReg(self, 2 * slot, Reg.sp);
    try emitArrayIntoDest(self, rhs, elem, count, .{ .sp = @intCast(slot) });
    try emitArrayIntoDest(self, lhs, elem, count, .{ .sp = 0 });

    // lhs copy at [sp], rhs copy at [sp + slot].
    try isa.movRegToReg(self, Reg.sp, Reg.r1);
    try isa.movRegToReg(self, Reg.sp, Reg.r2);
    try isa.addImmToReg(self, slot, Reg.r2);
    try emitBytesEqual(self, Reg.r1, Reg.r2, width, negate);

    // Drop both copies; `acu` (the result) survives the sp bump.
    try isa.addImmToReg(self, 2 * slot, Reg.sp);
}

/// Whether every element of a tuple can take part in an equality
/// comparison — false for a nullable / array / `Vec` element.
pub fn tupleEqSupported(self: *const Emitter, elems: []const *const types.Type) bool {
    for (elems, 0..) |et, i| {
        switch (self.tupleElemAggregate(elems, @intCast(i))) {
            .structure => |sub| if (!eqSupported(self, sub)) return false,
            .tuple => |nested| if (!tupleEqSupported(self, nested)) return false,
            .scalar => switch (et.*) {
                .primitive, .reference, .function => {}, // value / content / pointer identity
                .named => |n| {
                    if (self.enum_decls.get(n.name)) |ed| {
                        if (self.enumHasPayload(ed) and !enumEqSupported(self, ed)) return false;
                    }
                    // primitive-by-name or class → handled (value / identity)
                },
                .optional, .array, .vec => return false,
                // allow-strict: a `.tuple` element is classified `.tuple`
                // by `tupleElemAggregate`, never reaching this scalar arm.
                .tuple => unreachable,
            },
        }
    }
    return true;
}

/// The enum decl for a payload-carrying enum *type*, else `null`.
fn payloadEnumDeclOfType(self: *const Emitter, et: *const types.Type) ?*const ast.EnumDecl {
    if (et.* != .named) return null;
    const ed = self.enum_decls.get(et.named.name) orelse return null;
    return if (self.enumHasPayload(ed)) ed else null;
}

/// Copy `width` bytes from `[src]` to `[dest]` — word strides with a
/// trailing byte. Advances both pointers (offset 0 each step) rather
/// than indexing, so the copy never collides with the at-offset
/// helpers' scratch registers and works for a struct of any size.
/// Consumes `src`/`dest` (callers don't reuse them afterward).
pub fn copyBytes(self: *Emitter, src: u8, dest: u8, width: u16) !void {
    var remaining = width;
    while (remaining >= 2) : (remaining -= 2) {
        try isa.movRegOffsetToReg(self, src, 0, Reg.acu);
        try isa.movRegToRegOffset(self, Reg.acu, dest, 0);
        try isa.addImmToReg(self, 2, src);
        try isa.addImmToReg(self, 2, dest);
    }
    if (remaining == 1) {
        try class.emitByteLoadAtOffset(self, src, 0, Reg.acu);
        try class.emitByteStoreAtOffset(self, dest, 0, Reg.acu);
    }
}

fn storeWidth(self: *Emitter, base: u8, width: u16, src: u8) !void {
    try class_storeAt(self, base, 0, width, src);
}

fn class_storeAt(self: *Emitter, base: u8, offset: u16, width: u16, src: u8) !void {
    if (width == 1) {
        try class.emitByteStoreAtOffset(self, base, offset, src);
    } else {
        try class.emitWordStoreAtOffset(self, base, offset, src);
    }
}

/// `reg = fp + ofs` — the address of a frame slot (`ofs` negative for
/// locals, positive for params).
fn frameAddrToReg(self: *Emitter, ofs: i16, reg: u8) !void {
    try isa.movRegToReg(self, Reg.fp, reg);
    if (ofs < 0) {
        try isa.subImmFromReg(self, @intCast(-ofs), reg);
    } else if (ofs > 0) {
        try isa.addImmToReg(self, @intCast(ofs), reg);
    }
}

fn litFieldValue(self: *Emitter, sl: ast.StructLit, field_name: []const u8) ?*const ast.Expr {
    for (sl.fields) |f| {
        if (std.mem.eql(u8, self.source[f.name.start..f.name.end], field_name)) return f.value;
    }
    return null;
}
