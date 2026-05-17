/// Gero-lang codegen — typed AST → `.gx` bytecode image.
///
/// Direct emission (no asm intermediate per cli.md §3.2). Walks
/// the `CheckedProgram` from `typecheck.zig` and produces a `.gx`
/// archive ready for the VM loader (`gero.vm.parseGx`) per ISA §7.
///
/// This module is the *framework* slice — instruction selection
/// for the various AST shapes lands in subsequent slices. Today
/// it only emits enough to take an empty `def main() end` to a
/// valid bootable `.gx` that halts on entry.
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

// ---------- .gx file constants (mirror src/vm/loader.zig) ----------

const gx_magic = [4]u8{ 'G', 'E', 'R', 'O' };
const gx_version: u16 = 0x0001;
const gx_header_size: usize = 16;
const flag_has_debug: u16 = 0x0002;

// ---------- public surface ----------

/// Codegen output. Owns the `.gx` image bytes + the diagnostic
/// slice + the arena that backs everything else.
pub const Compiled = struct {
    /// Full `.gx` archive, ready to feed to `gero.vm.parseGx`.
    image: []u8,
    diagnostics: []Diagnostic,
    allocator: std.mem.Allocator,

    /// Release the image buffer + diagnostics slice. Idempotent
    /// after a successful `compile` — the codegen owns both.
    pub fn deinit(self: *Compiled) void {
        self.allocator.free(self.image);
        self.allocator.free(self.diagnostics);
    }

    /// `true` when at least one fatal diagnostic fired during
    /// codegen.
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
    /// symbols (per ISA §7.3). Slice B1 doesn't emit a body for
    /// the section yet; the flag stays clear regardless until the
    /// debug-symbols slice lands.
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
};

/// Walk a typechecked program and emit a `.gx` archive.
///
/// Slice-B1 scope: emits the bytes for the entry def's body
/// (today only `hlt` for an empty body) into the base image at
/// `code_base`. Header carries the entry-point address and total
/// image size. Banks / debug section / non-entry defs are
/// out-of-scope until later slices.
pub fn compile(
    allocator: std.mem.Allocator,
    source: []const u8,
    checked: *const CheckedProgram,
    opts: Options,
) CompileError!Compiled {
    _ = opts.debug_symbols;

    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    // Locate the entry def. The typechecker's `def_registry` is
    // private to that module; walking the program statements is
    // straightforward enough here.
    const entry = findEntryDef(source, checked.program, opts.entry_name) orelse return error.EntryNotFound;

    // Emit the entry def's body. Slice-B1 only handles the empty-
    // body shape: synthesize a single `hlt` so the VM halts on
    // entry. Future slices replace this with real instruction
    // selection over the body's statements.
    var code_buf: std.ArrayList(u8) = .empty;
    errdefer code_buf.deinit(allocator);
    try emitEntryBody(allocator, entry, &code_buf);

    // Build base image: zeros from 0x0000 up to `code_base`, then
    // the emitted bytes. Total length stays ≤ 64 KiB; for the
    // smoke test it's `code_base + 1`.
    // @as: widen u16 code_base to usize for the byte-length math (image stays ≤ 64 KiB by ISA).
    const total_image_bytes: usize = @as(usize, code_base) + code_buf.items.len;
    var base_image = try allocator.alloc(u8, total_image_bytes);
    errdefer allocator.free(base_image);
    @memset(base_image, 0);
    @memcpy(base_image[code_base..][0..code_buf.items.len], code_buf.items);
    code_buf.deinit(allocator);

    const image = try buildArchive(allocator, base_image, code_base);
    allocator.free(base_image);

    return .{
        .image = image,
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

// ---------- entry resolution ----------

/// Find the top-level `def` whose name matches `entry_name`.
/// Returns `null` when the program has no such def — caller maps
/// that to `error.EntryNotFound`. Names compare against bytes
/// borrowed from `source` (same convention as `Checker.lexeme`).
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

// ---------- emission ----------

/// `hlt` — VM opcode 0xFF. Halts execution per ISA §5.
const OP_HLT: u8 = 0xFF;

/// Emit the entry def's body. Slice-B1 walks the body statements;
/// for empty bodies it just emits `hlt`. Any non-empty body falls
/// back to the same hlt today — instruction selection per AST
/// shape is the next slice's scope.
fn emitEntryBody(
    allocator: std.mem.Allocator,
    entry: *const ast.DefDecl,
    out: *std.ArrayList(u8),
) !void {
    _ = entry;
    // The empty body emits one `hlt`. When the body becomes
    // non-empty in later slices the trailing `hlt` synthesizes the
    // program shutdown (or `ret` if `main` returns to a stub).
    try out.append(allocator, OP_HLT);
}

// ---------- archive layout (.gx per ISA §7.1) ----------

/// Build the full `.gx` byte image from a base-image buffer + an
/// entry-point address. Mirrors `src/asm/codegen.zig::buildArchive`
/// but trimmed to the lang-codegen subset: no banks (yet), no
/// debug-symbols emission, no SRAM banks.
fn buildArchive(
    allocator: std.mem.Allocator,
    base_image: []const u8,
    entry_point: u16,
) ![]u8 {
    // safety: base image always fits in 16-bit address space —
    // larger sources would have been rejected earlier (slice B1
    // never emits > 0x1101 bytes).
    const image_size: u16 = @intCast(base_image.len);
    const total = gx_header_size + base_image.len;
    var out = try allocator.alloc(u8, total);

    @memcpy(out[0..4], &gx_magic);
    writeU16Le(out[4..6], gx_version);
    writeU16Le(out[6..8], 0); // flags — banks + debug come later
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
