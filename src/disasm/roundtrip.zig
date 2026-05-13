/// Helpers that drive the asm → disasm → asm pipeline so tests
/// can assert byte-equality after a full round-trip.
///
/// Two entry points:
///
///   * `roundTripImage` — symbol-blind, takes a raw base-image
///     slice. Round-trips reliably only for pure-code sources
///     (no `data8` / `data16`). Cheap path for the legacy tests.
///   * `roundTripArchive` — takes a full `.gx` archive (header
///     included), reads the debug-symbol section to drive
///     data-mode rendering, and returns a re-assembled archive.
///     The right path for example-program round-trip tests.
const std = @import("std");
const gero = @import("../gero.zig");

/// Run the round-trip pipeline. Returns the re-assembled image
/// bytes (caller owns) on success. The caller can compare them
/// against the original image bytes to assert losslessness.
///
/// Caveats: the disasm has no way to distinguish code from data,
/// so passing an image with `data8` blobs (etc.) typically
/// produces gibberish on the way back. Use `roundTripArchive`
/// for sources that mix code + data.
pub fn roundTripImage(allocator: std.mem.Allocator, original_image: []const u8) ![]u8 {
    var disasm_text: std.Io.Writer.Allocating = .init(allocator);
    defer disasm_text.deinit();
    try gero.disasm.writeBytes(allocator, &disasm_text.writer, original_image);

    var pt = try gero.asm_.parse(allocator, disasm_text.written());
    defer pt.deinit();
    // Strip the debug-symbol section from the re-assembled
    // archive — the disasm's bare output (no symbols) drops
    // every label, so the re-asm's symbol table is empty
    // anyway. Disabling here keeps the byte-equality compare
    // tight against the original's base + banks tail.
    var cg = try gero.asm_.assemble(allocator, disasm_text.written(), pt, .{ .debug_symbols = false });
    defer cg.deinit();
    if (cg.hasErrors()) return error.RoundTripAssemblyFailed;

    // Strip the 16-byte header — the comparison is against the
    // raw image bytes, not the whole archive (entry point and
    // bank info on the re-assembled archive may differ slightly
    // because labels are gone).
    return allocator.dupe(u8, cg.image[16..]);
}

/// Run the round-trip pipeline over a full `.gx` archive (header
/// + base + banks + debug). Returns the re-assembled archive
/// (caller owns). The debug section drives data-mode rendering so
/// sources with `data8` blobs survive the trip — for example
/// programs that mix code + data, this is the entry point to use.
///
/// Caller should compare specific section slices (via
/// `parseHeader` on both) rather than the whole buffer: the
/// debug section's symbol order can vary even when code + data
/// bytes are byte-identical.
pub fn roundTripArchive(allocator: std.mem.Allocator, original_archive: []const u8) ![]u8 {
    const header = try gero.disasm.parseHeader(original_archive);
    const all_symbols = try gero.disasm.parseSymbols(allocator, header.debug);
    defer all_symbols.deinit(allocator);

    // Drop code labels — they'd substitute `&XXXX` for the label
    // name in jumps/calls, but the printer doesn't emit a
    // matching `LABEL:` declaration, so the reasm errors with
    // "undefined symbol". Data symbols are different: their
    // declaration *is* the `data8 NAME = ...` block the printer
    // emits, so keeping them is what makes mixed code+data
    // programs round-trip.
    const data_only = try filterDataSymbols(allocator, all_symbols);
    defer data_only.deinit(allocator);

    var disasm_text: std.Io.Writer.Allocating = .init(allocator);
    defer disasm_text.deinit();
    // `base_addr = 0` enables the symbol-address lookup in the
    // printer (data symbols carry CPU addresses), but
    // `show_addresses = false` suppresses the `XXXX:` gutter so
    // the output stays parseable by the assembler. Without
    // `show_bytes` either, the result reads as plain mnemonic +
    // operand lines plus `data8 NAME = ...` directives wherever
    // a data symbol lives.
    try gero.disasm.writeBytesPretty(allocator, &disasm_text.writer, header.image, .{
        .base_addr = 0,
        .show_addresses = false,
        .symbols = data_only,
    });

    var pt = try gero.asm_.parse(allocator, disasm_text.written());
    defer pt.deinit();
    var cg = try gero.asm_.assemble(allocator, disasm_text.written(), pt, .{ .debug_symbols = true });
    defer cg.deinit();
    if (cg.hasErrors()) return error.RoundTripAssemblyFailed;

    return allocator.dupe(u8, cg.image);
}

/// Return a new `Symbols` containing only the entries whose kind
/// is `data`. Caller owns the result via `deinit`.
fn filterDataSymbols(
    allocator: std.mem.Allocator,
    all_symbols: gero.disasm.Symbols,
) !gero.disasm.Symbols {
    var kept: std.ArrayList(gero.disasm.Symbol) = .empty;
    defer kept.deinit(allocator);
    for (all_symbols.entries) |e| {
        if (e.kind == .data) try kept.append(allocator, e);
    }
    return .{ .entries = try kept.toOwnedSlice(allocator) };
}
