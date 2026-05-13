/// Helper that drives the asm → disasm → asm pipeline so tests
/// can assert byte-equality between the original and re-assembled
/// images. The disasm side is byte-blind (no debug symbols), so
/// the helper only round-trips reliably for source that contains
/// no `data8` / `data16` / mixed-data regions.
const std = @import("std");
const gero = @import("../gero.zig");

/// Run the round-trip pipeline. Returns the re-assembled image
/// bytes (caller owns) on success. The caller can compare them
/// against the original image bytes to assert losslessness.
///
/// Caveats: the disasm has no way to distinguish code from data,
/// so passing an image with `data8` blobs (etc.) typically
/// produces gibberish on the way back. Real round-trip tests are
/// expected to stick to all-code programs until debug symbols
/// ship.
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
