// `str` instance-member lowering (§3.2.1) — operations on a `str` value,
// which is a 16-bit pointer to null-terminated bytes. `s.len` is a property
// (byte count); `s.at(i)` / `s.cmp(other)` are methods. Mirrors
// `vec_builtin`; the byte-walk primitives match `strings.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const class = @import("class.zig");
const strings = @import("strings.zig");
const overflow = @import("overflow.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// `true` when `e` is a `str`-typed expression (peeling a reference).
pub fn isStr(self: *const Emitter, e: *const ast.Expr) bool {
    const t = self.typeOf(e) orelse return false;
    const inner = if (t.* == .reference) t.reference else t;
    return inner.* == .primitive and inner.primitive == .str;
}

/// Lower the `s.len` property — walk to the null terminator, leaving the
/// byte count (`u16`, excluding the terminator) in `acu`.
pub fn emitLen(self: *Emitter, recv: *const ast.Expr) error{OutOfMemory}!void {
    try self.emitExpr(recv); // acu = str pointer
    try emitStrlen(self, Reg.acu, Reg.r2); // r2 = count
    try isa.movRegToReg(self, Reg.r2, Reg.acu);
}

/// Lower a `str` instance method — `s.at(i)` (byte at index `i`, `u8`) or
/// `s.cmp(other)` (byte-wise comparison, `i16` ordering).
pub fn emitMethod(self: *Emitter, recv: *const ast.Expr, method: []const u8, args: []const *ast.Expr) error{OutOfMemory}!void {
    if (std.mem.eql(u8, method, "at")) return emitAt(self, recv, args[0]);
    if (std.mem.eql(u8, method, "cmp")) return emitCmp(self, recv, args[0]);
    try self.unsupported(recv.span(), "this str method");
}

/// `s.at(i)` — the byte at index `i` (zero-extended `u8`), debug-bounds-
/// trapped against the string length.
fn emitAt(self: *Emitter, recv: *const ast.Expr, idx: *const ast.Expr) error{OutOfMemory}!void {
    try self.emitExpr(recv); // acu = str pointer
    try isa.pushReg(self, Reg.acu); // [sp+0] = str ptr
    try self.emitExpr(idx); // acu = index
    try isa.pushReg(self, Reg.acu); // [sp+0] = index, [sp+2] = str ptr
    // Debug bounds trap: idx >= len(s) faults to vector $02.
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.r1);
    try emitStrlen(self, Reg.r1, Reg.r2); // r2 = len
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.acu); // acu = index
    try overflow.emitBoundsTrapReg(self, Reg.acu, Reg.r2);
    // acu = byte at [str ptr + index].
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.r1); // r1 = str ptr
    try isa.addRegToAcu(self, Reg.r1); // acu = ptr + index
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try class.emitByteLoadAtOffset(self, Reg.r1, 0, Reg.acu);
    try isa.addImmToReg(self, 4, Reg.sp); // drop index + str ptr
}

/// `s.cmp(other)` — byte-wise lexicographic comparison; `acu` holds the
/// strcmp-style ordering (negative / 0 / positive) as `i16`.
fn emitCmp(self: *Emitter, recv: *const ast.Expr, other: *const ast.Expr) error{OutOfMemory}!void {
    try self.emitExpr(recv); // acu = lhs pointer
    try isa.pushReg(self, Reg.acu);
    try self.emitExpr(other); // acu = rhs pointer
    try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = rhs
    try isa.popReg(self, Reg.r1); // r1 = lhs
    try strings.emitStrCmp(self, Reg.r1, Reg.r2); // acu = ordering
}

/// Lower `str.format(fmt, args...)` (§3.2.2) — lay the `args` words out
/// contiguously on the stack, allocate a fresh heap buffer, and run the
/// `format_runtime` syscall to fill it from the runtime-parsed `fmt`. The
/// allocated buffer's base is left in `acu` (a `str` result).
pub fn emitFormat(self: *Emitter, fmt: *const ast.Expr, args: []const *ast.Expr) error{OutOfMemory}!void {
    // @as: arg count fits a u16; the i8 stack offsets below bound it well
    // under 62 args (2 + N*2 ≤ 127).
    const n: u16 = @intCast(args.len);
    const desc = elemDescriptor(self, if (args.len > 0) args[0] else null);

    // fmt pointer parked just above the args region.
    try self.emitExpr(fmt); // acu = fmt pointer
    try isa.pushReg(self, Reg.acu); // [sp] = fmt

    // Reserve the args region (N words) and fill it left-to-right.
    if (n > 0) try isa.subImmFromReg(self, n * 2, Reg.sp);
    for (args, 0..) |arg, k| {
        try self.emitExpr(arg); // acu = arg value (sp-neutral)
        // @as: k*2 within the reserved args region fits i8.
        try isa.movRegToRegOffset(self, Reg.acu, Reg.sp, @intCast(k * 2));
    }

    // Allocate the output buffer; park its base (the result) above all else.
    try isa.movImmToReg(self, strings.interp_buffer_size, Reg.acu);
    try isa.sys(self, Sys.alloc); // acu = buffer base
    try isa.pushReg(self, Reg.acu); // [sp] = buffer base

    // Stack now: [sp+0] buffer base | [sp+2 .. sp+2+N*2) args | [sp+2+N*2] fmt.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = cursor = buffer base
    // @as: fmt offset = 2 (buffer) + N*2 (args), bounded under 127.
    try isa.movRegOffsetToReg(self, Reg.sp, @intCast(2 + n * 2), Reg.acu); // acu = fmt ptr
    try isa.movRegToReg(self, Reg.sp, Reg.r2);
    try isa.addImmToReg(self, 2, Reg.r2); // r2 = args base = sp + 2
    try isa.movImmToReg(self, n | desc, Reg.r3); // count | element descriptor
    try isa.sys(self, Sys.format_runtime);
    try isa.sys(self, Sys.format_terminate_buf);

    // Result = the buffer base; drop buffer base + args + fmt.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.acu);
    // @as: 2 (buffer) + N*2 (args) + 2 (fmt), bounded under 127.
    try isa.addImmToReg(self, @intCast(2 + n * 2 + 2), Reg.sp);
}

/// The `format_runtime` `r3` element descriptor (default type + signed bit)
/// for a homogeneous `args` element of `arg`'s type — used to render a
/// bare `$(N)` placeholder.
fn elemDescriptor(self: *Emitter, arg: ?*const ast.Expr) u16 {
    const a = arg orelse return 0; // no args — irrelevant, default decimal
    if (self.isPrimitiveType(a, .str)) return 5 << 8; // str
    if (self.isPrimitiveType(a, .fixed)) return 7 << 8; // fixed
    if (self.isPrimitiveType(a, .char)) return 6 << 8; // char
    if (!self.isUnsignedInt(a)) return (1 << 11); // signed decimal
    return 0; // unsigned decimal
}

/// `count_reg = strlen(ptr_reg)` — walk a copy of `ptr_reg` to the null
/// terminator. Clobbers `acu` + `r3`; leaves `ptr_reg` untouched.
fn emitStrlen(self: *Emitter, ptr_reg: u8, count_reg: u8) error{OutOfMemory}!void {
    try isa.movRegToReg(self, ptr_reg, Reg.r3); // r3 = cursor
    try isa.movImmToReg(self, 0, count_reg);
    const loop = try self.currentOffset();
    try class.emitByteLoadAtOffset(self, Reg.r3, 0, Reg.acu);
    try isa.cmpRegImm(self, Reg.acu, 0);
    const done = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try isa.addImmToReg(self, 1, count_reg);
    try isa.addImmToReg(self, 1, Reg.r3);
    try isa.emitJumpBack(self, loop);
    try isa.patchJumpTo(self, done, try self.currentOffset());
}
