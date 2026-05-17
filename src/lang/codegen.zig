/// Gero-lang codegen — typed AST → `.gx` bytecode image.
///
/// Direct emission (no asm intermediate per cli.md §3.2). Walks
/// the `CheckedProgram` from `typecheck.zig` and produces a `.gx`
/// archive ready for the VM loader (`gero.vm.parseGx`) per ISA §7.
///
/// **M1 scope** (this slice — codegen walking-skeleton):
/// instruction selection for the entry def's body — `let` /
/// `const`, integer literals, ident loads, binary arithmetic,
/// unary neg, `print int_expr`, `return`. Locals live in
/// fp-relative stack slots; expression evaluation uses
/// `acu` + `r1` with push/pop for spills. Calling convention
/// for free fns + memory-placement annotations land in
/// subsequent M1 commits.
const std = @import("std");
const ast = @import("ast.zig");
const typecheck_mod = @import("typecheck.zig");
const diag_mod = @import("diagnostic.zig");

const Diagnostic = diag_mod.Diagnostic;
const CheckedProgram = typecheck_mod.CheckedProgram;

// ---------- public constants (boot layout per ISA §7) ----------

/// IVT base address — first IVT slot lives at `0x1000`. Each slot
/// is 2 bytes; the spec reserves `0x1000..0x10FF` for the table.
pub const ivt_base: u16 = 0x1000;
/// First byte of code emission. The 0x0000..0x10FF range is
/// reserved for the IVT + low-RAM scratch.
pub const code_base: u16 = 0x1100;
/// First byte of static-data emission. Code grows up from
/// `code_base`; data grows up from here.
pub const data_base: u16 = 0x2000;

// ---------- .gx file constants ----------

const gx_magic = [4]u8{ 'G', 'E', 'R', 'O' };
const gx_version: u16 = 0x0001;
const gx_header_size: usize = 16;

// ---------- VM opcode + register byte values ----------
//
// Mirrored from `src/vm/opcodes.zig`. We don't import the VM module
// at compile time (keeps lang codegen self-contained) — when a
// new opcode lands there, this table needs the matching constant.

const Op = struct {
    const mov_imm16_reg: u8 = 0x10;
    const mov_reg_reg: u8 = 0x11;
    const mov_reg_offset_reg: u8 = 0x1C; // load:  reg ← [base + ofs]
    const mov_reg_reg_offset: u8 = 0x1D; // store: [base + ofs] ← reg

    const push_reg: u8 = 0x31;
    const pop_reg: u8 = 0x32;

    const add_imm16_reg: u8 = 0x40;
    const add_reg_acu: u8 = 0x42; // acu ← acu + reg
    const sub_imm16_reg: u8 = 0x43;
    const sub_reg_acu: u8 = 0x45; // acu ← acu - reg
    const mul_reg_reg: u8 = 0x47; // dst ← dst * src
    const neg_reg: u8 = 0x4A;
    const divs_reg_reg: u8 = 0x4E; // dst ← dst / src (signed)
    const mod_reg_reg: u8 = 0x50; // assumed name; not used in M1

    const sys: u8 = 0xFB;
    const hlt: u8 = 0xFF;
};

/// VM register byte values per `src/vm/registers.zig`.
const Reg = struct {
    const acu: u8 = 0x01;
    const r1: u8 = 0x02;
    const r2: u8 = 0x03;
    const sp: u8 = 0x0A;
    const fp: u8 = 0x0B;
};

/// `sys` syscall ids per `src/vm/handlers/system.zig::SyscallId`.
const Sys = struct {
    const print_str: u8 = 0x01;
    const print_int: u8 = 0x02;
    const print_char: u8 = 0x03;
    const print_newline: u8 = 0x04;
};

// ---------- public surface ----------

/// Codegen output. Owns the `.gx` image bytes + the diagnostic
/// slice.
pub const Compiled = struct {
    /// Full `.gx` archive, ready to feed to `gero.vm.parseGx`.
    image: []u8,
    diagnostics: []Diagnostic,
    allocator: std.mem.Allocator,

    /// Release the image buffer + diagnostics slice.
    pub fn deinit(self: *Compiled) void {
        self.allocator.free(self.image);
        self.allocator.free(self.diagnostics);
    }

    /// `true` when at least one fatal diagnostic fired.
    pub fn hasErrors(self: Compiled) bool {
        for (self.diagnostics) |d| if (d.severity == .fatal) return true;
        return false;
    }
};

/// Knobs for `compile`. Mirrors `gero.asm_.Options` so callers
/// can wrap both pipelines uniformly.
pub const Options = struct {
    /// Name of the top-level `def` to use as the program entry.
    /// Spec convention is `main`.
    entry_name: []const u8 = "main",
    /// When `true` reserves a flag bit + section for debug
    /// symbols (per ISA §7.3). Slice M1 doesn't emit the body yet.
    debug_symbols: bool = true,
};

/// Errors `compile` can return. Grammar / semantic errors land in
/// the returned `Compiled.diagnostics` slice — only true host
/// failures propagate here.
pub const CompileError = error{
    OutOfMemory,
    /// `Options.entry_name` doesn't resolve to a top-level `def`
    /// in the typechecked program.
    EntryNotFound,
    /// Codegen tried to lower an AST shape that this slice
    /// doesn't yet support. The unsupported feature shows up in
    /// the diagnostic slice with the offending span.
    UnsupportedFeature,
};

/// Walk a typechecked program and emit a `.gx` archive.
pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    checked: *const CheckedProgram,
    opts: Options,
) CompileError!Compiled {
    _ = opts.debug_symbols;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const entry = findEntryDef(source, checked.program, opts.entry_name) orelse return error.EntryNotFound;

    // Emit the entry def's body into a working buffer.
    var emitter: Emitter = .{
        .allocator = allocator,
        .arena = arena.allocator(),
        .source = source,
        .code = .empty,
        .locals = .{},
        .frame_bytes = 0,
        .diagnostics = &diagnostics,
    };
    defer emitter.code.deinit(allocator);

    try emitter.emitEntryBody(entry);

    // Build base image: zeros from 0x0000 up to `code_base`, then
    // the emitted bytes.
    // @as: widen u16 code_base to usize for the byte-length math (image stays ≤ 64 KiB by ISA).
    const total_image_bytes: usize = @as(usize, code_base) + emitter.code.items.len;
    var base_image = try allocator.alloc(u8, total_image_bytes);
    errdefer allocator.free(base_image);
    @memset(base_image, 0);
    @memcpy(base_image[code_base..][0..emitter.code.items.len], emitter.code.items);

    const image = try buildArchive(allocator, base_image, code_base);
    allocator.free(base_image);

    return .{
        .image = image,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ---------- entry resolution ----------

fn findEntryDef(source: []const u8, program: *const ast.Program, entry_name: []const u8) ?*const ast.DefDecl {
    for (program.statements) |*stmt| switch (stmt.*) {
        .def_decl => |*dd| {
            const name = source[dd.name.start..dd.name.end];
            if (std.mem.eql(u8, name, entry_name)) return dd;
        },
        else => {},
    };
    return null;
}

// ---------- Emitter ----------

/// Per-fn codegen state — owns the working bytecode buffer, the
/// local-slot table, and the diagnostic sink. The entry-def
/// emission path owns one Emitter; later M1 commits will create
/// a fresh Emitter per non-entry def too.
const Emitter = struct {
    allocator: std.mem.Allocator,
    /// Arena for short-lived bookkeeping (local-name dupes,
    /// scratch buffers). Released at the end of `compile`.
    arena: std.mem.Allocator,
    source: []const u8,
    /// The growing bytecode buffer.
    code: std.ArrayList(u8),
    /// `let` / `const` bindings in the current fn's frame mapped
    /// to their negative fp-relative offsets (`fp - 2` is the
    /// first local, `fp - 4` the second, etc.).
    locals: std.StringHashMapUnmanaged(i8),
    /// Total bytes reserved for this fn's locals — the prologue
    /// emits `sub frame_bytes, sp`.
    frame_bytes: u8,
    /// Sink for codegen-time diagnostics.
    diagnostics: *std.ArrayList(Diagnostic),

    /// Mutually recursive emit fns need an explicit error set to
    /// break Zig's inferred-set deadlock.
    const EmitError = error{OutOfMemory};

    // ---------- raw emit primitives ----------

    fn emitByte(self: *Emitter, b: u8) !void {
        try self.code.append(self.allocator, b);
    }

    fn emitU16Le(self: *Emitter, value: u16) !void {
        // safety: u16 → 2 LE bytes; both casts are byte-mask, no truncation.
        try self.emitByte(@intCast(value & 0xFF));
        try self.emitByte(@intCast(value >> 8));
    }

    // ---------- ISA instructions used in M1 ----------

    /// `mov imm16, reg` (0x10) — `reg ← imm`.
    fn movImmToReg(self: *Emitter, imm: u16, reg: u8) !void {
        try self.emitByte(Op.mov_imm16_reg);
        try self.emitU16Le(imm);
        try self.emitByte(reg);
    }

    /// `mov src, dst` (0x11) — `dst ← src`.
    fn movRegToReg(self: *Emitter, src: u8, dst: u8) !void {
        try self.emitByte(Op.mov_reg_reg);
        try self.emitByte(src);
        try self.emitByte(dst);
    }

    /// `mov [base + ofs], dst` (0x1C) — load fp-relative into reg.
    fn movRegOffsetToReg(self: *Emitter, base: u8, ofs: i8, dst: u8) !void {
        try self.emitByte(Op.mov_reg_offset_reg);
        try self.emitByte(base);
        // safety: i8 → u8 bit pattern; reg_offset is signed byte per ISA §5.1.
        try self.emitByte(@bitCast(ofs));
        try self.emitByte(dst);
    }

    /// `mov src, [base + ofs]` (0x1D) — store reg to fp-relative.
    fn movRegToRegOffset(self: *Emitter, src: u8, base: u8, ofs: i8) !void {
        try self.emitByte(Op.mov_reg_reg_offset);
        try self.emitByte(src);
        try self.emitByte(base);
        // safety: i8 → u8 bit pattern; reg_offset is signed byte per ISA §5.1.
        try self.emitByte(@bitCast(ofs));
    }

    /// `push reg` (0x31).
    fn pushReg(self: *Emitter, reg: u8) !void {
        try self.emitByte(Op.push_reg);
        try self.emitByte(reg);
    }

    /// `pop reg` (0x32).
    fn popReg(self: *Emitter, reg: u8) !void {
        try self.emitByte(Op.pop_reg);
        try self.emitByte(reg);
    }

    /// `sub imm16, reg` (0x43) — `reg ← reg - imm`.
    fn subImmFromReg(self: *Emitter, imm: u16, reg: u8) !void {
        try self.emitByte(Op.sub_imm16_reg);
        try self.emitU16Le(imm);
        try self.emitByte(reg);
    }

    /// `add reg` (0x42) — `acu ← acu + reg`.
    fn addRegToAcu(self: *Emitter, reg: u8) !void {
        try self.emitByte(Op.add_reg_acu);
        try self.emitByte(reg);
    }

    /// `sub reg` (0x45) — `acu ← acu - reg`.
    fn subRegFromAcu(self: *Emitter, reg: u8) !void {
        try self.emitByte(Op.sub_reg_acu);
        try self.emitByte(reg);
    }

    /// `mul src, dst` (0x47) — `dst ← dst * src`.
    fn mulRegReg(self: *Emitter, src: u8, dst: u8) !void {
        try self.emitByte(Op.mul_reg_reg);
        try self.emitByte(src);
        try self.emitByte(dst);
    }

    /// `divs src, dst` (0x4E) — signed `dst ← dst / src`.
    fn divsRegReg(self: *Emitter, src: u8, dst: u8) !void {
        try self.emitByte(Op.divs_reg_reg);
        try self.emitByte(src);
        try self.emitByte(dst);
    }

    /// `neg reg` (0x4A) — `reg ← -reg` (two's complement).
    fn negReg(self: *Emitter, reg: u8) !void {
        try self.emitByte(Op.neg_reg);
        try self.emitByte(reg);
    }

    /// `sys imm8` (0xFB).
    fn sys(self: *Emitter, id: u8) !void {
        try self.emitByte(Op.sys);
        try self.emitByte(id);
    }

    /// `hlt` (0xFF).
    fn hlt(self: *Emitter) !void {
        try self.emitByte(Op.hlt);
    }

    // ---------- frame management ----------

    /// Reserve a 2-byte slot for `name` at the next fp-relative
    /// offset. Returns the offset (negative — locals grow down).
    fn allocLocal(self: *Emitter, name: []const u8) !i8 {
        const new_frame_bytes = self.frame_bytes + 2;
        // @as: i8 covers -128..127; with 2 bytes per slot we cap at 64 locals per frame, fits.
        const ofs: i8 = -@as(i8, @intCast(new_frame_bytes));
        try self.locals.put(self.arena, name, ofs);
        self.frame_bytes = new_frame_bytes;
        return ofs;
    }

    /// Pre-walk the body to count `let` / `const` bindings so the
    /// prologue can reserve their stack space up-front. Slice M1
    /// handles only top-level lets in the body — destructuring,
    /// nested blocks, conditional bindings come with M2 / M3.
    fn countLocalsInBody(self: *const Emitter, body: []const ast.Statement) usize {
        var n: usize = 0;
        for (body) |s| switch (s) {
            .let_decl, .const_decl => n += 1,
            else => {},
        };
        _ = self;
        return n;
    }

    // ---------- entry-def emission ----------

    fn emitEntryBody(self: *Emitter, def: *const ast.DefDecl) !void {
        // Pre-walk: reserve space for top-level locals.
        const local_count = self.countLocalsInBody(def.body);
        if (local_count > 0) {
            // safety: 2 bytes per slot, capped at 64 locals → fits u16 easily.
            const reserve_bytes: u16 = @intCast(local_count * 2);
            try self.subImmFromReg(reserve_bytes, Reg.sp);
        }
        for (def.body) |stmt| try self.emitStatement(stmt);
        // Entry epilogue: halt. The program ends here.
        try self.hlt();
    }

    // ---------- statement emission ----------

    fn emitStatement(self: *Emitter, stmt: ast.Statement) !void {
        switch (stmt) {
            .let_decl => |d| try self.emitLetDecl(d),
            .const_decl => |d| try self.emitConstDecl(d),
            .return_stmt => |r| try self.emitReturnStmt(r),
            .print_stmt => |p| try self.emitPrintStmt(p),
            .expr_stmt => |es| try self.emitExprDiscard(es.expr),
            .discard => |ds| try self.emitExprDiscard(ds.expr),
            // M1 stops here. Future commits add control flow, assignment,
            // calls, etc.
            else => try self.unsupported(stmt.span(), "this statement form"),
        }
    }

    fn emitLetDecl(self: *Emitter, d: ast.LetDecl) !void {
        if (d.pattern.* != .ident) {
            try self.unsupported(d.span, "non-ident `let` patterns");
            return;
        }
        const name = self.source[d.pattern.ident.name.start..d.pattern.ident.name.end];
        const dup_name = try self.arena.dupe(u8, name);
        const ofs = try self.allocLocal(dup_name);
        if (d.init) |init_expr| {
            try self.emitExpr(init_expr); // result in acu
            try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
        }
        // Uninitialized let leaves the slot at whatever the prologue
        // memset gave it (sub_imm pads sp downward without zeroing —
        // M2 may want a defensive zero-fill).
    }

    fn emitConstDecl(self: *Emitter, d: ast.ConstDecl) !void {
        const name = self.source[d.name.start..d.name.end];
        const dup_name = try self.arena.dupe(u8, name);
        const ofs = try self.allocLocal(dup_name);
        try self.emitExpr(d.init);
        try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
    }

    fn emitReturnStmt(self: *Emitter, r: ast.ReturnStmt) !void {
        if (r.value) |v| try self.emitExpr(v);
        // Inside the entry def, `return` halts (no caller to return
        // to). Non-entry defs get a real epilogue in the next M1
        // commit.
        try self.hlt();
    }

    fn emitPrintStmt(self: *Emitter, p: ast.PrintStmt) !void {
        for (p.args, 0..) |arg, i| {
            if (i > 0) {
                // Space separator between args per spec §4.9.
                try self.movImmToReg(' ', Reg.acu);
                try self.sys(Sys.print_char);
            }
            try self.emitPrintArg(arg);
        }
        // Trailing newline per spec §4.9.
        try self.sys(Sys.print_newline);
    }

    /// One `print` argument — dispatches on the expression's syntactic
    /// shape (string literal → print_str path, everything else →
    /// print_int / print_char). The typechecker already validated
    /// the arg's static type; we only need to pick the syscall.
    fn emitPrintArg(self: *Emitter, arg: *const ast.Expr) !void {
        switch (arg.*) {
            .char_lit => |c| {
                try self.movImmToReg(c.value, Reg.acu);
                try self.sys(Sys.print_char);
            },
            else => {
                // Default: evaluate as int, print as signed decimal.
                // String-literal lowering (`print_str`) wants a
                // static-data emission path that M3 / M4 brings.
                try self.emitExpr(arg);
                try self.sys(Sys.print_int);
            },
        }
    }

    fn emitExprDiscard(self: *Emitter, e: *const ast.Expr) !void {
        try self.emitExpr(e);
        // Result lands in acu; we just don't use it.
    }

    // ---------- expression emission (result → acu) ----------

    fn emitExpr(self: *Emitter, e: *const ast.Expr) EmitError!void {
        switch (e.*) {
            .int_lit => |lit| {
                // @as: truncate i32 → i16; safety: typechecker already verified the literal fits in the target primitive's width.
                const trimmed: i16 = @truncate(lit.value);
                // safety: i16 → u16 bit pattern; the two's-complement encoding is preserved.
                const v: u16 = @bitCast(trimmed);
                try self.movImmToReg(v, Reg.acu);
            },
            .bool_lit => |b| {
                const v: u16 = if (b.value) 1 else 0;
                try self.movImmToReg(v, Reg.acu);
            },
            .nil_lit => try self.movImmToReg(0, Reg.acu),
            .char_lit => |c| try self.movImmToReg(c.value, Reg.acu),
            .paren => |p| try self.emitExpr(p.inner),
            .ident => |i| {
                const name = self.source[i.span.start..i.span.end];
                const ofs = self.locals.get(name) orelse {
                    try self.unsupported(i.span, "ident not in current frame");
                    return;
                };
                try self.movRegOffsetToReg(Reg.fp, ofs, Reg.acu);
            },
            .unary => |u| try self.emitUnary(u),
            .binary => |b| try self.emitBinary(b),
            else => try self.unsupported(e.span(), "this expression form"),
        }
    }

    fn emitUnary(self: *Emitter, u: ast.UnaryExpr) !void {
        try self.emitExpr(u.operand);
        switch (u.op) {
            .neg => try self.negReg(Reg.acu),
            // `not` / `~` land in M2 with control-flow / bitwise ops.
            else => try self.unsupported(u.span, "this unary operator"),
        }
    }

    fn emitBinary(self: *Emitter, b: ast.BinaryExpr) !void {
        // Standard stack-machine pattern: eval RHS, push, eval LHS,
        // pop RHS into r1, apply op (acu = acu OP r1).
        try self.emitExpr(b.rhs);
        try self.pushReg(Reg.acu);
        try self.emitExpr(b.lhs);
        try self.popReg(Reg.r1);
        switch (b.op) {
            .add => try self.addRegToAcu(Reg.r1),
            .sub => try self.subRegFromAcu(Reg.r1),
            .mul => {
                // `mul src, dst` writes low(product) → dst AND
                // high(product) → acu. If dst == acu the high
                // half clobbers the low half — so we land the
                // result in `r2`, then move it back to acu.
                try self.movRegToReg(Reg.acu, Reg.r2);
                try self.mulRegReg(Reg.r1, Reg.r2);
                try self.movRegToReg(Reg.r2, Reg.acu);
            },
            .div => {
                // Signed 32÷16 divide. Dividend lives in acu:dst
                // (high:low). For M1 we assume the dividend fits
                // in 16 bits (positive) and clear acu — proper
                // sign extension lands in a later commit.
                try self.movRegToReg(Reg.acu, Reg.r2); // r2 = low half
                try self.movImmToReg(0, Reg.acu); // high half = 0
                try self.divsRegReg(Reg.r1, Reg.r2); // r2 = quotient, acu = remainder
                try self.movRegToReg(Reg.r2, Reg.acu);
            },
            // M2 picks up: comparison / logical / bitwise / shift / mod.
            else => try self.unsupported(b.span, "this binary operator"),
        }
    }

    // ---------- diagnostics ----------

    fn unsupported(self: *Emitter, span: ast.Span, what: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.arena,
            "codegen does not yet support {s} (slice M1 only covers let/const + arithmetic + print)",
            .{what},
        );
        try self.diagnostics.append(self.allocator, .{
            .severity = .fatal,
            .code = "E_CODEGEN_UNSUPPORTED",
            .message = msg,
            .span = span,
        });
    }
};

// ---------- archive layout (.gx per ISA §7.1) ----------

fn buildArchive(
    allocator: std.mem.Allocator,
    base_image: []const u8,
    entry_point: u16,
) ![]u8 {
    // safety: base image fits in 16-bit address space per ISA.
    const image_size: u16 = @intCast(base_image.len);
    const total = gx_header_size + base_image.len;
    var out = try allocator.alloc(u8, total);

    @memcpy(out[0..4], &gx_magic);
    writeU16Le(out[4..6], gx_version);
    writeU16Le(out[6..8], 0); // flags
    writeU16Le(out[8..10], entry_point);
    writeU16Le(out[10..12], image_size);
    out[12] = 0; // bank_count
    out[13] = 0; // sram_bank_count
    writeU16Le(out[14..16], 0); // reserved

    @memcpy(out[gx_header_size..][0..base_image.len], base_image);
    return out;
}

fn writeU16Le(dst: *[2]u8, value: u16) void {
    // safety: u16 → 2 bytes by definition; no truncation possible.
    dst[0] = @intCast(value & 0xFF);
    dst[1] = @intCast(value >> 8);
}
