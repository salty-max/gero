const std = @import("std");
const ast = @import("ast.zig");
const types_mod = @import("types.zig");
const typecheck_mod = @import("typecheck.zig");
const diag_mod = @import("diagnostic.zig");
const opcodes = @import("codegen/opcodes.zig");
/// Instruction decoder, re-exported so codegen submodules reach it
/// without a deep relative import (the `@inline` size gate decodes its
/// spliced body to count real instructions).
pub const disasm_decoder = @import("../disasm/decoder.zig");
const archive = @import("codegen/archive.zig");
const mem_builtin = @import("codegen/mem_builtin.zig");
const strings = @import("codegen/strings.zig");
const pattern = @import("codegen/pattern.zig");
const expr_emit = @import("codegen/expr.zig");
const control_flow = @import("codegen/control_flow.zig");
const class = @import("codegen/class.zig");
const lambda = @import("codegen/lambda.zig");
const inline_call = @import("codegen/inline_call.zig");
const globals = @import("codegen/globals.zig");
const def_emit = @import("codegen/def.zig");
const statements = @import("codegen/statements.zig");
const isa = @import("codegen/isa.zig");
const bake_mod = @import("bake.zig");

const Diagnostic = diag_mod.Diagnostic;
const CheckedProgram = typecheck_mod.CheckedProgram;
const Type = types_mod.Type;
const Op = opcodes.Op;
const Reg = opcodes.Reg;
const Sys = opcodes.Sys;

// ---------- public constants (boot layout per ISA §7) ----------

/// IVT base address (`0x1000..0x10FF` is reserved for 2-byte slots).
pub const ivt_base: u16 = 0x1000;
/// First byte of code emission.
pub const code_base: u16 = 0x1100;
/// First byte of static-data emission.
pub const data_base: u16 = 0x2000;

// ---------- .gx file constants (re-exported from archive) ----------

const bank_window_base = archive.bank_window_base;

const InternedString = strings.InternedString;
const StringPatch = strings.StringPatch;

// ---------- public surface ----------

/// Codegen output. Owns the `.gx` image bytes, the diagnostic
/// slice, and the arena backing diagnostic message strings.
pub const Compiled = struct {
    /// Full `.gx` archive. Pass to `gero.vm.parseGx`.
    image: []u8,
    diagnostics: []Diagnostic,
    diag_arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    /// Release the image buffer + diagnostics slice + the arena
    /// backing diagnostic message strings.
    pub fn deinit(self: *Compiled) void {
        self.allocator.free(self.image);
        self.allocator.free(self.diagnostics);
        self.diag_arena.deinit();
    }

    /// `true` when at least one fatal diagnostic fired.
    pub fn hasErrors(self: Compiled) bool {
        for (self.diagnostics) |d| if (d.severity == .fatal) return true;
        return false;
    }
};

/// Build-mode selector. Mirrors `--optimize=<m>` from `docs/cli.md`.
pub const Optimize = enum { debug, release, size };

/// Knobs for `compile`.
pub const Options = struct {
    /// Top-level `def` to use as the program entry.
    entry_name: []const u8 = "main",
    /// Reserve the flag bit + section for debug symbols
    /// (ISA §7.3).
    debug_symbols: bool = true,
    /// Build mode. Controls `debug_assert` elision (§5.3) and
    /// overflow trap insertion (§4.2.1).
    optimize: Optimize = .debug,
};

/// Errors `compile` can return. Semantic errors land in
/// `Compiled.diagnostics`; only host failures propagate here.
pub const CompileError = error{
    OutOfMemory,
    /// `Options.entry_name` doesn't resolve to a top-level `def`.
    EntryNotFound,
    /// Codegen tried to lower an unsupported AST shape; details
    /// are in `Compiled.diagnostics`.
    UnsupportedFeature,
};

/// Compile a typechecked program to a `.gx` archive.
///
/// ```
/// var compiled = try compile(allocator, source, &checked, .{});
/// defer compiled.deinit();
/// try std.fs.cwd().writeFile("out.gx", compiled.image);
/// ```
pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    checked: *const CheckedProgram,
    opts: Options,
) CompileError!Compiled {
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    // Scratch arena: short-lived bookkeeping.
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    // Diagnostics arena: persists via `Compiled.diag_arena`.
    var diag_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer diag_arena.deinit();

    if (findEntryDef(source, checked.program, opts.entry_name) == null) return error.EntryNotFound;

    var emitter: Emitter = .{
        .allocator = allocator,
        .arena = scratch_arena.allocator(),
        .diag_arena = diag_arena.allocator(),
        .source = source,
        .code = .empty,
        .locals = .{},
        .params = .{},
        .frame_bytes = 0,
        .frame_overflow = false,
        .is_entry = false,
        .is_isr = false,
        .current_ret_struct = null,
        .sret_param_ofs = 0,
        .sret_scratch_ofs = null,
        .inline_ret_struct = null,
        .inline_ret_slot = 0,
        .fn_addresses = .{},
        .fn_banks = .{},
        .noreturn_defs = .{},
        .fn_ret_struct = .{},
        .global_sret_scratch = 0,
        .inline_defs = .{},
        .interrupt_defs = .empty,
        .inline_returns = null,
        .inline_depth = 0,
        .trampoline_addr = null,
        .call_patches = .empty,
        .globals = .{},
        .data_cursor = data_base,
        .zp_cursor = 0,
        .banks = .{},
        .current_bank = null,
        .strings = .empty,
        .string_patches = .empty,
        .checked = checked,
        .enum_decls = .{},
        .struct_decls = .{},
        .class_decls = .{},
        .class_layouts = .{},
        .current_class_name = null,
        .fn_closure_info = .{
            .promoted = .{},
            .lambdas = .empty,
            .next_lambda_id = 0,
            .closure_bindings = .{},
        },
        .captures = .{},
        .lambda_patches = .empty,
        .vtable_patches = .empty,
        .block_stack = .empty,
        .loop_stack = .empty,
        .diagnostics = &diagnostics,
        .optimize = opts.optimize,
        .bake_inits = .{},
        .bake_defs = .{},
    };
    defer emitter.code.deinit(allocator);
    defer emitter.call_patches.deinit(allocator);
    defer emitter.bake_inits.deinit(allocator);
    defer emitter.bake_defs.deinit(allocator);
    defer emitter.vtable_patches.deinit(allocator);
    defer emitter.lambda_patches.deinit(allocator);
    defer emitter.strings.deinit(allocator);
    defer emitter.string_patches.deinit(allocator);
    defer emitter.block_stack.deinit(allocator);
    defer emitter.loop_stack.deinit(allocator);
    defer emitter.interrupt_defs.deinit(allocator);
    defer {
        var it = emitter.banks.valueIterator();
        while (it.next()) |b| b.deinit(allocator);
        emitter.banks.deinit(allocator);
    }

    try emitter.emitProgram(checked.program, opts.entry_name);

    // Build base image: zeros from 0x0000 up to `code_base`, then
    // the emitted code. The static-data region gets folded in only
    // when at least one global carries `bake`-init bytes — without
    // bake initializers the runtime sees zero-filled RAM at boot
    // for free, so we keep images small for plain programs.
    // @as: widen u16 code_base / data_cursor to usize for the byte-length math (image stays ≤ 64 KiB by ISA).
    const code_end: usize = @as(usize, code_base) + emitter.code.items.len;
    const has_bake_inits = emitter.bake_inits.count() > 0;
    const data_end: usize = if (has_bake_inits) emitter.data_cursor else 0;
    const total_image_bytes: usize = @max(code_end, data_end);
    var base_image = try allocator.alloc(u8, total_image_bytes);
    errdefer allocator.free(base_image);
    @memset(base_image, 0);
    @memcpy(base_image[code_base..][0..emitter.code.items.len], emitter.code.items);
    // Write each `bake` global's serialized bytes into the image
    // at its allocated address. Globals without a bake initializer
    // leave the data region at zero (their existing behavior).
    var bake_it = emitter.bake_inits.iterator();
    while (bake_it.next()) |entry| {
        const addr: usize = entry.key_ptr.*;
        const bytes = entry.value_ptr.*;
        @memcpy(base_image[addr..][0..bytes.len], bytes);
    }

    const debug_blob: ?[]u8 = if (opts.debug_symbols)
        try emitter.buildDebugSymbolSection()
    else
        null;
    defer if (debug_blob) |s| allocator.free(s);
    const image = try buildArchive(allocator, base_image, code_base, emitter.data_cursor, &emitter.banks, debug_blob);
    allocator.free(base_image);

    return .{
        .image = image,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .diag_arena = diag_arena,
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

/// `true` when `dd` carries a bare flag annotation named `name`.
/// Module-level helper so emit-loop branches in `emitProgram` can
/// route on `@cold` / `@interrupt` / etc. without spinning up a
/// full Emitter scope. Also consumed by `codegen/lambda.zig`'s
/// `@no_capture` short-circuit, which is the lone cross-module
/// caller — kept on this side so the source-walk lives next to
/// the other annotation-decoding logic.
pub fn defHasFlagAnnotation(source: []const u8, dd: *const ast.DefDecl, name: []const u8) bool {
    for (dd.annotations) |ann| {
        if (std.mem.eql(u8, source[ann.name.start..ann.name.end], name)) return true;
    }
    return false;
}

/// Append one row of the debug-symbol section:
/// `[u16 address][u8 kind][u8 name_len][name bytes]`. Truncates
/// long names to 255 bytes since `name_len` is a single byte.
fn appendDebugSymbol(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    address: u16,
    kind: u8,
    name: []const u8,
) !void {
    // safety: u16 → 2 bytes by definition; no truncation possible.
    try out.append(allocator, @intCast(address & 0xFF));
    try out.append(allocator, @intCast(address >> 8));
    try out.append(allocator, kind);
    // safety: name_len is u8 — clamp at 255 if the user picked a
    // pathologically long identifier (the lexer caps idents well
    // below this anyway).
    const name_len: u8 = @intCast(@min(name.len, 255));
    try out.append(allocator, name_len);
    try out.appendSlice(allocator, name[0..name_len]);
}

// ---------- Emitter ----------

/// One `@interrupt N` def collected during the pre-pass. The
/// boot init code writes `def_name`'s resolved address into
/// `mem[ivt_base + 2 * vector]` so the VM dispatches the handler
/// when vector `N` fires.
pub const InterruptHandler = struct {
    vector: u8,
    def_name: []const u8,
};

/// Unresolved `call addr` site — the codegen recorded the call
/// when the callee's address wasn't yet known (forward refs). At
/// the end of emission, every patch's 2-byte address-slot in
/// `code` is overwritten with the resolved callee address.
pub const CallPatch = struct {
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
    pub const Target = union(enum) {
        fn_name: []const u8,
        trampoline,
    };
};

/// One lexical block tracked at codegen time. Owns the LIFO list of
/// `defer` statements registered within the block so the codegen can
/// re-emit them at every exit path (fall-through, `return`, `break`,
/// `continue`). The body of a `defer` is held by pointer — the same
/// AST node is re-emitted once per exit path the codegen lowers.
pub const Block = struct {
    defers: std.ArrayList(*const ast.Statement),
};

/// One enclosing loop tracked while emitting the loop body. Carries
/// the patches accumulated for every `break` / `continue` inside the
/// body (forward jumps with the address slot unfilled) so the
/// codegen can resolve them at the end of the loop, and the index of
/// the loop body's block in `block_stack` so `break` / `continue`
/// know which range of blocks to unwind on the jump path.
pub const LoopFrame = struct {
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

/// One top-level `let` / `const` global. Addressed by `@addr`
/// literal, `@zero_page` (from `zp_cursor`), or the data region
/// (from `data_cursor`).
pub const Global = struct {
    /// Resolved absolute address.
    address: u16,
    /// Byte width: 1 for `u8`/`bool`/`char`; 2 for 16-bit
    /// primitives + references; larger for aggregates.
    width: u16,
    /// Placement family. Drives the addressing mode used for
    /// loads / stores against this global.
    placement: enum { addr, zero_page, data },
};

/// Unresolved vtable-address site. Patched by `patchVtableSlots`
/// once `emitVtables` resolves each class's `vtable_addr`.
pub const VtablePatch = struct {
    bank: ?u8,
    code_offset: usize,
    class_name: []const u8,
};

/// Unresolved lambda fn_ptr site — a closure-creation site left
/// an imm16 slot at `code_offset` for the lambda body's address.
/// `patchLambdaSlots` rewrites every slot once each lambda body
/// has emitted and `fn_addresses[label]` resolves.
pub const LambdaPatch = struct {
    bank: ?u8,
    code_offset: usize,
    label: []const u8,
};

/// Per-fn codegen state — owns the working bytecode buffer, the
/// local-slot table, and the diagnostic sink. The entry-def
/// emission path owns one Emitter; later M1 commits will create
/// a fresh Emitter per non-entry def too.
pub const Emitter = struct {
    allocator: std.mem.Allocator,
    /// Arena for short-lived bookkeeping (local-name dupes,
    /// scratch buffers). Released at the end of `compile`.
    arena: std.mem.Allocator,
    /// Persistent arena used exclusively for `Diagnostic.message`
    /// strings — survives past `compile`'s return so callers can
    /// read the diagnostics. Lives on `Compiled.diag_arena`.
    diag_arena: std.mem.Allocator,
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
    /// Set when a frame slot or param offset exceeds the i8 fp-relative
    /// addressing range (±127); `emitDefWithLabel` reports it as
    /// `E_CODEGEN_FRAME_TOO_LARGE`. Reset per def.
    frame_overflow: bool,
    /// `true` while emitting the entry def's body. Drives the
    /// `return` lowering (`hlt` vs `ret`) and skips the
    /// `push fp` / `mov sp, fp` parts of the prologue (the VM
    /// boots with `fp == sp`).
    is_entry: bool,
    /// Emitting the body of an `@interrupt N` def. Flips `return`
    /// lowering to `rti`.
    is_isr: bool,
    /// Struct return-type name of the def currently being emitted, or
    /// `null` for a scalar-returning def. When set, `return` copies the
    /// value into the caller-provided sret buffer.
    current_ret_struct: ?[]const u8,
    /// fp-offset of the hidden sret destination pointer in the current
    /// frame (`4 + Σ user-param widths` — it sits just above the last
    /// user param). Valid only while `current_ret_struct` is set.
    sret_param_ofs: i16,
    /// fp-offset of this frame's sret scratch buffer (a returned
    /// struct's holding space), or `null` when the program returns no
    /// structs.
    sret_scratch_ofs: ?i16,
    /// While splicing a struct-returning `@inline` body: the struct
    /// name + the caller-frame slot its `return` materializes into
    /// (`acu` then holds that slot's address). `null` outside such an
    /// inline. Takes precedence over the sret path — an inlined body
    /// has no callee frame, so its result lives in a caller local.
    inline_ret_struct: ?[]const u8,
    inline_ret_slot: i8,
    /// `def` name → absolute address. Banked defs live in the
    /// bank window; un-banked defs live in the base image.
    fn_addresses: std.StringHashMapUnmanaged(u16),
    /// `def` name → bank index (or `null` for the base image).
    /// Populated pre-emission so `emitCall` picks direct vs
    /// trampoline.
    fn_banks: std.StringHashMapUnmanaged(?u8),
    /// `def` names carrying `@noreturn`. `emitCall` skips the
    /// post-call epilogue for these.
    noreturn_defs: std.StringHashMapUnmanaged(void),
    /// `def` name → struct return-type name, for the ones that return
    /// a struct by value. Drives the sret calling convention: the
    /// caller passes a hidden destination pointer and the callee copies
    /// its result there (§3.4). Absent → returns a scalar in `acu`.
    fn_ret_struct: std.StringHashMapUnmanaged([]const u8),
    /// Largest (2-aligned) struct return width across the program — the
    /// size of the per-frame sret scratch buffer that holds a returned
    /// struct until its consumer copies it out. 0 when no def returns a
    /// struct.
    global_sret_scratch: u16,
    /// `def` names carrying `@inline`. `emitCall` inlines the
    /// body rather than emitting `call addr`.
    inline_defs: std.StringHashMapUnmanaged(*const ast.DefDecl),
    /// `@interrupt N` defs — vector index → def. Drives IVT-init
    /// emission before `main`.
    interrupt_defs: std.ArrayList(InterruptHandler),
    /// Pending `return` patch offsets accumulated while emitting
    /// an `@inline` body. Each is a `jmp_addr` 2-byte slot to be
    /// rewritten to the after-body address. `null` outside an
    /// inline.
    inline_returns: ?std.ArrayList(usize),
    /// `@inline` nesting depth guard. Past this, codegen emits
    /// `E_ANN_INLINE_RECURSIVE`.
    inline_depth: u8,
    /// `__call_bank` trampoline address in the base image.
    /// `null` until the trampoline is emitted.
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
    /// Next free byte in the dynamic data region.
    data_cursor: u16,
    /// Next free zero-page byte. Range-checked at `placeGlobal`.
    zp_cursor: u16,
    /// Per-bank emit buffers. `@bank N` defs land here; the base
    /// image gets un-banked bytes.
    banks: std.AutoHashMapUnmanaged(u8, std.ArrayList(u8)),
    /// Active bank for the current def. `null` = base image.
    current_bank: ?u8,
    /// Interned string pool + patches resolved at end-of-codegen.
    strings: std.ArrayList(InternedString),
    string_patches: std.ArrayList(StringPatch),
    /// Read-only view into the typechecker's per-expr type map.
    /// Drives type-aware lowering.
    checked: *const CheckedProgram,
    /// `enum` decls by name. Used for variant-tag indices,
    /// `is` tests, and `match` patterns.
    enum_decls: std.StringHashMapUnmanaged(*const ast.EnumDecl),
    /// `struct` decls by name. Used for `sizeof(NamedStruct)`
    /// width math + future struct-value lowering.
    struct_decls: std.StringHashMapUnmanaged(*const ast.StructDecl),
    /// `class` decls by name. Used by constructor detection,
    /// vtable lookup, and field / method access.
    class_decls: std.StringHashMapUnmanaged(*const ast.ClassDecl),
    /// Per-class layout: instance size, field offsets, vtable
    /// slots, vtable address (set by `class.emitVtables`).
    class_layouts: std.StringHashMapUnmanaged(class.ClassLayout),
    /// Class whose method body is currently emitting. Drives
    /// `super` resolution.
    current_class_name: ?[]const u8,
    /// Per-fn closure analysis. Populated by `lambda.analyzeFn`
    /// before each body emits. Reset between defs.
    fn_closure_info: lambda.FnClosureInfo,
    /// Captures visible to the emitting body (set inside a
    /// lambda body).
    captures: std.StringHashMapUnmanaged(lambda.CaptureSlot),
    /// Unresolved lambda fn_ptr slots. Patched by
    /// `lambda.patchLambdaSlots`.
    lambda_patches: std.ArrayList(LambdaPatch),
    /// Unresolved vtable-address slots emitted by class
    /// constructors. Patched by `patchVtableSlots`.
    vtable_patches: std.ArrayList(VtablePatch),
    /// Stack of lexical blocks at the current emit cursor. Each
    /// owns its registered `defer` statements.
    block_stack: std.ArrayList(Block),
    /// Stack of enclosing loops at the current emit cursor.
    /// `break` / `continue` find their target here.
    loop_stack: std.ArrayList(LoopFrame),
    /// Sink for codegen-time diagnostics.
    diagnostics: *std.ArrayList(Diagnostic),
    /// Active build mode. Drives `debug_assert` elision and
    /// overflow trap insertion.
    optimize: Optimize,
    /// Per-global init bytes from the `bake` evaluator, keyed by
    /// data-region address. Written into the base image at
    /// `compile()` so the runtime sees baked values at boot.
    bake_inits: std.AutoHashMapUnmanaged(u16, []const u8),
    /// `bake def`s by name. Populated pre-emission so
    /// `const X = bake_def_name()` initializers can find the
    /// callee.
    bake_defs: std.StringHashMapUnmanaged(*const ast.DefDecl),

    /// Mutually recursive emit fns need an explicit error set to
    /// break Zig's inferred-set deadlock.
    const EmitError = error{OutOfMemory};

    // ---------- raw emit primitives ----------

    /// Pointer to the buffer the next byte should go into — the
    /// base `code` buffer when no `@bank` is active, otherwise the
    /// per-bank buffer (created lazily on first byte).
    pub fn currentCode(self: *Emitter) !*std.ArrayList(u8) {
        if (self.current_bank) |b| {
            const gop = try self.banks.getOrPut(self.allocator, b);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            return gop.value_ptr;
        }
        return &self.code;
    }

    /// Byte cursor inside the active code buffer. Used to record
    /// patch sites.
    pub fn currentOffset(self: *Emitter) !usize {
        const buf = try self.currentCode();
        return buf.items.len;
    }

    /// Append one raw byte to the currently-active code buffer
    /// (base image or per-bank window).
    pub fn emitByte(self: *Emitter, b: u8) !void {
        const buf = try self.currentCode();
        try buf.append(self.allocator, b);
    }

    /// Append a 16-bit value in little-endian byte order.
    pub fn emitU16Le(self: *Emitter, value: u16) !void {
        // safety: u16 → 2 LE bytes; both casts are byte-mask, no truncation.
        try self.emitByte(@intCast(value & 0xFF));
        try self.emitByte(@intCast(value >> 8));
    }

    /// Base address of the current code buffer in VM memory.
    /// Used to turn a buffer-local offset into a `jmp` target.
    pub fn currentBufferBase(self: *const Emitter) u16 {
        if (self.current_bank) |_| return bank_window_base;
        return code_base;
    }

    // ---------- frame management ----------

    /// Reserve a 2-byte slot for `name` at the next fp-relative
    /// offset. Returns the offset (negative — locals grow down).
    pub fn allocLocal(self: *Emitter, name: []const u8) !i8 {
        return self.allocLocalSized(name, 2);
    }

    /// Allocate a frame slot of `bytes` (rounded up to a 2-byte
    /// boundary so word access stays aligned) and return the offset
    /// of its base. Multi-byte slots back inline value aggregates —
    /// a struct local occupies its full width, addressed as
    /// `[fp + ofs + field_offset]`.
    pub fn allocLocalSized(self: *Emitter, name: []const u8, bytes: u16) !i8 {
        const ofs = self.reserveFrameSlot(bytes);
        try self.locals.put(self.arena, name, ofs);
        return ofs;
    }

    /// Reserve `bytes` (2-aligned) of frame space and return the base
    /// offset, without registering a name. For anonymous slots (inline
    /// arg bindings) whose names bind into a scope set up afterward.
    pub fn reserveFrameSlot(self: *Emitter, bytes: u16) i8 {
        const slot: u16 = alignUpU16(bytes, 2);
        // @as: widen the u8 cursor so the sum can exceed 255 + be range-checked below instead of wrapping.
        const new_frame_bytes = @as(u16, self.frame_bytes) + slot;
        // The ISA's only fp-relative addressing is `[fp + imm8]` (±127),
        // so a frame past 127 bytes can't be addressed. Flag it and
        // return a placeholder; `emitDefWithLabel` turns the flag into a
        // clean `E_CODEGEN_FRAME_TOO_LARGE` rather than panicking on the
        // i8 cast (the compile fails, so the placeholder is never run).
        if (new_frame_bytes > 127) {
            self.frame_overflow = true;
            return -1;
        }
        // @as: bounded ≤127 by the check above.
        const ofs: i8 = -@as(i8, @intCast(new_frame_bytes));
        self.frame_bytes = @intCast(new_frame_bytes);
        return ofs;
    }

    /// Byte width of a checked type. Mirrors `widthOfTypeAnn` but over
    /// `types.Type` — 1 for `i8`/`u8`/`bool`/`char`, the field sum for
    /// a named struct, 2 otherwise (16-bit primitives, references,
    /// class/enum pointers).
    pub fn widthOfType(self: *const Emitter, ty: *const Type) u16 {
        switch (ty.*) {
            .primitive => |p| return switch (p) {
                .i8, .u8, .bool_, .char => 1,
                else => 2,
            },
            .named => |n| {
                if (self.struct_decls.get(n.name)) |sd| {
                    var total: u16 = 0;
                    for (sd.fields) |f| total +%= self.widthOfTypeAnn(f.type_ann.*);
                    return total;
                }
                return 2;
            },
            else => return 2,
        }
    }

    /// Bytes of frame space the body could need so the prologue can
    /// `sub frame_bytes, sp`. A scalar local is 2 bytes; a struct
    /// local takes its full (2-aligned) width. Reserves space for
    /// every arm of control-flow forms.
    pub fn countFrameBytes(self: *const Emitter, body: []const ast.Statement) usize {
        var n: usize = 0;
        for (body) |s| n += self.countStmtFrameBytes(s);
        return n;
    }

    fn countStmtFrameBytes(self: *const Emitter, stmt: ast.Statement) usize {
        return switch (stmt) {
            .let_decl => |d| self.letFrameBytes(d),
            .const_decl => 2,
            .block => |b| self.countFrameBytes(b.body),
            .if_stmt => |is_| blk: {
                var n: usize = 0;
                for (is_.arms) |a| {
                    if (a.let_pattern) |p| n += countBindingBytes(p.*);
                    // `if expr is Class as h` — `h` parks the
                    // instance pointer in a fresh local slot.
                    if (a.cond) |c| if (c.* == .is_test and c.is_test.classBinding() != null) {
                        n += 2;
                    };
                    n += self.countFrameBytes(a.body);
                }
                if (is_.else_body) |eb| n += self.countFrameBytes(eb);
                break :blk n;
            },
            .while_stmt => |ws| blk: {
                var n: usize = 0;
                if (ws.let_pattern) |p| n += countBindingBytes(p.*);
                n += self.countFrameBytes(ws.body);
                break :blk n;
            },
            // Range-based `for` reserves 1 hidden slot for the `end`
            // bound (the iteration variable uses its own slot).
            .for_stmt => |fs| 2 + 2 + self.countFrameBytes(fs.body),
            .repeat_stmt => |rs| self.countFrameBytes(rs.body),
            .match_stmt => |ms| blk: {
                // 1 scratch slot to bind the scrutinee when it isn't
                // already an ident (so subsequent cmps don't re-eval).
                var n: usize = if (ms.scrutinee.* == .ident) 0 else 2;
                for (ms.arms) |a| {
                    n += countBindingBytes(a.pattern.*);
                    n += self.countFrameBytes(a.body);
                }
                break :blk n;
            },
            .defer_stmt => |ds| self.countStmtFrameBytes(ds.body.*),
            else => 0,
        };
    }

    /// Frame bytes a `let` reserves: the 2-aligned width of its type
    /// (struct fields summed), 2 for scalars. Non-ident patterns
    /// (destructuring) reserve minimally — lowering them is separate.
    fn letFrameBytes(self: *const Emitter, d: ast.LetDecl) usize {
        if (d.pattern.* != .ident) return 2;
        const w: u16 = if (d.type_ann) |t|
            self.widthOfTypeAnn(t.*)
        else if (d.init) |e|
            (if (self.typeOf(e)) |ty| self.widthOfType(ty) else 2)
        else
            2;
        return alignUpU16(w, 2);
    }

    /// Frame bytes a pattern's binders introduce. A bare ident binds
    /// one 2-byte slot; a variant pattern binds one per payload field.
    /// These must be reserved so a binder slot doesn't overlap the
    /// stack-push region used by later binary ops.
    fn countBindingBytes(pat: ast.Pattern) usize {
        return switch (pat) {
            .ident => 2,
            .variant_pattern => |vp| blk: {
                var n: usize = 0;
                for (vp.args) |arg| n += countBindingBytes(arg.*);
                break :blk n;
            },
            else => 0,
        };
    }

    // ---------- program + def emission ----------

    /// Top-level orchestrator: emit the entry def first (so it
    /// lands at `code_base`, matching `Options.entry_name` →
    /// header `entry_point`), then every other top-level `def` in
    /// source order, then patch unresolved call sites.
    fn emitProgram(self: *Emitter, program: *const ast.Program, entry_name: []const u8) !void {
        // Pre-pass 0: index top-level enum + struct decls so
        // variant-tag and sizeof lookups resolve cheaply.
        try self.collectEnumDecls(program);
        try self.collectStructDecls(program);
        // Pre-pass 0b: index top-level class decls + compute
        // per-class layouts (with parent-chain resolution for
        // inherited fields + methods). Vtables emit later, once
        // method addresses exist.
        try class.collectClassDecls(self, program);
        try class.computeLayouts(self);
        // Pre-pass 0c: collect `bake def`s so global-init
        // resolution can call them at codegen time.
        try self.collectBakeDefs(program);
        // Pre-pass 1: register globals (top-level let/const).
        try self.registerGlobals(program);
        // Pre-pass 2: collect each def's bank so `emitCall` can
        // decide direct-call vs trampoline without needing the
        // target's address yet.
        try self.collectDefBanks(program);

        const entry = findEntryDef(self.source, program, entry_name).?;
        try self.emitDef(entry, .entry);
        // Two-pass over top-level defs: hot first (source order),
        // then `@cold`-marked defs (still source order within the
        // group) — deterministic layout across compiler versions.
        // `@inline` defs never emit standalone — every call site
        // splices the body in place.
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| if (dd != entry and !defHasFlagAnnotation(self.source, dd, "cold") and !defHasFlagAnnotation(self.source, dd, "inline"))
                try self.emitDef(dd, .regular),
            else => {},
        };
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| if (dd != entry and defHasFlagAnnotation(self.source, dd, "cold") and !defHasFlagAnnotation(self.source, dd, "inline"))
                try self.emitDef(dd, .regular),
            else => {},
        };
        // Emit class methods as plain defs with mangled labels.
        try class.emitClassMethods(self, program);

        // Emit the `__call_bank` trampoline only if at least one
        // cross-bank call site asked for it (saves 10 bytes when
        // the program is entirely un-banked or single-bank).
        if (self.needsTrampoline()) try self.emitCallBankTrampoline();

        // Append the interned string pool to the base image so all
        // recorded `StringPatch`es can resolve to real addresses.
        try self.emitStringPool();
        // Append per-class vtables (u16 method-address tables) to
        // the base image. Must run after all methods have emitted
        // so `fn_addresses` contains the resolved addresses.
        try class.emitVtables(self);
        // Resolve constructor-side placeholder slots now that each
        // class's vtable lives at a known address.
        try class.patchVtableSlots(self);
        // Resolve every closure-creation site's lambda fn_ptr slot
        // — lambda bodies emitted alongside their parent def, so
        // their addresses live in `fn_addresses` by now.
        try lambda.patchLambdaSlots(self);

        try self.patchCalls();
        try self.patchStrings();
    }

    /// Delegated to `codegen/strings.zig`.
    fn emitStringPool(self: *Emitter) !void {
        return strings.emitStringPool(self);
    }

    /// Delegated to `codegen/strings.zig`.
    fn patchStrings(self: *Emitter) !void {
        return strings.patchStrings(self);
    }

    /// Delegated to `codegen/strings.zig`.
    fn internString(self: *Emitter, bytes: []const u8) !usize {
        return strings.internString(self, bytes);
    }

    /// Delegated to `codegen/strings.zig`.
    fn emitMovStringAddrToReg(self: *Emitter, string_id: usize, reg: u8) !void {
        return strings.emitMovStringAddrToReg(self, string_id, reg);
    }

    /// Look up the typechecker's inferred type for an expression.
    /// Returns `null` when the typechecker couldn't infer a type
    /// (callers must fall back to a less-specific lowering).
    pub fn typeOf(self: *const Emitter, e: *const ast.Expr) ?*const Type {
        return self.checked.typeOf(e);
    }

    /// `true` when the expression's inferred type is the named
    /// primitive `p`. Returns `false` for missing types.
    pub fn isPrimitiveType(self: *const Emitter, e: *const ast.Expr, p: types_mod.Primitive) bool {
        const t = self.typeOf(e) orelse return false;
        return t.* == .primitive and t.primitive == p;
    }

    /// Pre-pass: index every top-level `enum` decl by name so the
    /// codegen can look up variant-tag indices during emission.
    fn collectEnumDecls(self: *Emitter, program: *const ast.Program) !void {
        for (program.statements) |*stmt| switch (stmt.*) {
            .enum_decl => |ed| {
                const name = self.source[ed.name.start..ed.name.end];
                const dup = try self.arena.dupe(u8, name);
                try self.enum_decls.put(self.arena, dup, &stmt.enum_decl);
            },
            else => {},
        };
    }

    /// Pre-pass: index every top-level `struct` decl by name so
    /// `widthOfTypeAnn` / `sizeof` can compute the byte size of
    /// a named struct (sum of field sizes).
    fn collectStructDecls(self: *Emitter, program: *const ast.Program) !void {
        for (program.statements) |*stmt| switch (stmt.*) {
            .struct_decl => |sd| {
                const name = self.source[sd.name.start..sd.name.end];
                const dup = try self.arena.dupe(u8, name);
                try self.struct_decls.put(self.arena, dup, &stmt.struct_decl);
            },
            else => {},
        };
    }

    /// Pre-pass: collect every `bake def` so a `const X =
    /// some_bake_def(args)` init can look the callee up at
    /// `registerGlobalConst` time. Also seeds the call-dispatch
    /// registry the bake evaluator threads through `Options.bake_defs`.
    fn collectBakeDefs(self: *Emitter, program: *const ast.Program) !void {
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| {
                if (!dd.is_bake) continue;
                const name = self.source[dd.name.start..dd.name.end];
                const dup = try self.arena.dupe(u8, name);
                try self.bake_defs.put(self.allocator, dup, dd);
            },
            else => {},
        };
    }

    /// Look up the tag index for `enum_name.variant_name` (0-based
    /// in declaration order per spec §3.6). `null` when unknown.
    pub fn variantTag(self: *const Emitter, enum_name: []const u8, variant_name: []const u8) ?u8 {
        const ed = self.enum_decls.get(enum_name) orelse return null;
        for (ed.variants, 0..) |v, i| {
            const v_name = self.source[v.name.start..v.name.end];
            if (std.mem.eql(u8, v_name, variant_name)) {
                // @as: variant index fits u8 — spec §3.6 limits the
                // tag to one byte (max 256 variants per enum).
                return @intCast(i);
            }
        }
        return null;
    }

    /// Whether any variant of `ed` carries a payload. This picks the
    /// runtime representation: a payload-free enum is a bare tag in a
    /// register; a payload-carrying enum is a `[tag | payload]` slot
    /// addressed by pointer (§3.6).
    pub fn enumHasPayload(self: *const Emitter, ed: *const ast.EnumDecl) bool {
        _ = self;
        for (ed.variants) |v| if (v.payload.len > 0) return true;
        return false;
    }

    /// Byte size of one variant's payload fields (no tag).
    pub fn variantPayloadSize(self: *const Emitter, v: ast.EnumVariant) u16 {
        var total: u16 = 0;
        for (v.payload) |f| total +%= self.widthOfTypeAnn(f.type_ann.*);
        return total;
    }

    /// Slot size of a payload-carrying enum: 1-byte tag + payload
    /// bytes sized to the largest variant (§3.6).
    pub fn enumSlotSize(self: *const Emitter, ed: *const ast.EnumDecl) u16 {
        var max_payload: u16 = 0;
        for (ed.variants) |v| {
            const sz = self.variantPayloadSize(v);
            if (sz > max_payload) max_payload = sz;
        }
        return 1 + max_payload;
    }

    /// Byte offset of payload field `i` within a variant's slot — the
    /// 1-byte tag, then each prior field's width.
    pub fn variantFieldOffset(self: *const Emitter, v: ast.EnumVariant, i: usize) u16 {
        var ofs: u16 = 1;
        for (v.payload[0..i]) |f| ofs +%= self.widthOfTypeAnn(f.type_ann.*);
        return ofs;
    }

    /// `true` when the type is a `Named` variant whose name matches
    /// a registered enum. Used to detect enum-typed expressions
    /// during print / match / store lowering.
    fn isEnumType(self: *const Emitter, ty: *const Type) bool {
        return ty.* == .named and self.enum_decls.contains(ty.named.name);
    }

    /// Resolve an expression's enum decl when its inferred type is
    /// a `Named` variant pointing to a registered enum. Used by the
    /// match-stmt lowerer to decide between jump-table and
    /// sequential-arm dispatch.
    pub fn enumDeclForExpr(self: *const Emitter, e: *const ast.Expr) ?*const ast.EnumDecl {
        const ty = self.typeOf(e) orelse return null;
        if (ty.* != .named) return null;
        return self.enum_decls.get(ty.named.name);
    }

    /// Resolve the enum a `match` dispatches on. Prefers the
    /// scrutinee's inferred type; falls back to a variant arm's path
    /// (`EnumName.Variant`) when the scrutinee carries no recorded
    /// type, so payload-enum lowering doesn't depend on inference
    /// reaching every scrutinee form.
    pub fn enumDeclForMatch(self: *const Emitter, ms: ast.MatchStmt) ?*const ast.EnumDecl {
        if (self.enumDeclForExpr(ms.scrutinee)) |ed| return ed;
        for (ms.arms) |arm| {
            if (arm.pattern.* != .variant_pattern) continue;
            const path = self.source[arm.pattern.variant_pattern.path.start..arm.pattern.variant_pattern.path.end];
            const dot = std.mem.indexOfScalar(u8, path, '.') orelse continue;
            if (self.enum_decls.get(path[0..dot])) |ed| return ed;
        }
        return null;
    }

    /// Scan top-level `def`s, recording each name → its `@bank N`
    /// annotation (or `null` for base-image defs).
    fn collectDefBanks(self: *Emitter, program: *const ast.Program) !void {
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| {
                const name = self.source[dd.name.start..dd.name.end];
                const dup = try self.arena.dupe(u8, name);
                var bank: ?u8 = null;
                var noreturn_marked: bool = false;
                var inline_marked: bool = false;
                var interrupt_vec: ?u8 = null;
                for (dd.annotations) |ann| {
                    const ann_name = self.source[ann.name.start..ann.name.end];
                    if (std.mem.eql(u8, ann_name, "bank") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
                        // @as: typechecker enforces u8 range on `@bank N`.
                        bank = @intCast(ann.args[0].int_lit.value & 0xFF);
                    } else if (std.mem.eql(u8, ann_name, "noreturn")) {
                        noreturn_marked = true;
                    } else if (std.mem.eql(u8, ann_name, "inline")) {
                        inline_marked = true;
                    } else if (std.mem.eql(u8, ann_name, "interrupt") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
                        // @as: vectors are capped at 64 (0x00..0x3F); narrow via mask.
                        interrupt_vec = @intCast(ann.args[0].int_lit.value & 0xFF);
                    }
                }
                try self.fn_banks.put(self.arena, dup, bank);
                if (dd.ret_type) |rt| if (self.structNameOfTypeAnn(rt.*)) |sname| {
                    try self.fn_ret_struct.put(self.arena, dup, sname);
                    const w = self.structSlotWidth(sname);
                    if (w > self.global_sret_scratch) self.global_sret_scratch = w;
                };
                if (noreturn_marked) try self.noreturn_defs.put(self.arena, dup, {});
                if (inline_marked) try self.inline_defs.put(self.arena, dup, dd);
                if (interrupt_vec) |vec| {
                    try self.interrupt_defs.append(self.allocator, .{
                        .vector = vec,
                        .def_name = dup,
                    });
                }
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

    /// Emit the `__call_bank` cross-bank trampoline (10 bytes) in
    /// the base image. Caller sets `r1 = target_addr`,
    /// `r2 = target_bank`, then `call __call_bank`.
    ///
    /// ```
    /// push mb         ; 31 0C
    /// mov r2, mb      ; 11 03 0C
    /// call r1         ; A1 02
    /// pop mb          ; 32 0C
    /// ret             ; A2
    /// ```
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

        // Save the caller's bank, switch via r2, call the target in r1,
        // restore. The byte sequence is the listing in the doc above.
        try self.emitByte(Op.push_reg);
        try self.emitByte(Reg.mb);
        try isa.movRegToReg(self, Reg.r2, Reg.mb);
        try self.emitByte(Op.call_reg);
        try self.emitByte(Reg.r1);
        try self.emitByte(Op.pop_reg);
        try self.emitByte(Reg.mb);
        try self.emitByte(Op.ret_op);
    }

    /// Register every top-level `let` / `const` as a `Global` —
    /// placement + bake-const eval in `codegen/globals.zig`.
    fn registerGlobals(self: *Emitter, program: *const ast.Program) !void {
        return globals.registerGlobals(self, program);
    }

    /// Load `g`'s value into `acu` — see `codegen/globals.zig`.
    pub fn emitGlobalLoad(self: *Emitter, g: Global) !void {
        return globals.emitGlobalLoad(self, g);
    }

    /// Store `src` into `g`'s slot — see `codegen/globals.zig`.
    pub fn emitGlobalStore(self: *Emitter, src: u8, g: Global) !void {
        return globals.emitGlobalStore(self, src, g);
    }

    /// Byte width of a type annotation: 1 for `i8`/`u8`/`bool`/
    /// `char`, 2 for 16-bit primitives + references + class names
    /// (which use a 2-byte instance pointer), sum-of-fields for
    /// named structs, sum-of-elements for tuples + arrays.
    pub fn widthOfTypeAnn(self: *const Emitter, t: ast.TypeAnn) u16 {
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
                // Named struct → sum of field sizes (recursive).
                // Class names stay at 2 (instance-pointer width).
                if (self.struct_decls.get(name)) |sd| {
                    var total: u16 = 0;
                    for (sd.fields) |f| total +%= self.widthOfTypeAnn(f.type_ann.*);
                    break :blk total;
                }
                break :blk 2;
            },
            .array => |a| blk: {
                const elem_w = self.widthOfTypeAnn(a.elem.*);
                // Spec §3.4: array length is an int-literal. Non-
                // literal lengths fall back to 0 (typecheck flags).
                if (a.len_expr.* == .int_lit) {
                    // safety: bit-cast i32 to u32 to drop sign for the masked truncate.
                    const raw: u32 = @bitCast(a.len_expr.int_lit.value);
                    // @as: low-16 of the masked length; spec §3.4 caps at u16 address space.
                    const len: u16 = @intCast(raw & 0xFFFF);
                    break :blk elem_w *% len;
                }
                break :blk 0;
            },
            .tuple => |xs| blk: {
                var total: u16 = 0;
                for (xs.elems) |elem| total +%= self.widthOfTypeAnn(elem.*);
                break :blk total;
            },
            else => 2,
        };
    }

    /// Whether a def is the program entry point (epilogue `hlt`, frame
    /// starts with `fp == sp`) or a regular fn (`ret` epilogue).
    pub const DefKind = enum { entry, regular };

    /// Emit one def: prologue + body + epilogue — see `codegen/def.zig`.
    fn emitDef(self: *Emitter, def: *const ast.DefDecl, kind: DefKind) !void {
        return def_emit.emitDef(self, def, kind);
    }

    /// Emit a method as a plain def under a mangled label.
    pub fn emitMethodAsDef(self: *Emitter, def: *const ast.DefDecl, class_name: []const u8, label: []const u8) !void {
        return def_emit.emitMethodAsDef(self, def, class_name, label);
    }

    /// Resolve forward-reference call sites — see `codegen/def.zig`.
    fn patchCalls(self: *Emitter) !void {
        return def_emit.patchCalls(self);
    }

    // ---------- statement emission ----------

    /// Dispatch one statement to its lowering. Sub-modules call
    /// back into this for body walks.
    pub fn emitStatement(self: *Emitter, stmt: ast.Statement) EmitError!void {
        switch (stmt) {
            .let_decl => |d| try self.emitLetDecl(d),
            .const_decl => |d| try self.emitConstDecl(d),
            .assign => |a| try self.emitAssign(a),
            .inc_dec => |id| try self.emitIncDec(id),
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
    /// Delegated to `codegen/control_flow.zig`.
    fn emitScopedBody(self: *Emitter, body: []const ast.Statement) EmitError!void {
        return control_flow.emitScopedBody(self, body);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn emitBlockStmt(self: *Emitter, b: ast.BlockStmt) !void {
        return control_flow.emitBlockStmt(self, b);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn emitDeferStmt(self: *Emitter, ds: ast.DeferStmt) !void {
        return control_flow.emitDeferStmt(self, ds);
    }

    // ---------- control-flow lowering (delegated) ----------

    /// Delegated to `codegen/control_flow.zig`.
    fn emitIfStmt(self: *Emitter, is_: ast.IfStmt) !void {
        return control_flow.emitIfStmt(self, is_);
    }

    /// Delegated to `codegen/expr.zig`.
    pub fn emitCondBranch(self: *Emitter, e: *const ast.Expr) !void {
        return expr_emit.emitCondBranch(self, e);
    }

    /// Delegated to `codegen/expr.zig`.
    fn materializeBoolFromFlags(self: *Emitter, op: ast.BinaryOp) !void {
        return expr_emit.materializeBoolFromFlags(self, op);
    }

    /// Delegated to `codegen/expr.zig`.
    fn emitShortCircuitBool(self: *Emitter, b: ast.BinaryExpr) !void {
        return expr_emit.emitShortCircuitBool(self, b);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn emitWhileStmt(self: *Emitter, ws: ast.WhileStmt) !void {
        return control_flow.emitWhileStmt(self, ws);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn emitRepeatStmt(self: *Emitter, rs: ast.RepeatStmt) !void {
        return control_flow.emitRepeatStmt(self, rs);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn emitForStmt(self: *Emitter, fs: ast.ForStmt) !void {
        return control_flow.emitForStmt(self, fs);
    }

    const LoopJumpKind = control_flow.LoopJumpKind;

    /// Delegated to `codegen/control_flow.zig`.
    fn emitLoopJump(self: *Emitter, j: ast.LoopJumpStmt, kind: LoopJumpKind) !void {
        return control_flow.emitLoopJump(self, j, kind);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn emitMatchStmt(self: *Emitter, ms: ast.MatchStmt) !void {
        return control_flow.emitMatchStmt(self, ms);
    }

    /// Delegated to `codegen/pattern.zig`.
    fn emitPatternTest(
        self: *Emitter,
        pat: ast.Pattern,
        scrutinee_ofs: i8,
        scrutinee_is_ident: bool,
        skip_patches: *std.ArrayList(usize),
    ) !void {
        return pattern.emitPatternTest(self, pat, scrutinee_ofs, scrutinee_is_ident, skip_patches);
    }

    /// Class name when `e` is a registered class (auto-derefs one
    /// `&T` per spec §3.4.4); otherwise `null`.
    pub fn classNameOf(self: *const Emitter, e: *const ast.Expr) ?[]const u8 {
        const ty = self.typeOf(e) orelse return null;
        const inner = if (ty.* == .reference) ty.reference else ty;
        if (inner.* != .named) return null;
        const name = inner.named.name;
        if (!self.class_decls.contains(name)) return null;
        return name;
    }

    /// Struct name when `e`'s type is a registered struct (auto-deref
    /// through a `&T` reference). Structs are inline value aggregates,
    /// so a struct-typed expression evaluates to its base address.
    pub fn structNameOf(self: *const Emitter, e: *const ast.Expr) ?[]const u8 {
        const ty = self.typeOf(e) orelse return null;
        const inner = if (ty.* == .reference) ty.reference else ty;
        if (inner.* != .named) return null;
        const name = inner.named.name;
        if (!self.struct_decls.contains(name)) return null;
        return name;
    }

    /// Layout of one struct field: byte offset, byte width, and — when
    /// the field is itself a struct — that struct's name (so codegen
    /// recurses into nested aggregates rather than storing a scalar).
    pub const FieldInfo = struct { offset: u16, width: u16, struct_name: ?[]const u8 };

    /// `FieldInfo` for `field_name` within `struct_name`, or `null` if
    /// unknown. Fields are laid out contiguously in declaration order
    /// (§3.4).
    pub fn structFieldInfo(self: *const Emitter, struct_name: []const u8, field_name: []const u8) ?FieldInfo {
        const sd = self.struct_decls.get(struct_name) orelse return null;
        var ofs: u16 = 0;
        for (sd.fields) |f| {
            const w = self.widthOfTypeAnn(f.type_ann.*);
            if (std.mem.eql(u8, self.source[f.name.start..f.name.end], field_name)) {
                return .{ .offset = ofs, .width = w, .struct_name = self.structNameOfTypeAnn(f.type_ann.*) };
            }
            ofs +%= w;
        }
        return null;
    }

    /// Struct name if `t` names a registered struct, else `null`.
    pub fn structNameOfTypeAnn(self: *const Emitter, t: ast.TypeAnn) ?[]const u8 {
        if (t != .named) return null;
        const name = self.source[t.named.name.start..t.named.name.end];
        return if (self.struct_decls.contains(name)) name else null;
    }

    /// Total byte width of struct `struct_name` (its fields summed).
    pub fn structWidth(self: *const Emitter, struct_name: []const u8) u16 {
        const sd = self.struct_decls.get(struct_name) orelse return 0;
        var total: u16 = 0;
        for (sd.fields) |f| total +%= self.widthOfTypeAnn(f.type_ann.*);
        return total;
    }

    /// Struct `struct_name`'s footprint rounded up to a 2-byte slot —
    /// the word-aligned size used for inline-value frame, param, and
    /// arg layout.
    pub fn structSlotWidth(self: *const Emitter, struct_name: []const u8) u16 {
        return alignUpU16(self.structWidth(struct_name), 2);
    }

    /// Struct name of a call argument, or `null` for a scalar arg. A
    /// struct literal carries its name directly; other struct-typed
    /// expressions resolve through their inferred type. Drives the
    /// pass-by-value path in free-fn and method calls alike.
    pub fn argStructName(self: *const Emitter, arg: *const ast.Expr) ?[]const u8 {
        if (arg.* == .struct_lit) {
            const name = self.source[arg.struct_lit.type_name.start..arg.struct_lit.type_name.end];
            return if (self.struct_decls.contains(name)) name else null;
        }
        return self.structNameOf(arg);
    }

    /// Stack footprint of a parameter: a struct param occupies its
    /// full (2-aligned) width — passed by value as a contiguous copy
    /// (§3.4) — and a scalar param one word. Drives both the param
    /// fp-offsets and the caller's arg-push width.
    pub fn paramWidthAligned(self: *const Emitter, p: ast.Param) u16 {
        const t = p.type_ann orelse return 2;
        if (self.structNameOfTypeAnn(t.*)) |sname| {
            return self.structSlotWidth(sname);
        }
        return 2;
    }

    /// `target = value` (and compound / inc-dec desugarings) — see
    /// `codegen/statements.zig`.
    fn emitAssign(self: *Emitter, a: ast.AssignStmt) !void {
        return statements.emitAssign(self, a);
    }

    /// `target++` / `target--` — see `codegen/statements.zig`.
    fn emitIncDec(self: *Emitter, id: ast.IncDecStmt) !void {
        return statements.emitIncDec(self, id);
    }

    /// `let` binding lowering — see `codegen/statements.zig`.
    fn emitLetDecl(self: *Emitter, d: ast.LetDecl) !void {
        return statements.emitLetDecl(self, d);
    }

    /// `const` binding lowering — see `codegen/statements.zig`.
    fn emitConstDecl(self: *Emitter, d: ast.ConstDecl) !void {
        return statements.emitConstDecl(self, d);
    }

    /// `return [value]` lowering — see `codegen/statements.zig`.
    fn emitReturnStmt(self: *Emitter, r: ast.ReturnStmt) !void {
        return statements.emitReturnStmt(self, r);
    }

    /// `print a, b, …` lowering — see `codegen/statements.zig`.
    fn emitPrintStmt(self: *Emitter, p: ast.PrintStmt) !void {
        return statements.emitPrintStmt(self, p);
    }

    /// Delegated to `codegen/strings.zig`.
    pub fn emitStrLitExpr(self: *Emitter, sl: ast.StrLitExpr) !void {
        return strings.emitStrLitExpr(self, sl);
    }

    /// Delegated to `codegen/strings.zig`.
    fn emitPrintStrLit(self: *Emitter, sl: ast.StrLitExpr) !void {
        return strings.emitPrintStrLit(self, sl);
    }

    /// Delegated to `codegen/expr.zig`.
    fn emitExprDiscard(self: *Emitter, e: *const ast.Expr) !void {
        return expr_emit.emitExprDiscard(self, e);
    }

    /// Lower one expression — result lands in `acu`. Sub-modules
    /// call back into this through the method dispatch.
    pub fn emitExpr(self: *Emitter, e: *const ast.Expr) EmitError!void {
        return expr_emit.emitExpr(self, e);
    }

    /// Delegated to `codegen/expr.zig`.
    fn emitFieldExpr(self: *Emitter, f: ast.FieldExpr, e: *const ast.Expr) !void {
        return expr_emit.emitFieldExpr(self, f, e);
    }

    /// Delegated to `codegen/expr.zig`.
    fn emitIsTest(self: *Emitter, it: ast.IsTestExpr) !void {
        return expr_emit.emitIsTest(self, it);
    }

    /// Delegated to `codegen/expr.zig`.
    fn emitUnary(self: *Emitter, u: ast.UnaryExpr) !void {
        return expr_emit.emitUnary(self, u);
    }

    /// Delegated to `codegen/expr.zig`.
    fn emitBinary(self: *Emitter, b: ast.BinaryExpr) !void {
        return expr_emit.emitBinary(self, b);
    }

    /// Delegated to `codegen/expr.zig`.
    fn emitCall(self: *Emitter, c: ast.CallExpr) !void {
        return expr_emit.emitCall(self, c);
    }

    /// Max bytecode instructions in an `@inline` body.
    pub const inline_body_instruction_cap: usize = 32;

    /// Max `@inline` nesting depth.
    pub const inline_max_depth: u8 = 8;

    /// Splice an `@inline` callee's body at the call site — see
    /// `codegen/inline_call.zig`.
    pub fn emitInlineCall(self: *Emitter, callee: *const ast.DefDecl, c: ast.CallExpr) !void {
        return inline_call.emitInlineCall(self, callee, c);
    }

    /// Emit the debug-symbol section. Includes resolved fn
    /// addresses (kind 0) and globals (kind 1). Compiler-internal
    /// labels are filtered out.
    ///
    /// ```
    /// [u16 symbol_count]
    /// for each: [u16 address][u8 kind][u8 name_len][name bytes]
    /// ```
    pub fn buildDebugSymbolSection(self: *Emitter) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        // Reserve space for the u16 symbol_count header — patched
        // at the end once we've walked every symbol.
        try out.append(self.allocator, 0);
        try out.append(self.allocator, 0);
        var count: u16 = 0;

        // Code labels — fn addresses. Skip compiler-internal
        // mangled prefixes that aren't user-meaningful in a
        // debugger.
        var fn_it = self.fn_addresses.iterator();
        while (fn_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (std.mem.startsWith(u8, name, "__lambda_")) continue;
            if (std.mem.startsWith(u8, name, "__class_vtable_")) continue;
            try appendDebugSymbol(self.allocator, &out, entry.value_ptr.*, 0, name);
            count += 1;
        }

        // Data labels — top-level let / const globals.
        var g_it = self.globals.iterator();
        while (g_it.next()) |entry| {
            try appendDebugSymbol(self.allocator, &out, entry.value_ptr.address, 1, entry.key_ptr.*);
            count += 1;
        }

        archive.writeU16Le(out.items[0..2], count);
        return out.toOwnedSlice(self.allocator);
    }

    /// Resolve a code-buffer offset to its run-time address.
    /// Picks `bank_window_base` or `code_base` from `current_bank`.
    pub fn codeOffsetToAddress(self: *const Emitter, offset: usize) u16 {
        // @as: per-buffer offsets stay ≤ 64 KiB by ISA constraint.
        const ofs: u16 = @intCast(offset);
        return if (self.current_bank != null) bank_window_base + ofs else code_base + ofs;
    }

    /// Mutable view into the active code buffer. Used for emit-
    /// time slot patches.
    pub fn currentBufferMut(self: *Emitter) []u8 {
        if (self.current_bank) |b| {
            if (self.banks.getPtr(b)) |bl| return bl.items;
        }
        return self.code.items;
    }

    // ---------- block + defer infrastructure (delegated) ----------

    /// Delegated to `codegen/control_flow.zig`.
    pub fn pushBlock(self: *Emitter) !void {
        return control_flow.pushBlock(self);
    }

    /// Delegated to `codegen/control_flow.zig`.
    pub fn popBlockWithDefers(self: *Emitter) !void {
        return control_flow.popBlockWithDefers(self);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn emitDefersLifo(self: *Emitter, stmts: []const *const ast.Statement) !void {
        return control_flow.emitDefersLifo(self, stmts);
    }

    /// Delegated to `codegen/control_flow.zig`.
    pub fn unwindAllDefersForReturn(self: *Emitter) !void {
        return control_flow.unwindAllDefersForReturn(self);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn unwindDefersDownTo(self: *Emitter, body_block_idx: usize) !void {
        return control_flow.unwindDefersDownTo(self, body_block_idx);
    }

    /// Delegated to `codegen/control_flow.zig`.
    fn findLoopFrame(self: *Emitter, label_span: ?ast.Span) ?*LoopFrame {
        return control_flow.findLoopFrame(self, label_span);
    }

    /// Delegated to `codegen/expr.zig`.
    fn emitMethodCall(self: *Emitter, m: ast.MethodCallExpr, e: *const ast.Expr) !void {
        return expr_emit.emitMethodCall(self, m, e);
    }

    // ---------- mem stdlib builtins (delegated) ----------

    /// Dispatch a `mem.X(args)` call to the matching emitter in
    /// `codegen/mem_builtin.zig`.
    pub fn emitMemCall(self: *Emitter, fe: ast.FieldExpr, c: ast.CallExpr) !void {
        return mem_builtin.emitMemCall(self, fe, c);
    }

    /// Compute the address of an addressable expression into
    /// `acu`. Backs `mem.addr_of(x)` and the `&x` reference
    /// operator.
    pub fn emitAddrOf(self: *Emitter, e: *const ast.Expr) !void {
        return mem_builtin.emitAddrOf(self, e);
    }

    // ---------- diagnostics ----------

    /// Append a fatal `Diagnostic` with the given code + literal
    /// message. The message string isn't duplicated — callers
    /// either pass a string literal or allocate on `diag_arena`.
    pub fn diagFatal(self: *Emitter, span: ast.Span, code: []const u8, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .severity = .fatal,
            .code = code,
            .message = message,
            .span = span,
        });
    }

    /// Emit `E_CODEGEN_UNSUPPORTED` with a message describing the
    /// shape that wasn't lowered. `what` is interpolated into the
    /// formatted message and the formatted string lives on
    /// `diag_arena`.
    pub fn unsupported(self: *Emitter, span: ast.Span, what: []const u8) !void {
        const msg = try std.fmt.allocPrint(
            self.diag_arena,
            "codegen does not yet support {s}",
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

const buildArchive = archive.buildArchive;
const decodeStringEscapes = archive.decodeStringEscapes;
const alignUpU16 = archive.alignUpU16;
const banksEqual = archive.banksEqual;
