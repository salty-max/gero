const std = @import("std");
const ast = @import("../ast.zig");
const codegen = @import("../codegen.zig");
const opcodes = @import("opcodes.zig");
const isa = @import("isa.zig");
const archive = @import("archive.zig");
const class = @import("class.zig");

const Emitter = codegen.Emitter;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

/// Bytes reserved per interpolated-string buffer in the data
/// region. Sized for the worst common case (a few interp values
/// + surrounding literal text). Programs that need larger
/// interpolations should compose with explicit concatenation —
/// the codegen rejects the formatted result at runtime if it
/// overflows (the VM doesn't bounds-check the buffer writes).
pub const interp_buffer_size: u16 = 64;

/// One interned string literal — emitted as a null-terminated
/// byte run at the end of the base image. Multiple call sites
/// that reference the same byte content share one entry; the
/// `address` field carries the resolved RAM address after the
/// pool emits.
pub const InternedString = struct {
    bytes: []const u8,
    address: u16,
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
    // address them (banks only cover `0xC000..0xFEFF`). Save +
    // restore the buffer-routing so callers in a banked def
    // still emit into the base buffer here.
    const saved_bank = self.current_bank;
    self.current_bank = null;
    defer self.current_bank = saved_bank;

    for (self.strings.items) |*s| {
        // @as: usize → u16; base image fits in 16-bit address space.
        const offset: u16 = @intCast(try self.currentOffset());
        s.address = codegen.code_base +% offset;
        for (s.bytes) |b| try self.emitByte(b);
        try self.emitByte(0);
    }
}

/// Rewrite each `StringPatch`'s 2-byte LE address slot with the
/// resolved string address.
pub fn patchStrings(self: *Emitter) !void {
    for (self.string_patches.items) |p| {
        const addr = self.strings.items[p.string_id].address;
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
    try self.strings.append(self.allocator, .{ .bytes = owned, .address = 0 });
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

/// Lower a `str_lit` at expression position. Single-literal
/// strings load the pooled address directly into `acu`.
/// Interpolated strings allocate a fixed-size buffer in the
/// data region and emit the `format_*_to_buf` syscall sequence
/// that fills it.
pub fn emitStrLitExpr(self: *Emitter, sl: ast.StrLitExpr) !void {
    if (sl.parts.len == 1 and sl.parts[0] == .lit) {
        const span = sl.parts[0].lit.span;
        const raw = self.source[span.start..span.end];
        const decoded = try archive.decodeStringEscapes(self.arena, raw);
        const id = try internString(self, decoded);
        try emitMovStringAddrToReg(self, id, Reg.acu);
        return;
    }

    const buf_addr = reserveInterpBuffer(self, sl.span) orelse {
        // Diagnostic already emitted; produce a valid placeholder
        // so downstream codegen doesn't see a bad acu shape.
        try isa.movImmToReg(self, 0, Reg.acu);
        return;
    };

    // r1 holds the moving write cursor. Initialize it to the
    // buffer's base address.
    try isa.movImmToReg(self, buf_addr, Reg.r1);
    try emitInterpFill(self, sl);
    try isa.sys(self, Sys.format_terminate_buf);
    try isa.movImmToReg(self, buf_addr, Reg.acu);
}

/// Reserve `interp_buffer_size` bytes at the top of the data
/// region for one interpolated-string site. Returns the
/// buffer's base address. Emits `E_CODEGEN_DATA_OVERFLOW` and
/// `null` when the data region (capped at the MMIO line) would
/// overflow.
pub fn reserveInterpBuffer(self: *Emitter, site_span: ast.Span) ?u16 {
    const base = self.data_cursor;
    // @as: widen u16 → u32 so the overflow check doesn't itself wrap.
    const next: u32 = @as(u32, self.data_cursor) + interp_buffer_size;
    if (next > 0xFE40) {
        self.diagFatal(site_span, "E_CODEGEN_DATA_OVERFLOW", "static-data region exhausted — too many interpolated string sites") catch return null;
        return null;
    }
    // @as: bounded by the > 0xFE40 check above; result fits u16.
    self.data_cursor = @intCast(next);
    return base;
}

/// Emit one `format_*_to_buf` syscall per `sl.parts` entry. `r1`
/// must hold the buffer cursor on entry and holds the
/// post-write cursor on exit. Saves / restores `r1` around
/// interp-expression evaluation so the stack-machine pattern's
/// scratch use of `r1` doesn't trash the cursor.
pub fn emitInterpFill(self: *Emitter, sl: ast.StrLitExpr) !void {
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
            if (ip.format_spec != null) {
                try self.unsupported(ip.span, "`$(expr:fmt)` format specs");
                return;
            }
            // Save the cursor — the interp-expression eval may
            // pop into r1 as scratch.
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
                try isa.sys(self, Sys.format_int_to_buf);
            }
        },
    };
}

/// Walk a string literal's parts inside `print`, emitting the
/// per-part syscall for each. Zero-alloc per spec §4.9: no
/// runtime buffer materializes — each part writes to `host.out`
/// directly. The interpolated value's type drives the syscall
/// pick (same dispatch as `emitPrintArg` for non-literal args).
pub fn emitPrintStrLit(self: *Emitter, sl: ast.StrLitExpr) !void {
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
            if (self.isPrimitiveType(ip.expr, .char)) {
                try self.emitExpr(ip.expr);
                try isa.sys(self, Sys.print_char);
            } else if (self.isPrimitiveType(ip.expr, .fixed)) {
                try self.emitExpr(ip.expr);
                try isa.sys(self, Sys.print_fixed);
            } else if (self.isPrimitiveType(ip.expr, .str)) {
                try self.emitExpr(ip.expr);
                try isa.sys(self, Sys.print_str);
            } else {
                try self.emitExpr(ip.expr);
                try isa.sys(self, Sys.print_int);
            }
        },
    };
}
