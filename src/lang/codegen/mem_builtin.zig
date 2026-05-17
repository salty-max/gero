/// Lowering for the stdlib `mem.*` builtins. Each entry maps to
/// a specific VM opcode sequence — typed peek/poke pairs, the
/// `bcpy` / `bfill` block ops, and the shared `addr_of` helper
/// that also backs the `&x` reference operator.
const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;

const MemReadKind = enum { byte_zext, byte_sext, word };
const MemWriteKind = enum { byte, word };

/// Dispatch a `mem.X(args)` call to the matching emitter. The
/// typechecker has already validated the builtin name + arity;
/// the codegen check repeats the arity guard as a defensive
/// safeguard against frontend changes.
pub fn emitMemCall(self: *Emitter, fe: ast.FieldExpr, c: ast.CallExpr) !void {
    const fn_name = self.source[fe.field.start..fe.field.end];
    if (std.mem.eql(u8, fn_name, "read_u8") or std.mem.eql(u8, fn_name, "peek")) {
        try emitMemRead1Arg(self, c, .byte_zext);
    } else if (std.mem.eql(u8, fn_name, "read_u16") or std.mem.eql(u8, fn_name, "read_i16")) {
        try emitMemRead1Arg(self, c, .word);
    } else if (std.mem.eql(u8, fn_name, "read_i8")) {
        try emitMemRead1Arg(self, c, .byte_sext);
    } else if (std.mem.eql(u8, fn_name, "write_u8") or std.mem.eql(u8, fn_name, "write_i8") or std.mem.eql(u8, fn_name, "poke")) {
        try emitMemWrite2Args(self, c, .byte);
    } else if (std.mem.eql(u8, fn_name, "write_u16") or std.mem.eql(u8, fn_name, "write_i16")) {
        try emitMemWrite2Args(self, c, .word);
    } else if (std.mem.eql(u8, fn_name, "memcpy")) {
        try emitMemCopy(self, c);
    } else if (std.mem.eql(u8, fn_name, "memset")) {
        try emitMemFill(self, c);
    } else if (std.mem.eql(u8, fn_name, "addr_of")) {
        if (c.args.len != 1) {
            try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: `mem.addr_of` takes exactly one argument");
            return;
        }
        try emitAddrOf(self, c.args[0]);
    } else {
        try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: unknown `mem` builtin");
    }
}

/// `mem.read_*(addr)` — one arg, returns a value in `acu`. The
/// width / sign-extension choice picks the load opcode (and an
/// optional sign-extension tail for `read_i8`).
fn emitMemRead1Arg(self: *Emitter, c: ast.CallExpr, kind: MemReadKind) !void {
    if (c.args.len != 1) {
        try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: `mem.read_*` takes exactly one argument");
        return;
    }
    try self.emitExpr(c.args[0]); // acu = addr
    try self.movRegToReg(Reg.acu, Reg.r1); // r1 = addr
    switch (kind) {
        .word => {
            try self.emitByte(Op.mov_ptr_to_reg);
            try self.emitByte(Reg.acu); // dst
            try self.emitByte(Reg.r1); // ptr
        },
        .byte_zext => {
            try self.emitByte(Op.mov8_ptr_to_reg);
            try self.emitByte(Reg.r1); // ptr
            try self.emitByte(Reg.acu); // dst
        },
        .byte_sext => {
            try self.emitByte(Op.mov8_ptr_to_reg);
            try self.emitByte(Reg.r1);
            try self.emitByte(Reg.acu);
            // Sign-extend 8 → 16: `shl 8 ; asr 8`. The byte sits
            // in `acu.lo`; shifting it into the top byte and back
            // arithmetic-shift-right preserves the sign bit
            // through the high half.
            try self.shlRegImm(Reg.acu, 8);
            try self.asrRegImm(Reg.acu, 8);
        },
    }
}

/// `mem.write_*(addr, v)` — two args, no return. Args eval
/// left-to-right via push/pop so `addr` and `v` can be arbitrary
/// subexpressions.
fn emitMemWrite2Args(self: *Emitter, c: ast.CallExpr, kind: MemWriteKind) !void {
    if (c.args.len != 2) {
        try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: `mem.write_*` takes exactly two arguments");
        return;
    }
    try self.emitExpr(c.args[0]); // acu = addr
    try self.pushReg(Reg.acu);
    try self.emitExpr(c.args[1]); // acu = value
    try self.popReg(Reg.r1); // r1 = addr
    switch (kind) {
        .word => {
            try self.emitByte(Op.mov_reg_to_ptr);
            try self.emitByte(Reg.r1); // ptr
            try self.emitByte(Reg.acu); // src
        },
        .byte => {
            try self.emitByte(Op.mov8_reg_to_ptr);
            try self.emitByte(Reg.acu); // src (low byte)
            try self.emitByte(Reg.r1); // ptr
        },
    }
}

/// `mem.memcpy(dst, src, n)` — eval each arg left-to-right into
/// a dedicated register, then emit `bcpy dst, src, len`.
fn emitMemCopy(self: *Emitter, c: ast.CallExpr) !void {
    if (c.args.len != 3) {
        try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: `mem.memcpy` takes exactly three arguments");
        return;
    }
    try self.emitExpr(c.args[0]); // dst
    try self.pushReg(Reg.acu);
    try self.emitExpr(c.args[1]); // src
    try self.pushReg(Reg.acu);
    try self.emitExpr(c.args[2]); // n → acu
    try self.movRegToReg(Reg.acu, Reg.r3); // r3 = len
    try self.popReg(Reg.r2); // r2 = src
    try self.popReg(Reg.r1); // r1 = dst
    try self.emitByte(Op.bcpy);
    try self.emitByte(Reg.r1); // dst
    try self.emitByte(Reg.r2); // src
    try self.emitByte(Reg.r3); // len
}

/// `mem.memset(dst, v, n)` — eval args into dedicated regs and
/// emit `bfill addr, len, val`. Note the operand order: the VM
/// reads bytes as `dst, len, val`.
fn emitMemFill(self: *Emitter, c: ast.CallExpr) !void {
    if (c.args.len != 3) {
        try self.diagFatal(c.span, "E_CODEGEN_UNSUPPORTED", "codegen: `mem.memset` takes exactly three arguments");
        return;
    }
    try self.emitExpr(c.args[0]); // dst
    try self.pushReg(Reg.acu);
    try self.emitExpr(c.args[1]); // v
    try self.pushReg(Reg.acu);
    try self.emitExpr(c.args[2]); // n → acu
    try self.movRegToReg(Reg.acu, Reg.r3); // r3 = len
    try self.popReg(Reg.r2); // r2 = val
    try self.popReg(Reg.r1); // r1 = dst
    try self.emitByte(Op.bfill);
    try self.emitByte(Reg.r1); // dst
    try self.emitByte(Reg.r3); // len
    try self.emitByte(Reg.r2); // val
}

/// Compute the address of an addressable expression and leave
/// it in `acu`. Backs `mem.addr_of(x)` and the typed `&x`
/// reference operator. Plain idents (locals, params, globals)
/// are supported; field / index targets are not yet supported.
pub fn emitAddrOf(self: *Emitter, e: *const ast.Expr) !void {
    if (e.* != .ident) {
        try self.unsupported(e.span(), "`addr_of` on non-ident expression");
        return;
    }
    const name = self.source[e.ident.span.start..e.ident.span.end];
    if (self.locals.get(name)) |ofs| {
        // Local: address = fp + ofs (ofs is negative).
        try self.movRegToReg(Reg.fp, Reg.acu);
        if (ofs < 0) {
            // @as: widen i8 → i16 so the negate doesn't trip on the minimum value.
            const widened: i16 = ofs;
            // @as: |ofs| ≤ 128 by allocLocal cap; result fits a u16.
            const neg: u16 = @intCast(-widened);
            try self.subImmFromReg(neg, Reg.acu);
        } else if (ofs > 0) {
            // @as: positive i8 → u16; cap by allocLocal layout.
            const pos: u16 = @intCast(ofs);
            try self.addImmToReg(pos, Reg.acu);
        }
        return;
    }
    if (self.params.get(name)) |ofs| {
        // Param: address = fp + ofs (ofs is positive).
        try self.movRegToReg(Reg.fp, Reg.acu);
        // @as: positive i8 → u16.
        const pos: u16 = @intCast(ofs);
        try self.addImmToReg(pos, Reg.acu);
        return;
    }
    if (self.globals.get(name)) |g| {
        try self.movImmToReg(g.address, Reg.acu);
        return;
    }
    try self.unsupported(e.span(), "`addr_of` target not in scope");
}
