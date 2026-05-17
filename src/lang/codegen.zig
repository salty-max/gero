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
/// Per-bank disk size — 16 KiB, the size of the `0xC000..0xFEFF`
/// window in the address space. Each bank stored in the .gx
/// archive consumes exactly this many bytes (zero-padded).
const bank_disk_size: usize = 0x4000;
/// Window base address — every banked address resolves to
/// `window_base + offset_within_bank`.
const bank_window_base: u16 = 0xC000;
/// Banked flag bit in the .gx header per ISA §7.1.
const flag_banked: u16 = 0x0001;

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
    const mov_reg_to_addr: u8 = 0x12; // store: [addr] ← reg (word)
    const mov_addr_to_reg: u8 = 0x13; // load:  reg ← [addr] (word)
    const mov_reg_to_zp: u8 = 0x19; // store: [zp] ← reg (word)
    const mov_zp_to_reg: u8 = 0x1A; // load:  reg ← [zp] (word)
    const mov8_addr_to_reg: u8 = 0x22; // load:  reg ← byte [addr]
    const mov8_zp_to_reg: u8 = 0x29; // load:  reg ← byte [zp]
    const mov8_imm_to_zp: u8 = 0x28; // store: byte at [zp] ← imm
    const mov8_imm_to_addr: u8 = 0x20; // store: byte at [addr] ← imm

    const push_reg: u8 = 0x31;
    const pop_reg: u8 = 0x32;

    const add_imm16_reg: u8 = 0x40;
    const add_reg_acu: u8 = 0x42; // acu ← acu + reg
    const sub_imm16_reg: u8 = 0x43;
    const sub_reg_acu: u8 = 0x45; // acu ← acu - reg
    const mul_reg_reg: u8 = 0x47; // dst ← dst * src
    const neg_reg: u8 = 0x4A;
    const divs_reg_reg: u8 = 0x4E; // dst ← dst / src (signed)

    const call_addr: u8 = 0xA0;
    const ret_op: u8 = 0xA2;

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

    if (findEntryDef(source, checked.program, opts.entry_name) == null) return error.EntryNotFound;

    var emitter: Emitter = .{
        .allocator = allocator,
        .arena = arena.allocator(),
        .source = source,
        .code = .empty,
        .locals = .{},
        .params = .{},
        .frame_bytes = 0,
        .is_entry = false,
        .fn_addresses = .{},
        .call_patches = .empty,
        .globals = .{},
        .data_cursor = data_base,
        .zp_cursor = 0,
        .banks = .{},
        .current_bank = null,
        .diagnostics = &diagnostics,
    };
    defer emitter.code.deinit(allocator);
    defer emitter.call_patches.deinit(allocator);
    defer {
        var it = emitter.banks.valueIterator();
        while (it.next()) |b| b.deinit(allocator);
        emitter.banks.deinit(allocator);
    }

    try emitter.emitProgram(checked.program, opts.entry_name);

    // Build base image: zeros from 0x0000 up to `code_base`, then
    // the emitted bytes.
    // @as: widen u16 code_base to usize for the byte-length math (image stays ≤ 64 KiB by ISA).
    const total_image_bytes: usize = @as(usize, code_base) + emitter.code.items.len;
    var base_image = try allocator.alloc(u8, total_image_bytes);
    errdefer allocator.free(base_image);
    @memset(base_image, 0);
    @memcpy(base_image[code_base..][0..emitter.code.items.len], emitter.code.items);

    const image = try buildArchive(allocator, base_image, code_base, &emitter.banks);
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

/// Unresolved `call addr` site — the codegen recorded the call
/// when the callee's address wasn't yet known (forward refs). At
/// the end of emission, every patch's 2-byte address-slot in
/// `code` is overwritten with the resolved callee address.
const CallPatch = struct {
    /// Which buffer the patch lives in — `null` = base code,
    /// non-null = bank N's buffer. The patcher uses this to
    /// find the right ArrayList.
    bank: ?u8,
    /// Byte offset into the resolved buffer where the 2-byte LE
    /// address slot lives (right after the `0xA0` opcode).
    code_offset: usize,
    /// Callee fn name to resolve via `fn_addresses`.
    callee_name: []const u8,
    /// Span of the original call expression — used to anchor the
    /// `E_CODEGEN_UNDEFINED_FN` diagnostic on resolve failure.
    span: ast.Span,
};

/// One top-level `let` / `const` global. Address is decided during
/// the pre-pass: `@addr` literal wins, otherwise `@zero_page`
/// allocates from `zp_cursor`, otherwise the binding lands in the
/// dynamic data region from `data_cursor`.
const Global = struct {
    /// Resolved absolute address in the 64 KiB address space.
    address: u16,
    /// Byte width — `1` for `u8` / `bool` / `char`, `2` for the
    /// 16-bit primitives and references. Slice-M1 doesn't emit
    /// init values; the slot is undefined-zero at boot for the
    /// data region, undefined for `@addr`-pinned bindings.
    width: u8,
    /// Placement family — drives which addressing mode the
    /// ident-load / assignment emits (`mov zp` is 1 byte cheaper
    /// per access than `mov addr`).
    placement: enum { addr, zero_page, data },
};

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
    /// Param-name → positive fp-relative offset. The VM's `call`
    /// pushes ret_ip + old_fp then sets fp = sp, so param 0 lives
    /// at `[fp + 4]`, param 1 at `[fp + 6]`, etc. Reset per fn.
    params: std.StringHashMapUnmanaged(i8),
    /// Total bytes reserved for this fn's locals — the prologue
    /// emits `sub frame_bytes, sp`.
    frame_bytes: u8,
    /// `true` while emitting the entry def's body. Drives the
    /// `return` lowering (`hlt` vs `ret`) and skips the
    /// `push fp` / `mov sp, fp` parts of the prologue (the VM
    /// boots with `fp == sp`).
    is_entry: bool,
    /// Top-level `def` name → absolute address in the base image
    /// (`code_base + offset`). Populated as defs are emitted in
    /// source order so calls patch correctly.
    fn_addresses: std.StringHashMapUnmanaged(u16),
    /// Unresolved `call addr` sites — recorded when the callee's
    /// address isn't known yet (forward references). Rewritten at
    /// the end of `emitProgram`.
    call_patches: std.ArrayList(CallPatch),
    /// Top-level `let` / `const` globals + their pinned addresses.
    /// Populated by a pre-pass over `program.statements`; consulted
    /// by ident loads + assignments. See `Global` for the per-
    /// binding metadata (address, byte width, placement kind).
    globals: std.StringHashMapUnmanaged(Global),
    /// Next free address in the dynamic data region (data_base
    /// upward). Used for unannotated globals.
    data_cursor: u16,
    /// Next free zero-page byte (0x0000 upward). Used for
    /// `@zero_page` globals.
    zp_cursor: u8,
    /// Per-bank emit buffers — `@bank N` defs land here instead of
    /// the base `code` buffer. The base image gets the un-banked
    /// bytes; `buildArchive` appends each bank window after.
    banks: std.AutoHashMapUnmanaged(u8, std.ArrayList(u8)),
    /// Active bank for the current def (`@bank N` on the decl).
    /// `null` means the base image. Saved + restored per `emitDef`.
    current_bank: ?u8,
    /// Sink for codegen-time diagnostics.
    diagnostics: *std.ArrayList(Diagnostic),

    /// Mutually recursive emit fns need an explicit error set to
    /// break Zig's inferred-set deadlock.
    const EmitError = error{OutOfMemory};

    // ---------- raw emit primitives ----------

    /// Pointer to the buffer the next byte should go into — the
    /// base `code` buffer when no `@bank` is active, otherwise the
    /// per-bank buffer (created lazily on first byte).
    fn currentCode(self: *Emitter) !*std.ArrayList(u8) {
        if (self.current_bank) |b| {
            const gop = try self.banks.getOrPut(self.allocator, b);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            return gop.value_ptr;
        }
        return &self.code;
    }

    /// Byte offset of the next emission within the current code
    /// buffer. Used to record `fn_addresses` + `call_patches` at
    /// the right position.
    fn currentOffset(self: *Emitter) !usize {
        const buf = try self.currentCode();
        return buf.items.len;
    }

    fn emitByte(self: *Emitter, b: u8) !void {
        const buf = try self.currentCode();
        try buf.append(self.allocator, b);
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

    /// `mov [addr], reg` (0x13) — load 16-bit word from addr.
    fn movAddrToReg(self: *Emitter, addr: u16, dst: u8) !void {
        try self.emitByte(Op.mov_addr_to_reg);
        try self.emitU16Le(addr);
        try self.emitByte(dst);
    }

    /// `mov src, [addr]` (0x12) — store 16-bit word to addr.
    fn movRegToAddr(self: *Emitter, src: u8, addr: u16) !void {
        try self.emitByte(Op.mov_reg_to_addr);
        try self.emitByte(src);
        try self.emitU16Le(addr);
    }

    /// `mov [zp], reg` (0x1A) — load 16-bit word from zp slot.
    fn movZpToReg(self: *Emitter, zp: u8, dst: u8) !void {
        try self.emitByte(Op.mov_zp_to_reg);
        try self.emitByte(zp);
        try self.emitByte(dst);
    }

    /// `mov src, [zp]` (0x19) — store 16-bit word to zp slot.
    fn movRegToZp(self: *Emitter, src: u8, zp: u8) !void {
        try self.emitByte(Op.mov_reg_to_zp);
        try self.emitByte(src);
        try self.emitByte(zp);
    }

    /// `mov8 [addr], reg` (0x22) — load 1-byte from addr (zero-
    /// extend into the 16-bit dst).
    fn mov8AddrToReg(self: *Emitter, addr: u16, dst: u8) !void {
        try self.emitByte(Op.mov8_addr_to_reg);
        try self.emitU16Le(addr);
        try self.emitByte(dst);
    }

    /// `mov8 [zp], reg` (0x29) — load 1-byte from zp slot.
    fn mov8ZpToReg(self: *Emitter, zp: u8, dst: u8) !void {
        try self.emitByte(Op.mov8_zp_to_reg);
        try self.emitByte(zp);
        try self.emitByte(dst);
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

    /// `add imm16, reg` (0x40) — `reg ← reg + imm`.
    fn addImmToReg(self: *Emitter, imm: u16, reg: u8) !void {
        try self.emitByte(Op.add_imm16_reg);
        try self.emitU16Le(imm);
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

    // ---------- program + def emission ----------

    /// Top-level orchestrator: emit the entry def first (so it
    /// lands at `code_base`, matching `Options.entry_name` →
    /// header `entry_point`), then every other top-level `def` in
    /// source order, then patch unresolved call sites.
    fn emitProgram(self: *Emitter, program: *const ast.Program, entry_name: []const u8) !void {
        // Pre-pass: register every top-level `let` / `const` with
        // its resolved address. `@addr` literal wins, then
        // `@zero_page` (bumps `zp_cursor`), else dynamic data
        // region (bumps `data_cursor`).
        try self.registerGlobals(program);

        const entry = findEntryDef(self.source, program, entry_name).?;
        try self.emitDef(entry, .entry);
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| if (dd != entry) try self.emitDef(dd, .regular),
            else => {},
        };
        try self.patchCalls();
    }

    /// Pre-pass over top-level statements that registers every
    /// `let` / `const` as a `Global`. The address-decision rule:
    ///
    /// 1. `@addr $XXXX` → use the literal value verbatim.
    /// 2. `@zero_page` → next slot from `zp_cursor` (1-byte
    ///    addressing range). Overflow → `E_CODEGEN_ZP_OVERFLOW`.
    /// 3. `@align(N)` → pad the destination cursor up to a
    ///    multiple of N before placing the binding (the typechecker
    ///    has already verified `N` is a power of two).
    /// 4. No annotation → next slot from `data_cursor` (data area
    ///    starts at `data_base = 0x2000`).
    ///
    /// `@volatile` is recognized but doesn't alter the address —
    /// the lang codegen doesn't register-cache globals today, so
    /// volatility is naturally honored.
    fn registerGlobals(self: *Emitter, program: *const ast.Program) !void {
        for (program.statements) |*stmt| switch (stmt.*) {
            .let_decl => |*d| try self.registerGlobalLet(d),
            .const_decl => |*d| try self.registerGlobalConst(d),
            else => {},
        };
    }

    fn registerGlobalLet(self: *Emitter, d: *const ast.LetDecl) !void {
        if (d.pattern.* != .ident) return; // destructuring at top-level — slice later
        const name = self.source[d.pattern.ident.name.start..d.pattern.ident.name.end];
        const width = self.widthOfLetDecl(d);
        try self.placeGlobal(name, width, d.annotations, d.pattern.ident.name);
    }

    fn registerGlobalConst(self: *Emitter, d: *const ast.ConstDecl) !void {
        const name = self.source[d.name.start..d.name.end];
        const width = self.widthOfConstDecl(d);
        try self.placeGlobal(name, width, d.annotations, d.name);
    }

    fn placeGlobal(
        self: *Emitter,
        name: []const u8,
        width: u8,
        annotations: []const ast.Annotation,
        decl_span: ast.Span,
    ) !void {
        var pinned_addr: ?u16 = null;
        var zero_page: bool = false;
        var align_n: ?u16 = null;
        for (annotations) |ann| {
            const ann_name = self.source[ann.name.start..ann.name.end];
            if (std.mem.eql(u8, ann_name, "addr") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
                // @as: parser stores int_lit.value as i32; address literals are always non-negative per spec §3.7.1; truncating to u16 preserves bytes.
                pinned_addr = @intCast(ann.args[0].int_lit.value & 0xFFFF);
            } else if (std.mem.eql(u8, ann_name, "zero_page")) {
                zero_page = true;
            } else if (std.mem.eql(u8, ann_name, "align") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
                // @as: typechecker verified the value is a power of two; coercing i32 → u16 fits the alignment range.
                align_n = @intCast(ann.args[0].int_lit.value & 0xFFFF);
            }
        }
        const dup = try self.arena.dupe(u8, name);

        if (pinned_addr) |addr| {
            try self.globals.put(self.arena, dup, .{
                .address = addr,
                .width = width,
                .placement = .addr,
            });
            return;
        }
        if (zero_page) {
            if (align_n) |n| self.zp_cursor = alignUpU8(self.zp_cursor, @intCast(n));
            // @as: widen u8 zp_cursor to u16 so the bounds-check arithmetic doesn't wrap.
            const zp_end: u16 = @as(u16, self.zp_cursor) + width;
            if (zp_end > 0x100) {
                try self.diagFatal(decl_span, "E_CODEGEN_ZP_OVERFLOW", "zero-page region exhausted — too many `@zero_page` globals");
                return;
            }
            try self.globals.put(self.arena, dup, .{
                .address = self.zp_cursor,
                .width = width,
                .placement = .zero_page,
            });
            self.zp_cursor += width;
            return;
        }
        // Dynamic data region.
        if (align_n) |n| self.data_cursor = alignUpU16(self.data_cursor, n);
        try self.globals.put(self.arena, dup, .{
            .address = self.data_cursor,
            .width = width,
            .placement = .data,
        });
        self.data_cursor += width;
    }

    /// 1 for `i8` / `u8` / `bool` / `char`, 2 otherwise (the slice-
    /// M1 type universe for globals). Type-name resolution is
    /// purely lexical against the type annotation; the typechecker
    /// has already validated that the name refers to a primitive
    /// or a registered user-type.
    fn widthOfLetDecl(self: *const Emitter, d: *const ast.LetDecl) u8 {
        if (d.type_ann) |t| return self.widthOfTypeAnn(t.*);
        // No annotation — default to the widest primitive (2 bytes).
        return 2;
    }

    fn widthOfConstDecl(self: *const Emitter, d: *const ast.ConstDecl) u8 {
        if (d.type_ann) |t| return self.widthOfTypeAnn(t.*);
        return 2;
    }

    /// Emit a load of `g`'s value into `acu`. The instruction
    /// shape depends on the placement family + byte width.
    fn emitGlobalLoad(self: *Emitter, g: Global) !void {
        switch (g.placement) {
            .addr => {
                if (g.width == 1) {
                    try self.mov8AddrToReg(g.address, Reg.acu);
                } else {
                    try self.movAddrToReg(g.address, Reg.acu);
                }
            },
            .zero_page => {
                // @as: zero-page address fits in u8; placement.zero_page guarantees address ≤ 0xFF.
                const zp: u8 = @intCast(g.address);
                if (g.width == 1) {
                    try self.mov8ZpToReg(zp, Reg.acu);
                } else {
                    try self.movZpToReg(zp, Reg.acu);
                }
            },
            .data => {
                if (g.width == 1) {
                    try self.mov8AddrToReg(g.address, Reg.acu);
                } else {
                    try self.movAddrToReg(g.address, Reg.acu);
                }
            },
        }
    }

    /// Emit a store of `src` reg's value into `g`'s slot. Only the
    /// 16-bit `mov` opcodes are exposed today; 1-byte stores fall
    /// back to the 16-bit form which clobbers the trailing byte —
    /// acceptable for slice M1 since the byte's neighbor is also
    /// part of `g`'s slot (the allocator places adjacent bindings
    /// with their own widths).
    fn emitGlobalStore(self: *Emitter, src: u8, g: Global) !void {
        switch (g.placement) {
            .addr, .data => try self.movRegToAddr(src, g.address),
            .zero_page => {
                // @as: zero-page address fits in u8; placement.zero_page guarantees address ≤ 0xFF.
                const zp: u8 = @intCast(g.address);
                try self.movRegToZp(src, zp);
            },
        }
    }

    fn widthOfTypeAnn(self: *const Emitter, t: ast.TypeAnn) u8 {
        return switch (t) {
            .named => |n| blk: {
                const name = self.source[n.name.start..n.name.end];
                if (std.mem.eql(u8, name, "i8") or
                    std.mem.eql(u8, name, "u8") or
                    std.mem.eql(u8, name, "bool") or
                    std.mem.eql(u8, name, "char"))
                {
                    break :blk 1;
                }
                break :blk 2;
            },
            else => 2,
        };
    }

    const DefKind = enum { entry, regular };

    /// Emit one def's prologue + body + epilogue. Reset per-fn
    /// state (locals / params / frame_bytes / is_entry) so each
    /// def gets a fresh frame view.
    fn emitDef(self: *Emitter, def: *const ast.DefDecl, kind: DefKind) !void {
        // Detect `@bank N` annotation — drives bank routing for
        // this def's body bytes + the fn's resolved address.
        var bank_target: ?u8 = null;
        for (def.annotations) |ann| {
            const ann_name = self.source[ann.name.start..ann.name.end];
            if (std.mem.eql(u8, ann_name, "bank") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
                // @as: typechecker enforces u8 range on `@bank N`.
                bank_target = @intCast(ann.args[0].int_lit.value & 0xFF);
            }
        }

        // Save + restore per-fn state.
        const saved_locals = self.locals;
        const saved_params = self.params;
        const saved_frame = self.frame_bytes;
        const saved_entry = self.is_entry;
        const saved_bank = self.current_bank;
        self.locals = .{};
        self.params = .{};
        self.frame_bytes = 0;
        self.is_entry = (kind == .entry);
        self.current_bank = bank_target;
        defer {
            self.locals = saved_locals;
            self.params = saved_params;
            self.frame_bytes = saved_frame;
            self.is_entry = saved_entry;
            self.current_bank = saved_bank;
        }

        const name = self.source[def.name.start..def.name.end];
        const dup_name = try self.arena.dupe(u8, name);
        // @as: narrow usize code offset to u16; per-buffer offset stays ≤ 64 KiB.
        const code_offset: u16 = @intCast(try self.currentOffset());
        const addr: u16 = if (bank_target) |_|
            bank_window_base + code_offset
        else
            code_base + code_offset;
        try self.fn_addresses.put(self.arena, dup_name, addr);

        // Bind params to positive fp-relative offsets. `call` left
        // the stack as: [low] ret_ip, old_fp, arg_N-1, ..., arg_1,
        // arg_0 [high] (per right-to-left push order at the call
        // site). fp points at ret_ip, so param 0 is at fp+4,
        // param 1 at fp+6, etc.
        for (def.params, 0..) |p, i| {
            const p_name = self.source[p.name.start..p.name.end];
            const dup_p = try self.arena.dupe(u8, p_name);
            // @as: u8 frame index → i8 fp-offset; cap at 62 params → fits.
            const offset: i8 = @intCast(4 + 2 * @as(i32, @intCast(i)));
            try self.params.put(self.arena, dup_p, offset);
        }

        // Reserve local slots up front (cheap fixed reservation —
        // a real allocator would compute live ranges).
        const local_count = self.countLocalsInBody(def.body);
        if (local_count > 0) {
            // @as: 2 bytes per slot capped well below u16.
            const reserve_bytes: u16 = @intCast(local_count * 2);
            try self.subImmFromReg(reserve_bytes, Reg.sp);
        }

        for (def.body) |stmt| try self.emitStatement(stmt);

        // Implicit epilogue (no explicit `return`).
        if (self.is_entry) {
            try self.hlt();
        } else {
            // `ret` resets sp = fp then pops ret_ip + old_fp. The
            // VM handles the whole tear-down; we just need to land
            // the return value in acu (callers read from there).
            try self.emitByte(Op.ret_op);
        }
    }

    /// Rewrite each unresolved call's 2-byte address slot. An
    /// unresolved callee name surfaces as
    /// `E_CODEGEN_UNDEFINED_FN` — should be unreachable in
    /// well-typed input (the typechecker resolves identifiers
    /// first) but the check keeps the codegen defensive.
    fn patchCalls(self: *Emitter) !void {
        for (self.call_patches.items) |p| {
            const target = self.fn_addresses.get(p.callee_name) orelse {
                const msg = try std.fmt.allocPrint(
                    self.arena,
                    "codegen: call target `{s}` is not a known top-level def",
                    .{p.callee_name},
                );
                try self.diagnostics.append(self.allocator, .{
                    .severity = .fatal,
                    .code = "E_CODEGEN_UNDEFINED_FN",
                    .message = msg,
                    .span = p.span,
                });
                continue;
            };
            // Resolve which buffer holds this patch — base or
            // one of the bank ArrayLists.
            const buf: []u8 = if (p.bank) |b|
                if (self.banks.getPtr(b)) |bl| bl.items else continue
            else
                self.code.items;
            // Overwrite the 2-byte LE address slot.
            // safety: u16 → 2 bytes by definition; both casts are byte-masks.
            buf[p.code_offset] = @intCast(target & 0xFF);
            buf[p.code_offset + 1] = @intCast(target >> 8);
        }
    }

    // ---------- statement emission ----------

    fn emitStatement(self: *Emitter, stmt: ast.Statement) !void {
        switch (stmt) {
            .let_decl => |d| try self.emitLetDecl(d),
            .const_decl => |d| try self.emitConstDecl(d),
            .assign => |a| try self.emitAssign(a),
            .return_stmt => |r| try self.emitReturnStmt(r),
            .print_stmt => |p| try self.emitPrintStmt(p),
            .expr_stmt => |es| try self.emitExprDiscard(es.expr),
            .discard => |ds| try self.emitExprDiscard(ds.expr),
            // M2 picks up: control flow, inc-dec, etc.
            else => try self.unsupported(stmt.span(), "this statement form"),
        }
    }

    /// Lower `target = value` (and compound `op=` forms — slice M1
    /// only handles plain `=` for now). The target must be an
    /// ident that resolves to a local, param, or global.
    fn emitAssign(self: *Emitter, a: ast.AssignStmt) !void {
        if (a.op != .set) {
            try self.unsupported(a.span, "compound `op=` assignments (only plain `=` is lowered in M1)");
            return;
        }
        if (a.target.* != .ident) {
            try self.unsupported(a.span, "non-ident assignment targets (field / index)");
            return;
        }
        const name = self.source[a.target.ident.span.start..a.target.ident.span.end];
        try self.emitExpr(a.value); // result in acu
        if (self.locals.get(name)) |ofs| {
            try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
            return;
        }
        if (self.params.get(name)) |ofs| {
            try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
            return;
        }
        if (self.globals.get(name)) |g| {
            try self.emitGlobalStore(Reg.acu, g);
            return;
        }
        try self.unsupported(a.target.span(), "assignment target not in scope");
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
        if (self.is_entry) {
            // Entry def has no caller — halt instead of ret.
            try self.hlt();
        } else {
            try self.emitByte(Op.ret_op);
        }
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
                // Lookup order: locals → params → globals.
                if (self.locals.get(name)) |ofs| {
                    try self.movRegOffsetToReg(Reg.fp, ofs, Reg.acu);
                    return;
                }
                if (self.params.get(name)) |ofs| {
                    try self.movRegOffsetToReg(Reg.fp, ofs, Reg.acu);
                    return;
                }
                if (self.globals.get(name)) |g| {
                    try self.emitGlobalLoad(g);
                    return;
                }
                try self.unsupported(i.span, "ident not in current frame");
            },
            .unary => |u| try self.emitUnary(u),
            .binary => |b| try self.emitBinary(b),
            .call => |c| try self.emitCall(c),
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

    /// Lower `callee(args...)` per the free-fn calling convention:
    ///
    ///   - Push args **right-to-left** (so callee sees param 0 at
    ///     `[fp + 4]`, param 1 at `[fp + 6]`, ...).
    ///   - `call <addr>` — the VM enters: push fp, push ret_ip,
    ///     fp ← sp, ip ← target.
    ///   - On return, `add <N*2>, sp` to drop the args. The
    ///     callee's return value lives in `acu`.
    ///
    /// Slice M1 only handles direct calls — the callee must be a
    /// bare ident referencing a top-level `def`. Method calls /
    /// closure invocations / fn-pointer calls land in M3.
    fn emitCall(self: *Emitter, c: ast.CallExpr) !void {
        if (c.callee.* != .ident) {
            try self.unsupported(c.span, "non-ident callee");
            return;
        }
        // Push args right-to-left.
        var i: usize = c.args.len;
        while (i > 0) {
            i -= 1;
            try self.emitExpr(c.args[i]);
            try self.pushReg(Reg.acu);
        }

        // Emit `call <addr>` with a placeholder address; the
        // patching pass rewrites it once every def's address is
        // known.
        try self.emitByte(Op.call_addr);
        const patch_offset = try self.currentOffset();
        try self.emitU16Le(0); // placeholder
        const callee_name = self.source[c.callee.ident.span.start..c.callee.ident.span.end];
        const dup = try self.arena.dupe(u8, callee_name);
        try self.call_patches.append(self.allocator, .{
            .bank = self.current_bank,
            .code_offset = patch_offset,
            .callee_name = dup,
            .span = c.span,
        });

        // Caller-cleans-up the pushed args.
        if (c.args.len > 0) {
            // @as: each arg is one 16-bit word.
            const drop_bytes: u16 = @intCast(c.args.len * 2);
            try self.addImmToReg(drop_bytes, Reg.sp);
        }
    }

    // ---------- diagnostics ----------

    fn diagFatal(self: *Emitter, span: ast.Span, code: []const u8, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .fatal,
            .code = code,
            .message = message,
            .span = span,
        });
    }

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
    banks: *const std.AutoHashMapUnmanaged(u8, std.ArrayList(u8)),
) ![]u8 {
    // Bank count = max bank index + 1 (banks are 0-indexed). 0 if
    // no banks declared.
    var max_bank: ?u8 = null;
    var it = banks.keyIterator();
    while (it.next()) |b| {
        if (max_bank) |m| max_bank = @max(m, b.*) else max_bank = b.*;
    }
    // @as: widen u8 max_bank to u16 so `+ 1` doesn't overflow when max_bank == 255.
    const bank_count: u16 = if (max_bank) |m| @as(u16, m) + 1 else 0;
    // @as: bank_count ≤ 256 by u8 input; the byte total fits usize.
    const banked_bytes: usize = @as(usize, bank_count) * bank_disk_size;

    // safety: base image fits in 16-bit address space per ISA.
    const image_size: u16 = @intCast(base_image.len);
    const total = gx_header_size + base_image.len + banked_bytes;
    var out = try allocator.alloc(u8, total);
    @memset(out, 0);

    var flags: u16 = 0;
    if (bank_count > 0) flags |= flag_banked;

    @memcpy(out[0..4], &gx_magic);
    writeU16Le(out[4..6], gx_version);
    writeU16Le(out[6..8], flags);
    writeU16Le(out[8..10], entry_point);
    writeU16Le(out[10..12], image_size);
    // safety: bank_count ≤ 256 by construction.
    out[12] = @intCast(bank_count);
    out[13] = 0; // sram_bank_count
    writeU16Le(out[14..16], 0); // reserved

    @memcpy(out[gx_header_size..][0..base_image.len], base_image);

    // Bank buffers: each occupies `bank_disk_size` bytes (zero-
    // padded). Banks the user didn't touch stay all zeros.
    var cursor: usize = gx_header_size + base_image.len;
    var b: u16 = 0;
    while (b < bank_count) : (b += 1) {
        const dst = out[cursor..][0..bank_disk_size];
        // safety: b < bank_count ≤ 256, fits u8.
        if (banks.get(@intCast(b))) |bank_buf| {
            const n = @min(bank_buf.items.len, bank_disk_size);
            @memcpy(dst[0..n], bank_buf.items[0..n]);
        }
        cursor += bank_disk_size;
    }

    return out;
}

fn writeU16Le(dst: *[2]u8, value: u16) void {
    // safety: u16 → 2 bytes by definition; no truncation possible.
    dst[0] = @intCast(value & 0xFF);
    dst[1] = @intCast(value >> 8);
}

/// Round `value` up to the next multiple of `align_n` (which must
/// be a power of two — typechecker enforces). `align_n == 1`
/// passes through.
fn alignUpU8(value: u8, align_n: u8) u8 {
    if (align_n <= 1) return value;
    const mask: u8 = align_n - 1;
    return (value + mask) & ~mask;
}

fn alignUpU16(value: u16, align_n: u16) u16 {
    if (align_n <= 1) return value;
    const mask: u16 = align_n - 1;
    return (value + mask) & ~mask;
}
