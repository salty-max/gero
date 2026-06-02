// `Vec(T)` lowering (§3.4.3) — a growable dynamic array. The value is a
// 6-byte `(ptr, len, cap)` header stored inline (like a struct); the
// backing buffer lives on the heap (`sys alloc`, a bump allocator — growth
// allocates a new buffer and copies, leaking the old one). This covers the
// non-optional surface; `pop` / `get` (which return `T?`) await the scalar-
// optional model.

const std = @import("std");
const ast = @import("../ast.zig");
const types = @import("../types.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const class = @import("class.zig");
const value_struct = @import("value_struct.zig");
const overflow = @import("overflow.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Type = types.Type;

/// Byte size of a `Vec` value's inline header.
pub const header_size: u16 = 6;
const ptr_ofs: u16 = 0;
const len_ofs: u16 = 2;
const cap_ofs: u16 = 4;

/// Element type of a Vec-typed expression (peeling a reference), or `null`.
pub fn elemOf(self: *const Emitter, e: *const ast.Expr) ?*const Type {
    const t = self.typeOf(e) orelse return null;
    const inner = if (t.* == .reference) t.reference else t;
    return if (inner.* == .vec) inner.vec else null;
}

/// `true` when `name` is a `Vec.<name>(...)` constructor.
pub fn isConstructor(name: []const u8) bool {
    return std.mem.eql(u8, name, "new") or
        std.mem.eql(u8, name, "with_capacity") or
        std.mem.eql(u8, name, "from");
}

// ---- constructors — materialize the 6-byte header into a frame slot ----

/// Materialize a `Vec.<method>(...)` result into the frame slot at
/// `dest_ofs`. `elem` is the element type (sizing the buffer).
pub fn emitConstructInto(self: *Emitter, method: []const u8, args: []const *ast.Expr, elem: *const Type, dest_ofs: i16) error{OutOfMemory}!void {
    const ew = self.widthOfType(elem);
    if (std.mem.eql(u8, method, "new")) {
        // {ptr: 0, len: 0, cap: 0} — no buffer.
        try frameAddr(self, dest_ofs, Reg.r1);
        try isa.movImmToReg(self, 0, Reg.acu);
        try class.emitWordStoreAtOffset(self, Reg.r1, ptr_ofs, Reg.acu);
        try class.emitWordStoreAtOffset(self, Reg.r1, len_ofs, Reg.acu);
        try class.emitWordStoreAtOffset(self, Reg.r1, cap_ofs, Reg.acu);
        return;
    }
    if (std.mem.eql(u8, method, "with_capacity")) {
        // cap = n; ptr = alloc(n * ew); len = 0.
        try self.emitExpr(args[0]); // acu = n
        try isa.pushReg(self, Reg.acu); // [sp] = n
        try scaleBytes(self, Reg.acu, ew); // acu = n * ew
        try emitAlloc(self, Reg.acu); // acu = buffer ptr
        try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = ptr
        try isa.popReg(self, Reg.r3); // r3 = n (cap)
        try frameAddr(self, dest_ofs, Reg.r1); // r1 = header addr
        try class.emitWordStoreAtOffset(self, Reg.r1, ptr_ofs, Reg.r2);
        try class.emitWordStoreAtOffset(self, Reg.r1, cap_ofs, Reg.r3);
        try isa.movImmToReg(self, 0, Reg.acu);
        try class.emitWordStoreAtOffset(self, Reg.r1, len_ofs, Reg.acu);
        return;
    }
    // `from([..])` — materialize a fixed array into a fresh exact-fit
    // buffer (the literal lands directly in the heap slot).
    const arr_ty = self.typeOf(args[0]) orelse {
        try self.unsupported(args[0].span(), "`Vec.from` expects a fixed-array argument");
        return;
    };
    if (arr_ty.* != .array) {
        try self.unsupported(args[0].span(), "`Vec.from` expects a fixed-array argument");
        return;
    }
    // @as: array count fits u16 (bounded by the i8 frame cap on the source).
    const n: u16 = @intCast(arr_ty.array.len);
    const bytes: u16 = n *% ew;
    try isa.movImmToReg(self, bytes, Reg.acu);
    try emitAlloc(self, Reg.acu); // acu = buffer ptr
    try isa.pushReg(self, Reg.acu); // [sp] = buffer ptr
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.acu); // acu = buffer ptr (dest)
    try value_struct.emitAggregateStoreInto(self, args[0], arr_ty, Reg.acu); // array → [buffer]
    try isa.popReg(self, Reg.r2); // r2 = buffer ptr
    try frameAddr(self, dest_ofs, Reg.r1); // r1 = header addr
    try class.emitWordStoreAtOffset(self, Reg.r1, ptr_ofs, Reg.r2);
    try isa.movImmToReg(self, n, Reg.acu);
    try class.emitWordStoreAtOffset(self, Reg.r1, len_ofs, Reg.acu);
    try class.emitWordStoreAtOffset(self, Reg.r1, cap_ofs, Reg.acu);
}

/// Materialize a `recv.slice(a, b)` borrowed view into the frame slot at
/// `dest_ofs`: a new header aliasing the parent's buffer (`ptr = parent.ptr
/// + a*ew`, `len = cap = b - a`). Mutating the slice mutates the parent.
pub fn emitSliceInto(self: *Emitter, recv: *const ast.Expr, a: *const ast.Expr, b: *const ast.Expr, elem: *const Type, dest_ofs: i16) error{OutOfMemory}!void {
    const ew = self.widthOfType(elem);
    try self.emitExpr(b); // acu = b
    try isa.pushReg(self, Reg.acu); // [sp] = b
    try self.emitExpr(a); // acu = a
    try isa.pushReg(self, Reg.acu); // [sp] = a, [sp+2] = b
    // new ptr = parent.ptr + a*ew.
    try headerAddr(self, recv, Reg.r1); // r1 = parent header addr
    try class.emitWordLoadAtOffset(self, Reg.r1, ptr_ofs, Reg.r2); // r2 = parent ptr
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.acu); // acu = a
    try scaleBytes(self, Reg.acu, ew); // acu = a*ew
    try isa.addRegToAcu(self, Reg.r2); // acu = parent.ptr + a*ew
    try isa.movRegToReg(self, Reg.acu, Reg.r3); // r3 = new ptr
    // new len = cap = b - a.
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.acu); // acu = b
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = a
    try isa.subRegFromAcu(self, Reg.r1); // acu = b - a
    try isa.movRegToReg(self, Reg.acu, Reg.r2); // r2 = len
    try frameAddr(self, dest_ofs, Reg.r1); // r1 = header addr
    try class.emitWordStoreAtOffset(self, Reg.r1, ptr_ofs, Reg.r3);
    try class.emitWordStoreAtOffset(self, Reg.r1, len_ofs, Reg.r2);
    try class.emitWordStoreAtOffset(self, Reg.r1, cap_ofs, Reg.r2);
    try isa.addImmToReg(self, 4, Reg.sp); // drop a, b
}

/// Materialize `recv.pop()` — a `T?` — into the frame slot at `dest_ofs`:
/// when `len > 0`, `{present: 1, value: buf[len-1]}` and `len -= 1`; else
/// `{present: 0, value: 0}`. Scalar element types only (the 4-byte tagged
/// optional); pointer-element pop awaits the pointer-optional path.
pub fn emitPopInto(self: *Emitter, recv: *const ast.Expr, elem: *const Type, dest_ofs: i16) error{OutOfMemory}!void {
    const ew = self.widthOfType(elem);
    try headerAddr(self, recv, Reg.acu);
    try isa.pushReg(self, Reg.acu); // [sp] = vec header addr
    try class.emitWordLoadAtOffset(self, Reg.acu, len_ofs, Reg.r2); // r2 = len
    try isa.cmpRegImm(self, Reg.r2, 0);
    const empty = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    // Present: len -= 1; value = buf[len].
    try isa.subImmFromReg(self, 1, Reg.r2); // r2 = len - 1 (the popped index + new len)
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = vec header
    try class.emitWordStoreAtOffset(self, Reg.r1, len_ofs, Reg.r2); // len = len - 1
    try isa.movRegToReg(self, Reg.r2, Reg.acu); // acu = index
    try value_struct.scaleIndex(self, Reg.acu, ew); // acu = index * ew
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = vec header
    try class.emitWordLoadAtOffset(self, Reg.r1, ptr_ofs, Reg.r1); // r1 = buffer ptr
    try isa.addRegToAcu(self, Reg.r1); // acu = &buf[index]
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = element addr
    try loadElem(self, Reg.r1, elem); // acu = popped value
    try storeOptional(self, dest_ofs, 1, Reg.acu);
    const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    // Empty: {present: 0, value: 0}.
    try isa.patchJumpTo(self, empty, try self.currentOffset());
    try isa.movImmToReg(self, 0, Reg.acu);
    try storeOptional(self, dest_ofs, 0, Reg.acu);
    try isa.patchJumpTo(self, done, try self.currentOffset());
    try isa.addImmToReg(self, 2, Reg.sp); // drop vec header addr
}

/// Materialize `recv.get(i)` — a `T?` — into `[fp + dest_ofs]`: when
/// `i < len`, `{1, buf[i]}`; else `{0, 0}`. Scalar element types only.
pub fn emitGetInto(self: *Emitter, recv: *const ast.Expr, idx: *const ast.Expr, elem: *const Type, dest_ofs: i16) error{OutOfMemory}!void {
    const ew = self.widthOfType(elem);
    try headerAddr(self, recv, Reg.acu);
    try isa.pushReg(self, Reg.acu); // [sp] = vec header
    try self.emitExpr(idx); // acu = index (sp-neutral)
    try isa.pushReg(self, Reg.acu); // [sp] = index, [sp+2] = header
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.r1); // r1 = header
    try class.emitWordLoadAtOffset(self, Reg.r1, len_ofs, Reg.r2); // r2 = len
    try isa.cmpRegReg(self, Reg.acu, Reg.r2); // index - len; C=0 ⇒ index >= len
    const absent = try isa.emitJumpPlaceholder(self, Op.jcc_addr); // index >= len → None
    // Present: value = buf[index].
    try value_struct.scaleIndex(self, Reg.acu, ew); // acu = index*ew
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.r1); // r1 = header
    try class.emitWordLoadAtOffset(self, Reg.r1, ptr_ofs, Reg.r1); // r1 = buffer ptr
    try isa.addRegToAcu(self, Reg.r1); // acu = &buf[index]
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try loadElem(self, Reg.r1, elem); // acu = value
    try storeOptional(self, dest_ofs, 1, Reg.acu);
    const done = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, absent, try self.currentOffset());
    try isa.movImmToReg(self, 0, Reg.acu);
    try storeOptional(self, dest_ofs, 0, Reg.acu);
    try isa.patchJumpTo(self, done, try self.currentOffset());
    try isa.addImmToReg(self, 4, Reg.sp); // drop index + header
}

/// Materialize an optional-producing expression into the frame slot at
/// `dest_ofs`: `v.pop()` / `v.get(i)` (the producers), `nil` (absent), or
/// another optional value (byte-copied). `inner` is the element type.
pub fn emitOptionalInto(self: *Emitter, src: *const ast.Expr, inner: *const Type, dest_ofs: i16) error{OutOfMemory}!void {
    if (src.* == .method_call) {
        const mc = src.method_call;
        if (elemOf(self, mc.receiver) != null) {
            const m = self.source[mc.method.start..mc.method.end];
            if (std.mem.eql(u8, m, "pop")) return emitPopInto(self, mc.receiver, inner, dest_ofs);
            if (std.mem.eql(u8, m, "get")) return emitGetInto(self, mc.receiver, mc.args[0], inner, dest_ofs);
        }
    }
    if (src.* == .nil_lit) {
        try isa.movImmToReg(self, 0, Reg.acu);
        try storeOptional(self, dest_ofs, 0, Reg.acu);
        return;
    }
    // Another optional value — byte-copy its header.
    try self.emitExpr(src); // acu = source optional address
    try isa.movRegToReg(self, Reg.acu, Reg.r1);
    try frameAddr(self, dest_ofs, Reg.r2);
    const w: u16 = if (codegen.Emitter.isScalarOptional(inner)) codegen.Emitter.opt_scalar_size else 2;
    try value_struct.copyBytes(self, Reg.r1, Reg.r2, w);
}

/// Store a scalar optional `{present, value}` into the 4-byte slot at
/// `[fp + dest_ofs]` (`value` ignored when `present == 0`).
fn storeOptional(self: *Emitter, dest_ofs: i16, present: u16, value_reg: u8) error{OutOfMemory}!void {
    try isa.movRegToReg(self, value_reg, Reg.r2); // r2 = value (before frameAddr clobbers regs)
    try frameAddr(self, dest_ofs, Reg.r1); // r1 = optional header addr
    try isa.movImmToReg(self, present, Reg.acu);
    try class.emitWordStoreAtOffset(self, Reg.r1, codegen.Emitter.opt_present_ofs, Reg.acu);
    try class.emitWordStoreAtOffset(self, Reg.r1, codegen.Emitter.opt_value_ofs, Reg.r2);
}

// ---- instance methods — receiver evaluates to the header's base address ----

/// Lower `recv.<method>(args)` for a Vec receiver of element type `elem`.
pub fn emitMethod(self: *Emitter, recv: *const ast.Expr, method: []const u8, args: []const *ast.Expr, elem: *const Type) error{OutOfMemory}!void {
    const ew = self.widthOfType(elem);
    if (std.mem.eql(u8, method, "len")) {
        try headerAddr(self, recv, Reg.r1);
        try class.emitWordLoadAtOffset(self, Reg.r1, len_ofs, Reg.acu);
        return;
    }
    if (std.mem.eql(u8, method, "cap")) {
        try headerAddr(self, recv, Reg.r1);
        try class.emitWordLoadAtOffset(self, Reg.r1, cap_ofs, Reg.acu);
        return;
    }
    if (std.mem.eql(u8, method, "clear")) {
        try headerAddr(self, recv, Reg.r1);
        try isa.movImmToReg(self, 0, Reg.acu);
        try class.emitWordStoreAtOffset(self, Reg.r1, len_ofs, Reg.acu);
        return;
    }
    if (std.mem.eql(u8, method, "at")) {
        try emitIndexLoad(self, recv, args[0], elem);
        return;
    }
    if (std.mem.eql(u8, method, "set")) {
        try emitIndexStore(self, recv, args[0], args[1], elem);
        return;
    }
    if (std.mem.eql(u8, method, "push")) {
        try emitPush(self, recv, args[0], ew);
        return;
    }
    if (std.mem.eql(u8, method, "slice")) {
        // A `slice` returns a new Vec value — only lowered when its result
        // binds to a `let` (which routes through `emitSliceInto`).
        try self.unsupported(recv.span(), "`Vec.slice` result must bind to a `let`");
        return;
    }
    try self.unsupported(recv.span(), "this Vec method");
}

/// `acu = &element[idx]` of the Vec at `recv`, debug-bounds-trapped against
/// `len` ($02). Clobbers r1 / r3 / acu; balances its own stack use.
pub fn emitElemAddr(self: *Emitter, recv: *const ast.Expr, idx_expr: *const ast.Expr, ew: u16) error{OutOfMemory}!void {
    try headerAddr(self, recv, Reg.acu); // acu = header addr
    try isa.pushReg(self, Reg.acu); // [sp] = header addr
    try self.emitExpr(idx_expr); // acu = index (sp-neutral)
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = header
    try class.emitWordLoadAtOffset(self, Reg.r1, len_ofs, Reg.r1); // r1 = len
    try overflow.emitBoundsTrapReg(self, Reg.acu, Reg.r1); // trap idx >= len
    try value_struct.scaleIndex(self, Reg.acu, ew); // acu = idx * ew
    try isa.popReg(self, Reg.r1); // r1 = header addr
    try class.emitWordLoadAtOffset(self, Reg.r1, ptr_ofs, Reg.r1); // r1 = buffer ptr
    try isa.addRegToAcu(self, Reg.r1); // acu = ptr + idx*ew
}

/// `v[idx]` load — leaves the element value in `acu` (`at` / index-read).
pub fn emitIndexLoad(self: *Emitter, recv: *const ast.Expr, idx: *const ast.Expr, elem: *const Type) error{OutOfMemory}!void {
    try emitElemAddr(self, recv, idx, self.widthOfType(elem)); // acu = &elem
    try loadElem(self, Reg.acu, elem);
}

/// `v[idx] = val` store (`set` / index-write).
pub fn emitIndexStore(self: *Emitter, recv: *const ast.Expr, idx: *const ast.Expr, val: *const ast.Expr, elem: *const Type) error{OutOfMemory}!void {
    const ew = self.widthOfType(elem);
    try self.emitExpr(val); // acu = value
    try isa.pushReg(self, Reg.acu); // [sp] = value
    try emitElemAddr(self, recv, idx, ew); // acu = &elem (balances its own stack)
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = &elem
    try isa.popReg(self, Reg.r2); // r2 = value
    try storeElem(self, Reg.r1, ew, Reg.r2);
}

fn emitPush(self: *Emitter, recv: *const ast.Expr, val_expr: *const ast.Expr, ew: u16) error{OutOfMemory}!void {
    try self.emitExpr(val_expr); // acu = value
    try isa.pushReg(self, Reg.acu); // value → [sp+2] after the header push
    try headerAddr(self, recv, Reg.acu);
    try isa.pushReg(self, Reg.acu); // [sp] = header addr
    // Grow when len == cap.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = header
    try class.emitWordLoadAtOffset(self, Reg.r1, len_ofs, Reg.r2); // r2 = len
    try class.emitWordLoadAtOffset(self, Reg.r1, cap_ofs, Reg.r3); // r3 = cap
    try isa.cmpRegReg(self, Reg.r2, Reg.r3);
    const skip_grow = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try emitGrow(self, ew); // header stays at [sp+0]; updates ptr + cap
    try isa.patchJumpTo(self, skip_grow, try self.currentOffset());
    // Store value at &buffer[len].
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = header
    try class.emitWordLoadAtOffset(self, Reg.r1, len_ofs, Reg.acu); // acu = len
    try value_struct.scaleIndex(self, Reg.acu, ew); // acu = len*ew
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = header (re-derive)
    try class.emitWordLoadAtOffset(self, Reg.r1, ptr_ofs, Reg.r2); // r2 = ptr
    try isa.addRegToAcu(self, Reg.r2); // acu = &slot
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // r1 = &slot
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.r2); // r2 = value
    try storeElem(self, Reg.r1, ew, Reg.r2);
    // len += 1.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1);
    try class.emitWordLoadAtOffset(self, Reg.r1, len_ofs, Reg.r2);
    try isa.addImmToReg(self, 1, Reg.r2);
    try class.emitWordStoreAtOffset(self, Reg.r1, len_ofs, Reg.r2);
    try isa.addImmToReg(self, 4, Reg.sp); // drop header + value
}

/// Grow the Vec whose header address is at `[sp + 0]`: new_cap =
/// max(1, cap*2); alloc; copy `len*ew` bytes; write back ptr + cap. The
/// header stays at `[sp + 0]` on exit (the temporaries are dropped).
fn emitGrow(self: *Emitter, ew: u16) error{OutOfMemory}!void {
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = header
    try class.emitWordLoadAtOffset(self, Reg.r1, cap_ofs, Reg.r2); // r2 = cap
    // new_cap = cap == 0 ? 1 : cap*2.
    try isa.cmpRegImm(self, Reg.r2, 0);
    const nonzero = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.movImmToReg(self, 1, Reg.r2);
    const have_cap = try isa.emitJumpPlaceholder(self, Op.jmp_addr);
    try isa.patchJumpTo(self, nonzero, try self.currentOffset());
    try isa.shlRegImm(self, Reg.r2, 1); // cap * 2
    try isa.patchJumpTo(self, have_cap, try self.currentOffset());
    try isa.pushReg(self, Reg.r2); // [sp] = new_cap; header now [sp+2]
    // Allocate new_cap * ew bytes.
    try isa.movRegToReg(self, Reg.r2, Reg.acu);
    try scaleBytes(self, Reg.acu, ew);
    try emitAlloc(self, Reg.acu); // acu = new buffer
    try isa.pushReg(self, Reg.acu); // [sp]=new_ptr; [sp+2]=new_cap; [sp+4]=header
    // Copy len*ew bytes from old ptr to new ptr.
    try isa.movRegOffsetToReg(self, Reg.sp, 4, Reg.r1); // r1 = header
    try class.emitWordLoadAtOffset(self, Reg.r1, len_ofs, Reg.acu); // acu = len
    try scaleBytes(self, Reg.acu, ew); // acu = len*ew
    try isa.movRegToReg(self, Reg.acu, Reg.r3); // r3 = byte count
    try isa.movRegOffsetToReg(self, Reg.sp, 4, Reg.r1); // r1 = header
    try class.emitWordLoadAtOffset(self, Reg.r1, ptr_ofs, Reg.r2); // r2 = old ptr
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1); // r1 = new ptr
    try isa.bcpy(self, Reg.r1, Reg.r2, Reg.r3); // dst, src, len
    // header.ptr = new ptr; header.cap = new_cap.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r2); // r2 = new ptr
    try isa.movRegOffsetToReg(self, Reg.sp, 2, Reg.r3); // r3 = new_cap
    try isa.movRegOffsetToReg(self, Reg.sp, 4, Reg.r1); // r1 = header
    try class.emitWordStoreAtOffset(self, Reg.r1, ptr_ofs, Reg.r2);
    try class.emitWordStoreAtOffset(self, Reg.r1, cap_ofs, Reg.r3);
    try isa.addImmToReg(self, 4, Reg.sp); // drop new_ptr + new_cap
}

// ---- shared element load / store ----

fn loadElem(self: *Emitter, addr_reg: u8, elem: *const Type) error{OutOfMemory}!void {
    if (self.widthOfType(elem) == 1) {
        try class.emitByteLoadAtOffset(self, addr_reg, 0, Reg.acu);
        if (elem.* == .primitive and elem.primitive == .i8) try isa.signExtendByte(self, Reg.acu);
    } else {
        try class.emitWordLoadAtOffset(self, addr_reg, 0, Reg.acu);
    }
}

fn storeElem(self: *Emitter, addr_reg: u8, ew: u16, src: u8) error{OutOfMemory}!void {
    if (ew == 1) {
        try class.emitByteStoreAtOffset(self, addr_reg, 0, src);
    } else {
        try class.emitWordStoreAtOffset(self, addr_reg, 0, src);
    }
}

fn headerAddr(self: *Emitter, recv: *const ast.Expr, reg: u8) error{OutOfMemory}!void {
    try self.emitExpr(recv); // acu = header base address (a Vec value is its address)
    if (reg != Reg.acu) try isa.movRegToReg(self, Reg.acu, reg);
}

fn emitAlloc(self: *Emitter, size_reg: u8) error{OutOfMemory}!void {
    if (size_reg != Reg.acu) try isa.movRegToReg(self, size_reg, Reg.acu);
    try self.emitByte(Op.sys);
    try self.emitByte(opcodes.Sys.alloc);
}

/// `reg = reg * ew` — an element count to a byte count (reuses the array
/// index scaler).
fn scaleBytes(self: *Emitter, reg: u8, ew: u16) error{OutOfMemory}!void {
    try value_struct.scaleIndex(self, reg, ew);
}

fn frameAddr(self: *Emitter, ofs: i16, reg: u8) error{OutOfMemory}!void {
    try isa.movRegToReg(self, Reg.fp, reg);
    if (ofs < 0) {
        try isa.subImmFromReg(self, @intCast(-ofs), reg);
    } else if (ofs > 0) {
        try isa.addImmToReg(self, @intCast(ofs), reg);
    }
}
