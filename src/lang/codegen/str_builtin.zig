// `str` instance-member lowering (§3.2.1) — operations on a `str` value,
// which is a 16-bit pointer to null-terminated bytes. `s.len` is a property
// (byte count); `s.at(i)` / `s.cmp(other)` are methods. Mirrors
// `vec_builtin`; the byte-walk primitives match `strings.zig`.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const class = @import("class.zig");
const strings = @import("strings.zig");
const variadic = @import("variadic.zig");
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
/// Lower `str.format_into(dst, fmt, args...)` — the allocation-free form.
/// Writes into the caller's buffer at `dst` and leaves the byte count
/// (excluding the terminator) in `acu`.
///
/// The heap never reclaims (§5.4), so this is the form a per-frame
/// caller wants: a cart formatting its score every frame through
/// `str.format` exhausts the heap in seconds, while this writes into a
/// buffer the cart owns and reuses.
pub fn emitFormatInto(
    self: *Emitter,
    dst: *const ast.Expr,
    fmt: *const ast.Expr,
    args: []const *ast.Expr,
) error{OutOfMemory}!void {
    return emitFormatCommon(self, dst, fmt, args);
}

/// Lower `str.format(fmt, args...)` (§3.2.2) — lay the `args` words out
/// contiguously on the stack, allocate a fresh heap buffer, and run the
/// `format_runtime` syscall to fill it from the runtime-parsed `fmt`. The
/// allocated buffer's base is left in `acu` (a `str` result).
pub fn emitFormat(self: *Emitter, fmt: *const ast.Expr, args: []const *ast.Expr) error{OutOfMemory}!void {
    return emitFormatCommon(self, null, fmt, args);
}

/// Shared lowering. With `dst` the buffer comes from the caller and the
/// result is the byte count; without it a buffer is allocated and the
/// result is its base — the only difference between the two forms.
fn emitFormatCommon(
    self: *Emitter,
    dst: ?*const ast.Expr,
    fmt: *const ast.Expr,
    args: []const *ast.Expr,
) error{OutOfMemory}!void {
    // `format(fmt, args)` with a single tuple argument forwards that
    // tuple's elements positionally (§3.2.2) — the variadic `args` slot
    // is the spelled case. Re-lay its elements as words and format those.
    if (dst == null and args.len == 1) if (self.tupleElemsOf(args[0])) |elems| {
        try emitFormatForward(self, fmt, args[0], elems);
        return;
    };
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

    // Park the buffer base above all else. `format_into` takes it from
    // the caller; `format` allocates one.
    if (dst) |d| {
        try self.emitExpr(d); // acu = caller's buffer address
    } else {
        try isa.movImmToReg(self, strings.interp_buffer_size, Reg.acu);
        try isa.sys(self, Sys.alloc); // acu = buffer base
    }
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

    // `format` yields the buffer base; `format_into` yields how many
    // bytes it wrote, which the syscall left as the advance in `r1`.
    if (dst == null) {
        try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.acu);
    } else {
        try isa.movRegToReg(self, Reg.r1, Reg.acu);
        try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r2);
        try isa.subRegFromAcu(self, Reg.r2); // acu = cursor - base
        try isa.subImmFromReg(self, 1, Reg.acu); // less the terminator
    }
    // @as: 2 (buffer) + N*2 (args) + 2 (fmt), bounded under 127.
    try isa.addImmToReg(self, @intCast(2 + n * 2 + 2), Reg.sp);
}

/// Forward a single tuple argument to `format` (§3.2.2) — re-lay its `N`
/// elements as `N` contiguous words, then run `format_runtime` over them.
/// The variadic `args` slot is word-strided (each vararg pushed whole),
/// so its elements read at `k * 2`; a plain tuple value is byte-packed,
/// so each element reads at its inline offset.
fn emitFormatForward(self: *Emitter, fmt: *const ast.Expr, tuple: *const ast.Expr, elems: []const *const types.Type) error{OutOfMemory}!void {
    const word_strided = variadic.isArgsForward(self, tuple);
    // The forwarded count is this specialization's arity (§4.6.2), not
    // the body's `args` type — that type is the whole-program *minimum*
    // arity, pinned for sound `args.N` indexing, which may be smaller.
    // A plain tuple value uses its own element count.
    // @as: count is frame-bounded — the i8 offsets below cap it under 62
    // (4 + N*2 ≤ 127).
    const n: u16 = if (word_strided) self.current_variadic.?.arity else @intCast(elems.len);
    const elem_ty: ?*const types.Type = if (word_strided)
        self.current_variadic.?.elem
    else if (elems.len > 0) elems[0] else null;
    const desc = if (elem_ty) |t| elemDescriptorForType(t) else 0;

    // Park fmt, then the tuple base, above the args region.
    try self.emitExpr(fmt); // acu = fmt pointer
    try isa.pushReg(self, Reg.acu); // [sp] = fmt
    try self.emitAddrOf(tuple); // acu = tuple base address
    try isa.pushReg(self, Reg.acu); // [sp] = tuple base, [sp+2] = fmt

    // Reserve the args region (N words) and fill it from the tuple.
    if (n > 0) try isa.subImmFromReg(self, n * 2, Reg.sp);
    var k: u16 = 0;
    while (k < n) : (k += 1) {
        // @as: tuple base sits just above the N-word region; the reload
        // offset N*2 stays within the i8 stack window.
        try isa.movRegOffsetToReg(self, Reg.sp, @intCast(n * 2), Reg.r1); // r1 = tuple base
        if (word_strided) {
            try class.emitWordLoadAtOffset(self, Reg.r1, k * 2, Reg.acu);
        } else {
            const info = self.tupleElemInfo(elems, @intCast(k));
            if (info.width == 1) {
                try class.emitByteLoadAtOffset(self, Reg.r1, info.offset, Reg.acu);
                if (info.signed_byte) try isa.signExtendByte(self, Reg.acu);
            } else {
                try class.emitWordLoadAtOffset(self, Reg.r1, info.offset, Reg.acu);
            }
        }
        // @as: k*2 within the reserved args region fits i8.
        try isa.movRegToRegOffset(self, Reg.acu, Reg.sp, @intCast(k * 2));
    }

    // Allocate the output buffer; park its base (the result) on top.
    try isa.movImmToReg(self, strings.interp_buffer_size, Reg.acu);
    try isa.sys(self, Sys.alloc); // acu = buffer base
    try isa.pushReg(self, Reg.acu); // [sp] = buffer base

    // Stack: [sp] buf | [sp+2 .. +2+N*2) args | [sp+2+N*2] base | [sp+4+N*2] fmt.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = cursor = buffer base
    // @as: fmt offset = 4 (buffer + base) + N*2, bounded under 127.
    try isa.movRegOffsetToReg(self, Reg.sp, @intCast(4 + n * 2), Reg.acu); // acu = fmt ptr
    try isa.movRegToReg(self, Reg.sp, Reg.r2);
    try isa.addImmToReg(self, 2, Reg.r2); // r2 = args base = sp + 2
    try isa.movImmToReg(self, n | desc, Reg.r3); // count | element descriptor
    try isa.sys(self, Sys.format_runtime);
    try isa.sys(self, Sys.format_terminate_buf);

    // Result = the buffer base; drop buffer + args + base + fmt.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.acu);
    // @as: 2 (buffer) + N*2 (args) + 2 (base) + 2 (fmt), bounded under 127.
    try isa.addImmToReg(self, @intCast(6 + n * 2), Reg.sp);
}

/// The `format_runtime` `r3` element descriptor (default type + signed bit)
/// for a homogeneous `args` element of `arg`'s type — used to render a
/// bare `{N}` placeholder.
fn elemDescriptor(self: *Emitter, arg: ?*const ast.Expr) u16 {
    const a = arg orelse return 0; // no args — irrelevant, default decimal
    if (self.isPrimitiveType(a, .str)) return 5 << 8; // str
    if (self.isPrimitiveType(a, .fixed)) return 7 << 8; // fixed
    if (self.isPrimitiveType(a, .char)) return 6 << 8; // char
    if (!self.isUnsignedInt(a)) return (1 << 11); // signed decimal
    return 0; // unsigned decimal
}

/// Element descriptor from a type (forwarded-tuple element) — mirrors
/// `elemDescriptor` but resolves a `*Type` rather than an expression.
fn elemDescriptorForType(t: *const types.Type) u16 {
    const inner = if (t.* == .reference) t.reference else t;
    if (inner.* != .primitive) return 0; // aggregate element — decimal
    return switch (inner.primitive) {
        .str => 5 << 8,
        .fixed => 7 << 8,
        .char => 6 << 8,
        .i8, .i16 => 1 << 11, // signed decimal
        else => 0, // u8 / u16 / bool / nil — unsigned decimal
    };
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
