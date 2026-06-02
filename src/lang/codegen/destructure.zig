// Pattern destructuring (§4.2 / §4.4.1 / §4.5.2 / §4.8.1) — shared by
// `let` binds, `if let` / `while let`, and `match` arms. The scrutinee is
// materialized into a frame slot; the matcher walks the pattern against
// that slot, binding idents (an inline binder aliases the slot sub-region
// directly; an enum payload — behind the value's `[tag|payload]` pointer —
// loads into a fresh slot) and emitting tests for refutable shapes (each
// mismatch pushes a skip-jump patch the caller resolves to the else /
// loop-exit / next-arm).

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const class = @import("class.zig");
const value_struct = @import("value_struct.zig");
const vec_builtin = @import("vec_builtin.zig");
const pattern = @import("pattern.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Type = types.Type;

/// Materialize `expr` (type `ty`) into a fresh frame slot, returning its
/// fp-relative offset — the root the matcher destructures from. An inline
/// aggregate (tuple / struct / array) is copied whole so its bytes are
/// private + stable; a scalar / enum / class stores its word (value or
/// `[tag|payload]` slot pointer).
pub fn materializeScrutinee(self: *Emitter, expr: *const ast.Expr, ty: ?*const Type) error{OutOfMemory}!i8 {
    // An optional scrutinee (`if let n = v.pop()`) — materialize the
    // tagged / pointer optional into a slot, then the matcher unwraps it.
    if (ty != null and ty.?.* == .optional) {
        const slot = try self.allocLocalSized("\x00__scrut", self.widthOfType(ty.?));
        try vec_builtin.emitOptionalInto(self, expr, ty.?.optional, slot);
        return slot;
    }
    if (ty != null and self.isInlineAggregateType(ty.?)) {
        const width = self.widthOfType(ty.?);
        const slot = try self.allocLocalSized("\x00__scrut", width);
        switch (ty.?.*) {
            .tuple => |elems| try value_struct.emitTupleInto(self, expr, elems, slot),
            .array => |a| try value_struct.emitArrayInto(self, expr, a.elem, a.len, slot),
            .named => |n| try value_struct.emitInto(self, expr, n.name, slot),
            // `isInlineAggregateType` admits only tuple / array / struct.
            else => unreachable,
        }
        return slot;
    }
    try self.emitExpr(expr);
    const slot = try self.allocLocal("\x00__scrut");
    try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, slot);
    return slot;
}

/// Match `pat` against the component inline at `[fp + ofs]` (type `ty`).
/// Binds idents and recurses into tuple / struct / variant sub-patterns;
/// a refutable leaf or variant tag pushes a skip patch onto `skip`.
pub fn emitMatchPattern(self: *Emitter, pat: *const ast.Pattern, ofs: i8, ty: ?*const Type, skip: *std.ArrayList(usize)) error{OutOfMemory}!void {
    // Optional scrutinee — unwrap (§3.4.1: `if let` matches the inner
    // value): test present (skip on absent), then match `pat` against the
    // value. A scalar `T?` keeps present @0 + value @2; a pointer-like `T?`
    // is the value itself (0 = nil).
    if (ty) |t| if (t.* == .optional) {
        const inner = t.optional;
        const scalar = codegen.Emitter.isScalarOptional(inner);
        // present is at offset 0 (scalar tag) or is the pointer itself.
        const present_at: i8 = ofs;
        // @as: the value offset (2) keeps the slot within the i8 frame cap.
        const value_at: i8 = if (scalar) ofs + @as(i8, @intCast(codegen.Emitter.opt_value_ofs)) else ofs;
        try isa.movRegOffsetToReg(self, Reg.fp, present_at, Reg.acu);
        try isa.cmpRegImm(self, Reg.acu, 0);
        try skip.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jeq_addr));
        try emitMatchPattern(self, pat, value_at, inner, skip);
        return;
    };
    switch (pat.*) {
        .wildcard => {},
        .ident => |ip| {
            // Inline binder: alias the slot sub-region — no load, no slot.
            const name = try self.arena.dupe(u8, self.source[ip.name.start..ip.name.end]);
            try self.locals.put(self.arena, name, ofs);
        },
        .tuple_pattern => |tp| {
            const elems: ?[]const *const Type = if (ty != null and ty.?.* == .tuple) ty.?.tuple else null;
            for (tp.elems, 0..) |elem, i| {
                const et: ?*const Type = if (elems != null and i < elems.?.len) elems.?[i] else null;
                const eo: i8 = if (elems) |es|
                    // @as: element offset within a ≤127-byte frame slot fits i8.
                    ofs + @as(i8, @intCast(self.tupleElemInfo(es, @intCast(i)).offset))
                else
                    ofs;
                try emitMatchPattern(self, elem, eo, et, skip);
            }
        },
        .struct_pattern => |sp| try matchStruct(self, sp, ofs, ty, skip),
        .variant_pattern => |vp| try matchVariant(self, vp, ofs, ty, skip),
        else => {
            try loadInline(self, ofs, ty, Reg.acu);
            try pattern.emitLeafTest(self, pat.*, skip);
        },
    }
}

fn matchStruct(self: *Emitter, sp: ast.StructPattern, ofs: i8, ty: ?*const Type, skip: *std.ArrayList(usize)) error{OutOfMemory}!void {
    const sname: []const u8 = if (ty != null and ty.?.* == .named) ty.?.named.name else self.source[sp.type_name.start..sp.type_name.end];
    const sd = self.struct_decls.get(sname);
    for (sp.fields) |f| {
        const fname = self.source[f.name.start..f.name.end];
        const info = self.structFieldInfo(sname, fname) orelse continue;
        // @as: field offset within a ≤127-byte frame slot fits i8.
        const fo: i8 = ofs + @as(i8, @intCast(info.offset));
        const fty: ?*const Type = blk: {
            const decl = sd orelse break :blk null;
            for (decl.fields) |df| {
                if (std.mem.eql(u8, self.source[df.name.start..df.name.end], fname))
                    break :blk try self.typeAnnToType(df.type_ann.*);
            }
            break :blk null;
        };
        try emitMatchPattern(self, f.sub, fo, fty, skip);
    }
}

fn matchVariant(self: *Emitter, vp: ast.VariantPattern, ofs: i8, ty: ?*const Type, skip: *std.ArrayList(usize)) error{OutOfMemory}!void {
    const path = self.source[vp.path.start..vp.path.end];
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse {
        try self.diagFatal(vp.span, "E_CODEGEN_BAD_VARIANT_PATH", "codegen: variant pattern must be `EnumName.Variant`");
        return;
    };
    const enum_name = path[0..dot];
    const variant_name = path[dot + 1 ..];
    const ed = self.enum_decls.get(enum_name) orelse {
        try self.diagFatal(vp.span, "E_CODEGEN_UNDEFINED_VARIANT", "codegen: unknown enum in variant pattern");
        return;
    };
    const tag = self.variantTag(enum_name, variant_name) orelse {
        try self.diagFatal(vp.span, "E_CODEGEN_UNDEFINED_VARIANT", "codegen: unknown enum variant in pattern");
        return;
    };
    if (!self.enumHasPayload(ed)) {
        // Payload-free: the inline value IS the tag.
        try loadInline(self, ofs, ty, Reg.acu);
        try isa.cmpRegImm(self, Reg.acu, tag);
        try skip.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
        return;
    }
    // Payload enum: [fp+ofs] holds the `[tag|payload]` slot pointer.
    try isa.movRegOffsetToReg(self, Reg.fp, ofs, Reg.r1); // r1 = pointer
    try class.emitByteLoadAtOffset(self, Reg.r1, 0, Reg.acu); // acu = tag byte
    try isa.cmpRegImm(self, Reg.acu, tag);
    try skip.append(self.allocator, try isa.emitJumpPlaceholder(self, Op.jne_addr));
    for (ed.variants) |v| {
        if (!std.mem.eql(u8, self.source[v.name.start..v.name.end], variant_name)) continue;
        for (vp.args, 0..) |arg, i| {
            if (i >= v.payload.len) break;
            try bindPayload(self, arg, ofs, self.variantFieldOffset(v, i), v.payload[i].type_ann.*, skip);
        }
        return;
    }
}

/// Bind / test one enum payload field at `[<ptr at fp+scrut_ofs> + off]`.
/// The pointer is reloaded per field — prior binders / nested recursion
/// churn registers, so `r1` can't be assumed live across calls.
fn bindPayload(self: *Emitter, arg: *const ast.Pattern, scrut_ofs: i8, off: u16, fty_ann: ast.TypeAnn, skip: *std.ArrayList(usize)) error{OutOfMemory}!void {
    // An aggregate payload (struct / tuple / array) lays out inline within
    // the slot at `off` (the enum owns its bytes — §3.6). Copy it into a
    // fresh sized slot the binder owns, then bind / recurse against that.
    if (self.structNameOfTypeAnn(fty_ann) != null or fty_ann == .tuple or fty_ann == .array) {
        if (arg.* == .wildcard) return;
        const w = self.widthOfTypeAnn(fty_ann);
        const slot_name: []const u8 = if (arg.* == .ident)
            try self.arena.dupe(u8, self.source[arg.ident.name.start..arg.ident.name.end])
        else
            "\x00__pl";
        const dest = try self.allocLocalSized(slot_name, w);
        try copyInlinePayload(self, scrut_ofs, off, w, dest);
        // An ident binds the copied aggregate directly (the slot is its
        // value); any other pattern destructures the copy in place.
        if (arg.* != .ident) try emitMatchPattern(self, arg, dest, try self.typeAnnToType(fty_ann), skip);
        return;
    }
    switch (arg.*) {
        .wildcard => {},
        .ident => |ip| {
            try loadPayload(self, scrut_ofs, off, fty_ann, Reg.acu);
            const name = try self.arena.dupe(u8, self.source[ip.name.start..ip.name.end]);
            const slot = try self.allocLocal(name);
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, slot);
        },
        .variant_pattern => {
            // A nested enum payload — park its pointer in a temp slot + recurse.
            try isa.movRegOffsetToReg(self, Reg.fp, scrut_ofs, Reg.r1);
            try class.emitWordLoadAtOffset(self, Reg.r1, off, Reg.acu);
            const temp = try self.allocLocal("\x00__pl");
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, temp);
            try emitMatchPattern(self, arg, temp, try self.typeAnnToType(fty_ann), skip);
        },
        else => {
            try loadPayload(self, scrut_ofs, off, fty_ann, Reg.acu);
            try pattern.emitLeafTest(self, arg.*, skip);
        },
    }
}

/// Copy a `w`-byte inline aggregate payload at `[<slot ptr at fp+scrut_ofs>
/// + off]` into the frame slot at `dest`.
fn copyInlinePayload(self: *Emitter, scrut_ofs: i8, off: u16, w: u16, dest: i8) error{OutOfMemory}!void {
    try isa.movRegOffsetToReg(self, Reg.fp, scrut_ofs, Reg.r1); // r1 = slot pointer
    if (off > 0) try isa.addImmToReg(self, off, Reg.r1); // r1 = &payload aggregate
    try frameAddr(self, dest, Reg.r2);
    try value_struct.copyBytes(self, Reg.r1, Reg.r2, w);
}

fn loadPayload(self: *Emitter, scrut_ofs: i8, off: u16, fty_ann: ast.TypeAnn, reg: u8) error{OutOfMemory}!void {
    try isa.movRegOffsetToReg(self, Reg.fp, scrut_ofs, Reg.r1); // r1 = slot pointer
    if (self.widthOfTypeAnn(fty_ann) == 1) {
        try class.emitByteLoadAtOffset(self, Reg.r1, off, reg);
        if (self.isPrimitiveTypeAnn(fty_ann, "i8")) try isa.signExtendByte(self, reg);
    } else {
        try class.emitWordLoadAtOffset(self, Reg.r1, off, reg);
    }
}

/// Load the inline scalar value at `[fp + ofs]` into `reg` (sign-extends
/// an `i8`). `reg` must not be `r1` (used as the byte-load address).
fn loadInline(self: *Emitter, ofs: i8, ty: ?*const Type, reg: u8) error{OutOfMemory}!void {
    const w: u16 = if (ty) |t| self.widthOfType(t) else 2;
    if (w == 1) {
        try frameAddr(self, ofs, Reg.r1);
        try class.emitByteLoadAtOffset(self, Reg.r1, 0, reg);
        if (ty != null and ty.?.* == .primitive and ty.?.primitive == .i8) try isa.signExtendByte(self, reg);
    } else {
        try isa.movRegOffsetToReg(self, Reg.fp, ofs, reg);
    }
}

/// `reg = fp + ofs` — the address of a frame slot.
fn frameAddr(self: *Emitter, ofs: i8, reg: u8) error{OutOfMemory}!void {
    try isa.movRegToReg(self, Reg.fp, reg);
    if (ofs < 0) {
        // @as: |ofs| ≤ 127 fits u16.
        try isa.subImmFromReg(self, @intCast(-@as(i16, ofs)), reg);
    } else if (ofs > 0) {
        try isa.addImmToReg(self, @intCast(ofs), reg);
    }
}
