/// `gero check` — validate a `.gas` source through the full
/// assembler pipeline (resolveIncludes → parse → codegen) without
/// writing a `.gx` output. Editor-LSP-style use case + CI gate
/// covering more failure modes than `gero asm` would because the
/// caller gets the merged diagnostics for free.
///
/// Exit codes per cli.md §3.9 + §5:
///   - `0` clean (one-line `✓ <path>` summary, suppressed by `--quiet`)
///   - `1` host IO problem (file missing, unreadable, etc.)
///   - `2` usage error (missing positional)
///   - `4` lint / parse / codegen error (≥ 1 diagnostic)
///
/// `.gr` source dispatches to a "not yet implemented" stub until
/// the gero-lang front-end lands in v0.3 (#7).
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const diagnostics = @import("diagnostics.zig");

/// Drive `gero check` end-to-end against `opts.positional()[0]`.
/// Caller owns `arena`; every allocation is short-lived.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len < 1) {
        try term.err("gero check: missing source file path", .{});
        return 2;
    }
    const src_path = positionals[0];

    if (std.mem.endsWith(u8, src_path, ".gr")) {
        try term.err("gero check: .gr support lands in v0.3 (gero-lang front-end)", .{});
        return 1;
    }

    var fused = gero.asm_.resolveIncludes(io, arena, src_path) catch |err| {
        try term.err("gero check: cannot read {s} ({s})", .{ src_path, @errorName(err) });
        return 1;
    };
    defer fused.deinit();

    const style: gero.asm_.Style = if (term.color) .ansi else .plain;
    if (fused.errors.len > 0) {
        try diagnostics.printSingle(stdout, fused.source_map, fused.errors, style);
        return 4;
    }

    // Statement-level recovery means parse always returns a tree;
    // run codegen unconditionally so codegen-only errors (E001
    // duplicate label, E003 undefined symbol, etc.) surface in the
    // same pass as parse errors.
    var pt = try gero.asm_.parse(arena, fused.source);
    defer pt.deinit();

    var cg = try gero.asm_.assemble(arena, fused.source, pt, .{});
    defer cg.deinit();

    if (pt.hasErrors() or cg.hasErrors()) {
        try diagnostics.printMerged(arena, stdout, fused.source_map, pt.errors, cg.errors, style);
        return 4;
    }

    if (!opts.quiet) {
        try stdout.print("{s}✓{s} {s}\n", .{ style.location, style.reset, src_path });
    }
    return 0;
}
