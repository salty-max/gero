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
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const class = @import("class.zig");
const strings = @import("strings.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

/// Where a materialized struct lands. `frame` is fp-relative (a local
/// or param slot — `ofs` negative for locals, positive for params).
/// `sp` is sp-relative (a freshly reserved stack region for an
/// outgoing argument — `ofs` ≥ 0 from the current `sp`). `indirect` is
/// the buffer pointed to by a frame slot holding an address (`ptr_ofs`)
/// plus a field `delta` — used to write a returned struct into the
/// caller's sret destination.
const Dest = union(enum) {
    frame: i16,
    sp: i16,
    indirect: struct { ptr_ofs: i16, delta: i16 },

    /// Shift the destination deeper by `delta` bytes (a nested field).
    fn at(self: Dest, delta: i16) Dest {
        return switch (self) {
            .frame => |o| .{ .frame = o + delta },
            .sp => |o| .{ .sp = o + delta },
            .indirect => |ind| .{ .indirect = .{ .ptr_ofs = ind.ptr_ofs, .delta = ind.delta + delta } },
        };
    }
};

/// `reg = base + ofs` for a destination. The `sp` form re-reads `sp`
/// and `indirect` re-loads its pointer slot — both valid because every
/// field-value expression restores `sp` and leaves the frame slot
/// untouched, so the destination base stays stable across fields.
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

fn emitIntoDest(self: *Emitter, src: *const ast.Expr, sname: []const u8, dest: Dest) error{OutOfMemory}!void {
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
// struct (contiguous, byte-packed slots). #305 lowers register-width
// elements (scalar / `str` / enum / class / reference); nested inline
// aggregates are rejected at the dispatch sites (deferred).

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

/// Materialize a returned tuple into the caller's sret buffer.
pub fn emitTupleIntoSret(self: *Emitter, src: *const ast.Expr, elems: []const *const types.Type, ptr_ofs: i16) error{OutOfMemory}!void {
    try emitTupleIntoDest(self, src, elems, .{ .indirect = .{ .ptr_ofs = ptr_ofs, .delta = 0 } });
}

fn emitTupleIntoDest(self: *Emitter, src: *const ast.Expr, elems: []const *const types.Type, dest: Dest) error{OutOfMemory}!void {
    if (self.tupleHasAggregateElem(elems)) {
        try self.unsupported(src.span(), "a tuple with a nested struct/tuple element");
        return;
    }
    if (src.* == .tuple_lit) {
        for (src.tuple_lit.elems, 0..) |elem, i| {
            // safety: tuple arity ≤ 4 (§3.4) fits u8.
            const info = self.tupleElemInfo(elems, @intCast(i));
            try self.emitExpr(elem);
            try isa.movRegToReg(self, Reg.acu, Reg.r2);
            try destAddrToReg(self, dest.at(@intCast(info.offset)), Reg.r1);
            try storeWidth(self, Reg.r1, info.width, Reg.r2);
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
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    if (info.width == 1) {
        try class.emitByteLoadAtOffset(self, Reg.r1, info.offset, Reg.acu);
        if (info.signed_byte) try isa.signExtendByte(self, Reg.acu);
    } else {
        try class.emitWordLoadAtOffset(self, Reg.r1, info.offset, Reg.acu);
    }
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
    if (info.struct_name != null) {
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
/// `recv`. A nested struct field copies the value's bytes.
pub fn emitFieldStore(self: *Emitter, recv: *const ast.Expr, sname: []const u8, field_name: []const u8, value: *const ast.Expr) !void {
    const info = self.structFieldInfo(sname, field_name).?;
    // Evaluate the value first and stash it on the stack — computing
    // the receiver's address reuses acu, so the value can't stay there.
    if (info.struct_name) |sub| {
        try self.emitExpr(value);
        try isa.pushReg(self, Reg.acu);
        try self.emitExpr(recv);
        if (info.offset != 0) try isa.addImmToReg(self, info.offset, Reg.acu);
        try isa.movRegToReg(self, Reg.acu, Reg.r2);
        try isa.popReg(self, Reg.r1);
        try copyBytes(self, Reg.r1, Reg.r2, self.structWidth(sub));
        return;
    }
    try self.emitExpr(value);
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(recv);
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try isa.popReg(self, Reg.r2);
    try class_storeAt(self, Reg.r1, info.offset, info.width, Reg.r2);
}

/// Lower `a == b` / `a != b` on struct operands (`negate` selects
/// `!=`), leaving a 0/1 boolean in `acu` per §3.4 "structurally equal
/// if fields equal". Each field compares with the same semantics its
/// own `==` would use: scalars / `&T` / class / payload-free enum by
/// value/pointer, `str` by content (§3.2.1), nested structs recursively.
/// A struct whose fields are all value/pointer-comparable reduces to a
/// fast byte compare over the packed width (no padding); a struct with
/// any `str` field uses per-field dispatch so those compare by content.
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
        .nullable, .array, .vec, .tuple => return false,
    }
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
