// Codegen for inline value structs (§3.4). A struct value lives in
// its owner's frame as contiguous bytes; a struct-typed expression
// evaluates to that base address. Construction writes each field at
// its offset (recursing into nested struct fields); assignment copies
// the bytes (value semantics). Nested structs work because they sit
// inline at a fixed frame offset within the parent. A struct argument
// is passed by value: the caller reserves its width on the stack and
// materializes a copy there (`pushArg`).

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const class = @import("class.zig");

const Emitter = codegen.Emitter;
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
