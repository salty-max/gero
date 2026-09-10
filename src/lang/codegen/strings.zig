const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const archive = @import("archive.zig");
const class = @import("class.zig");
const statements = @import("statements.zig");
const fmtspec = @import("../fmtspec.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// Bytes allocated per interpolated-string evaluation. Sized for the
/// worst common case (a few interp values + surrounding literal text).
/// Programs that need larger interpolations should compose with explicit
/// concatenation — the VM doesn't bounds-check the buffer writes, so an
/// over-long fill silently runs past the allocation.
pub const interp_buffer_size: u16 = 64;

/// One interned string literal — emitted as a null-terminated
/// byte run at the end of the base image. Multiple call sites
/// that reference the same byte content share one entry; the
/// `ref` field carries its position in the pool, which the link
/// step resolves to an address.
pub const InternedString = struct {
    bytes: []const u8,
    ref: codegen.CodeRef,
};

/// Forward reference to a string literal — recorded when an
/// emit site needs to load the string's address into a register
/// but the pool hasn't been laid out yet. The `code_offset` is
/// the 2-byte `mov imm16, reg` operand slot waiting for the
/// resolved address.
pub const StringPatch = struct {
    bank: ?u8,
    code_offset: usize,
    string_id: usize,
};

/// Lay out every interned string at the end of the base buffer.
/// Each entry gets its bytes plus a trailing null terminator
/// (the VM's `print_str` syscall reads until `\0`). Records the
/// resolved address into the pool entry.
pub fn emitStringPool(self: *Emitter) !void {
    // Strings live in the base image so banked code can still
    // address them (banks only cover the window). Save +
    // restore the buffer-routing so callers in a banked def
    // still emit into the base buffer here.
    const saved_bank = self.current_bank;
    self.current_bank = null;
    defer self.current_bank = saved_bank;

    for (self.strings.items) |*s| {
        s.ref = .{ .bank = null, .offset = try self.currentOffset() };
        for (s.bytes) |b| try self.emitByte(b);
        try self.emitByte(0);
    }
}

/// Rewrite each `StringPatch`'s 2-byte LE address slot with the
/// resolved string address.
pub fn patchStrings(self: *Emitter) !void {
    for (self.string_patches.items) |p| {
        const addr = self.strings.items[p.string_id].ref.addr();
        const buf: []u8 = if (p.bank) |b|
            if (self.banks.getPtr(b)) |bl| bl.items else continue
        else
            self.code.items;
        // safety: u16 → 2 bytes by definition; byte-mask casts.
        buf[p.code_offset] = @intCast(addr & 0xFF);
        buf[p.code_offset + 1] = @intCast(addr >> 8);
    }
}

/// Intern a byte string by content. Returns the index into
/// `Emitter.strings`. Callers that need the address use a
/// `StringPatch` since the pool isn't laid out until the end of
/// `emitProgram`.
pub fn internString(self: *Emitter, bytes: []const u8) !usize {
    for (self.strings.items, 0..) |s, i| {
        if (std.mem.eql(u8, s.bytes, bytes)) return i;
    }
    const owned = try self.arena.dupe(u8, bytes);
    try self.strings.append(self.allocator, .{ .bytes = owned, .ref = .{ .bank = null, .offset = 0 } });
    return self.strings.items.len - 1;
}

/// Emit a `mov imm16, reg` whose imm is the resolved address
/// of the interned string with index `string_id`. The imm slot
/// is recorded as a `StringPatch` and back-patched after the
/// pool lays out.
pub fn emitMovStringAddrToReg(self: *Emitter, string_id: usize, reg: u8) !void {
    try self.emitByte(Op.mov_imm16_reg);
    const slot = try self.currentOffset();
    try self.emitU16Le(0); // placeholder
    try self.emitByte(reg);
    try self.string_patches.append(self.allocator, .{
        .bank = self.current_bank,
        .code_offset = slot,
        .string_id = string_id,
    });
}

/// Compare two null-terminated strings by content (§3.2.1 —
/// lexicographic, byte-wise equality), leaving `1`/`0` in `acu`
/// (`negate` selects `!=`). `p1` and `p2` hold the string pointers and
/// are advanced (consumed); `acu` and `r3` are byte scratch — neither
/// may be passed as `p1`/`p2`.
pub fn emitContentEq(self: *Emitter, p1: u8, p2: u8, negate: bool) !void {
    // Walk both strings in lockstep: a differing byte is not-equal;
    // reaching the shared null terminator is equal.
    const loop_start = try self.currentOffset();
    try class.emitByteLoadAtOffset(self, p1, 0, Reg.acu);
    try class.emitByteLoadAtOffset(self, p2, 0, Reg.r3);
    try isa.cmpRegReg(self, Reg.acu, Reg.r3);
    const ne_patch = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.cmpRegImm(self, Reg.acu, 0);
    const eq_patch = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try isa.addImmToReg(self, 1, p1);
    try isa.addImmToReg(self, 1, p2);
    try isa.emitJumpBack(self, loop_start);

    // Equal arm.
    try isa.patchJumpTo(self, eq_patch, try self.currentOffset());
    try isa.movImmToReg(self, if (negate) 0 else 1, Reg.acu);
    const end_patch = try isa.emitJumpPlaceholder(self, Op.jmp_addr);

    // Not-equal arm.
    try isa.patchJumpTo(self, ne_patch, try self.currentOffset());
    try isa.movImmToReg(self, if (negate) 1 else 0, Reg.acu);

    try isa.patchJumpTo(self, end_patch, try self.currentOffset());
}

/// Lexicographic byte compare of two `str` values (§3.2.1): walks `p1` /
/// `p2` in lockstep and leaves a strcmp-style result in `acu` — negative
/// when `p1 < p2`, `0` when equal, positive when `p1 > p2`. The caller
/// turns that into the `< / <= / > / >=` boolean via `cmp acu, 0` +
/// `materializeBoolFromFlags`. Bytes are zero-extended (always `0..255`,
/// non-negative), so the signed subtraction orders them as unsigned and
/// the shared null terminator (`0`) sorts before any byte — a prefix is
/// less than its extension. `p1` / `p2` / `r3` are scratch.
pub fn emitStrCmp(self: *Emitter, p1: u8, p2: u8) error{OutOfMemory}!void {
    const loop = try self.currentOffset();
    try class.emitByteLoadAtOffset(self, p1, 0, Reg.acu); // a
    try class.emitByteLoadAtOffset(self, p2, 0, Reg.r3); // b
    try isa.cmpRegReg(self, Reg.acu, Reg.r3);
    const differ = try isa.emitJumpPlaceholder(self, Op.jne_addr);
    try isa.cmpRegImm(self, Reg.acu, 0); // equal bytes — at the shared null?
    const end = try isa.emitJumpPlaceholder(self, Op.jeq_addr); // → acu already 0
    try isa.addImmToReg(self, 1, p1);
    try isa.addImmToReg(self, 1, p2);
    try isa.emitJumpBack(self, loop);
    // First differing byte: acu = a - b carries the ordering.
    try isa.patchJumpTo(self, differ, try self.currentOffset());
    try isa.subRegFromAcu(self, Reg.r3);
    try isa.patchJumpTo(self, end, try self.currentOffset());
}

/// Concatenate two `str` values into a fresh heap buffer (§3.2.1): `a` /
/// `b` hold the operand pointers. Computes `len(a) + len(b) + 1`,
/// `alloc`s it, copies `a` then `b`, null-terminates, and leaves the new
/// buffer's address in `acu`. The pointers are parked on the stack and
/// reloaded, since the strlen / copy loops + `alloc` churn the scratch
/// registers. (Needs a heap — `alloc` faults `heap_exhausted` otherwise,
/// like every allocating construct.)
pub fn emitStrConcat(self: *Emitter, a: u8, b: u8) error{OutOfMemory}!void {
    try isa.pushReg(self, a); // lhs ptr at [sp + 2]
    try isa.pushReg(self, b); // rhs ptr at [sp + 0]

    // total = len(lhs) + len(rhs) + 1 (terminator), accumulated in r2.
    try isa.movImmToReg(self, 0, Reg.r2);
    try emitStrlenAdd(self, 2, Reg.r2);
    try emitStrlenAdd(self, 0, Reg.r2);
    try isa.addImmToReg(self, 1, Reg.r2);

    // alloc(total) → acu = dst; park it above the two operand pointers.
    try isa.movRegToReg(self, Reg.r2, Reg.acu);
    try isa.sys(self, Sys.alloc);
    try isa.pushReg(self, Reg.acu); // dst [sp+0]; rhs [sp+2]; lhs [sp+4]

    // Copy lhs then rhs into the buffer; r1 is the running dst cursor.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.r1);
    try emitStrCopy(self, 4, Reg.r1); // lhs
    try emitStrCopy(self, 2, Reg.r1); // rhs
    try isa.movImmToReg(self, 0, Reg.acu); // null-terminate at the cursor
    try class.emitByteStoreAtOffset(self, Reg.r1, 0, Reg.acu);

    // Result = the buffer base; drop the three parked pointers.
    try isa.movRegOffsetToReg(self, Reg.sp, 0, Reg.acu);
    try isa.addImmToReg(self, 6, Reg.sp);
}

/// Walk the null-terminated string parked at `[sp + ofs]`, adding its
/// length (excluding the terminator) to `counter`. `acu` + `r3` scratch.
fn emitStrlenAdd(self: *Emitter, ofs: i8, counter: u8) error{OutOfMemory}!void {
    try isa.movRegOffsetToReg(self, Reg.sp, ofs, Reg.r3);
    const loop = try self.currentOffset();
    try class.emitByteLoadAtOffset(self, Reg.r3, 0, Reg.acu);
    try isa.cmpRegImm(self, Reg.acu, 0);
    const done = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try isa.addImmToReg(self, 1, counter);
    try isa.addImmToReg(self, 1, Reg.r3);
    try isa.emitJumpBack(self, loop);
    try isa.patchJumpTo(self, done, try self.currentOffset());
}

/// Copy the null-terminated string parked at `[sp + ofs]` to `[dst]`
/// (excluding the terminator), advancing `dst`. `acu` + `r3` scratch.
fn emitStrCopy(self: *Emitter, ofs: i8, dst: u8) error{OutOfMemory}!void {
    try isa.movRegOffsetToReg(self, Reg.sp, ofs, Reg.r3);
    const loop = try self.currentOffset();
    try class.emitByteLoadAtOffset(self, Reg.r3, 0, Reg.acu);
    try isa.cmpRegImm(self, Reg.acu, 0);
    const done = try isa.emitJumpPlaceholder(self, Op.jeq_addr);
    try class.emitByteStoreAtOffset(self, dst, 0, Reg.acu);
    try isa.addImmToReg(self, 1, dst);
    try isa.addImmToReg(self, 1, Reg.r3);
    try isa.emitJumpBack(self, loop);
    try isa.patchJumpTo(self, done, try self.currentOffset());
}

/// Lower a `str_lit` at expression position. Single-literal
/// strings load the pooled address directly into `acu`.
/// Interpolated strings allocate a fresh heap buffer per evaluation
/// and emit the `format_*_to_buf` syscall sequence that fills it.
pub fn emitStrLitExpr(self: *Emitter, sl: ast.StrLitExpr) !void {
    if (sl.parts.len == 1 and sl.parts[0] == .lit) {
        const span = sl.parts[0].lit.span;
        const raw = self.source[span.start..span.end];
        const decoded = try archive.decodeStringEscapes(self.arena, raw);
        const id = try internString(self, decoded);
        try emitMovStringAddrToReg(self, id, Reg.acu);
        return;
    }

    // A fresh heap buffer per evaluation (§3.2.2) — distinct results,
    // including repeated evaluations of the same literal, never alias (a
    // static per-site buffer would let a later evaluation clobber an
    // earlier binding). `r1` is the moving write cursor; the base is
    // parked across the fill and becomes the result. `alloc` faults
    // `heap_exhausted` when the heap is full, like every allocating
    // construct; the fill itself isn't bounds-checked (`interp_buffer_size`).
    try isa.movImmToReg(self, interp_buffer_size, Reg.acu);
    try isa.sys(self, Sys.alloc); // acu = buffer base
    try isa.pushReg(self, Reg.acu);
    try isa.movRegToReg(self, Reg.acu, Reg.r1); // cursor starts at the base
    try emitInterpFill(self, sl);
    try isa.sys(self, Sys.format_terminate_buf);
    try isa.popReg(self, Reg.acu); // result = buffer base
}

/// Emit one `format_*_to_buf` syscall per `sl.parts` entry. `r1`
/// must hold the buffer cursor on entry and holds the
/// post-write cursor on exit. Saves / restores `r1` around
/// interp-expression evaluation so the stack-machine pattern's
/// scratch use of `r1` doesn't trash the cursor.
pub fn emitInterpFill(self: *Emitter, sl: ast.StrLitExpr) !void {
    // A scalar part keeps the cursor in `r1` (fast path). A non-scalar
    // part renders through the shared `emitRenderValue` machinery, which
    // needs `r1` for the value base — so its cursor lives in this
    // fp-relative slot, reserved on first use (and counted by
    // `countFrameBytes` for the prologue).
    var cursor_slot: ?i8 = null;
    for (sl.parts) |part| switch (part) {
        .lit => |lp| {
            const raw = self.source[lp.span.start..lp.span.end];
            if (raw.len == 0) continue;
            const decoded = try archive.decodeStringEscapes(self.arena, raw);
            const id = try internString(self, decoded);
            try emitMovStringAddrToReg(self, id, Reg.acu);
            try isa.sys(self, Sys.format_str_to_buf);
        },
        .interp => |ip| {
            if (ip.format_spec) |fs_span| {
                // `$(expr:fmt)` — format the scalar per the spec into the
                // buffer via `format_spec_to_buf` (the spec is a compile-time
                // literal; the typechecker has validated it).
                const spec = fmtspec.parse(self.source[fs_span.start..fs_span.end]) catch {
                    try self.unsupported(ip.span, "malformed `$(expr:fmt)` format spec");
                    return;
                };
                const params = packFormatSpec(self, ip.expr, spec);
                try isa.pushReg(self, Reg.r1); // save cursor across expr eval
                try self.emitExpr(ip.expr); // acu = value (str pointer for `s`)
                try isa.popReg(self, Reg.r1); // cursor back in r1
                try isa.movImmToReg(self, params.r2, Reg.r2);
                try isa.movImmToReg(self, params.r3, Reg.r3);
                try isa.sys(self, Sys.format_spec_to_buf);
                continue;
            }
            if (!self.interpFormattable(ip.expr)) {
                const slot = cursor_slot orelse blk: {
                    const s = self.reserveFrameSlot(2);
                    cursor_slot = s;
                    break :blk s;
                };
                try isa.movRegToRegOffset(self, Reg.r1, Reg.fp, slot); // park cursor
                try statements.emitRenderValue(self, ip.expr, .{ .buffer = slot });
                try isa.movRegOffsetToReg(self, Reg.fp, slot, Reg.r1); // reload cursor
                continue;
            }
            // Scalar fast path: save the cursor — the interp-expression
            // eval may pop into `r1` as scratch.
            try isa.pushReg(self, Reg.r1);
            try self.emitExpr(ip.expr);
            try isa.popReg(self, Reg.r1);

            if (self.isPrimitiveType(ip.expr, .char)) {
                try isa.sys(self, Sys.format_char_to_buf);
            } else if (self.isPrimitiveType(ip.expr, .fixed)) {
                try isa.sys(self, Sys.format_fixed_to_buf);
            } else if (self.isPrimitiveType(ip.expr, .str)) {
                try isa.sys(self, Sys.format_str_to_buf);
            } else {
                try isa.sys(self, if (self.isUnsignedInt(ip.expr)) Sys.format_uint_to_buf else Sys.format_int_to_buf);
            }
        },
    };
}

/// Pack `format_spec_to_buf`'s `r2` / `r3` params for `expr` formatted per
/// `spec`. The effective output type + signedness come from the value's
/// type when the spec leaves them implicit (no explicit type letter).
fn packFormatSpec(self: *Emitter, expr: *const ast.Expr, spec: fmtspec.Spec) struct { r2: u16, r3: u16 } {
    var signed = false;
    // Effective type code (the numeric codes are the `docs/isa.md` contract):
    // the explicit spec type, or the value's natural rendering.
    const type_code: u16 = switch (spec.ty) {
        .dec => blk: {
            signed = !self.isUnsignedInt(expr);
            break :blk 0;
        },
        .hex_lower => 1,
        .hex_upper => 2,
        .bin => 3,
        .oct => 4,
        .str => 5,
        .char => 6,
        .default => if (self.isPrimitiveType(expr, .char))
            6
        else if (self.isPrimitiveType(expr, .fixed))
            7
        else if (self.isPrimitiveType(expr, .str))
            5
        else dec: {
            signed = !self.isUnsignedInt(expr);
            break :dec 0;
        },
    };
    const align_code: u16 = switch (spec.alignment) {
        .default => 0,
        .left => 1,
        .right => 2,
        .center => 3,
    };
    var r3: u16 = type_code | (align_code << Sys.FmtSpec.align_shift);
    if (signed) r3 |= Sys.FmtSpec.flag_signed;
    if (spec.zero_pad) r3 |= Sys.FmtSpec.flag_zero_pad;
    if (spec.precision) |p| {
        r3 |= Sys.FmtSpec.flag_has_precision;
        // @as: widen the u8 precision into its r3 bit field.
        r3 |= @as(u16, p) << Sys.FmtSpec.precision_shift;
    }
    // @as: width + fill are u8 fields packed into the 16-bit r2 word.
    const r2: u16 = @as(u16, spec.width) | (@as(u16, spec.fill) << Sys.FmtSpec.fill_shift);
    return .{ .r2 = r2, .r3 = r3 };
}

/// Walk a string literal's parts inside `print`, emitting the
/// per-part syscall for each. Zero-alloc per spec §4.9: no
/// runtime buffer materializes — each part writes to `host.out`
/// directly. The interpolated value's type drives the syscall
/// pick (same dispatch as `emitPrintArg` for non-literal args).
pub fn emitPrintStrLit(self: *Emitter, sl: ast.StrLitExpr) !void {
    // A format spec needs the buffer formatter (`format_spec_to_buf` writes
    // to a cursor, not the host) — build the whole string in a heap buffer,
    // then print it once (vs the zero-alloc per-part host path below).
    for (sl.parts) |part| if (part == .interp and part.interp.format_spec != null) {
        try emitStrLitExpr(self, sl);
        try isa.sys(self, Sys.print_str);
        return;
    };
    for (sl.parts) |part| switch (part) {
        .lit => |lp| {
            const raw = self.source[lp.span.start..lp.span.end];
            if (raw.len == 0) continue;
            const decoded = try archive.decodeStringEscapes(self.arena, raw);
            const id = try internString(self, decoded);
            try emitMovStringAddrToReg(self, id, Reg.acu);
            try isa.sys(self, Sys.print_str);
        },
        .interp => |ip| {
            if (ip.format_spec != null) {
                try self.unsupported(ip.span, "`$(expr:fmt)` format specs");
                return;
            }
            // Render the value straight to the host (no buffer) — handles
            // scalars and aggregate default renderings (§4.9) alike.
            try statements.emitRenderValue(self, ip.expr, .host);
        },
    };
}
