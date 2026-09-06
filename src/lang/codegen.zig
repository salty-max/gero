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
const vec_builtin = @import("codegen/vec_builtin.zig");
const variadic = @import("codegen/variadic.zig");
const inline_asm = @import("codegen/inline_asm.zig");
const object = @import("codegen/object.zig");
const stdlib = @import("codegen/stdlib.zig");

/// The asm assembler, re-exported here (one level up from
/// `codegen/`) so `codegen/inline_asm.zig` can lower an
/// `asm "<instr>"` statement without a deep cross-layer import.
pub const assembleInstruction = @import("../asm.zig").assembleInstruction;
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
/// Upper bound (exclusive) of the static-data region — and of the whole
/// program image. Code, the interned string pool, and data globals all
/// grow toward this and must stay below the host IO / command surface
/// just above (gtx-16 maps its command surface at `0xFE50`); past it an
/// address can't be reached (data → `E_CODEGEN_DATA_OVERFLOW`, the whole
/// image → `E_CODEGEN_IMAGE_OVERFLOW`).
pub const data_region_end: u16 = 0xFE40;

/// Convert a buffer-local `offset` under code base `base` to a u16
/// address, clamping at the u16 ceiling. An over-large image yields a
/// meaningless (clamped) address but never panics on the narrowing cast —
/// the post-emit `E_CODEGEN_IMAGE_OVERFLOW` check rejects it cleanly.
pub fn offsetToAddr(base: u16, offset: usize) u16 {
    // @as: clamped to ≤ 0xFFFF before the narrow, so it can't truncate.
    return @intCast(@min(@as(usize, base) + offset, 0xFFFF));
}

// ---------- cross-bank save-stack (codegen-internal) ----------

// A software save-stack for the `__call_bank` trampoline: each cross-bank
// call parks (saved `mb`, caller return-ip) here so nested cross-bank
// calls — including one re-entered from an `@interrupt` handler — unwind
// correctly. It sits at the bottom of low RAM, below `code_base` /
// `data_base` and always mapped regardless of `mb`. Banked programs run
// their runtime stack from the top of low RAM (`bank_stack_top`) growing
// down toward this area, so the two share low RAM — roughly 3.5 KB of
// runtime stack before they meet (untrapped, as with any stack overflow).
const bank_save_ptr: u16 = 0x0100; // 2-byte cell holding the live save-sp
const bank_save_slot_bytes: u16 = 4; // one (mb, return-ip) pair per level
const bank_save_mb_ofs: i8 = 0; // saved `mb` within a slot
const bank_save_ret_ofs: i8 = 2; // saved caller return-ip within a slot
const bank_save_levels: u16 = 64; // max cross-bank nesting depth
const bank_save_base: u16 = bank_save_ptr + 2; // first save-area byte
const bank_save_top: u16 = bank_save_base + bank_save_slot_bytes * bank_save_levels; // initial save-sp (grows down)

// Initial `sp` for banked programs. The boot default (`0xFFFE`) puts
// the runtime stack in the IO page + bank window (`0xC000..0xFEFF`,
// bank-switched) — so call frames would land in bank-mapped memory and
// corrupt across a bank hop. Banked programs instead start the stack at
// the top of low RAM (the ISA's canonical stack home, always flat),
// growing down toward the save-stack at `bank_save_ptr`.
const bank_stack_top: u16 = 0x0FFE;

// GP registers an `@interrupt` handler saves on entry + restores before
// `rti`, so it's transparent to the interrupted code (the VM saves only
// `ip`/`fp`/`flg`). All of them: regular codegen uses `acu`/`r1`–`r3`
// and the cross-bank trampoline `r4`–`r6`, and a handler may exercise
// either — saving the full set keeps it correct regardless of which.
const isr_saved_regs = [_]u8{ Reg.acu, Reg.r1, Reg.r2, Reg.r3, Reg.r4, Reg.r5, Reg.r6 };

// ---------- .gx file constants (re-exported from archive) ----------

const bank_window_base = archive.bank_window_base;

const InternedString = strings.InternedString;
const StringPatch = strings.StringPatch;

// ---------- public surface ----------

/// A deferred address write. Emission records where an address goes
/// and which buffer-relative offset it names; the link step turns that
/// into an absolute address once every buffer's base is fixed. Keeping
/// this out of emission is what makes a module's code position-
/// independent — the bytes don't change when something ahead of them
/// grows.
pub const Relocation = struct {
    /// Bank holding the patch site, or `null` for the base image.
    bank: ?u8,
    /// Byte offset of the 2-byte address slot within that buffer.
    patch_offset: usize,
    /// Offset the slot should name, within the same buffer.
    target_offset: usize,
};

/// One symbol's relocatable code, sliced out of the emitted buffers.
pub const Fragment = object.Fragment;

/// Byte range one symbol's emission occupied.
pub const FragmentSpan = object.Span;

/// Where a symbol lives, named independently of its run-time
/// address: the buffer that holds it and the byte offset within it.
/// Emission records symbols this way and the link step resolves them,
/// so a definition's recorded position doesn't depend on where its
/// buffer eventually sits.
pub const CodeRef = struct {
    /// Bank holding the symbol, or `null` for the base image.
    bank: ?u8,
    /// Byte offset of the symbol within that buffer. Kept wide so an
    /// over-large image still records positions; `addr` clamps.
    offset: usize,

    /// Run-time address of this symbol.
    pub fn addr(self: CodeRef) u16 {
        return offsetToAddr(if (self.bank) |_| bank_window_base else code_base, self.offset);
    }
};

/// One string pointer inside a baked global: the absolute image
/// offset of its 2-byte slot, and the interned string whose resolved
/// address goes there.
const BakeStrPatch = struct {
    image_offset: usize,
    string_id: usize,
};

/// Element type and length of a def's fixed-array return type.
pub const ArrayRet = struct {
    elem: *const Type,
    count: u32,
};

/// Codegen output. Owns the `.gx` image bytes, the diagnostic
/// slice, and the arena backing diagnostic message strings.
pub const Compiled = struct {
    /// Full `.gx` archive. Pass to `gero.vm.parseGx`.
    image: []u8,
    diagnostics: []Diagnostic,
    /// Per-symbol relocatable code, empty unless `Options.emit_fragments`
    /// asked for it. Backed by `diag_arena`.
    fragments: []const Fragment = &.{},
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
    /// Require a top-level entry `def`. `true` for a runnable image;
    /// `false` for validation-only (e.g. `gero check`), where a library
    /// file with no `main` still has its bodies lowered + checked.
    require_entry: bool = true,
    /// Fragments from a previous build this one may reuse. A def whose
    /// label matches one is spliced rather than lowered; the caller is
    /// responsible for only offering fragments still valid for this
    /// source (see the build cache's staleness check).
    cached_fragments: []const Fragment = &.{},
    /// Return each symbol's relocatable code on `Compiled.fragments`.
    /// Off by default — only a caching build needs it, and extracting
    /// copies every emitted byte.
    emit_fragments: bool = false,
    /// `use X as Y from "./mod"` quoted-path aliases (`Y` → `X`) from
    /// the fuser, or `null` for a single-file build.
    import_aliases: ?*const std.StringHashMapUnmanaged([]const u8) = null,
    /// Module graph from the fuser, or `null` for a single-file
    /// build. Lets same-named defs in different modules get distinct
    /// symbols (§5).
    graph: ?typecheck_mod.ModuleGraph = null,
};

/// A stdlib function pulled into scope by a selective `use` —
/// `use rng from math` records `rng → (math, rng)`.
pub const StdlibImport = struct { module: []const u8, name: []const u8 };

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

    if (opts.require_entry and findEntryDef(source, checked.program, opts.entry_name) == null) return error.EntryNotFound;

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
        .current_ret_is_tuple = false,
        .current_ret_array = null,
        .current_ret_scalar_opt = null,
        .sret_param_ofs = 0,
        .sret_scratch_ofs = null,
        .inline_ret_struct = null,
        .inline_ret_slot = 0,
        .inline_ret_is_tuple = false,
        .inline_ret_tuple_slot = 0,
        .fn_addresses = .{},
        .fn_banks = .{},
        .noreturn_defs = .{},
        .fn_ret_struct = .{},
        .fn_ret_tuple = .{},
        .fn_ret_array = .{},
        .fn_ret_scalar_opt = .{},
        .global_sret_scratch = 0,
        .inline_defs = .{},
        .variadic_decls = .{},
        .interrupt_defs = .empty,
        .inline_returns = null,
        .inline_depth = 0,
        .trampoline_addr = null,
        .call_patches = .empty,
        .relocations = .empty,
        .fragment_spans = .empty,
        .cached_fragments = opts.cached_fragments,
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
        .import_aliases = opts.import_aliases,
        .graph = opts.graph,
        .duplicated_defs = .{},
        .selective_stdlib = .{},
        .class_layouts = .{},
        .current_class_name = null,
        .current_variadic = null,
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
        .bake_str_patches = .empty,
        .global_inits = .empty,
        .global_destructures = .empty,
        .bake_defs = .{},
    };
    defer emitter.code.deinit(allocator);
    defer emitter.call_patches.deinit(allocator);
    defer emitter.relocations.deinit(allocator);
    defer emitter.fragment_spans.deinit(allocator);
    defer emitter.bake_inits.deinit(allocator);
    defer emitter.bake_str_patches.deinit(allocator);
    defer emitter.global_inits.deinit(allocator);
    defer emitter.global_destructures.deinit(allocator);
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

    // Reject an image that overruns the addressable ceiling before
    // assembling it — the address narrowing during emission clamped
    // (never panicked), so the size is meaningful here. The code buffer
    // (code + interned string pool) and the data globals both grow toward
    // `data_region_end`; past it nothing downstream (heap, IO page) has
    // room.
    // @as: widen the u16 bases to usize for the byte-length math.
    const image_top: usize = @max(@as(usize, code_base) + emitter.code.items.len, @as(usize, emitter.data_cursor));
    // A `@bank` def's code lives in a separate 16 KiB window buffer; the
    // archive would silently truncate one that overran it (and the
    // address clamp above hides the spilled jump targets), so reject it.
    var bank_overflow = false;
    var bank_it = emitter.banks.valueIterator();
    while (bank_it.next()) |b| {
        if (b.items.len > archive.bank_disk_size) bank_overflow = true;
    }
    if (image_top > data_region_end or bank_overflow) {
        if (bank_overflow) {
            try emitter.diagFatal(.{ .start = 0, .end = 0 }, "E_CODEGEN_BANK_OVERFLOW", "a `@bank` def's code exceeds the 16 KiB bank window — split it across banks or reduce its size");
        } else {
            try emitter.diagFatal(.{ .start = 0, .end = 0 }, "E_CODEGEN_IMAGE_OVERFLOW", "program image (code + interned strings + data) exceeds the addressable ceiling — reduce program size");
        }
        return .{
            .image = try allocator.alloc(u8, 0),
            .diagnostics = try diagnostics.toOwnedSlice(allocator),
            .diag_arena = diag_arena,
            .allocator = allocator,
        };
    }

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
    // The string pool laid out during `emitProgram`, so a baked
    // `str`'s pointer slot can now take its real address.
    for (emitter.bake_str_patches.items) |p| {
        const addr = emitter.strings.items[p.string_id].ref.addr();
        // safety: u16 → 2 LE bytes; byte-mask casts.
        base_image[p.image_offset] = @intCast(addr & 0xFF);
        base_image[p.image_offset + 1] = @intCast(addr >> 8);
    }

    const debug_blob: ?[]u8 = if (opts.debug_symbols)
        try emitter.buildDebugSymbolSection()
    else
        null;
    defer if (debug_blob) |s| allocator.free(s);
    // Heap starts above the whole image — past the code + interned
    // string pool (which grows the code buffer, so `code_end` can exceed
    // `data_cursor`) AND past the data-global region. Pinning it at
    // `data_cursor` alone let `alloc` hand out addresses inside the live
    // string literals, so a concat's copy aliased its own source.
    // @as: code_end / data_cursor are both ≤ 64 KiB by ISA; the max fits u16.
    const heap_base: u16 = @intCast(@max(code_end, @as(usize, emitter.data_cursor)));
    const image = try buildArchive(allocator, base_image, code_base, heap_base, &emitter.banks, debug_blob);
    allocator.free(base_image);

    const fragments: []const Fragment = if (opts.emit_fragments)
        try object.extract(diag_arena.allocator(), &emitter)
    else
        &.{};

    return .{
        .image = image,
        .fragments = fragments,
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
    /// `true` for an `i8` global — a byte load sign-extends rather than
    /// zero-extends, so a negative value keeps its sign.
    signed_byte: bool = false,
};

/// A top-level `let` / `const` whose initializer isn't `bake`-seeded —
/// its value is evaluated and stored into the global's slot at entry-def
/// startup. Recorded in declaration order so a later init can read an
/// earlier one.
pub const GlobalInit = struct {
    name: []const u8,
    init: *const ast.Expr,
};

/// A module-scope `let PATTERN = init` whose pattern binds more than a
/// single name. Each bound name already has its own global; entry
/// startup destructures `init` into them.
pub const GlobalDestructure = struct {
    pattern: *const ast.Pattern,
    init: *const ast.Expr,
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
    /// `true` while emitting a tuple-returning def — `return` copies the
    /// tuple into the caller's sret buffer (same convention as
    /// `current_ret_struct`; the element layout comes from the return
    /// expression's inferred type).
    current_ret_is_tuple: bool,
    /// Element type + length of a fixed-array return for the def being
    /// emitted, or `null`. Like a struct return, the array materializes
    /// into the caller's sret buffer.
    current_ret_array: ?ArrayRet,
    /// Element type of a scalar `T?` return for the def currently being
    /// emitted, or `null`. A scalar optional is a 4-byte `{present, value}`
    /// that rides the sret convention like a struct; `return` materializes
    /// it into the caller's sret buffer. A pointer-like `T?` returns its
    /// nullable word in `acu`, so it stays `null` here.
    current_ret_scalar_opt: ?*const Type,
    /// fp-offset of the hidden sret destination pointer in the current
    /// frame (`4 + Σ user-param widths` — it sits just above the last
    /// user param). Valid while `current_ret_struct` is set,
    /// `current_ret_is_tuple` is true, or `current_ret_scalar_opt` is set.
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
    /// While splicing a tuple-returning `@inline` body: `true` + the
    /// caller-frame result slot its `return` materializes into (element
    /// layout comes from the return expression's type). Mirrors
    /// `inline_ret_struct`.
    inline_ret_is_tuple: bool,
    inline_ret_tuple_slot: i8,
    /// `def` name → absolute address. Banked defs live in the
    /// bank window; un-banked defs live in the base image.
    fn_addresses: std.StringHashMapUnmanaged(CodeRef),
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
    /// `def` names that return a tuple by value — drives the same sret
    /// convention as `fn_ret_struct` (a set: the element layout is read
    /// from the call/return expression's inferred type).
    fn_ret_tuple: std.StringHashMapUnmanaged(void),
    /// Defs whose return type is a fixed array. They ride the same sret
    /// convention as struct / tuple returns.
    fn_ret_array: std.StringHashMapUnmanaged(void),
    /// `def` names that return a scalar `T?` by value — the 4-byte
    /// `{present, value}` rides the same sret convention as a struct
    /// (a set: the element type is read from the call/return expression).
    fn_ret_scalar_opt: std.StringHashMapUnmanaged(void),
    /// Largest (2-aligned) aggregate return width across the program — the
    /// size of the per-frame sret scratch buffer that holds a returned
    /// struct / tuple / scalar-optional until its consumer copies it out.
    /// 0 when no def returns by sret.
    global_sret_scratch: u16,
    /// `def` names carrying `@inline`. `emitCall` inlines the
    /// body rather than emitting `call addr`.
    inline_defs: std.StringHashMapUnmanaged(*const ast.DefDecl),
    /// Variadic `def` names → their decl. `emitCall` reads the fixed-
    /// param count to route each call to the matching `name$N`
    /// specialization (§4.6.2); emission walks the decls directly.
    variadic_decls: std.StringHashMapUnmanaged(*const ast.DefDecl),
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
    trampoline_addr: ?CodeRef,
    /// Unresolved `call addr` sites — recorded when the callee's
    /// address isn't known yet (forward references). Rewritten at
    /// the end of `emitProgram`.
    call_patches: std.ArrayList(CallPatch),
    /// Address writes deferred to the link step. See `Relocation`.
    relocations: std.ArrayList(Relocation),
    /// Byte range each emitted symbol occupied, in emission order.
    fragment_spans: std.ArrayList(FragmentSpan),
    /// Fragments this build may splice instead of lowering. Empty for
    /// a full build.
    cached_fragments: []const Fragment,
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
    /// `use X as Y from "./mod"` aliases (`Y` → `X`), or `null` for a
    /// single-file build. Resolved before a top-level name lookup so
    /// an alias lowers like its target.
    import_aliases: ?*const std.StringHashMapUnmanaged([]const u8),
    /// Module graph, when the program spans more than one file.
    graph: ?typecheck_mod.ModuleGraph,
    /// Top-level def names declared in more than one module. Only
    /// these get module-qualified symbols — an unambiguous name keeps
    /// its bare form so a disassembly stays readable.
    duplicated_defs: std.StringHashMapUnmanaged(void),
    /// Selectively-imported stdlib functions (`use rng from math`):
    /// local name → `(module, real_name)`. Built in the pre-pass.
    selective_stdlib: std.StringHashMapUnmanaged(StdlibImport),
    /// Per-class layout: instance size, field offsets, vtable
    /// slots, vtable address (set by `class.emitVtables`).
    class_layouts: std.StringHashMapUnmanaged(class.ClassLayout),
    /// Class whose method body is currently emitting. Drives
    /// `super` resolution.
    current_class_name: ?[]const u8,
    /// The variadic specialization currently emitting, or `null`.
    /// Carries the trailing `args` slot's name, element type `T`,
    /// this specialization's vararg count, and the fp-offset of the
    /// first vararg word — drives `args.N` word-strided loads and
    /// `format(fmt, args)` forwarding inside the body (§4.6.2).
    current_variadic: ?variadic.Active,
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
    /// String pointers inside baked values, resolved after the pool
    /// lays out. Each entry names an absolute image offset and the
    /// interned string whose address belongs there.
    bake_str_patches: std.ArrayList(BakeStrPatch),
    /// Non-`bake` top-level initializers, emitted as stores at entry
    /// startup (declaration order). See `GlobalInit`.
    global_inits: std.ArrayListUnmanaged(GlobalInit),
    /// Module-scope destructuring `let`s, seeded at entry startup in
    /// declaration order alongside `global_inits`.
    global_destructures: std.ArrayList(GlobalDestructure),
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

    /// Element type / width / count of an `[T; N]` array — peeling a
    /// reference. `null` when the expression isn't array-typed.
    pub const ArrayInfo = struct { elem: *const Type, elem_width: u16, count: u32, signed_byte: bool };

    /// Resolve the `ArrayInfo` of an array-typed expression (peeling a
    /// reference); `null` when `e` isn't array-typed.
    pub fn arrayInfoOf(self: *const Emitter, e: *const ast.Expr) ?ArrayInfo {
        const t = self.typeOf(e) orelse return null;
        const peeled = if (t.* == .reference) t.reference else t;
        if (peeled.* != .array) return null;
        const elem = peeled.array.elem;
        const signed_byte = elem.* == .primitive and elem.primitive == .i8;
        return .{ .elem = elem, .elem_width = self.widthOfType(elem), .count = peeled.array.len, .signed_byte = signed_byte };
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
    /// `types.Type` — 1 for `i8`/`u8`/`bool`/`char`, the element sum for
    /// a named struct or tuple, 2 otherwise (16-bit primitives,
    /// references, class/enum pointers).
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
            .tuple => |elems| {
                var total: u16 = 0;
                for (elems) |elem| total +%= self.widthOfType(elem);
                return total;
            },
            .array => |a| {
                // @as: nested-array width stays ≤ the i8 frame cap.
                return @intCast(@as(u32, self.widthOfType(a.elem)) * a.len);
            },
            // A `Vec(T)` value is a 6-byte `(ptr, len, cap)` header (§3.4.3),
            // stored inline like a struct; its backing buffer is on the heap.
            .vec => return vec_builtin.header_size,
            // A scalar `T?` is a 4-byte `{present, value}` header; a
            // pointer-like `T?` is a single nullable-pointer word.
            .optional => |inner| return if (isScalarOptional(inner)) opt_scalar_size else 2,
            else => return 2,
        }
    }

    /// Optional-value layout. A scalar `T?` is a tagged 4-byte
    /// `{present, value}` header (present @0, value @2); a pointer-like `T?`
    /// is a single nullable-pointer word (0 = nil).
    pub const opt_present_ofs: u16 = 0;
    /// Byte offset of the value word in a scalar `T?`.
    pub const opt_value_ofs: u16 = 2;
    /// Byte size of a scalar `T?` (`{present, value}`).
    pub const opt_scalar_size: u16 = 4;

    /// Whether an optional with element type `inner` uses the tagged scalar
    /// representation (vs a nullable pointer).
    pub fn isScalarOptional(inner: *const Type) bool {
        return inner.* == .primitive and switch (inner.primitive) {
            .i8, .u8, .i16, .u16, .char, .bool_, .fixed => true,
            else => false,
        };
    }

    /// Inner type of a scalar-optional-typed expression (peeling a
    /// reference), or `null` — the 4-byte `{present, value}` form only.
    pub fn scalarOptionalElemOf(self: *const Emitter, e: *const ast.Expr) ?*const Type {
        const t = self.typeOf(e) orelse return null;
        const inner = if (t.* == .reference) t.reference else t;
        if (inner.* != .optional) return null;
        return if (isScalarOptional(inner.optional)) inner.optional else null;
    }

    /// Element type of a scalar `T?` return annotation (`-> T?` with a
    /// scalar `T`), or `null` for any other return shape. A scalar optional
    /// rides the sret convention; a pointer-like `T?` returns its nullable
    /// word in `acu`, so it stays `null` here.
    pub fn scalarOptReturnInner(self: *const Emitter, rt: ast.TypeAnn) error{OutOfMemory}!?*const Type {
        if (rt != .nullable) return null;
        const inner = (try self.typeAnnToType(rt.nullable.inner.*)) orelse return null;
        return if (isScalarOptional(inner)) inner else null;
    }

    /// Element type + length of a fixed-array return type, or `null`
    /// when `rt` isn't an array. Mirrors `scalarOptReturnInner` — the
    /// def prologue uses it to decide the sret convention.
    pub fn arrayReturnInfo(self: *const Emitter, rt: ast.TypeAnn) error{OutOfMemory}!?ArrayRet {
        if (rt != .array) return null;
        const t = (try self.typeAnnToType(rt)) orelse return null;
        if (t.* != .array) return null;
        return .{ .elem = t.array.elem, .count = t.array.len };
    }

    /// Resolve a surface `TypeAnn` to an arena `types.Type` so the
    /// destructuring matcher can thread one type representation (struct
    /// field / enum payload types come from AST `TypeAnn`s, tuple slots
    /// from inferred `types.Type`s). `Vec` / fn-types — never destructured
    /// through a binder — return `null`.
    pub fn typeAnnToType(self: *const Emitter, t: ast.TypeAnn) error{OutOfMemory}!?*const Type {
        switch (t) {
            .named => |n| {
                const name = self.source[n.name.start..n.name.end];
                const prim: ?types_mod.Primitive = if (std.mem.eql(u8, name, "i8"))
                    .i8
                else if (std.mem.eql(u8, name, "u8"))
                    .u8
                else if (std.mem.eql(u8, name, "i16"))
                    .i16
                else if (std.mem.eql(u8, name, "u16"))
                    .u16
                else if (std.mem.eql(u8, name, "bool"))
                    .bool_
                else if (std.mem.eql(u8, name, "nil"))
                    .nil_
                else if (std.mem.eql(u8, name, "str"))
                    .str
                else if (std.mem.eql(u8, name, "fixed"))
                    .fixed
                else if (std.mem.eql(u8, name, "char"))
                    .char
                else
                    null;
                if (prim) |p| return try types_mod.mkPrimitive(self.arena, p);
                return try types_mod.mkNamed(self.arena, name, n.name);
            },
            .tuple => |tt| {
                const elems = try self.arena.alloc(*const Type, tt.elems.len);
                for (tt.elems, 0..) |e, i| elems[i] = (try self.typeAnnToType(e.*)) orelse return null;
                const out = try self.arena.create(Type);
                out.* = .{ .tuple = elems };
                return out;
            },
            .array => |a| {
                const elem = (try self.typeAnnToType(a.elem.*)) orelse return null;
                if (a.len_expr.* != .int_lit) return null;
                // safety: int-lit length → low 16 bits, spec §3.4 caps the count.
                const raw: u32 = @bitCast(a.len_expr.int_lit.value);
                return try types_mod.mkArray(self.arena, elem, raw & 0xFFFF);
            },
            .reference => |r| {
                const inner = (try self.typeAnnToType(r.inner.*)) orelse return null;
                return try types_mod.mkReference(self.arena, inner);
            },
            .nullable => |o| {
                const inner = (try self.typeAnnToType(o.inner.*)) orelse return null;
                return try types_mod.mkOptional(self.arena, inner);
            },
            .vec, .fn_type => return null,
        }
    }

    /// Bytes of frame space the body could need so the prologue can
    /// `sub frame_bytes, sp`. A scalar local is 2 bytes; a struct
    /// local takes its full (2-aligned) width. Reserves space for
    /// every arm of control-flow forms.
    pub fn countFrameBytes(self: *const Emitter, body: []const ast.Statement) usize {
        return self.countFrameBytesDepth(body, 0);
    }

    /// Frame bytes the prologue must reserve for `body`: the def's own
    /// locals plus the frame every `@inline` call-site splices in. Inline
    /// expansions reserve fp-relative slots but emit no `sub sp` of their
    /// own — the prologue backs them here, so a slot always sits above the
    /// entry `sp` and a mid-expression inline call can't alias a value the
    /// surrounding expression already pushed. `depth` bounds the recursion
    /// at the same cap the expander uses for recursive inlines.
    fn countFrameBytesDepth(self: *const Emitter, body: []const ast.Statement, depth: u8) usize {
        var n: usize = 0;
        for (body) |s| n += self.countStmtFrameBytes(s, depth);
        return n;
    }

    fn countStmtFrameBytes(self: *const Emitter, stmt: ast.Statement, depth: u8) usize {
        // Locals + nested-body bytes the statement reserves directly...
        const own: usize = switch (stmt) {
            .let_decl => |d| self.letFrameBytes(d),
            .const_decl => 2,
            .block => |b| self.countFrameBytesDepth(b.body, depth),
            .if_stmt => |is_| blk: {
                var n: usize = 0;
                for (is_.arms) |a| {
                    if (a.let_pattern) |p| n += self.letArmFrameBytes(p, a.let_expr);
                    // `if expr is Class as h` — `h` parks the
                    // instance pointer in a fresh local slot.
                    if (a.cond) |c| if (c.* == .is_test and c.is_test.classBinding() != null) {
                        n += 2;
                    };
                    n += self.countFrameBytesDepth(a.body, depth);
                }
                if (is_.else_body) |eb| n += self.countFrameBytesDepth(eb, depth);
                break :blk n;
            },
            .while_stmt => |ws| blk: {
                var n: usize = 0;
                if (ws.let_pattern) |p| n += self.letArmFrameBytes(p, ws.let_expr);
                n += self.countFrameBytesDepth(ws.body, depth);
                break :blk n;
            },
            .for_stmt => |fs| self.forFrameBytes(fs) + self.countFrameBytesDepth(fs.body, depth),
            .repeat_stmt => |rs| self.countFrameBytesDepth(rs.body, depth),
            .match_stmt => |ms| blk: {
                // The scrutinee is materialized into a slot once (full width
                // for a tuple / struct, else a word); each arm's binders
                // then alias it or load from behind its pointer.
                const scrut_ty = self.typeOf(ms.scrutinee);
                var n: usize = if (scrut_ty != null and self.isInlineAggregateType(scrut_ty.?))
                    alignUpU16(self.widthOfType(scrut_ty.?), 2)
                else
                    2;
                for (ms.arms) |a| {
                    n += self.ownSlotBinderBytes(a.pattern, false);
                    n += self.countFrameBytesDepth(a.body, depth);
                }
                break :blk n;
            },
            .defer_stmt => |ds| self.countStmtFrameBytes(ds.body.*, depth),
            else => 0,
        };
        // ...plus the inline frames in the statement's own expressions
        // (sub-bodies are covered by the recursion above).
        return own + self.stmtInlineFrameBytes(stmt, depth);
    }

    /// Frame bytes a `for x in iter` loop reserves for its hidden slots +
    /// loop variable, by iterable kind — mirrors the codegen dispatch in
    /// `control_flow.emitForStmt`. The body's own locals are counted by the
    /// caller's recursion. An over-estimate is harmless (a larger reserve);
    /// an under-estimate corrupts the frame, so this must be an upper bound.
    fn forFrameBytes(self: *const Emitter, fs: ast.ForStmt) usize {
        // Range: iteration variable + a hidden `end` bound.
        if (fs.iter.* == .range) return 2 + 2;
        const it_ty = self.typeOf(fs.iter) orelse return 2 + 2;
        // A `&T` reference iterates the pointed-to aggregate (§3.4.4).
        const peeled = if (it_ty.* == .reference) it_ty.reference else it_ty;
        return switch (peeled.*) {
            // base + count + index hidden slots, plus the loop variable.
            // An array-literal iterable also materializes into a temp slot.
            .array => |a| blk: {
                var n: usize = 6 + self.loopVarBytes(a.elem);
                if (fs.iter.* == .list_lit or fs.iter.* == .list_repeat) {
                    // @as: array byte width is bounded by the i8 frame cap.
                    const w: u16 = @intCast(@as(usize, self.widthOfType(a.elem)) * a.len);
                    n += alignUpU16(w, 2);
                }
                break :blk n;
            },
            .vec => |elem| 6 + self.loopVarBytes(elem),
            // `str`: a byte cursor + the `char` loop variable.
            .primitive => |p| if (p == .str) 2 + 2 else 0,
            // Iterator: the hidden instance pointer + the `T?` result slot
            // (the loop variable aliases that slot's value region).
            .named => 2 + opt_scalar_size,
            else => 0,
        };
    }

    /// Frame bytes a loop variable of element type `elem` occupies — a word
    /// for a scalar / pointer element, the full (2-aligned) inline width for
    /// an aggregate element (struct / array / tuple).
    fn loopVarBytes(self: *const Emitter, elem: *const Type) usize {
        return switch (self.arrayElemKindOf(elem)) {
            .scalar => 2,
            else => alignUpU16(self.widthOfType(elem), 2),
        };
    }

    /// Inline-expansion bytes reachable from a statement's own
    /// expressions (conditions / initializers / arguments / values),
    /// mirroring `freeStatement`'s expression walk. Sub-statement bodies
    /// are not visited here — `countStmtFrameBytes` recurses into those.
    fn stmtInlineFrameBytes(self: *const Emitter, stmt: ast.Statement, depth: u8) usize {
        return switch (stmt) {
            .let_decl => |d| if (d.init) |e| self.countExprInlineBytes(e, depth) else 0,
            .const_decl => |d| self.countExprInlineBytes(d.init, depth),
            .assign => |a| self.countExprInlineBytes(a.target, depth) + self.countExprInlineBytes(a.value, depth),
            .inc_dec => |id| self.countExprInlineBytes(id.target, depth),
            .discard => |d| self.countExprInlineBytes(d.expr, depth),
            .expr_stmt => |es| self.countExprInlineBytes(es.expr, depth),
            .if_stmt => |is_| blk: {
                var n: usize = 0;
                for (is_.arms) |a| {
                    if (a.cond) |c| n += self.countExprInlineBytes(c, depth);
                    if (a.let_expr) |e| n += self.countExprInlineBytes(e, depth);
                    if (a.let_guard) |g| n += self.countExprInlineBytes(g, depth);
                }
                break :blk n;
            },
            .while_stmt => |ws| blk: {
                var n: usize = 0;
                if (ws.cond) |c| n += self.countExprInlineBytes(c, depth);
                if (ws.let_expr) |e| n += self.countExprInlineBytes(e, depth);
                if (ws.let_guard) |g| n += self.countExprInlineBytes(g, depth);
                break :blk n;
            },
            .for_stmt => |fs| blk: {
                var n: usize = self.countExprInlineBytes(fs.iter, depth);
                if (fs.step) |s| n += self.countExprInlineBytes(s, depth);
                break :blk n;
            },
            .repeat_stmt => |rs| self.countExprInlineBytes(rs.cond, depth),
            .match_stmt => |ms| blk: {
                var n: usize = self.countExprInlineBytes(ms.scrutinee, depth);
                for (ms.arms) |a| if (a.guard) |g| {
                    n += self.countExprInlineBytes(g, depth);
                };
                break :blk n;
            },
            .return_stmt => |rs| if (rs.value) |v| self.countExprInlineBytes(v, depth) else 0,
            .print_stmt => |ps| blk: {
                var n: usize = 0;
                for (ps.args) |a| n += self.countExprInlineBytes(a, depth);
                break :blk n;
            },
            else => 0,
        };
    }

    /// Sum of every `@inline` expansion frame reachable from `e`,
    /// recursing into sub-expressions exactly like `freeExpr`.
    fn countExprInlineBytes(self: *const Emitter, e: *const ast.Expr, depth: u8) usize {
        return switch (e.*) {
            .int_lit, .fixed_lit, .bool_lit, .nil_lit, .char_lit, .ident, .self_expr, .super_expr, .sizeof => 0,
            // A lambda body is a separate def with its own prologue; an
            // `if` expression isn't lowered at value position. A `do …
            // end` value block (§4.3) reserves its inner locals in THIS
            // frame, so count its body.
            .if_expr, .lambda => 0,
            .do_expr => |de| self.countFrameBytesDepth(de.body, depth),
            .str_lit => |s| blk: {
                var n: usize = 0;
                var has_aggregate = false;
                for (s.parts) |p| switch (p) {
                    .lit => {},
                    .interp => |ip| {
                        n += self.countExprInlineBytes(ip.expr, depth);
                        // A non-scalar interpolation buffers its render
                        // through a cursor slot (see `emitInterpFill`).
                        if (!self.interpFormattable(ip.expr)) has_aggregate = true;
                    },
                };
                if (has_aggregate) n += 2;
                break :blk n;
            },
            .paren => |p| self.countExprInlineBytes(p.inner, depth),
            .unary => |u| self.countExprInlineBytes(u.operand, depth),
            .binary => |b| self.countExprInlineBytes(b.lhs, depth) + self.countExprInlineBytes(b.rhs, depth),
            .range => |r| self.countExprInlineBytes(r.start, depth) + self.countExprInlineBytes(r.end, depth),
            .call => |c| blk: {
                var n: usize = 0;
                for (c.args) |a| n += self.countExprInlineBytes(a, depth);
                if (c.callee.* == .ident) {
                    const name = self.source[c.callee.ident.span.start..c.callee.ident.span.end];
                    if (self.inline_defs.get(name)) |callee| n += self.inlineExpansionBytes(callee, c.args, depth);
                } else n += self.countExprInlineBytes(c.callee, depth);
                break :blk n;
            },
            .method_call => |m| blk: {
                var n: usize = self.countExprInlineBytes(m.receiver, depth);
                for (m.args) |a| n += self.countExprInlineBytes(a, depth);
                break :blk n;
            },
            .field => |f| self.countExprInlineBytes(f.receiver, depth),
            .tuple_index => |t| self.countExprInlineBytes(t.receiver, depth),
            .index => |i| self.countExprInlineBytes(i.receiver, depth) + self.countExprInlineBytes(i.index, depth),
            .list_lit => |ll| blk: {
                var n: usize = 0;
                for (ll.elems) |x| n += self.countExprInlineBytes(x, depth);
                break :blk n;
            },
            .list_repeat => |lr| self.countExprInlineBytes(lr.value, depth) + self.countExprInlineBytes(lr.count, depth),
            .struct_lit => |sl| blk: {
                var n: usize = 0;
                for (sl.fields) |f| n += self.countExprInlineBytes(f.value, depth);
                break :blk n;
            },
            .tuple_lit => |tl| blk: {
                var n: usize = 0;
                for (tl.elems) |x| n += self.countExprInlineBytes(x, depth);
                break :blk n;
            },
            .is_test => |it| self.countExprInlineBytes(it.lhs, depth),
            .cast => |c| self.countExprInlineBytes(c.inner, depth),
            .ref_of => |r| self.countExprInlineBytes(r.inner, depth),
        };
    }

    /// Frame an `@inline` call-site reserves when it splices: an arg slot
    /// per argument (by the argument's shape), the return slot for an
    /// aggregate return, and the callee body's own frame (recursively).
    /// Mirrors the reservations `emitInlineCall` makes. Past the inline
    /// nesting cap it returns 0 — the expander rejects that as recursive.
    fn inlineExpansionBytes(self: *const Emitter, callee: *const ast.DefDecl, args: []const *ast.Expr, depth: u8) usize {
        if (depth >= inline_max_depth) return 0;
        var n: usize = 0;
        for (args) |arg| {
            if (self.argStructName(arg)) |sname|
                n += self.structSlotWidth(sname)
            else if (self.tupleElemsOf(arg)) |elems|
                n += self.tupleSlotWidth(elems)
            else
                n += 2;
        }
        if (callee.ret_type) |rt| {
            if (self.structNameOfTypeAnn(rt.*)) |sname|
                n += self.structSlotWidth(sname)
            else if (rt.* == .tuple)
                n += alignUpU16(self.widthOfTypeAnn(rt.*), 2);
        }
        return n + self.countFrameBytesDepth(callee.body, depth + 1);
    }

    /// Frame bytes a `let` reserves: the 2-aligned width of its type
    /// (struct fields summed), 2 for scalars. Non-ident patterns
    /// (destructuring) reserve minimally — lowering them is separate.
    fn letFrameBytes(self: *const Emitter, d: ast.LetDecl) usize {
        if (d.pattern.* != .ident) {
            const ty = if (d.init) |e| self.typeOf(e) else null;
            return self.destructureFrameBytes(d.pattern, ty);
        }
        const w: u16 = if (d.type_ann) |t|
            self.widthOfTypeAnn(t.*)
        else if (d.init) |e|
            (if (self.typeOf(e)) |ty| self.widthOfType(ty) else 2)
        else
            2;
        return alignUpU16(w, 2);
    }

    /// `true` when a value of `ty` lives inline as contiguous bytes (a
    /// tuple / struct / array) — vs a register-width scalar / enum-pointer
    /// / class-pointer.
    pub fn isInlineAggregateType(self: *const Emitter, ty: *const Type) bool {
        return switch (ty.*) {
            .tuple, .array => true,
            .named => |n| self.struct_decls.contains(n.name),
            else => false,
        };
    }

    /// Frame bytes a destructure of `pat` against `ty` reserves: the
    /// materialized scrutinee slot (full width for an inline aggregate,
    /// else a word) plus a slot per enum-payload binder. Inline
    /// tuple / struct binders alias the scrutinee slot, costing nothing.
    fn destructureFrameBytes(self: *const Emitter, pat: *const ast.Pattern, ty: ?*const Type) usize {
        const scrut: usize = if (ty != null and self.isInlineAggregateType(ty.?))
            alignUpU16(self.widthOfType(ty.?), 2)
        else
            2;
        return scrut + self.ownSlotBinderBytes(pat, false);
    }

    /// Frame bytes an `if let` / `while let` head reserves: a 2-byte slot
    /// for a bare-ident binder, else the full destructure footprint
    /// (scrutinee slot + payload binders) against the scrutinee's type.
    fn letArmFrameBytes(self: *const Emitter, pat: *const ast.Pattern, let_expr: ?*const ast.Expr) usize {
        if (pat.* == .ident) return 2;
        const ty = if (let_expr) |e| self.typeOf(e) else null;
        return self.destructureFrameBytes(pat, ty);
    }

    /// Frame bytes for the binders that need their own slot — enum-payload
    /// binders (loaded from behind the value's pointer), an aggregate
    /// payload's sized copy, and the temp that parks a nested enum's
    /// pointer. Inline binders (`behind == false`) alias the scrutinee
    /// slot and cost nothing.
    fn ownSlotBinderBytes(self: *const Emitter, pat: *const ast.Pattern, behind: bool) usize {
        return switch (pat.*) {
            .ident => if (behind) 2 else 0,
            .tuple_pattern => |t| blk: {
                var n: usize = 0;
                for (t.elems) |e| n += self.ownSlotBinderBytes(e, behind);
                break :blk n;
            },
            .struct_pattern => |st| blk: {
                var n: usize = 0;
                for (st.fields) |f| n += self.ownSlotBinderBytes(f.sub, behind);
                break :blk n;
            },
            .variant_pattern => |vp| blk: {
                // A variant behind a pointer parks its slot pointer in a
                // temp first; payload binders then live behind it.
                var n: usize = if (behind) 2 else 0;
                const path = self.source[vp.path.start..vp.path.end];
                const dot = std.mem.indexOfScalar(u8, path, '.');
                const ed = if (dot) |d| self.enum_decls.get(path[0..d]) else null;
                const vname = if (dot) |d| path[d + 1 ..] else path;
                for (vp.args, 0..) |a, i| {
                    const pann: ?ast.TypeAnn = if (ed) |e| self.variantPayloadAnn(e, vname, i) else null;
                    // An aggregate payload is copied into a sized slot the
                    // binder owns; its sub-binders alias that copy.
                    if (pann) |ann| if (self.structNameOfTypeAnn(ann) != null or ann == .tuple or ann == .array) {
                        n += alignUpU16(self.widthOfTypeAnn(ann), 2);
                        n += self.ownSlotBinderBytes(a, false);
                        continue;
                    };
                    n += self.ownSlotBinderBytes(a, true);
                }
                break :blk n;
            },
            else => 0,
        };
    }

    /// The `i`-th payload field's type annotation for variant `vname` of
    /// `ed`, or `null` when the variant / index doesn't resolve.
    fn variantPayloadAnn(self: *const Emitter, ed: *const ast.EnumDecl, vname: []const u8, i: usize) ?ast.TypeAnn {
        for (ed.variants) |v| {
            if (!std.mem.eql(u8, self.source[v.name.start..v.name.end], vname)) continue;
            return if (i < v.payload.len) v.payload[i].type_ann.* else null;
        }
        return null;
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
        // Pre-pass 0d: index selectively-imported stdlib functions
        // so a bare call lowers like its qualified form.
        try self.collectSelectiveStdlib(program);
        // Pre-pass 1: register globals (top-level let/const).
        try self.registerGlobals(program);
        // Pre-pass 2: collect each def's bank so `emitCall` can
        // decide direct-call vs trampoline without needing the
        // target's address yet.
        try self.collectDefBanks(program);
        try self.collectDuplicatedDefs(program);

        // Validation-only builds (no entry) still lower every def / method
        // body below so codegen errors surface; only the entry prologue
        // (IVT init, global seeding, `hlt`) is skipped.
        const entry = findEntryDef(self.source, program, entry_name);
        if (entry) |e| try self.emitDef(e, .entry);
        // Two-pass over top-level defs: hot first (source order),
        // then `@cold`-marked defs (still source order within the
        // group) — deterministic layout across compiler versions.
        // `@inline` defs never emit standalone — every call site
        // splices the body in place.
        // A variadic def never emits standalone — it has no single
        // arity. `emitSpecializations` emits one `name$N` per call-site
        // arity below, sharing the body (§4.6.2).
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| if ((entry == null or dd != entry.?) and !defHasFlagAnnotation(self.source, dd, "cold") and !defHasFlagAnnotation(self.source, dd, "inline") and !variadic.isVariadicDef(dd.*))
                try self.emitDef(dd, .regular),
            else => {},
        };
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| if ((entry == null or dd != entry.?) and defHasFlagAnnotation(self.source, dd, "cold") and !defHasFlagAnnotation(self.source, dd, "inline") and !variadic.isVariadicDef(dd.*))
                try self.emitDef(dd, .regular),
            else => {},
        };
        try variadic.emitSpecializations(self, program);
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

        // ---- link ----
        //
        // Every address the emitted code names is written here, once
        // each buffer's base is fixed: intra-buffer jumps, calls
        // (including cross-module ones, resolved through the
        // module-qualified symbols), and string-pool pointers.
        try self.resolveRelocations();
        try self.patchCalls();
        try self.patchStrings();
    }

    /// Write every deferred address. Emission recorded where each
    /// address goes and which offset it names; only here is the
    /// buffer's base known, which is what keeps the emitted bytes
    /// independent of where the buffer ends up.
    fn resolveRelocations(self: *Emitter) !void {
        for (self.relocations.items) |r| {
            const buf: []u8 = if (r.bank) |b|
                if (self.banks.getPtr(b)) |bl| bl.items else continue
            else
                self.code.items;
            const target: CodeRef = .{ .bank = r.bank, .offset = r.target_offset };
            const addr = target.addr();
            // safety: u16 → 2 LE bytes; both casts are byte-masks.
            buf[r.patch_offset] = @intCast(addr & 0xFF);
            buf[r.patch_offset + 1] = @intCast(addr >> 8);
        }
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
    pub fn internString(self: *Emitter, bytes: []const u8) !usize {
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

    /// `true` when `e` has a direct scalar `$(…)` formatter (a primitive).
    /// A non-primitive interpolation — struct / tuple / enum — renders via
    /// the shared `emitRenderValue` machinery into the buffer instead; this
    /// distinguishes the fast scalar path from that aggregate path. A
    /// missing type falls through as scalar (the dispatch then formats it
    /// as an integer).
    pub fn interpFormattable(self: *const Emitter, e: *const ast.Expr) bool {
        const t = self.typeOf(e) orelse return true;
        return t.* == .primitive;
    }

    /// `true` when the type annotation is the named primitive `name`
    /// (e.g. `"i8"`). Used to pick signed vs unsigned narrow-load
    /// handling where only the declared type — not an inferred type —
    /// is in hand.
    pub fn isPrimitiveTypeAnn(self: *const Emitter, t: ast.TypeAnn, name: []const u8) bool {
        return t == .named and std.mem.eql(u8, self.source[t.named.name.start..t.named.name.end], name);
    }

    /// `true` when the expression's inferred type is an unsigned integer
    /// (`u8` / `u16`) — picks `print_uint` over the signed `print_int`
    /// so a high-bit value renders as its unsigned magnitude.
    pub fn isUnsignedInt(self: *const Emitter, e: *const ast.Expr) bool {
        return self.isPrimitiveType(e, .u8) or self.isPrimitiveType(e, .u16);
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

    /// Pre-pass: record selectively-imported stdlib functions
    /// (`use rng [as r] from math`) keyed by local name → its
    /// `(module, real_name)`, so a bare call routes to the module's
    /// inline emitter like the qualified `math.rng()` form.
    fn collectSelectiveStdlib(self: *Emitter, program: *const ast.Program) !void {
        for (program.statements) |stmt| switch (stmt) {
            .use_decl => |d| {
                if (d.items.len == 0) continue;
                const module = self.source[d.module.start..d.module.end];
                if (!stdlib.isModule(module)) continue;
                const mod_dup = try self.arena.dupe(u8, module);
                for (d.items) |it| {
                    const orig = self.source[it.name.start..it.name.end];
                    const local = if (it.alias) |a| self.source[a.start..a.end] else orig;
                    try self.selective_stdlib.put(self.arena, try self.arena.dupe(u8, local), .{
                        .module = mod_dup,
                        .name = try self.arena.dupe(u8, orig),
                    });
                }
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

    /// Scan top-level `def`s, recording each name → its `@bank N`
    /// annotation (or `null` for base-image defs).
    /// Record every top-level def name declared by more than one
    /// module. Those are the only names needing a module-qualified
    /// symbol; a unique name keeps its bare form so a disassembly
    /// stays readable.
    fn collectDuplicatedDefs(self: *Emitter, program: *const ast.Program) !void {
        if (self.graph == null) return;
        var seen: std.StringHashMapUnmanaged(u16) = .{};
        for (program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| {
                const name = self.source[dd.name.start..dd.name.end];
                const module = self.moduleOf(dd.name.start);
                if (seen.get(name)) |first| {
                    if (first != module) try self.duplicated_defs.put(self.arena, name, {});
                } else {
                    try seen.put(self.arena, name, module);
                }
            },
            else => {},
        };
    }

    /// Module id owning a fused-source offset, or `0` without a graph.
    /// Record the byte range `label`'s emission occupied, so the
    /// build cache can reuse it without re-emitting the body.
    pub fn noteFragment(self: *Emitter, label: []const u8, module: u16, bank: ?u8, start: usize, end: usize) !void {
        try self.fragment_spans.append(self.allocator, .{
            .symbol = label,
            .module = module,
            .bank = bank,
            .start = start,
            .end = end,
        });
    }

    /// Module owning `span`, as a `SourceMap` file id.
    pub fn moduleOfSpan(self: *const Emitter, span: ast.Span) u16 {
        return self.moduleOf(span.start);
    }

    /// The cached fragment for `label`, or `null` when this build must
    /// lower the body itself.
    pub fn cachedFragment(self: *const Emitter, label: []const u8) ?Fragment {
        for (self.cached_fragments) |f| {
            if (std.mem.eql(u8, f.symbol, label)) return f;
        }
        return null;
    }

    fn moduleOf(self: *const Emitter, offset: u32) u16 {
        const g = self.graph orelse return 0;
        return g.source_map.fileIdAt(offset) orelse 0;
    }

    /// Symbol name for a top-level def referenced at `offset`. A name
    /// only one module declares keeps its bare form. A duplicated one
    /// resolves the way the typechecker did — the referring module's
    /// own declaration first, then the modules it imports — and takes
    /// that module's qualified symbol.
    pub fn qualifiedFnName(self: *Emitter, name: []const u8, offset: u32) ![]const u8 {
        if (!self.duplicated_defs.contains(name)) return name;
        const g = self.graph orelse return name;
        const here = self.moduleOf(offset);
        if (self.moduleDeclares(here, name)) return self.qualify(name, here);
        for (g.imports) |edge| {
            if (edge.from != here) continue;
            if (self.moduleDeclares(edge.to, name)) return self.qualify(name, edge.to);
        }
        return self.qualify(name, here);
    }

    /// Whether module `id` declares a top-level def called `name`.
    fn moduleDeclares(self: *const Emitter, id: u16, name: []const u8) bool {
        for (self.checked.program.statements) |*stmt| switch (stmt.*) {
            .def_decl => |*dd| {
                if (self.moduleOf(dd.name.start) != id) continue;
                if (std.mem.eql(u8, self.source[dd.name.start..dd.name.end], name)) return true;
            },
            else => {},
        };
        return false;
    }

    fn qualify(self: *Emitter, name: []const u8, module: u16) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}${d}", .{ name, module });
    }

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
                // A tuple-returning def uses the same sret scratch buffer.
                if (dd.ret_type) |rt| if (rt.* == .tuple) {
                    try self.fn_ret_tuple.put(self.arena, dup, {});
                    const w = alignUpU16(self.widthOfTypeAnn(rt.*), 2);
                    if (w > self.global_sret_scratch) self.global_sret_scratch = w;
                };
                // An array-returning def uses the same sret scratch buffer.
                if (dd.ret_type) |rt| if (rt.* == .array) {
                    try self.fn_ret_array.put(self.arena, dup, {});
                    const w = alignUpU16(self.widthOfTypeAnn(rt.*), 2);
                    if (w > self.global_sret_scratch) self.global_sret_scratch = w;
                };
                // A scalar-`T?`-returning def shares the sret scratch too.
                if (dd.ret_type) |rt| if (try self.scalarOptReturnInner(rt.*)) |_| {
                    try self.fn_ret_scalar_opt.put(self.arena, dup, {});
                    if (opt_scalar_size > self.global_sret_scratch) self.global_sret_scratch = opt_scalar_size;
                };
                if (noreturn_marked) try self.noreturn_defs.put(self.arena, dup, {});
                if (inline_marked) try self.inline_defs.put(self.arena, dup, dd);
                if (variadic.isVariadicDef(dd.*)) try self.variadic_decls.put(self.arena, dup, dd);
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

    /// `true` when any top-level def carries `@bank N`. Cross-bank
    /// calls are then possible, so the entry prologue seeds the
    /// save-stack pointer.
    fn hasBankedDefs(self: *const Emitter) bool {
        var it = self.fn_banks.valueIterator();
        while (it.next()) |b| if (b.* != null) return true;
        return false;
    }

    /// Seed the cross-bank save-stack pointer to the top of its area.
    /// Emitted once in the entry prologue, only when the program has
    /// banked defs — the first `__call_bank` then finds a valid slot.
    pub fn seedBankSaveStack(self: *Emitter) !void {
        if (!self.hasBankedDefs()) return;
        try isa.movImmToAddr(self, bank_save_top, bank_save_ptr);
    }

    /// Move the runtime stack into low RAM for banked programs so call
    /// frames stay out of the bank-switched window. Sets both `sp` and
    /// `fp` (the entry's own locals are `fp`-relative, so `fp` must move
    /// too). No-op (keeps the boot `sp`/`fp`) for unbanked programs.
    /// Emit before the frame reserve.
    pub fn relocateBankStack(self: *Emitter) !void {
        if (!self.hasBankedDefs()) return;
        try isa.movImmToReg(self, bank_stack_top, Reg.sp);
        try isa.movRegToReg(self, Reg.sp, Reg.fp);
    }

    /// `@interrupt` prologue: interrupt entry saves only `ip`/`fp`/`flg`,
    /// so a handler must preserve every GP register it might clobber for
    /// the interrupted code to resume intact. Push them, then give the
    /// handler its own frame (`fp = sp`) so its locals don't alias the
    /// interrupted frame. `mb` is left alone — a handler never changes it
    /// except via the cross-bank trampoline, which restores it. Emit
    /// before the frame reserve.
    pub fn emitIsrPrologue(self: *Emitter) !void {
        for (isr_saved_regs) |r| try isa.pushReg(self, r);
        try isa.movRegToReg(self, Reg.sp, Reg.fp);
    }

    /// `@interrupt` epilogue: release the frame, restore the saved GP
    /// registers (reverse push order), then `rti`. Replaces the bare
    /// `rti` at every handler exit (fall-off + explicit `return`).
    pub fn emitIsrEpilogue(self: *Emitter) !void {
        try isa.movRegToReg(self, Reg.fp, Reg.sp); // release the frame
        var i: usize = isr_saved_regs.len;
        while (i > 0) {
            i -= 1;
            try isa.popReg(self, isr_saved_regs[i]);
        }
        try self.emitByte(Op.rti_op);
    }

    /// Emit the cross-bank call trampoline in the base image (always
    /// reachable regardless of `mb`). A caller pushes `target_bank`
    /// then `target_addr`, then `call __call_bank`.
    ///
    /// The trampoline is frame-transparent: it pops its own return
    /// frame + the stack-passed target, parks (caller `mb`, caller
    /// return-ip) on the save-stack, then rebuilds the callee's frame
    /// below `arg0` and enters via `rti` so the callee reads `arg0` at
    /// `[fp+4]` exactly as a direct call would. The `__bank_return`
    /// continuation (entered when the callee returns) restores `mb` +
    /// the caller return-ip. Both the save-stack push / pop and the
    /// bank-switched entry / exit run with interrupts masked: `sei`
    /// guards the critical section, and `rti` restores the saved `flg`
    /// (and jumps) atomically — so no register stays live across an
    /// unmask, and an `@interrupt` handler that itself cross-bank-calls
    /// can neither corrupt the shared save-stack nor the target.
    fn emitCallBankTrampoline(self: *Emitter) !void {
        const saved_bank = self.current_bank;
        self.current_bank = null;
        defer self.current_bank = saved_bank;
        // `__bank_return` emits first so its address is a known immediate
        // for the `__call_bank` continuation push.
        const bank_return = try self.emitBankReturn();
        try self.emitCallBankEntry(bank_return);
    }

    /// Emit `__bank_return` — the continuation the callee returns to.
    /// On entry sp is at arg0, fp = caller fp, `acu` holds the result.
    /// Pops the save-stack under a mask, restores the caller's bank, and
    /// returns via `rti` (atomic flg-restore + jump). Returns its own
    /// address for the entry half to push as the callee's return-ip.
    fn emitBankReturn(self: *Emitter) !CodeRef {
        const bank_return: CodeRef = .{ .bank = null, .offset = self.code.items.len };
        try isa.movRegToReg(self, Reg.flg, Reg.r6); // save flg (incl. I bit)
        try isa.sei(self);
        try isa.movAddrToReg(self, bank_save_ptr, Reg.r4);
        try isa.movRegOffsetToReg(self, Reg.r4, bank_save_mb_ofs, Reg.r5); // saved mb
        try isa.movRegOffsetToReg(self, Reg.r4, bank_save_ret_ofs, Reg.r3); // caller return-ip
        try isa.addImmToReg(self, bank_save_slot_bytes, Reg.r4);
        try isa.movRegToAddr(self, Reg.r4, bank_save_ptr);
        try isa.movRegToReg(self, Reg.r5, Reg.mb); // restore caller bank
        // `rti` pops flg, then fp, then return-ip — push them reversed
        // (return-ip deepest, saved flg on top); `rti` restores the
        // interrupt state and jumps to the caller in one step.
        try isa.pushReg(self, Reg.r3); // caller return-ip
        try isa.pushReg(self, Reg.fp); // caller fp (rti re-sets it; unchanged)
        try isa.pushReg(self, Reg.r6); // saved flg
        try self.emitByte(Op.rti_op);
        return bank_return;
    }

    /// Emit `__call_bank` — the entry callers target (records
    /// `trampoline_addr`). Pops its own return frame + the stack-passed
    /// target, parks (caller mb, caller return-ip) on the save-stack,
    /// then rebuilds the callee's frame below arg0 and enters via `rti`.
    /// `bank_return` becomes the callee's return-ip.
    fn emitCallBankEntry(self: *Emitter, bank_return: CodeRef) !void {
        self.trampoline_addr = .{ .bank = null, .offset = self.code.items.len };
        // Mask before touching the save-stack: r3 (caller return-ip) +
        // r4 (save-sp) must survive the read-modify-write, and an
        // interrupt clobbers all general registers.
        try isa.movRegToReg(self, Reg.flg, Reg.r6); // save flg
        try isa.sei(self);
        try isa.popReg(self, Reg.r3); // caller return-ip
        try isa.popReg(self, Reg.fp); // caller old fp
        try isa.popReg(self, Reg.r1); // target address
        try isa.popReg(self, Reg.r2); // target bank; sp now at arg0
        // Park (caller mb, caller return-ip) on the save-stack.
        try isa.movAddrToReg(self, bank_save_ptr, Reg.r4);
        try isa.subImmFromReg(self, bank_save_slot_bytes, Reg.r4);
        try isa.movRegToReg(self, Reg.mb, Reg.r5);
        try isa.movRegToRegOffset(self, Reg.r5, Reg.r4, bank_save_mb_ofs);
        try isa.movRegToRegOffset(self, Reg.r3, Reg.r4, bank_save_ret_ofs);
        try isa.movRegToAddr(self, Reg.r4, bank_save_ptr);
        try isa.movRegToReg(self, Reg.r2, Reg.mb); // switch to target bank
        // Rebuild the callee's frame directly below arg0: (caller fp,
        // __bank_return) become its (old_fp, return-ip), so its `ret`
        // lands in __bank_return and it reads arg0 at [fp+4].
        try isa.pushReg(self, Reg.fp); // callee [fp+2] = old fp
        try isa.pushImm16(self, bank_return.addr()); // callee [fp+0] = return-ip
        try isa.movRegToReg(self, Reg.sp, Reg.fp); // callee fp = sp
        // Enter via `rti`: target address rides the stack (not a
        // register) across the atomic flg-restore + jump.
        try isa.pushReg(self, Reg.r1); // rti return-ip = target address
        try isa.pushReg(self, Reg.fp); // rti fp = callee fp
        try isa.pushReg(self, Reg.r6); // rti flg = saved flg
        try self.emitByte(Op.rti_op);
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
                const name = self.resolveImportAlias(self.source[n.name.start..n.name.end]);
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
            // A `Vec(T)` value is a 6-byte inline header (§3.4.3).
            .vec => vec_builtin.header_size,
            // Scalar `T?` → 4-byte tagged header; pointer-like → word.
            .nullable => |o| blk: {
                const inner = (self.typeAnnToType(o.inner.*) catch null) orelse break :blk 2;
                break :blk if (isScalarOptional(inner)) opt_scalar_size else 2;
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
            .asm_stmt => |as_| try inline_asm.emitInlineAsm(self, as_),
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

    /// Resolve a quoted-path import alias to its real exported name;
    /// identity when `name` isn't an alias.
    pub fn resolveImportAlias(self: *const Emitter, name: []const u8) []const u8 {
        const aliases = self.import_aliases orelse return name;
        return aliases.get(name) orelse name;
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
    pub const FieldInfo = struct { offset: u16, width: u16, struct_name: ?[]const u8, signed_byte: bool = false, is_tuple: bool = false };

    /// `FieldInfo` for `field_name` within `struct_name`, or `null` if
    /// unknown. Fields are laid out contiguously in declaration order
    /// (§3.4).
    pub fn structFieldInfo(self: *const Emitter, struct_name: []const u8, field_name: []const u8) ?FieldInfo {
        const sd = self.struct_decls.get(struct_name) orelse return null;
        var ofs: u16 = 0;
        for (sd.fields) |f| {
            const w = self.widthOfTypeAnn(f.type_ann.*);
            if (std.mem.eql(u8, self.source[f.name.start..f.name.end], field_name)) {
                return .{
                    .offset = ofs,
                    .width = w,
                    .struct_name = self.structNameOfTypeAnn(f.type_ann.*),
                    .signed_byte = self.isPrimitiveTypeAnn(f.type_ann.*, "i8"),
                    .is_tuple = f.type_ann.* == .tuple,
                };
            }
            ofs +%= w;
        }
        return null;
    }

    /// Struct name if `t` names a registered struct, else `null`.
    pub fn structNameOfTypeAnn(self: *const Emitter, t: ast.TypeAnn) ?[]const u8 {
        if (t != .named) return null;
        const name = self.resolveImportAlias(self.source[t.named.name.start..t.named.name.end]);
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

    /// `true` when `arg` has reference type `&T` — a 2-byte pointer that
    /// must be pushed as a scalar, never copied by value (the aggregate
    /// classifiers peel the reference, so a bare `&Struct` / `&[T;N]` /
    /// `&Vec` would otherwise be mistaken for a by-value aggregate).
    pub fn isReferenceArg(self: *const Emitter, arg: *const ast.Expr) bool {
        const t = self.typeOf(arg) orelse return false;
        return t.* == .reference;
    }

    /// Stack footprint of a parameter: a struct or tuple param occupies
    /// its full (2-aligned) width — passed by value as a contiguous copy
    /// (§3.4) — and a scalar param one word. Drives both the param
    /// fp-offsets and the caller's arg-push width.
    pub fn paramWidthAligned(self: *const Emitter, p: ast.Param) u16 {
        const t = p.type_ann orelse return 2;
        if (self.structNameOfTypeAnn(t.*)) |sname| {
            return self.structSlotWidth(sname);
        }
        // A struct / tuple / fixed-array / `Vec` param is passed by value —
        // its full (2-aligned) width (a `Vec` moves its 6-byte header,
        // §3.4.3). A `&T` reference is `.reference`, not the aggregate, so it
        // stays a 2-byte pointer.
        if (t.* == .tuple or t.* == .array or t.* == .vec) return alignUpU16(self.widthOfTypeAnn(t.*), 2);
        return 2;
    }

    /// Element list of a tuple-typed expression, or `null` for a
    /// non-tuple. The tuple analog of `structNameOf`: a tuple value is
    /// its base address (inline contiguous slots, §3.4).
    pub fn tupleElemsOf(self: *const Emitter, e: *const ast.Expr) ?[]const *const Type {
        const ty = self.typeOf(e) orelse return null;
        const inner = if (ty.* == .reference) ty.reference else ty;
        return if (inner.* == .tuple) inner.tuple else null;
    }

    /// Total byte width of a tuple (elements summed).
    pub fn tupleWidth(self: *const Emitter, elems: []const *const Type) u16 {
        var total: u16 = 0;
        for (elems) |e| total +%= self.widthOfType(e);
        return total;
    }

    /// A tuple's footprint rounded up to a 2-byte slot — the aligned
    /// size for inline-value frame, param, and arg layout.
    pub fn tupleSlotWidth(self: *const Emitter, elems: []const *const Type) u16 {
        return alignUpU16(self.tupleWidth(elems), 2);
    }

    /// 2-aligned stack footprint of a `[T; N]` value — `N` element widths
    /// byte-packed, rounded up so word access stays aligned.
    pub fn arraySlotWidth(self: *const Emitter, elem: *const Type, count: u32) u16 {
        // @as: total array width ≤ the i8 frame cap.
        return alignUpU16(@intCast(@as(u32, self.widthOfType(elem)) * count), 2);
    }

    /// Layout of one tuple element: byte offset (sum of prior element
    /// widths, byte-packed) + width, and whether it is a signed byte
    /// (`i8`, sign-extended on load).
    pub const TupleElemInfo = struct { offset: u16, width: u16, signed_byte: bool };

    /// Layout of tuple element `index` within its inline slots.
    pub fn tupleElemInfo(self: *const Emitter, elems: []const *const Type, index: u8) TupleElemInfo {
        var ofs: u16 = 0;
        for (elems[0..index]) |e| ofs +%= self.widthOfType(e);
        const et = elems[index];
        return .{
            .offset = ofs,
            .width = self.widthOfType(et),
            .signed_byte = et.* == .primitive and et.primitive == .i8,
        };
    }

    /// Classifies a tuple element as a register-width scalar, an inline
    /// named struct, or a nested tuple — so construction / `.N` access /
    /// `==` / `print` can recurse into aggregate elements.
    pub const TupleElemKind = union(enum) { scalar, structure: []const u8, tuple: []const *const Type };

    /// Classify tuple element `index` — a register-width scalar, an
    /// inline named struct, or a nested tuple.
    pub fn tupleElemAggregate(self: *const Emitter, elems: []const *const Type, index: u8) TupleElemKind {
        const et = elems[index];
        if (et.* == .tuple) return .{ .tuple = et.tuple };
        if (et.* == .named and self.struct_decls.contains(et.named.name)) return .{ .structure = et.named.name };
        return .scalar;
    }

    /// Classifies an array element type — a register-width scalar, an
    /// inline named struct, a nested tuple, or a nested array — so array
    /// construction / indexing can recurse into aggregate elements (each
    /// laid out inline at `i * elem_width`).
    pub const ArrayElemKind = union(enum) {
        scalar,
        structure: []const u8,
        tuple: []const *const Type,
        array: struct { elem: *const Type, len: u32 },
    };

    /// Classify an array's element type. A class / enum / reference is a
    /// register-width scalar (stored as its pointer / value word).
    pub fn arrayElemKindOf(self: *const Emitter, elem: *const Type) ArrayElemKind {
        return switch (elem.*) {
            .array => |a| .{ .array = .{ .elem = a.elem, .len = a.len } },
            .tuple => |t| .{ .tuple = t },
            .named => |n| if (self.struct_decls.contains(n.name)) .{ .structure = n.name } else .scalar,
            else => .scalar,
        };
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
            try appendDebugSymbol(self.allocator, &out, entry.value_ptr.addr(), 0, name);
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
