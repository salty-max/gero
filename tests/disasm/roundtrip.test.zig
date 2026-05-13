/// Round-trip property tests for the disassembler.
///
/// Property: for any all-code asm source, the pipeline
///   asm src1 → bytes1 → disasm bytes1 → src2 → asm src2 → bytes2
/// must produce `bytes1 == bytes2`.
///
/// Programs that mix code + data are NOT round-trippable without
/// debug symbols (the disasm can't tell where code ends and data
/// begins by inspecting bytes alone). Those land when debug
/// symbols ship — for v0.1 we test the pure-code case only.
const std = @import("std");
const gero = @import("gero");
const examples = @import("examples");

const alloc = std.testing.allocator;

/// Assemble `src` and return the raw image bytes (header stripped).
/// Debug symbols disabled so the round-trip compare only looks at
/// base + banks bytes — the disasm side strips labels anyway.
fn assembleImage(src: []const u8) ![]u8 {
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, src, pt, .{ .debug_symbols = false });
    defer cg.deinit();
    if (cg.hasErrors()) return error.AssemblyFailed;
    return alloc.dupe(u8, cg.image[16..]);
}

test "roundtrip: hlt" {
    const original = try assembleImage("hlt\n");
    defer alloc.free(original);
    const reassembled = try gero.disasm.roundTripImage(alloc, original);
    defer alloc.free(reassembled);
    try std.testing.expectEqualSlices(u8, original, reassembled);
}

test "roundtrip: every operand kind hits at least one path" {
    // Mix of immediate / addr / reg-reg / indirect / indexed / int /
    // jump / shift / hlt. The disasm has to emit each operand form
    // and the asm has to parse it back.
    const src =
        \\main:
        \\  mov $1234, r1
        \\  mov r2, r1
        \\  mov &2620, r1
        \\  mov r1, &2620
        \\  mov [r1], r2
        \\  mov [&2620 + r1], r2
        \\  shl r1, $03
        \\  int $10
        \\  jmp main
        \\  hlt
        \\
    ;
    const original = try assembleImage(src);
    defer alloc.free(original);
    const reassembled = try gero.disasm.roundTripImage(alloc, original);
    defer alloc.free(reassembled);
    try std.testing.expectEqualSlices(u8, original, reassembled);
}

test "roundtrip: call + ret + arithmetic" {
    const src =
        \\main:
        \\  mov $05, r1
        \\  call double
        \\  hlt
        \\double:
        \\  add $01, r1
        \\  ret
        \\
    ;
    const original = try assembleImage(src);
    defer alloc.free(original);
    const reassembled = try gero.disasm.roundTripImage(alloc, original);
    defer alloc.free(reassembled);
    try std.testing.expectEqualSlices(u8, original, reassembled);
}

test "roundtrip: push / pop / cmp / jne" {
    const src =
        \\main:
        \\  mov $00, r1
        \\loop:
        \\  push r1
        \\  inc r1
        \\  cmp r1, $05
        \\  jne loop
        \\  pop r2
        \\  hlt
        \\
    ;
    const original = try assembleImage(src);
    defer alloc.free(original);
    const reassembled = try gero.disasm.roundTripImage(alloc, original);
    defer alloc.free(reassembled);
    try std.testing.expectEqualSlices(u8, original, reassembled);
}

/// Assemble `src` with debug symbols on and return the full `.gx`
/// archive. Caller owns the slice.
fn assembleArchive(src: []const u8) ![]u8 {
    var pt = try gero.asm_.parse(alloc, src);
    defer pt.deinit();
    var cg = try gero.asm_.assemble(alloc, src, pt, .{ .debug_symbols = true });
    defer cg.deinit();
    if (cg.hasErrors()) return error.AssemblyFailed;
    return alloc.dupe(u8, cg.image);
}

/// Drive `src` through assemble → `roundTripArchive` → parse and
/// assert that the base image + bank tail are byte-identical
/// before and after. The debug section is intentionally skipped:
/// symbol order in the encoded blob can vary even when code +
/// data bytes match.
fn expectArchiveRoundTrip(src: []const u8) !void {
    const orig = try assembleArchive(src);
    defer alloc.free(orig);
    const reasm = try gero.disasm.roundTripArchive(alloc, orig);
    defer alloc.free(reasm);

    const h_orig = try gero.disasm.parseHeader(orig);
    const h_reasm = try gero.disasm.parseHeader(reasm);
    try std.testing.expectEqualSlices(u8, h_orig.image, h_reasm.image);
    try std.testing.expectEqualSlices(u8, h_orig.banks, h_reasm.banks);
}

// The #41 round-trip CI gate: each shipped example program must
// survive a full asm → disasm → asm trip with the same code +
// data bytes coming out. Anything that breaks one of these
// breaks the disasm's losslessness contract.

test "roundtrip(example): hello.gas survives data-section round-trip" {
    try expectArchiveRoundTrip(examples.hello_gas);
}

test "roundtrip(example): fib.gas survives recursive-code round-trip" {
    try expectArchiveRoundTrip(examples.fib_gas);
}

test "roundtrip(example): counter.gas survives flag-driven-loop round-trip" {
    try expectArchiveRoundTrip(examples.counter_gas);
}
