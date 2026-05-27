const std = @import("std");
const ast = @import("ast.zig");
const types_mod = @import("types.zig");
const typecheck_mod = @import("typecheck.zig");
const diag_mod = @import("diagnostic.zig");
const opcodes = @import("codegen/opcodes.zig");
const disasm_decoder = @import("../disasm/decoder.zig");
const archive = @import("codegen/archive.zig");
const mem_builtin = @import("codegen/mem_builtin.zig");
const strings = @import("codegen/strings.zig");
const pattern = @import("codegen/pattern.zig");
const expr_emit = @import("codegen/expr.zig");
const control_flow = @import("codegen/control_flow.zig");
const class = @import("codegen/class.zig");
const lambda = @import("codegen/lambda.zig");
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
        .is_entry = false,
        .is_isr = false,
        .fn_addresses = .{},
        .fn_banks = .{},
        .noreturn_defs = .{},
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
const Global = struct {
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
    /// `true` while emitting the entry def's body. Drives the
    /// `return` lowering (`hlt` vs `ret`) and skips the
    /// `push fp` / `mov sp, fp` parts of the prologue (the VM
    /// boots with `fp == sp`).
    is_entry: bool,
    /// Emitting the body of an `@interrupt N` def. Flips `return`
    /// lowering to `rti`.
    is_isr: bool,
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
        const new_frame_bytes = self.frame_bytes + 2;
        // @as: i8 covers -128..127; with 2 bytes per slot we cap at 64 locals per frame, fits.
        const ofs: i8 = -@as(i8, @intCast(new_frame_bytes));
        try self.locals.put(self.arena, name, ofs);
        self.frame_bytes = new_frame_bytes;
        return ofs;
    }

    /// Conservatively count locals the body could need so the
    /// prologue can `sub frame_bytes, sp`. Reserves slots for
    /// every arm of control-flow forms.
    pub fn countLocalsInBody(self: *const Emitter, body: []const ast.Statement) usize {
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

    /// Count the local-slot bindings a pattern introduces. Only
    /// the ident pattern binds; or-patterns reject inner binders
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

        // push mb
        try self.emitByte(Op.push_reg);
        try self.emitByte(Reg.mb);
        // mov r2, mb
        try isa.movRegToReg(self, Reg.r2, Reg.mb);
        // call r1
        try self.emitByte(Op.call_reg);
        try self.emitByte(Reg.r1);
        // pop mb
        try self.emitByte(Op.pop_reg);
        try self.emitByte(Reg.mb);
        // ret
        try self.emitByte(Op.ret_op);
    }

    /// Register every top-level `let` / `const` as a `Global`.
    /// Placement rule:
    /// 1. `@addr $XXXX` → that literal address.
    /// 2. `@zero_page` → next `zp_cursor` slot (overflow →
    ///    `E_CODEGEN_ZP_OVERFLOW`).
    /// 3. `@align(N)` → pad the cursor to a multiple of `N`.
    /// 4. No annotation → next `data_cursor` slot.
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
        // Run the bake evaluator first so the resulting value
        // tells us both the storage width AND the bytes to write
        // into the data region. Non-bake initializers fall back
        // to the type-annotation-driven width path.
        const baked: ?bake_mod.BakeValue = try self.evalConstIfBake(d);
        const width: u16 = if (baked) |v| @intCast(bake_mod.widthOf(v)) else self.widthOfConstDecl(d);
        try self.placeGlobal(name, width, d.annotations, d.name);

        if (baked) |v| {
            const g = self.globals.get(name) orelse return;
            const bytes = try self.arena.alloc(u8, bake_mod.widthOf(v));
            _ = bake_mod.serialize(v, bytes);
            try self.bake_inits.put(self.allocator, g.address, bytes);
        }
    }

    /// Evaluate a `const X = …` initializer when the RHS is a
    /// `bake do` block or a `bake def` call. `null` for
    /// non-bake initializers.
    fn evalConstIfBake(self: *Emitter, d: *const ast.ConstDecl) !?bake_mod.BakeValue {
        switch (d.init.*) {
            .do_expr => |do| {
                if (!do.is_bake) return null;
                return try self.runBake(d.span, .{ .do_expr = &d.init.do_expr });
            },
            .call => |c| {
                if (c.callee.* != .ident) return null;
                const callee_name = self.source[c.callee.ident.span.start..c.callee.ident.span.end];
                const decl = self.bake_defs.get(callee_name) orelse return null;
                // Top-level entry call: args must be literal /
                // const-foldable.
                const args = try self.arena.alloc(bake_mod.BakeValue, c.args.len);
                for (c.args, 0..) |a, i| {
                    args[i] = bake_mod.literalAsBakeValue(self.source, a) orelse {
                        try self.diagFatal(a.span(), "E_BAKE_UNSUPPORTED", "bake-call args at top-level must be literal values");
                        return null;
                    };
                }
                return try self.runBakeDef(d.span, decl, args);
            },
            else => return null,
        }
    }

    /// Tagged input to `runBake` — pick the entry shape so a
    /// single helper handles the diagnostic plumbing.
    const BakeEntry = union(enum) {
        do_expr: *const ast.DoExpr,
    };

    fn runBake(self: *Emitter, span: ast.Span, entry: BakeEntry) !?bake_mod.BakeValue {
        const opts: bake_mod.Options = .{ .bake_defs = &self.bakeDefsAdapter() };
        var result = switch (entry) {
            .do_expr => |de| try bake_mod.evaluateDo(self.allocator, self.source, de, opts),
        };
        defer result.deinit(self.allocator);
        for (result.diagnostics) |diag| {
            try self.diagnostics.append(self.allocator, .{
                .severity = diag.severity,
                .code = diag.code,
                .message = try self.diag_arena.dupe(u8, diag.message),
                .span = diag.span,
            });
        }
        if (result.value == null) {
            try self.diagFatal(span, "E_BAKE_UNSUPPORTED", "bake evaluation failed; see diagnostics above");
            return null;
        }
        return try bake_mod.cloneBakeValue(self.arena, result.value.?);
    }

    fn runBakeDef(self: *Emitter, span: ast.Span, decl: *const ast.DefDecl, args: []const bake_mod.BakeValue) !?bake_mod.BakeValue {
        const adapter = self.bakeDefsAdapter();
        const opts: bake_mod.Options = .{ .bake_defs = &adapter };
        var result = try bake_mod.evaluateDef(self.allocator, self.source, decl, args, opts);
        defer result.deinit(self.allocator);
        for (result.diagnostics) |diag| {
            try self.diagnostics.append(self.allocator, .{
                .severity = diag.severity,
                .code = diag.code,
                .message = try self.diag_arena.dupe(u8, diag.message),
                .span = diag.span,
            });
        }
        if (result.value == null) {
            try self.diagFatal(span, "E_BAKE_UNSUPPORTED", "bake evaluation failed; see diagnostics above");
            return null;
        }
        return try bake_mod.cloneBakeValue(self.arena, result.value.?);
    }

    /// Snapshot the bake-def index into the std-StringHashMap
    /// shape the evaluator expects. The evaluator borrows the
    /// map for the duration of one call; we rebuild the snapshot
    /// each time so any future bake-def discovery stays visible.
    fn bakeDefsAdapter(self: *Emitter) std.StringHashMap(*const ast.DefDecl) {
        var map = std.StringHashMap(*const ast.DefDecl).init(self.arena);
        var it = self.bake_defs.iterator();
        while (it.next()) |e| {
            // allow-strict: copies fit in the same arena that owns `bake_defs`; OOM here would have surfaced upstream.
            map.put(e.key_ptr.*, e.value_ptr.*) catch unreachable;
        }
        return map;
    }

    fn placeGlobal(
        self: *Emitter,
        name: []const u8,
        width: u16,
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
            if (align_n) |n| self.zp_cursor = alignUpU16(self.zp_cursor, n);
            const zp_end: u16 = self.zp_cursor + width;
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

    /// 1 for `i8` / `u8` / `bool` / `char`, 2 otherwise. Type-name
    /// resolution is purely lexical against the type annotation;
    /// the typechecker has already validated that the name refers
    /// to a primitive or a registered user-type.
    fn widthOfLetDecl(self: *const Emitter, d: *const ast.LetDecl) u16 {
        if (d.type_ann) |t| return self.widthOfTypeAnn(t.*);
        // No annotation — default to the widest primitive (2 bytes).
        return 2;
    }

    fn widthOfConstDecl(self: *const Emitter, d: *const ast.ConstDecl) u16 {
        if (d.type_ann) |t| return self.widthOfTypeAnn(t.*);
        return 2;
    }

    /// Emit a load of `g`'s value into `acu`. The instruction
    /// shape depends on the placement family + byte width.
    pub fn emitGlobalLoad(self: *Emitter, g: Global) !void {
        switch (g.placement) {
            .addr => {
                if (g.width == 1) {
                    try isa.mov8AddrToReg(self, g.address, Reg.acu);
                } else {
                    try isa.movAddrToReg(self, g.address, Reg.acu);
                }
            },
            .zero_page => {
                // @as: zero-page address fits in u8; placement.zero_page guarantees address ≤ 0xFF.
                const zp: u8 = @intCast(g.address);
                if (g.width == 1) {
                    try isa.mov8ZpToReg(self, zp, Reg.acu);
                } else {
                    try isa.movZpToReg(self, zp, Reg.acu);
                }
            },
            .data => {
                if (g.width == 1) {
                    try isa.mov8AddrToReg(self, g.address, Reg.acu);
                } else {
                    try isa.movAddrToReg(self, g.address, Reg.acu);
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
                    try isa.movlRegToAddr(self, src, g.address);
                } else {
                    try isa.movRegToAddr(self, src, g.address);
                }
            },
            .zero_page => {
                // @as: zero-page address fits in u8; placement.zero_page guarantees address ≤ 0xFF.
                const zp: u8 = @intCast(g.address);
                if (g.width == 1) {
                    try isa.movlRegToZp(self, src, zp);
                } else {
                    try isa.movRegToZp(self, src, zp);
                }
            },
        }
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

    const DefKind = enum { entry, regular };

    /// Emit one def: prologue + body + epilogue. Resets per-fn
    /// state for a fresh frame view.
    fn emitDef(self: *Emitter, def: *const ast.DefDecl, kind: DefKind) !void {
        const name = self.source[def.name.start..def.name.end];
        return self.emitDefWithLabel(def, kind, name);
    }

    /// Emit a method as a plain def under a mangled
    /// `ClassName.methodName` label. Threads
    /// `current_class_name` so `super` resolves correctly.
    pub fn emitMethodAsDef(self: *Emitter, def: *const ast.DefDecl, class_name: []const u8, label: []const u8) !void {
        const saved = self.current_class_name;
        self.current_class_name = class_name;
        defer self.current_class_name = saved;
        return self.emitDefWithLabel(def, .regular, label);
    }

    fn emitDefWithLabel(self: *Emitter, def: *const ast.DefDecl, kind: DefKind, label: []const u8) !void {
        // Detect `@bank N` annotation — drives bank routing for
        // this def's body bytes + the fn's resolved address.
        // `@interrupt N` swaps the body epilogue from `ret` to
        // `rti` (pop flg/fp/ip in reverse of entry).
        var bank_target: ?u8 = null;
        var is_isr: bool = false;
        for (def.annotations) |ann| {
            const ann_name = self.source[ann.name.start..ann.name.end];
            if (std.mem.eql(u8, ann_name, "bank") and ann.args.len == 1 and ann.args[0].* == .int_lit) {
                // @as: typechecker enforces u8 range on `@bank N`.
                bank_target = @intCast(ann.args[0].int_lit.value & 0xFF);
            } else if (std.mem.eql(u8, ann_name, "interrupt")) {
                is_isr = true;
            }
        }

        // Save + restore per-fn state.
        const saved_locals = self.locals;
        const saved_params = self.params;
        const saved_frame = self.frame_bytes;
        const saved_entry = self.is_entry;
        const saved_isr = self.is_isr;
        const saved_bank = self.current_bank;
        self.locals = .{};
        self.params = .{};
        self.frame_bytes = 0;
        self.is_entry = (kind == .entry);
        self.is_isr = is_isr;
        self.current_bank = bank_target;
        defer {
            self.locals = saved_locals;
            self.params = saved_params;
            self.frame_bytes = saved_frame;
            self.is_entry = saved_entry;
            self.is_isr = saved_isr;
            self.current_bank = saved_bank;
        }

        const dup_name = try self.arena.dupe(u8, label);
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
            try isa.subImmFromReg(self, reserve_bytes, Reg.sp);
        }

        // Closure-analysis pre-pass — populates fn_closure_info
        // with the lambda inventory, capture layouts, and the
        // promotion set. Drives the heap-cell paths in
        // emitLetDecl / emitIdent / emitAssign + the closure-call
        // dispatch in emitCall.
        try lambda.analyzeFn(self, def);
        defer lambda.resetFnInfo(self);

        // Entry-def prologue: write every `@interrupt N` handler's
        // address into its IVT slot BEFORE the user body runs.
        // Boot leaves `flg.I = 0` so an interrupt could otherwise
        // fire against an uninitialized vector.
        if (self.is_entry) try self.emitIvtInit();

        // Function body opens the outermost block of the frame —
        // `defer`s at the top of the body run before the implicit
        // epilogue's `hlt` / `ret` / `rti`.
        try self.pushBlock();
        for (def.body) |stmt| try self.emitStatement(stmt);
        try self.popBlockWithDefers();

        // Implicit epilogue (no explicit `return`).
        if (self.is_entry) {
            try isa.hlt(
                self,
            );
        } else if (is_isr) {
            // ISR teardown — pop flg/fp/ip in reverse of entry.
            try self.emitByte(Op.rti_op);
        } else {
            // `ret` resets sp = fp then pops ret_ip + old_fp. The
            // VM handles the whole tear-down; we just need to land
            // the return value in acu (callers read from there).
            try self.emitByte(Op.ret_op);
        }

        // Emit any lambda bodies discovered during analyzeFn —
        // they emit as plain defs adjacent to the parent so their
        // call sites + closure-creation patches resolve normally.
        try lambda.emitLambdaBodies(self, def);
    }

    /// Rewrite each unresolved call's 2-byte address slot.
    /// Unknown callees emit `E_CODEGEN_UNDEFINED_FN`.
    fn patchCalls(self: *Emitter) !void {
        for (self.call_patches.items) |p| {
            const target_addr: u16 = switch (p.target) {
                .fn_name => |name| self.fn_addresses.get(name) orelse {
                    const msg = try std.fmt.allocPrint(
                        self.diag_arena,
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

    /// Dispatch one statement to its lowering. Sub-modules call
    /// back into this for body walks.
    pub fn emitStatement(self: *Emitter, stmt: ast.Statement) EmitError!void {
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

    fn emitAssign(self: *Emitter, a: ast.AssignStmt) !void {
        if (a.op != .set) {
            try self.unsupported(a.span, "compound `op=` assignments — only plain `=` is supported");
            return;
        }
        // Field-target assignment — `recv.field = value` on a class
        // receiver routes to the class field-store path.
        if (a.target.* == .field) {
            if (self.classNameOf(a.target.field.receiver)) |cname| {
                const fname = self.source[a.target.field.field.start..a.target.field.field.end];
                try class.emitFieldStore(self, a.target.field.receiver, cname, fname, a.value, a.target.field.span);
                return;
            }
        }
        if (a.target.* != .ident) {
            try self.unsupported(a.span, "non-ident assignment targets (field / index)");
            return;
        }
        const name = self.source[a.target.ident.span.start..a.target.ident.span.end];
        // Captured-binding write inside a lambda body — store
        // through the env-relative cell pointer (the parent
        // promoted the binding so the write is visible everywhere).
        if (self.captures.get(name)) |slot| {
            try lambda.emitCaptureStore(self, slot, a.value);
            return;
        }
        // Promoted local in the parent fn — store through the
        // local-slot cell pointer.
        if (lambda.isPromoted(self, name)) {
            if (self.locals.get(name)) |ofs| {
                try lambda.emitPromotedAssign(self, ofs, a.value);
                return;
            }
        }
        try self.emitExpr(a.value); // result in acu
        if (self.locals.get(name)) |ofs| {
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
            return;
        }
        if (self.params.get(name)) |ofs| {
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
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
        // Promoted bindings live as heap cells — the slot holds
        // the cell pointer instead of the value directly.
        if (lambda.isPromoted(self, name)) {
            try lambda.emitPromotedLetInit(self, d.init, ofs);
            return;
        }
        if (d.init) |init_expr| {
            try self.emitExpr(init_expr); // result in acu
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
        }
        // Uninitialized let leaves the slot at whatever the prologue
        // memset gave it (sub_imm pads sp downward without zeroing).
    }

    fn emitConstDecl(self: *Emitter, d: ast.ConstDecl) !void {
        const name = self.source[d.name.start..d.name.end];
        const dup_name = try self.arena.dupe(u8, name);
        const ofs = try self.allocLocal(dup_name);
        try self.emitExpr(d.init);
        try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
    }

    fn emitReturnStmt(self: *Emitter, r: ast.ReturnStmt) !void {
        if (r.value) |v| try self.emitExpr(v);
        // Defers attached to every still-active block fire before
        // the frame tears down — innermost first, LIFO within each
        // block. `acu` carries the return value through the cleanup
        // (the defer-emitter saves / restores it).
        try self.unwindAllDefersForReturn();
        if (self.inline_returns) |*returns| {
            // Inside an `@inline` body — redirect `return` to a
            // forward jmp to the after-inlined site. Patch slot
            // queued for resolution after the body emits.
            try self.emitByte(Op.jmp_addr);
            const patch = try self.currentOffset();
            try self.emitU16Le(0);
            try returns.append(self.allocator, patch);
            return;
        }
        if (self.is_entry) {
            try isa.hlt(
                self,
            );
        } else if (self.is_isr) {
            try self.emitByte(Op.rti_op);
        } else {
            try self.emitByte(Op.ret_op);
        }
    }

    /// Emit `mov_imm16_addr <handler>, ivt_base + 2*vec` for every
    /// `@interrupt N` handler. Handler addresses patch later via
    /// `call_patches`. Runs at the top of the entry body.
    fn emitIvtInit(self: *Emitter) !void {
        for (self.interrupt_defs.items) |handler| {
            try self.emitByte(Op.mov_imm16_addr);
            const addr_patch_offset = try self.currentOffset();
            // 2-byte imm slot — will be patched with the handler's
            // resolved address.
            try self.emitU16Le(0);
            // 2-byte addr slot — IVT slot for this vector (known
            // at emit time, no patch needed).
            // @as: widen u8 vector to u16 before doubling so the wrap-add against ivt_base stays in u16.
            const slot: u16 = ivt_base +% (@as(u16, handler.vector) *% 2);
            try self.emitU16Le(slot);
            try self.call_patches.append(self.allocator, .{
                .bank = self.current_bank,
                .code_offset = addr_patch_offset,
                .target = .{ .fn_name = handler.def_name },
                .span = .{ .start = 0, .end = 0 },
            });
        }
    }

    fn emitPrintStmt(self: *Emitter, p: ast.PrintStmt) !void {
        for (p.args, 0..) |arg, i| {
            if (i > 0) {
                // Space separator between args per spec §4.9.
                try isa.movImmToReg(self, ' ', Reg.acu);
                try isa.sys(self, Sys.print_char);
            }
            try self.emitPrintArg(arg);
        }
        // Trailing newline per spec §4.9.
        try isa.sys(self, Sys.print_newline);
    }

    /// Emit one `print` argument. Routes to the right syscall by
    /// the arg's inferred type (spec §4.9):
    ///
    /// - `char` → `print_char`.
    /// - `fixed` → `print_fixed`.
    /// - String literals: per-part emission for interpolations.
    /// - `str` non-literal → `print_str`.
    /// - Otherwise → `print_int`.
    fn emitPrintArg(self: *Emitter, arg: *const ast.Expr) !void {
        if (arg.* == .str_lit) {
            try self.emitPrintStrLit(arg.str_lit);
            return;
        }
        if (self.isPrimitiveType(arg, .char)) {
            try self.emitExpr(arg);
            try isa.sys(self, Sys.print_char);
            return;
        }
        if (self.isPrimitiveType(arg, .fixed)) {
            try self.emitExpr(arg);
            try isa.sys(self, Sys.print_fixed);
            return;
        }
        if (self.isPrimitiveType(arg, .str)) {
            try self.emitExpr(arg);
            try isa.sys(self, Sys.print_str);
            return;
        }
        try self.emitExpr(arg);
        try isa.sys(self, Sys.print_int);
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

    /// Splice an `@inline` callee's body at the current emit
    /// position. Args land in fresh locals in the caller's frame;
    /// `return` in the body redirects to a jmp past the splice.
    /// Body size capped at `inline_body_instruction_cap` (over →
    /// `E_ANN_INLINE_TOO_LARGE`).
    pub fn emitInlineCall(
        self: *Emitter,
        callee: *const ast.DefDecl,
        c: ast.CallExpr,
    ) !void {
        if (self.inline_depth >= inline_max_depth) {
            try self.diagFatal(c.span, "E_ANN_INLINE_RECURSIVE", "codegen: `@inline` def expanded past nesting cap — likely recursive inlining");
            return;
        }
        self.inline_depth += 1;
        defer self.inline_depth -= 1;

        if (c.args.len != callee.params.len) {
            try self.diagFatal(c.span, "E_ANN_INLINE_ARITY", "codegen: `@inline` call arity mismatch — typechecker should have flagged");
            return;
        }

        // Bind args → fresh locals in the caller's frame. Each
        // local extends `frame_bytes` and stays addressable for
        // the body's emit (gero pre-reserves the whole frame at
        // the def's prologue, so a new sub-imm-from-sp is needed
        // for the inline-only slots).
        const saved_locals = self.locals;
        const saved_params = self.params;
        self.locals = .{};
        self.params = .{};
        defer {
            self.locals = saved_locals;
            self.params = saved_params;
        }
        for (callee.params, c.args) |p, arg| {
            try isa.subImmFromReg(self, 2, Reg.sp);
            try expr_emit.emitExpr(self, arg);
            const pname = self.source[p.name.start..p.name.end];
            const dup = try self.arena.dupe(u8, pname);
            const ofs = try self.allocLocal(dup);
            try isa.movRegToRegOffset(self, Reg.acu, Reg.fp, ofs);
        }

        // Body-emit setup: capture starting offset for the
        // instruction-count gate; install a fresh inline_returns
        // collector so nested `return` statements rewrite to a
        // forward jmp instead of `ret`.
        const start_offset = try self.currentOffset();
        const saved_returns = self.inline_returns;
        self.inline_returns = std.ArrayList(usize).empty;
        defer self.inline_returns = saved_returns;

        // Lambdas inside `@inline` bodies are unsupported
        // (their mangled labels would collide across call sites).
        const saved_fn_info = self.fn_closure_info;
        defer self.fn_closure_info = saved_fn_info;
        try lambda.analyzeFn(self, callee);
        if (self.fn_closure_info.lambdas.items.len > 0) {
            const name = self.source[callee.name.start..callee.name.end];
            const msg = try std.fmt.allocPrint(
                self.arena,
                "`@inline` def `{s}` declares a lambda in its body — unsupported (lambdas need a host def, but inlined bodies don't emit one)",
                .{name},
            );
            try self.diagFatal(c.span, "E_ANN_INLINE_LAMBDA_BODY", msg);
            return;
        }

        try self.pushBlock();
        for (callee.body) |stmt| try self.emitStatement(stmt);
        try self.popBlockWithDefers();

        // Patch every `return`-redirected jmp to land HERE (after
        // the body). The return value is in `acu` and stays there
        // for the caller — matches the regular-call ABI.
        const end_offset = try self.currentOffset();
        const end_addr: u16 = self.codeOffsetToAddress(end_offset);
        if (self.inline_returns) |*returns| {
            const buf: []u8 = self.currentBufferMut();
            for (returns.items) |patch| {
                buf[patch] = @intCast(end_addr & 0xFF);
                buf[patch + 1] = @intCast((end_addr >> 8) & 0xFF);
            }
            returns.deinit(self.allocator);
        }

        // Size gate: the body must emit ≤ 32 instructions. Walk
        // the spliced bytes via the disasm decoder so the count
        // matches what the ISA considers an instruction (not "Zig
        // emit calls").
        const buf: []const u8 = self.currentBufferMut();
        var inst_count: usize = 0;
        var cursor: usize = start_offset;
        while (cursor < end_offset) {
            const dec = disasm_decoder.decodeOne(self.allocator, buf, cursor) catch break;
            defer self.allocator.free(dec.instruction.operands);
            inst_count += 1;
            if (cursor == dec.next_offset) break;
            cursor = dec.next_offset;
        }
        if (inst_count > inline_body_instruction_cap) {
            const name = self.source[callee.name.start..callee.name.end];
            const msg = try std.fmt.allocPrint(
                self.arena,
                "`@inline` body of `{s}` lowers to {d} instructions — over the cap of {d}",
                .{ name, inst_count, inline_body_instruction_cap },
            );
            try self.diagFatal(c.span, "E_ANN_INLINE_TOO_LARGE", msg);
        }
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
    fn codeOffsetToAddress(self: *const Emitter, offset: usize) u16 {
        // @as: per-buffer offsets stay ≤ 64 KiB by ISA constraint.
        const ofs: u16 = @intCast(offset);
        return if (self.current_bank != null) bank_window_base + ofs else code_base + ofs;
    }

    /// Mutable view into the active code buffer. Used for emit-
    /// time slot patches.
    fn currentBufferMut(self: *Emitter) []u8 {
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
    fn unwindAllDefersForReturn(self: *Emitter) !void {
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
