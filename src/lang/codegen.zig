/// Gero-lang codegen — typed AST → `.gx` bytecode image.
///
/// Direct emission (no asm intermediate per cli.md §3.2). Walks
/// the `CheckedProgram` from `typecheck.zig` and produces a `.gx`
/// archive ready for the VM loader (`gero.vm.parseGx`) per ISA §7.
///
/// **M1 surface** (instruction selection + free-fn calling
/// convention + memory-placement annotations):
///   - Statements: `let` / `const` / `return` / `print` /
///     `target = value` / discard / expression statements.
///   - Expressions: literals, idents (local + param + global),
///     unary neg, binary `+ - * /`, direct calls.
///   - Stack frames: locals at `[fp - 2*N]`, params at
///     `[fp + 4 + 2*i]`; the VM's `call` / `ret` handle the
///     ret_ip + fp push / pop.
///   - Globals: top-level `let` / `const` with optional
///     `@addr` / `@volatile` / `@zero_page` / `@align(N)`
///     placement annotations. Byte-width globals use `movl`.
///   - Banks: `@bank N` routes defs into per-bank buffers;
///     cross-bank calls go through a `__call_bank` trampoline
///     in the base image.
///
/// **M2 surface** (control flow + match + defer):
///   - Statements: `do…end` blocks, `if / else if / else`
///     (incl. `if let` ident-binder form), `while` (incl.
///     `while let`), `for x in start..end [step N]`, `repeat
///     body until cond`, `match`, `break [:label]`,
///     `continue [:label]`, `defer stmt`.
///   - Expressions: comparison ops (`== != < <= > >=`), logical
///     `and` / `or` (short-circuit), `not`, bitwise `& | ^ ~`,
///     shifts `<< >>`, `%` (mod via `divs` remainder).
///   - Flag-driven lowering: `cmp` + `jeq/jne/jlt/jle/jgt/jge`
///     for comparisons; condition fast-path skips the 0/1
///     materialization when the cmp drives a branch directly.
///   - Loop frames carry per-loop break / continue patch lists
///     so labeled jumps resolve at loop teardown.
///   - Match: sequential cmp+branch decision tree. OR-patterns
///     collapse onto one shared body label; range patterns emit
///     a single low+high cmp pair; `when` guards run after the
///     pattern bind. Enum-variant patterns + jump-table
///     dispatch wait on M3's enum tag codegen.
///   - Defer: per-block LIFO list of statements; cleanup emits
///     inline at every exit path (normal block end, `return`,
///     `break`, `continue`). `acu` is preserved across the
///     cleanup so the caller's return value survives.
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
    const movl_reg_to_addr: u8 = 0x27; // store: [addr] ← reg.lo  (byte store)
    const movl_reg_to_zp: u8 = 0x2B; // store: [zp]   ← reg.lo  (byte store)

    const push_reg: u8 = 0x31;
    const pop_reg: u8 = 0x32;

    const add_imm16_reg: u8 = 0x40;
    const add_reg_acu: u8 = 0x42; // acu ← acu + reg
    const sub_imm16_reg: u8 = 0x43;
    const sub_reg_acu: u8 = 0x45; // acu ← acu - reg
    const mul_reg_reg: u8 = 0x47; // dst ← dst * src
    const neg_reg: u8 = 0x4A;
    const divs_reg_reg: u8 = 0x4E; // dst ← dst / src (signed)

    const and_reg_reg: u8 = 0x61; // dst ← dst & src
    const or_reg_reg: u8 = 0x63; // dst ← dst | src
    const xor_reg_reg: u8 = 0x65; // dst ← dst ^ src
    const not_reg: u8 = 0x66; // reg ← ~reg
    const shl_reg_reg: u8 = 0x71; // dst ← dst << src
    const shr_reg_reg: u8 = 0x73; // dst ← dst >> src

    const cmp_reg_imm16: u8 = 0x80; // flags ← reg - imm
    const cmp_reg_reg: u8 = 0x81; // flags ← dst - src

    const jmp_addr: u8 = 0x90; // unconditional
    const jeq_addr: u8 = 0x92; // Z = 1
    const jne_addr: u8 = 0x93; // Z = 0
    const jlt_addr: u8 = 0x94; // signed less
    const jle_addr: u8 = 0x95; // signed ≤
    const jgt_addr: u8 = 0x96; // signed >
    const jge_addr: u8 = 0x97; // signed ≥

    const call_addr: u8 = 0xA0;
    const call_reg: u8 = 0xA1;
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
    const mb: u8 = 0x0C;
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
        .fn_banks = .{},
        .trampoline_addr = null,
        .call_patches = .empty,
        .globals = .{},
        .data_cursor = data_base,
        .zp_cursor = 0,
        .banks = .{},
        .current_bank = null,
        .block_stack = .empty,
        .loop_stack = .empty,
        .diagnostics = &diagnostics,
    };
    defer emitter.code.deinit(allocator);
    defer emitter.call_patches.deinit(allocator);
    defer emitter.block_stack.deinit(allocator);
    defer emitter.loop_stack.deinit(allocator);
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
    /// non-null = bank N's buffer.
    bank: ?u8,
    /// Byte offset into the resolved buffer where the 2-byte LE
    /// address slot lives.
    code_offset: usize,
    /// What address to write into the slot at patch time.
    target: Target,
    /// Span of the original call expression — used to anchor the
    /// `E_CODEGEN_UNDEFINED_FN` diagnostic on resolve failure.
    span: ast.Span,

    /// Patch-target kinds:
    /// - `fn_name`: resolve via the codegen's `fn_addresses` map.
    /// - `trampoline`: resolve to the `__call_bank` trampoline's
    ///   address, recorded after the trampoline emits.
    const Target = union(enum) {
        fn_name: []const u8,
        trampoline,
    };
};

/// One lexical block tracked at codegen time. Owns the LIFO list of
/// `defer` statements registered within the block so the codegen can
/// re-emit them at every exit path (fall-through, `return`, `break`,
/// `continue`). The body of a `defer` is held by pointer — the same
/// AST node is re-emitted once per exit path the codegen lowers.
const Block = struct {
    defers: std.ArrayList(*const ast.Statement),
};

/// One enclosing loop tracked while emitting the loop body. Carries
/// the patches accumulated for every `break` / `continue` inside the
/// body (forward jumps with the address slot unfilled) so the
/// codegen can resolve them at the end of the loop, and the index of
/// the loop body's block in `block_stack` so `break` / `continue`
/// know which range of blocks to unwind on the jump path.
const LoopFrame = struct {
    /// Optional `:label` on the loop head. `null` for unlabeled
    /// loops. Lookup matches by string equality against this; a
    /// `break :name` with no enclosing match is a codegen-time error
    /// (the typechecker should catch this earlier).
    label: ?[]const u8,
    /// Index of this loop's body block inside `block_stack` — used to
    /// determine which blocks `break` / `continue` need to unwind.
    body_block_idx: usize,
    /// Unresolved forward jumps for `break` — resolved to the byte
    /// immediately after the loop's exit code at loop teardown.
    break_patches: std.ArrayList(usize),
    /// Unresolved forward jumps for `continue` — resolved to the
    /// loop's `continue target`, which varies per loop kind (the
    /// cond test for `while`, the step+test prologue for `for`, the
    /// trailing `until` test for `repeat`).
    continue_patches: std.ArrayList(usize),
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
    /// Top-level `def` name → absolute address. Populated as defs
    /// are emitted in source order so calls patch correctly. For
    /// banked defs, the recorded address sits in the bank window
    /// (`bank_window_base + offset`); for un-banked defs, it sits
    /// in the base image (`code_base + offset`).
    fn_addresses: std.StringHashMapUnmanaged(u16),
    /// Top-level `def` name → the bank it lives in (or `null`
    /// for the base image). Populated in a pre-pass over
    /// `program.statements` BEFORE emission, so `emitCall` knows
    /// the target's bank when deciding direct-call vs trampoline.
    fn_banks: std.StringHashMapUnmanaged(?u8),
    /// Address of the `__call_bank` trampoline in the base image
    /// after emission. `null` until the trampoline is emitted —
    /// trampoline-target call patches resolve against this.
    trampoline_addr: ?u16,
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
    /// Stack of lexical blocks active at the current emit cursor.
    /// The function body opens the bottom block; nested `do…end`,
    /// loop bodies, `if` arms, etc. push more on top. Each block
    /// owns its registered `defer` statements.
    block_stack: std.ArrayList(Block),
    /// Stack of enclosing loops at the current emit cursor. `break`
    /// and `continue` look up their target frame here (innermost
    /// match for unlabeled, label-equal for labeled).
    loop_stack: std.ArrayList(LoopFrame),
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

    /// `movl reg, [addr]` (0x27) — store reg's low byte to addr.
    /// Used for 1-byte global stores so neighboring bytes stay
    /// untouched (critical for MMIO).
    fn movlRegToAddr(self: *Emitter, src: u8, addr: u16) !void {
        try self.emitByte(Op.movl_reg_to_addr);
        try self.emitByte(src);
        try self.emitU16Le(addr);
    }

    /// `movl reg, [zp]` (0x2B) — store reg's low byte to zp slot.
    fn movlRegToZp(self: *Emitter, src: u8, zp: u8) !void {
        try self.emitByte(Op.movl_reg_to_zp);
        try self.emitByte(src);
        try self.emitByte(zp);
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

    /// `cmp reg, imm16` (0x80) — flags ← reg - imm. Result discarded.
    fn cmpRegImm(self: *Emitter, reg: u8, imm: u16) !void {
        try self.emitByte(Op.cmp_reg_imm16);
        try self.emitByte(reg);
        try self.emitU16Le(imm);
    }

    /// `cmp dst, src` (0x81) — flags ← dst - src.
    fn cmpRegReg(self: *Emitter, dst: u8, src: u8) !void {
        try self.emitByte(Op.cmp_reg_reg);
        try self.emitByte(dst);
        try self.emitByte(src);
    }

    /// `and src, dst` (0x61) — `dst ← dst & src`. Source-first byte
    /// per `bitwise.andRegReg` decode.
    fn andRegReg(self: *Emitter, dst: u8, src: u8) !void {
        try self.emitByte(Op.and_reg_reg);
        try self.emitByte(src);
        try self.emitByte(dst);
    }

    /// `or src, dst` (0x63).
    fn orRegReg(self: *Emitter, dst: u8, src: u8) !void {
        try self.emitByte(Op.or_reg_reg);
        try self.emitByte(src);
        try self.emitByte(dst);
    }

    /// `xor src, dst` (0x65).
    fn xorRegReg(self: *Emitter, dst: u8, src: u8) !void {
        try self.emitByte(Op.xor_reg_reg);
        try self.emitByte(src);
        try self.emitByte(dst);
    }

    /// `not reg` (0x66) — `reg ← ~reg`.
    fn notRegOp(self: *Emitter, reg: u8) !void {
        try self.emitByte(Op.not_reg);
        try self.emitByte(reg);
    }

    /// `shl dst, src` (0x71). Source register holds the shift count.
    fn shlRegReg(self: *Emitter, dst: u8, src: u8) !void {
        try self.emitByte(Op.shl_reg_reg);
        try self.emitByte(dst);
        try self.emitByte(src);
    }

    /// `shr dst, src` (0x73).
    fn shrRegReg(self: *Emitter, dst: u8, src: u8) !void {
        try self.emitByte(Op.shr_reg_reg);
        try self.emitByte(dst);
        try self.emitByte(src);
    }

    /// Emit a forward jump with a placeholder address slot. Returns
    /// the offset of the 2-byte slot inside the current code buffer —
    /// pass it to `patchJumpTo` once the target offset is known.
    fn emitJumpPlaceholder(self: *Emitter, op: u8) !usize {
        try self.emitByte(op);
        const slot = try self.currentOffset();
        try self.emitU16Le(0); // placeholder
        return slot;
    }

    /// Resolve a forward-jump patch: writes the absolute address
    /// `currentBufferBase() + target_offset` into the 2-byte slot at
    /// `patch_offset`. `target_offset` is a byte offset inside the
    /// current code buffer.
    fn patchJumpTo(self: *Emitter, patch_offset: usize, target_offset: usize) !void {
        const buf = try self.currentCode();
        // @as: usize → u16; per-buffer offset stays ≤ 64 KiB.
        const target_in_buffer: u16 = @intCast(target_offset);
        const target_addr: u16 = self.currentBufferBase() +% target_in_buffer;
        // safety: u16 → 2 LE bytes; both casts are byte-masks.
        buf.items[patch_offset] = @intCast(target_addr & 0xFF);
        buf.items[patch_offset + 1] = @intCast(target_addr >> 8);
    }

    /// Emit an unconditional jump to a known target offset within the
    /// current buffer. Used for back-edges (loop bottom → loop top).
    fn emitJumpBack(self: *Emitter, target_offset: usize) !void {
        try self.emitByte(Op.jmp_addr);
        // @as: usize → u16; per-buffer offset stays ≤ 64 KiB.
        const target_in_buffer: u16 = @intCast(target_offset);
        try self.emitU16Le(self.currentBufferBase() +% target_in_buffer);
    }

    /// Base address of the current code buffer in VM memory — used to
    /// turn a buffer-local offset into a `jmp` target.
    fn currentBufferBase(self: *const Emitter) u16 {
        if (self.current_bank) |_| return bank_window_base;
        return code_base;
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

    /// Conservatively count every local slot the fn body could need
    /// so the prologue can `sub frame_bytes, sp` up-front. The count
    /// recurses through control-flow forms; arms that never execute
    /// at runtime still reserve their slots (the savings of slot
    /// reuse aren't worth a live-range analysis at this scale).
    fn countLocalsInBody(self: *const Emitter, body: []const ast.Statement) usize {
        var n: usize = 0;
        for (body) |s| n += self.countLocalsInStmt(s);
        return n;
    }

    fn countLocalsInStmt(self: *const Emitter, stmt: ast.Statement) usize {
        return switch (stmt) {
            .let_decl, .const_decl => 1,
            .block => |b| self.countLocalsInBody(b.body),
            .if_stmt => |is_| blk: {
                var n: usize = 0;
                for (is_.arms) |a| {
                    if (a.let_pattern) |p| n += countBindingsInPattern(p.*);
                    n += self.countLocalsInBody(a.body);
                }
                if (is_.else_body) |eb| n += self.countLocalsInBody(eb);
                break :blk n;
            },
            .while_stmt => |ws| blk: {
                var n: usize = 0;
                if (ws.let_pattern) |p| n += countBindingsInPattern(p.*);
                n += self.countLocalsInBody(ws.body);
                break :blk n;
            },
            // Range-based `for` reserves 1 hidden slot for the
            // `end` bound (the iteration variable uses its own slot).
            // User-iterator support lands in M3 with method calls.
            .for_stmt => |fs| 1 + 1 + self.countLocalsInBody(fs.body),
            .repeat_stmt => |rs| self.countLocalsInBody(rs.body),
            .match_stmt => |ms| blk: {
                // 1 scratch slot to bind the scrutinee when it isn't
                // already an ident (so subsequent cmps don't re-eval).
                var n: usize = if (ms.scrutinee.* == .ident) 0 else 1;
                for (ms.arms) |a| {
                    n += countBindingsInPattern(a.pattern.*);
                    n += self.countLocalsInBody(a.body);
                }
                break :blk n;
            },
            .defer_stmt => |ds| self.countLocalsInStmt(ds.body.*),
            else => 0,
        };
    }

    /// Count the local-slot bindings a pattern introduces. Only the
    /// ident pattern binds at M2; or-patterns reject inner binders
    /// (parser already enforces this).
    fn countBindingsInPattern(pat: ast.Pattern) usize {
        return switch (pat) {
            .ident => 1,
            else => 0,
        };
    }

    // ---------- program + def emission ----------

    /// Top-level orchestrator: emit the entry def first (so it
    /// lands at `code_base`, matching `Options.entry_name` →
    /// header `entry_point`), then every other top-level `def` in
    /// source order, then patch unresolved call sites.
    fn emitProgram(self: *Emitter, program: *const ast.Program, entry_name: []const u8) !void {
        // Pre-pass 1: register globals (top-level let/const).
        try self.registerGlobals(program);
        // Pre-pass 2: collect each def's bank so `emitCall` can
        // decide direct-call vs trampoline without needing the
        // target's address yet.
        try self.collectDefBanks(program);

        const entry = findEntryDef(self.source, program, entry_name).?;
        try self.emitDef(entry, .entry);
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| if (dd != entry) try self.emitDef(dd, .regular),
            else => {},
        };

        // Emit the `__call_bank` trampoline only if at least one
        // cross-bank call site asked for it (saves 10 bytes when
        // the program is entirely un-banked or single-bank).
        if (self.needsTrampoline()) try self.emitCallBankTrampoline();

        try self.patchCalls();
    }

    /// Scan top-level `def`s, recording each name → its `@bank N`
    /// annotation (or `null` for base-image defs).
    fn collectDefBanks(self: *Emitter, program: *const ast.Program) !void {
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| {
                const name = self.source[dd.name.start..dd.name.end];
                const dup = try self.arena.dupe(u8, name);
                var bank: ?u8 = null;
                for (dd.annotations) |ann| {
                    const ann_name = self.source[ann.name.start..ann.name.end];
                    if (std.mem.eql(u8, ann_name, "bank") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
                        // @as: typechecker enforces u8 range on `@bank N`.
                        bank = @intCast(ann.args[0].int_lit.value & 0xFF);
                    }
                }
                try self.fn_banks.put(self.arena, dup, bank);
            },
            else => {},
        };
    }

    /// `true` when any unresolved call patch targets the
    /// trampoline. We only emit the trampoline body when at least
    /// one call site needs it — keeps single-bank programs lean.
    fn needsTrampoline(self: *const Emitter) bool {
        for (self.call_patches.items) |p| switch (p.target) {
            .trampoline => return true,
            else => {},
        };
        return false;
    }

    /// Emit the `__call_bank` trampoline at the current base-
    /// image cursor. Caller sets up `r1 = target_addr`,
    /// `r2 = target_bank`, then `call __call_bank`. The trampoline
    /// saves the caller's `mb`, switches to the target bank, calls
    /// through `r1`, restores `mb`, and `ret`s back.
    ///
    /// Layout (10 bytes):
    ///   push mb         ; 31 0C
    ///   mov r2, mb      ; 11 03 0C
    ///   call r1         ; A1 02
    ///   pop mb          ; 32 0C
    ///   ret             ; A2
    fn emitCallBankTrampoline(self: *Emitter) !void {
        // The trampoline must live in the base image (always
        // reachable regardless of `mb`). Save / restore the
        // bank-routing state explicitly even though we expect the
        // caller to be in the base buffer already.
        const saved_bank = self.current_bank;
        self.current_bank = null;
        defer self.current_bank = saved_bank;

        // @as: narrow usize → u16; base image fits in 64 KiB.
        const tramp_offset: u16 = @intCast(self.code.items.len);
        self.trampoline_addr = code_base + tramp_offset;

        // push mb
        try self.emitByte(Op.push_reg);
        try self.emitByte(Reg.mb);
        // mov r2, mb
        try self.movRegToReg(Reg.r2, Reg.mb);
        // call r1
        try self.emitByte(Op.call_reg);
        try self.emitByte(Reg.r1);
        // pop mb
        try self.emitByte(Op.pop_reg);
        try self.emitByte(Reg.mb);
        // ret
        try self.emitByte(Op.ret_op);
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

    /// Emit a store of `src` reg's value into `g`'s slot. Byte-
    /// width globals use `movl` (low-byte store) so the
    /// neighboring byte stays untouched — critical for MMIO where
    /// adjacent addresses are distinct registers.
    fn emitGlobalStore(self: *Emitter, src: u8, g: Global) !void {
        switch (g.placement) {
            .addr, .data => {
                if (g.width == 1) {
                    try self.movlRegToAddr(src, g.address);
                } else {
                    try self.movRegToAddr(src, g.address);
                }
            },
            .zero_page => {
                // @as: zero-page address fits in u8; placement.zero_page guarantees address ≤ 0xFF.
                const zp: u8 = @intCast(g.address);
                if (g.width == 1) {
                    try self.movlRegToZp(src, zp);
                } else {
                    try self.movRegToZp(src, zp);
                }
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

        // Function body opens the outermost block of the frame —
        // `defer`s at the top of the body run before the implicit
        // epilogue's `hlt` / `ret`.
        try self.pushBlock();
        for (def.body) |stmt| try self.emitStatement(stmt);
        try self.popBlockWithDefers();

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
            const target_addr: u16 = switch (p.target) {
                .fn_name => |name| self.fn_addresses.get(name) orelse {
                    const msg = try std.fmt.allocPrint(
                        self.arena,
                        "codegen: call target `{s}` is not a known top-level def",
                        .{name},
                    );
                    try self.diagnostics.append(self.allocator, .{
                        .severity = .fatal,
                        .code = "E_CODEGEN_UNDEFINED_FN",
                        .message = msg,
                        .span = p.span,
                    });
                    continue;
                },
                .trampoline => self.trampoline_addr orelse continue,
            };
            // Resolve which buffer holds this patch — base or
            // one of the bank ArrayLists.
            const buf: []u8 = if (p.bank) |b|
                if (self.banks.getPtr(b)) |bl| bl.items else continue
            else
                self.code.items;
            // Overwrite the 2-byte LE address slot.
            // safety: u16 → 2 bytes by definition; both casts are byte-masks.
            buf[p.code_offset] = @intCast(target_addr & 0xFF);
            buf[p.code_offset + 1] = @intCast(target_addr >> 8);
        }
    }

    // ---------- statement emission ----------

    fn emitStatement(self: *Emitter, stmt: ast.Statement) EmitError!void {
        switch (stmt) {
            .let_decl => |d| try self.emitLetDecl(d),
            .const_decl => |d| try self.emitConstDecl(d),
            .assign => |a| try self.emitAssign(a),
            .return_stmt => |r| try self.emitReturnStmt(r),
            .print_stmt => |p| try self.emitPrintStmt(p),
            .expr_stmt => |es| try self.emitExprDiscard(es.expr),
            .discard => |ds| try self.emitExprDiscard(ds.expr),
            .block => |b| try self.emitBlockStmt(b),
            .if_stmt => |is_| try self.emitIfStmt(is_),
            .while_stmt => |ws| try self.emitWhileStmt(ws),
            .for_stmt => |fs| try self.emitForStmt(fs),
            .repeat_stmt => |rs| try self.emitRepeatStmt(rs),
            .match_stmt => |ms| try self.emitMatchStmt(ms),
            .break_stmt => |bs| try self.emitLoopJump(bs, .break_),
            .continue_stmt => |cs| try self.emitLoopJump(cs, .continue_),
            .defer_stmt => |ds| try self.emitDeferStmt(ds),
            else => try self.unsupported(stmt.span(), "this statement form"),
        }
    }

    /// Walk `body` inside a fresh `Block` scope. The common
    /// helper for any statement-list with its own defer lifetime
    /// (do-blocks, if-arm bodies, loop bodies, match-arm bodies).
    fn emitScopedBody(self: *Emitter, body: []const ast.Statement) EmitError!void {
        try self.pushBlock();
        for (body) |s| try self.emitStatement(s);
        try self.popBlockWithDefers();
    }

    fn emitBlockStmt(self: *Emitter, b: ast.BlockStmt) !void {
        try self.emitScopedBody(b.body);
    }

    fn emitDeferStmt(self: *Emitter, ds: ast.DeferStmt) !void {
        if (self.block_stack.items.len == 0) {
            try self.diagFatal(ds.span, "E_CODEGEN_DEFER_NO_BLOCK", "codegen: `defer` outside a block — likely a frontend bug");
            return;
        }
        // Reject the immediate forbidden shapes per spec §4.10. The
        // typechecker should also catch these but the codegen check
        // keeps the lowering defensive against frontend changes.
        switch (ds.body.*) {
            .return_stmt => {
                try self.diagFatal(ds.span, "E_DEFER_RETURN", "codegen: `defer return` is not allowed — defers may not redirect control flow");
                return;
            },
            .break_stmt => {
                try self.diagFatal(ds.span, "E_DEFER_BREAK", "codegen: `defer break` is not allowed — defers may not redirect control flow");
                return;
            },
            .continue_stmt => {
                try self.diagFatal(ds.span, "E_DEFER_CONTINUE", "codegen: `defer continue` is not allowed — defers may not redirect control flow");
                return;
            },
            .defer_stmt => {
                try self.diagFatal(ds.span, "E_DEFER_DEFER", "codegen: `defer defer` is not allowed — wrap the body in `do … end` if you need a multi-statement defer");
                return;
            },
            else => {},
        }
        const top = self.block_stack.items.len - 1;
        try self.block_stack.items[top].defers.append(self.allocator, ds.body);
    }

    // ---------- control-flow lowering ----------

    /// Lower `if cond1 then ... elif cond2 then ... else ... end`.
    /// Each arm emits its condition test (jumping over the body on
    /// false), then the body, then a forward jump over every later
    /// arm. The forward jumps collapse at the end of the if chain
    /// onto one shared `end` label.
    ///
    /// The `if let pat = expr [when guard]` form binds a fresh local
    /// for the pattern and guards the arm on the bind + the optional
    /// `when` predicate. Slice M2 supports ident binders only —
    /// destructuring patterns land in M3 alongside enums.
    fn emitIfStmt(self: *Emitter, is_: ast.IfStmt) !void {
        // Patches that need to jump to the end of the whole chain
        // once the chain finishes emitting (one per arm body fall-
        // through, plus the else body if it terminates with one).
        var end_patches: std.ArrayList(usize) = .empty;
        defer end_patches.deinit(self.allocator);

        for (is_.arms) |arm| {
            // Per spec §4.4: an arm is either the plain `cond`
            // shape OR the `let pat = expr [when guard]` shape.
            const skip_body_patch = try self.emitIfArmTest(arm);

            // Body — own scope (defers attach here).
            try self.emitScopedBody(arm.body);

            // After the body, jump to the end of the chain. We can
            // skip this jump if it's the last arm AND there is no
            // else body (the body's last byte naturally falls
            // through to whatever's next).
            try end_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jmp_addr));

            // Wire the "false" jump to land here, after the body's
            // forward jump and right before the next arm's test.
            const after_body = try self.currentOffset();
            try self.patchJumpTo(skip_body_patch, after_body);
        }

        if (is_.else_body) |eb| try self.emitScopedBody(eb);

        const end_offset = try self.currentOffset();
        for (end_patches.items) |p| try self.patchJumpTo(p, end_offset);
    }

    /// Emit the test for one if-arm and return the offset of the
    /// "skip body" jump patch — the caller resolves it to the byte
    /// right after the body.
    fn emitIfArmTest(self: *Emitter, arm: ast.IfArm) !usize {
        if (arm.cond) |c| {
            // Plain `if cond` arm — evaluate the cond as a 0 / 1
            // value in acu, compare against 0, jump-on-equal.
            try self.emitCondBranch(c);
            // `emitCondBranch` returns nothing — emit the placeholder
            // here. Falls through when cond is truthy, jumps when
            // cond is falsy. We use jeq (skip body on zero).
            return try self.emitJumpPlaceholder(Op.jeq_addr);
        }
        // `if let pat = expr [when guard]` — M2 ident-binder form.
        const pat = arm.let_pattern.?.*;
        const expr = arm.let_expr.?;
        // Evaluate the RHS into acu.
        try self.emitExpr(expr);
        switch (pat) {
            .ident => |id| {
                const name = self.source[id.name.start..id.name.end];
                const dup = try self.arena.dupe(u8, name);
                const ofs = try self.allocLocal(dup);
                // Bind the slot — the ident pattern always matches.
                try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
                // Optional `when guard` — evaluate and skip body
                // on zero. With no guard, the bind always succeeds,
                // so we emit `cmp acu, 0; jeq skip` after binding to
                // turn the bind itself into a "non-zero" test? No —
                // an ident binder matches anything, including 0.
                // Without a guard, the arm always fires.
                if (arm.let_guard) |g| {
                    try self.emitExpr(g);
                    try self.cmpRegImm(Reg.acu, 0);
                    return try self.emitJumpPlaceholder(Op.jeq_addr);
                }
                // No guard — placeholder for symmetry with the plain
                // arm, but emit an `unconditional NO-skip`: a never-
                // taken jump. Simplest is to compare a const-true to
                // 0 with jne, which never branches. We model that by
                // not emitting a real skip — but the caller expects
                // an offset to patch. Emit a `jeq` past a comparison
                // that always fails (acu = 1; cmp 0).
                try self.movImmToReg(1, Reg.r1);
                try self.cmpRegImm(Reg.r1, 0);
                return try self.emitJumpPlaceholder(Op.jeq_addr);
            },
            else => {
                try self.unsupported(arm.span, "`if let` patterns other than a bare ident (M3 brings destructuring)");
                // Emit a placeholder anyway so the caller doesn't
                // walk the patches list into a hole.
                return try self.emitJumpPlaceholder(Op.jeq_addr);
            },
        }
    }

    /// Evaluate a boolean-valued expression and leave a 0 / 1 in
    /// `acu`, then `cmp acu, 0` so the caller can pick a conditional
    /// jump (typically `jeq` to skip on false, `jne` to fall through
    /// on true). When the expression is a direct comparison or
    /// boolean literal the codegen folds the materialization step,
    /// emitting just the cmp.
    fn emitCondBranch(self: *Emitter, e: *const ast.Expr) !void {
        // Fast-path: a top-level comparison or logical-not can drive
        // the flags directly without going through a 0/1 materialize.
        if (e.* == .binary) {
            const b = e.binary;
            switch (b.op) {
                .eq, .neq, .lt, .lte, .gt, .gte => {
                    // Eval LHS into acu, eval RHS into r1, cmp acu, r1.
                    try self.emitExpr(b.rhs);
                    try self.pushReg(Reg.acu);
                    try self.emitExpr(b.lhs);
                    try self.popReg(Reg.r1);
                    try self.cmpRegReg(Reg.acu, Reg.r1);
                    // We always emit a jeq below to skip the body on
                    // `false`; turn the comparison's flag-test
                    // accordingly. For `==`, `false` means Z=0 (so
                    // jne skips). We can't easily change the op the
                    // caller emits without a callback, so we
                    // materialize a synthetic acu-vs-0 result by
                    // flipping with a small sequence:
                    //
                    //   <cmp>
                    //   mov 0, acu
                    //   <set acu = 1 if cond>
                    //   cmp acu, 0
                    //
                    // That's more bytes than needed. Cleaner: do
                    // the full materialization path and let the
                    // caller's jeq do the right thing on the 0/1.
                    try self.materializeBoolFromFlags(b.op);
                    try self.cmpRegImm(Reg.acu, 0);
                    return;
                },
                .log_and, .log_or => {
                    try self.emitShortCircuitBool(b);
                    try self.cmpRegImm(Reg.acu, 0);
                    return;
                },
                else => {},
            }
        }
        if (e.* == .unary and e.unary.op == .log_not) {
            try self.emitExpr(e.unary.operand);
            // Logical NOT — invert acu: acu = (acu == 0) ? 1 : 0.
            try self.cmpRegImm(Reg.acu, 0);
            try self.materializeBoolFromFlags(.eq);
            try self.cmpRegImm(Reg.acu, 0);
            return;
        }
        // Generic path — evaluate to acu, then test against 0.
        try self.emitExpr(e);
        try self.cmpRegImm(Reg.acu, 0);
    }

    /// Materialize a 0 / 1 boolean in `acu` from the current flag
    /// state set by a preceding `cmp`. Picks the right conditional
    /// jump per comparison kind.
    fn materializeBoolFromFlags(self: *Emitter, op: ast.BinaryOp) !void {
        const taken_op: u8 = switch (op) {
            .eq => Op.jeq_addr,
            .neq => Op.jne_addr,
            .lt => Op.jlt_addr,
            .lte => Op.jle_addr,
            .gt => Op.jgt_addr,
            .gte => Op.jge_addr,
            // allow-strict: emitCondBranch filters to comparison ops before calling here.
            else => unreachable,
        };
        // Pattern:
        //   <prior cmp>
        //   jXX true_label
        //   mov 0, acu
        //   jmp end
        // true_label:
        //   mov 1, acu
        // end:
        const true_patch = try self.emitJumpPlaceholder(taken_op);
        try self.movImmToReg(0, Reg.acu);
        const end_patch = try self.emitJumpPlaceholder(Op.jmp_addr);
        const true_offset = try self.currentOffset();
        try self.movImmToReg(1, Reg.acu);
        const end_offset = try self.currentOffset();
        try self.patchJumpTo(true_patch, true_offset);
        try self.patchJumpTo(end_patch, end_offset);
    }

    /// Lower a short-circuiting `and` / `or` into a chain of
    /// conditional jumps that leaves a 0 / 1 in `acu`.
    fn emitShortCircuitBool(self: *Emitter, b: ast.BinaryExpr) !void {
        switch (b.op) {
            .log_and => {
                // acu = lhs; if acu == 0 -> short-circuit false.
                try self.emitExpr(b.lhs);
                try self.cmpRegImm(Reg.acu, 0);
                const short_patch = try self.emitJumpPlaceholder(Op.jeq_addr);
                try self.emitExpr(b.rhs);
                // Normalize rhs to 0/1.
                try self.cmpRegImm(Reg.acu, 0);
                try self.materializeBoolFromFlags(.neq);
                const end_patch = try self.emitJumpPlaceholder(Op.jmp_addr);
                const short_offset = try self.currentOffset();
                try self.movImmToReg(0, Reg.acu);
                const end_offset = try self.currentOffset();
                try self.patchJumpTo(short_patch, short_offset);
                try self.patchJumpTo(end_patch, end_offset);
            },
            .log_or => {
                try self.emitExpr(b.lhs);
                try self.cmpRegImm(Reg.acu, 0);
                const short_patch = try self.emitJumpPlaceholder(Op.jne_addr);
                try self.emitExpr(b.rhs);
                try self.cmpRegImm(Reg.acu, 0);
                try self.materializeBoolFromFlags(.neq);
                const end_patch = try self.emitJumpPlaceholder(Op.jmp_addr);
                const short_offset = try self.currentOffset();
                try self.movImmToReg(1, Reg.acu);
                const end_offset = try self.currentOffset();
                try self.patchJumpTo(short_patch, short_offset);
                try self.patchJumpTo(end_patch, end_offset);
            },
            // allow-strict: caller filters to log_and / log_or before invoking this helper.
            else => unreachable,
        }
    }

    /// Lower `while cond ... end`. Standard top-test loop:
    /// continue-target sits at the cond test, exit-target at the
    /// byte after the back-edge. `while let` is supported for the
    /// ident-binder form per spec §4.5.2.
    fn emitWhileStmt(self: *Emitter, ws: ast.WhileStmt) !void {
        const cond_offset = try self.currentOffset();
        const label_str: ?[]const u8 = if (ws.label) |s|
            try self.arena.dupe(u8, self.source[s.start..s.end])
        else
            null;

        // Push the body block BEFORE the cond test so the frame's
        // `body_block_idx` aligns with the actual body block. Defers
        // registered inside the body live in this block.
        try self.pushBlock();
        const body_block_idx = self.block_stack.items.len - 1;
        try self.loop_stack.append(self.allocator, .{
            .label = label_str,
            .body_block_idx = body_block_idx,
            .break_patches = .empty,
            .continue_patches = .empty,
        });

        // Condition test — either plain cond or `while let pat = expr`.
        const exit_on_false_patch = if (ws.cond) |c| blk: {
            try self.emitCondBranch(c);
            break :blk try self.emitJumpPlaceholder(Op.jeq_addr);
        } else blk: {
            // while let pat = expr [when guard]
            const pat = ws.let_pattern.?.*;
            try self.emitExpr(ws.let_expr.?);
            switch (pat) {
                .ident => |id| {
                    const name = self.source[id.name.start..id.name.end];
                    const dup = try self.arena.dupe(u8, name);
                    const ofs = try self.allocLocal(dup);
                    try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
                    if (ws.let_guard) |g| {
                        try self.emitExpr(g);
                        try self.cmpRegImm(Reg.acu, 0);
                        break :blk try self.emitJumpPlaceholder(Op.jeq_addr);
                    }
                    // No guard — ident binder always matches; emit
                    // a never-taken skip for symmetry.
                    try self.movImmToReg(1, Reg.r1);
                    try self.cmpRegImm(Reg.r1, 0);
                    break :blk try self.emitJumpPlaceholder(Op.jeq_addr);
                },
                else => {
                    try self.unsupported(ws.span, "`while let` patterns other than a bare ident");
                    break :blk try self.emitJumpPlaceholder(Op.jeq_addr);
                },
            }
        };

        // Body — defers register against the block we just pushed.
        for (ws.body) |s| try self.emitStatement(s);
        try self.popBlockWithDefers();

        // Back-edge to the cond test.
        try self.emitJumpBack(cond_offset);

        // `break` lands here; `continue` lands at the cond test.
        const exit_offset = try self.currentOffset();
        try self.patchJumpTo(exit_on_false_patch, exit_offset);

        var frame = self.loop_stack.pop().?;
        for (frame.break_patches.items) |p| try self.patchJumpTo(p, exit_offset);
        for (frame.continue_patches.items) |p| try self.patchJumpTo(p, cond_offset);
        frame.break_patches.deinit(self.allocator);
        frame.continue_patches.deinit(self.allocator);
    }

    /// Lower `repeat body until cond`. Bottom-test loop: the body
    /// always runs at least once; `cond` is tested after the body
    /// and the loop exits when `cond` is truthy. `continue` jumps
    /// to the trailing test; `break` jumps past it.
    fn emitRepeatStmt(self: *Emitter, rs: ast.RepeatStmt) !void {
        const top_offset = try self.currentOffset();
        const label_str: ?[]const u8 = if (rs.label) |s|
            try self.arena.dupe(u8, self.source[s.start..s.end])
        else
            null;

        try self.pushBlock();
        const body_block_idx = self.block_stack.items.len - 1;
        try self.loop_stack.append(self.allocator, .{
            .label = label_str,
            .body_block_idx = body_block_idx,
            .break_patches = .empty,
            .continue_patches = .empty,
        });

        for (rs.body) |s| try self.emitStatement(s);
        try self.popBlockWithDefers();

        // `continue` jumps here — the trailing `until` test.
        const test_offset = try self.currentOffset();
        try self.emitCondBranch(rs.cond);
        // `repeat … until cond` exits when cond is truthy — so
        // `jne` (cond non-zero) jumps back over the back-edge to
        // the bottom of the loop, while a `jeq` falls back to top.
        // Simpler: emit `jeq top` so that when cond is false (zero)
        // we go back, and when cond is true we fall through to exit.
        try self.emitByte(Op.jeq_addr);
        // @as: usize → u16; per-buffer offset stays ≤ 64 KiB.
        const top_in_buffer: u16 = @intCast(top_offset);
        try self.emitU16Le(self.currentBufferBase() +% top_in_buffer);

        const exit_offset = try self.currentOffset();
        var frame = self.loop_stack.pop().?;
        for (frame.break_patches.items) |p| try self.patchJumpTo(p, exit_offset);
        for (frame.continue_patches.items) |p| try self.patchJumpTo(p, test_offset);
        frame.break_patches.deinit(self.allocator);
        frame.continue_patches.deinit(self.allocator);
    }

    /// Lower `for x in start..end [step S] body end`. M2 ships the
    /// range-special-case per spec §4.5.3; user-defined iterators
    /// (objects with `next(self) -> T?`) land in M3 alongside method
    /// calls + class codegen.
    fn emitForStmt(self: *Emitter, fs: ast.ForStmt) !void {
        // Only handle the range special case for M2 — the spec
        // designates ranges + arrays + strings as compiler-known
        // iterables; method-call iteration lands in M3.
        if (fs.iter.* != .range) {
            try self.unsupported(fs.span, "`for` over non-range iterables (M3 brings user-iterator support via method calls)");
            return;
        }
        const range = fs.iter.range;
        const inclusive = range.inclusive;
        const step_expr = fs.step;
        const binding_name = self.source[fs.binding.start..fs.binding.end];

        // Allocate slots: the loop variable + a hidden `end` slot.
        const dup_name = try self.arena.dupe(u8, binding_name);
        const var_ofs = try self.allocLocal(dup_name);
        const end_ofs = try self.allocLocal(try self.arena.dupe(u8, "\x00__for_end"));

        // Evaluate start → acu, store into the loop variable.
        try self.emitExpr(range.start);
        try self.movRegToRegOffset(Reg.acu, Reg.fp, var_ofs);
        // Evaluate end → acu, store into the hidden end slot.
        try self.emitExpr(range.end);
        try self.movRegToRegOffset(Reg.acu, Reg.fp, end_ofs);

        const label_str: ?[]const u8 = if (fs.label) |s|
            try self.arena.dupe(u8, self.source[s.start..s.end])
        else
            null;

        try self.pushBlock();
        const body_block_idx = self.block_stack.items.len - 1;
        try self.loop_stack.append(self.allocator, .{
            .label = label_str,
            .body_block_idx = body_block_idx,
            .break_patches = .empty,
            .continue_patches = .empty,
        });

        // Top-of-loop: load `current`, load `end`, compare. Exit
        // when current > end (inclusive) or current >= end (exclusive).
        const test_offset = try self.currentOffset();
        try self.movRegOffsetToReg(Reg.fp, var_ofs, Reg.acu);
        try self.movRegOffsetToReg(Reg.fp, end_ofs, Reg.r1);
        try self.cmpRegReg(Reg.acu, Reg.r1);
        const exit_patch = if (inclusive)
            try self.emitJumpPlaceholder(Op.jgt_addr) // exit on current > end
        else
            try self.emitJumpPlaceholder(Op.jge_addr); // exit on current >= end

        // Body.
        for (fs.body) |s| try self.emitStatement(s);
        try self.popBlockWithDefers();

        // `continue` target — the step-and-back-edge. Step then
        // jump back to the test.
        const continue_offset = try self.currentOffset();
        // Load current, add step, store back.
        try self.movRegOffsetToReg(Reg.fp, var_ofs, Reg.acu);
        if (step_expr) |se| {
            // Evaluate step expression — typechecker has already
            // confirmed it's an integer expression. For M2 we accept
            // an int_lit fast-path; arbitrary exprs fall through to
            // the general eval-and-add path.
            if (se.* == .int_lit) {
                // @as: parser stores int_lit as i32; range steps fit i16 per spec §4.5.1.
                const step_i16: i16 = @truncate(se.int_lit.value);
                // safety: i16 → u16 keeps the two's-complement bit pattern for negative steps.
                const step_val: u16 = @bitCast(step_i16);
                try self.addImmToReg(step_val, Reg.acu);
            } else {
                try self.pushReg(Reg.acu);
                try self.emitExpr(se);
                try self.movRegToReg(Reg.acu, Reg.r1);
                try self.popReg(Reg.acu);
                try self.addRegToAcu(Reg.r1);
            }
        } else {
            try self.addImmToReg(1, Reg.acu);
        }
        try self.movRegToRegOffset(Reg.acu, Reg.fp, var_ofs);
        try self.emitJumpBack(test_offset);

        const exit_offset = try self.currentOffset();
        try self.patchJumpTo(exit_patch, exit_offset);

        var frame = self.loop_stack.pop().?;
        for (frame.break_patches.items) |p| try self.patchJumpTo(p, exit_offset);
        for (frame.continue_patches.items) |p| try self.patchJumpTo(p, continue_offset);
        frame.break_patches.deinit(self.allocator);
        frame.continue_patches.deinit(self.allocator);
    }

    const LoopJumpKind = enum { break_, continue_ };

    /// Lower `break [:label]` / `continue [:label]`. Unwinds every
    /// block between the jump site and the target loop (innermost
    /// match for unlabeled, named match for labeled), emits the
    /// jump placeholder, and records it on the target frame's
    /// `break_patches` / `continue_patches` for resolution at loop
    /// teardown.
    fn emitLoopJump(self: *Emitter, j: ast.LoopJumpStmt, kind: LoopJumpKind) !void {
        const frame = self.findLoopFrame(j.label) orelse {
            try self.diagFatal(j.span, "E_CODEGEN_LOOP_JUMP_NO_LOOP", "codegen: `break` / `continue` outside an enclosing loop");
            return;
        };
        try self.unwindDefersDownTo(frame.body_block_idx);
        const patch = try self.emitJumpPlaceholder(Op.jmp_addr);
        switch (kind) {
            .break_ => try frame.break_patches.append(self.allocator, patch),
            .continue_ => try frame.continue_patches.append(self.allocator, patch),
        }
    }

    /// Lower `match scrutinee case … end`. Pure decision-tree for
    /// M2 (sequential cmp + branch per arm); a jump-table optimizer
    /// for tag-dispatch enums can slot in once enum codegen lands
    /// (M3). The compiler handles the common shapes:
    ///
    /// - Wildcard `_` and ident binders (always match).
    /// - Integer / char / bool / nil literal patterns.
    /// - `A | B | C` or-patterns (DEDUPED — each alt emits one cmp,
    ///   then all alts jump to one shared body label).
    /// - Range patterns (`a..b` / `a..=b`) — one cmp + cond branch
    ///   pair instead of a per-element chain.
    /// - `when guard` clauses — evaluated after the pattern match.
    ///
    /// Slice M2 leaves enum-variant / tuple / struct destructuring
    /// patterns on the M3 boundary (they require enum-tag layout
    /// + field offsets, which arrive with the class / struct codegen).
    fn emitMatchStmt(self: *Emitter, ms: ast.MatchStmt) !void {
        // Bind the scrutinee to a slot so subsequent arms can re-test
        // it without re-evaluating side effects. Skip the bind if
        // the source already wrote an ident — direct loads stay cheap.
        const scrutinee_ofs: i8 = blk: {
            switch (ms.scrutinee.*) {
                .ident => {
                    // We re-load via the normal ident path each arm.
                    // Return 0 as a sentinel that the code below
                    // shouldn't touch — we'll dispatch on a flag.
                    break :blk 0;
                },
                else => {
                    try self.emitExpr(ms.scrutinee);
                    const ofs = try self.allocLocal(try self.arena.dupe(u8, "\x00__match"));
                    try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
                    break :blk ofs;
                },
            }
        };
        const scrutinee_is_ident = ms.scrutinee.* == .ident;

        // End-patches collapse onto the byte after the last arm.
        var end_patches: std.ArrayList(usize) = .empty;
        defer end_patches.deinit(self.allocator);

        for (ms.arms) |arm| {
            // Reload scrutinee → acu at the head of each arm so the
            // arm's tests use a known register state.
            if (scrutinee_is_ident) {
                try self.emitExpr(ms.scrutinee);
            } else {
                try self.movRegOffsetToReg(Reg.fp, scrutinee_ofs, Reg.acu);
            }

            // Emit the pattern test — returns a list of "skip body"
            // patches (one per alt for an or-pattern, one for a
            // simple pattern). Body matches when control falls
            // through to the body emission; skips when any patch
            // resolves to the post-body offset.
            var skip_patches: std.ArrayList(usize) = .empty;
            defer skip_patches.deinit(self.allocator);
            try self.emitPatternTest(arm.pattern.*, scrutinee_ofs, scrutinee_is_ident, &skip_patches);

            // Optional `when guard` — evaluate after the pattern
            // bound any names. Failure routes to the same skip set.
            if (arm.guard) |g| {
                try self.emitExpr(g);
                try self.cmpRegImm(Reg.acu, 0);
                try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jeq_addr));
            }

            // Body — own scope.
            try self.emitScopedBody(arm.body);
            // Skip past the rest of the match on success.
            try end_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jmp_addr));

            const after_arm = try self.currentOffset();
            for (skip_patches.items) |p| try self.patchJumpTo(p, after_arm);
        }

        const end_offset = try self.currentOffset();
        for (end_patches.items) |p| try self.patchJumpTo(p, end_offset);
    }

    /// Emit a pattern test against the scrutinee. The scrutinee
    /// is reloaded into `acu` per call — caller is responsible for
    /// any prelude that needs the same register state. Failures
    /// emit placeholder jumps and push them onto `skip_patches`;
    /// the caller resolves all of them to the same post-body offset.
    fn emitPatternTest(
        self: *Emitter,
        pat: ast.Pattern,
        scrutinee_ofs: i8,
        scrutinee_is_ident: bool,
        skip_patches: *std.ArrayList(usize),
    ) !void {
        switch (pat) {
            .wildcard => {
                // Always matches — emit nothing.
            },
            .ident => |ip| {
                // Bind the value to a local slot. Always matches.
                const name = self.source[ip.name.start..ip.name.end];
                const dup = try self.arena.dupe(u8, name);
                const ofs = try self.allocLocal(dup);
                try self.movRegToRegOffset(Reg.acu, Reg.fp, ofs);
            },
            .int_lit => |lit| {
                // @as: parser holds int_lit.value as i32; literals fit i16 by typecheck rule.
                const trimmed: i16 = @truncate(lit.value);
                // safety: i16 → u16 bit pattern preserved.
                const v: u16 = @bitCast(trimmed);
                try self.cmpRegImm(Reg.acu, v);
                try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jne_addr));
            },
            .char_lit => |c| {
                try self.cmpRegImm(Reg.acu, c.value);
                try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jne_addr));
            },
            .bool_lit => |b| {
                const v: u16 = if (b.value) 1 else 0;
                try self.cmpRegImm(Reg.acu, v);
                try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jne_addr));
            },
            .nil_lit => {
                try self.cmpRegImm(Reg.acu, 0);
                try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jne_addr));
            },
            .range_pattern => |rp| {
                // Lower `start..end` as: cmp acu, start; jlt skip;
                //                       cmp acu, end;   j(g[te]) skip.
                // We need the start / end as immediates — only
                // handle the int_lit fast-path in M2.
                if (rp.start.* != .int_lit or rp.end.* != .int_lit) {
                    try self.unsupported(rp.span, "non-literal range pattern endpoints (compile-time literals only in M2)");
                    return;
                }
                // @as: parser holds int_lit.value as i32; range bounds fit i16 by spec.
                const start_i16: i16 = @truncate(rp.start.int_lit.value);
                // safety: i16 → u16 keeps the two's-complement bit pattern.
                const start_v: u16 = @bitCast(start_i16);
                // @as: same i32 → i16 truncation for the end bound.
                const end_i16: i16 = @truncate(rp.end.int_lit.value);
                // safety: i16 → u16 keeps the two's-complement bit pattern.
                const end_v: u16 = @bitCast(end_i16);
                try self.cmpRegImm(Reg.acu, start_v);
                try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jlt_addr));
                try self.cmpRegImm(Reg.acu, end_v);
                const above_bound_op: u8 = if (rp.inclusive) Op.jgt_addr else Op.jge_addr;
                try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(above_bound_op));
            },
            .or_pattern => |op_| {
                // Each alt emits its own cmp + branch. A match jumps
                // OVER the remaining alts to the body. A non-match
                // falls through to the next alt. After the last alt,
                // a non-match jumps to the shared skip target.
                var match_patches: std.ArrayList(usize) = .empty;
                defer match_patches.deinit(self.allocator);

                for (op_.alts) |alt| {
                    var alt_skip: std.ArrayList(usize) = .empty;
                    defer alt_skip.deinit(self.allocator);
                    try self.emitPatternTest(alt.*, scrutinee_ofs, scrutinee_is_ident, &alt_skip);
                    // The alt matched if we reach this point — jump
                    // to the shared "body entry" label.
                    try match_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jmp_addr));
                    // Failure-skips of this alt land at the next alt
                    // (or, after the final alt, at the outer skip).
                    const after_alt = try self.currentOffset();
                    for (alt_skip.items) |p| try self.patchJumpTo(p, after_alt);
                }
                // None of the alts matched — punt to the outer
                // skip set.
                try skip_patches.append(self.allocator, try self.emitJumpPlaceholder(Op.jmp_addr));
                // All match-patches resolve to the byte after the
                // outer skip jump — i.e. the body's first byte.
                const body_offset = try self.currentOffset();
                for (match_patches.items) |p| try self.patchJumpTo(p, body_offset);
            },
            else => try self.unsupported(pat.span(), "this pattern shape (M3 brings enum / struct / tuple destructuring)"),
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
        // Defers attached to every still-active block fire before
        // the frame tears down — innermost first, LIFO within each
        // block. `acu` carries the return value through the cleanup
        // (the defer-emitter saves / restores it).
        try self.unwindAllDefersForReturn();
        if (self.is_entry) {
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
            .bit_not => try self.notRegOp(Reg.acu),
            .log_not => {
                // acu = (acu == 0) ? 1 : 0
                try self.cmpRegImm(Reg.acu, 0);
                try self.materializeBoolFromFlags(.eq);
            },
        }
    }

    fn emitBinary(self: *Emitter, b: ast.BinaryExpr) !void {
        // Short-circuit operators need to not evaluate their RHS
        // unconditionally — split them out before the standard
        // stack-machine pattern.
        switch (b.op) {
            .log_and, .log_or => {
                try self.emitShortCircuitBool(b);
                return;
            },
            else => {},
        }

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
                // (high:low); the dividend assumed to fit in 16
                // bits (sign-extension lands in a later commit).
                try self.movRegToReg(Reg.acu, Reg.r2); // r2 = low half
                try self.movImmToReg(0, Reg.acu); // high half = 0
                try self.divsRegReg(Reg.r1, Reg.r2); // r2 = quotient, acu = remainder
                try self.movRegToReg(Reg.r2, Reg.acu);
            },
            .mod => {
                // Same divs pattern as `div`, but keep `acu` (the
                // remainder is exactly what `mod` wants).
                try self.movRegToReg(Reg.acu, Reg.r2); // r2 = low half
                try self.movImmToReg(0, Reg.acu); // high half = 0
                try self.divsRegReg(Reg.r1, Reg.r2); // r2 = quotient, acu = remainder
            },
            .bit_and => try self.andRegReg(Reg.acu, Reg.r1),
            .bit_or => try self.orRegReg(Reg.acu, Reg.r1),
            .bit_xor => try self.xorRegReg(Reg.acu, Reg.r1),
            .shl => try self.shlRegReg(Reg.acu, Reg.r1),
            .shr => try self.shrRegReg(Reg.acu, Reg.r1),
            .eq, .neq, .lt, .lte, .gt, .gte => {
                try self.cmpRegReg(Reg.acu, Reg.r1);
                try self.materializeBoolFromFlags(b.op);
            },
            // allow-strict: handled by the short-circuit branch above; emitBinary never falls through here for these ops.
            .log_and, .log_or => unreachable,
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
        const callee_name = self.source[c.callee.ident.span.start..c.callee.ident.span.end];
        const dup = try self.arena.dupe(u8, callee_name);

        // Decide direct call vs trampoline by comparing the
        // caller's bank with the target's. The pre-pass populated
        // `fn_banks` so this resolves without needing the address.
        const target_bank: ?u8 = self.fn_banks.get(callee_name) orelse null;
        const cross_bank = !banksEqual(self.current_bank, target_bank);

        // Push args right-to-left (caller-cleans-up).
        var i: usize = c.args.len;
        while (i > 0) {
            i -= 1;
            try self.emitExpr(c.args[i]);
            try self.pushReg(Reg.acu);
        }

        if (cross_bank) {
            // Trampoline path:
            //   mov <target_addr>, r1   ; patched at end
            //   mov <target_bank>,  r2  ; literal at emit time
            //   call __call_bank        ; patched at end
            try self.emitByte(Op.mov_imm16_reg);
            const addr_patch_offset = try self.currentOffset();
            try self.emitU16Le(0); // placeholder
            try self.emitByte(Reg.r1);
            // mov <bank>, r2  — bank known at emit time (null → 0).
            const target_bank_byte: u8 = target_bank orelse 0;
            try self.movImmToReg(target_bank_byte, Reg.r2);
            // call __call_bank  (patched at end)
            try self.emitByte(Op.call_addr);
            const tramp_patch_offset = try self.currentOffset();
            try self.emitU16Le(0);

            try self.call_patches.append(self.allocator, .{
                .bank = self.current_bank,
                .code_offset = addr_patch_offset,
                .target = .{ .fn_name = dup },
                .span = c.span,
            });
            try self.call_patches.append(self.allocator, .{
                .bank = self.current_bank,
                .code_offset = tramp_patch_offset,
                .target = .trampoline,
                .span = c.span,
            });
        } else {
            // Direct same-bank call.
            try self.emitByte(Op.call_addr);
            const patch_offset = try self.currentOffset();
            try self.emitU16Le(0); // placeholder
            try self.call_patches.append(self.allocator, .{
                .bank = self.current_bank,
                .code_offset = patch_offset,
                .target = .{ .fn_name = dup },
                .span = c.span,
            });
        }

        if (c.args.len > 0) {
            // @as: each arg is one 16-bit word; arg count capped by parser.
            const drop_bytes: u16 = @intCast(c.args.len * 2);
            try self.addImmToReg(drop_bytes, Reg.sp);
        }
    }

    // ---------- block + defer infrastructure ----------

    /// Open a fresh lexical block on top of `block_stack`. Each
    /// nested `do…end`, `if`-arm body, loop body, and `match`-arm
    /// body pushes one before walking its statements.
    fn pushBlock(self: *Emitter) !void {
        try self.block_stack.append(self.allocator, .{ .defers = .empty });
    }

    /// Close the innermost block, emitting its registered `defer`
    /// statements inline in LIFO order before discarding the block.
    /// Use this on the fall-through exit path of the block.
    fn popBlockWithDefers(self: *Emitter) !void {
        // The block exits normally — emit its defers in reverse
        // registration order. `acu` may hold a return value (e.g. the
        // last expression statement in a fn body); we save / restore
        // around the defer body so cleanup statements can scribble
        // over acu freely.
        const top = self.block_stack.items.len - 1;
        const block = &self.block_stack.items[top];
        try self.emitDefersLifo(block.defers.items);
        var popped = self.block_stack.pop().?;
        popped.defers.deinit(self.allocator);
    }

    /// Emit `stmts` in LIFO order, preserving `acu` across the
    /// cleanup sequence (so a `return value` keeps its value
    /// visible to the caller after defers run).
    fn emitDefersLifo(self: *Emitter, stmts: []const *const ast.Statement) !void {
        if (stmts.len == 0) return;
        try self.pushReg(Reg.acu);
        var i = stmts.len;
        while (i > 0) {
            i -= 1;
            try self.emitStatement(stmts[i].*);
        }
        try self.popReg(Reg.acu);
    }

    /// Emit every active block's defers in LIFO order from the
    /// innermost outward. Used on the `return` path — the entire
    /// frame is being unwound, so every block's cleanup fires before
    /// the actual `ret` / `hlt`.
    fn unwindAllDefersForReturn(self: *Emitter) !void {
        var bi = self.block_stack.items.len;
        while (bi > 0) {
            bi -= 1;
            try self.emitDefersLifo(self.block_stack.items[bi].defers.items);
        }
    }

    /// Emit defers for every block in `[body_block_idx .. top]`
    /// inclusive — the range the codegen needs to unwind on
    /// `break` / `continue` for the loop whose body opens at
    /// `body_block_idx`.
    fn unwindDefersDownTo(self: *Emitter, body_block_idx: usize) !void {
        var bi = self.block_stack.items.len;
        while (bi > body_block_idx) {
            bi -= 1;
            try self.emitDefersLifo(self.block_stack.items[bi].defers.items);
        }
    }

    /// Walk the loop stack from innermost outward looking for the
    /// frame targeted by a `break` / `continue`. Unlabeled jumps
    /// match the innermost frame; labeled jumps match by string
    /// equality. Returns the matching pointer so the caller can
    /// append patches in place.
    fn findLoopFrame(self: *Emitter, label_span: ?ast.Span) ?*LoopFrame {
        if (self.loop_stack.items.len == 0) return null;
        const want_label: ?[]const u8 = if (label_span) |s|
            self.source[s.start..s.end]
        else
            null;
        var i = self.loop_stack.items.len;
        while (i > 0) {
            i -= 1;
            const f = &self.loop_stack.items[i];
            if (want_label) |w| {
                if (f.label) |fl| if (std.mem.eql(u8, fl, w)) return f;
            } else {
                return f; // innermost
            }
        }
        return null;
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

/// `true` when two optional bank tags refer to the same code
/// location — both `null` (base image) or both wrapping the same
/// bank index.
fn banksEqual(a: ?u8, b: ?u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}
