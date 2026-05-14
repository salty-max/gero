const std = @import("std");
const gero = @import("gero");

const alloc = std.testing.allocator;

/// Run `parse → print` once. Caller owns the returned buffer +
/// must `deinit` the parse tree. The buffer is large enough for
/// every example in `examples/asm/`.
const Printed = struct {
    pt: gero.asm_.ParseTree,
    text: []u8,

    fn deinit(self: *Printed) void {
        self.pt.deinit();
        alloc.free(self.text);
    }
};

fn parseAndPrint(source: []const u8) !Printed {
    var pt = try gero.asm_.parse(alloc, source);
    errdefer pt.deinit();

    var allocating = std.Io.Writer.Allocating.init(alloc);
    errdefer allocating.deinit();
    try gero.asm_.printProgram(&allocating.writer, &pt.program, source, gero.asm_.default_print_options);

    const text = try allocating.toOwnedSlice();
    return .{ .pt = pt, .text = text };
}

test "printProgram: empty program → empty output" {
    var p = try parseAndPrint("");
    defer p.deinit();
    try std.testing.expectEqualStrings("", p.text);
}

test "printProgram: single label" {
    var p = try parseAndPrint("main:\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("main:\n", p.text);
}

test "printProgram: const decl with hex literal" {
    var p = try parseAndPrint("const PRINT = $10\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("const PRINT = $10\n", p.text);
}

test "printProgram: consecutive consts stay clustered (no blank line)" {
    var p = try parseAndPrint("const A = $01\nconst B = $02\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("const A = $01\nconst B = $02\n", p.text);
}

test "printProgram: blank line between kind transitions" {
    var p = try parseAndPrint("const A = $01\nmain:\n  hlt\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("const A = $01\n\nmain:\n  hlt\n", p.text);
}

test "printProgram: instructions indent under label" {
    var p = try parseAndPrint("main:\n  mov $00, r1\n  hlt\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("main:\n  mov $00, r1\n  hlt\n", p.text);
}

test "printProgram: zero-operand instruction has no trailing space" {
    var p = try parseAndPrint("main:\nhlt\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("main:\n  hlt\n", p.text);
}

test "printProgram: data8 with mixed value forms" {
    var p = try parseAndPrint("data8 GREETING = \"Hi\", $00\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("data8 GREETING = \"Hi\", $00\n", p.text);
}

test "printProgram: data16 with single value" {
    var p = try parseAndPrint("data16 IVT = $FFFF\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("data16 IVT = $FFFF\n", p.text);
}

test "printProgram: org directive" {
    var p = try parseAndPrint("org $1000\nmain:\n  hlt\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("org $1000\n\nmain:\n  hlt\n", p.text);
}

test "printProgram: bank directive" {
    var p = try parseAndPrint("bank $01\nmain:\n  hlt\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("bank $01\n\nmain:\n  hlt\n", p.text);
}

test "printProgram: sram_banks directive" {
    var p = try parseAndPrint("sram_banks $02\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("sram_banks $02\n", p.text);
}

test "printProgram: struct multi-line" {
    var p = try parseAndPrint("struct Player { hp: u8, x: u16 }\n");
    defer p.deinit();
    try std.testing.expectEqualStrings(
        \\struct Player {
        \\  hp: u8,
        \\  x: u16,
        \\}
        \\
    , p.text);
}

test "printProgram: indirect operand uses [reg] form" {
    var p = try parseAndPrint("main:\n  mov [r1], r2\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("main:\n  mov [r1], r2\n", p.text);
}

test "printProgram: address-literal operand" {
    var p = try parseAndPrint("main:\n  call &C000\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("main:\n  call &C000\n", p.text);
}

test "printProgram: label-ref operand (forward reference)" {
    var p = try parseAndPrint("main:\n  jmp loop\nloop:\n  hlt\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("main:\n  jmp loop\n\nloop:\n  hlt\n", p.text);
}

test "printProgram: sym-ref operand" {
    var p = try parseAndPrint("data8 GREETING = \"Hi\"\nmain:\n  mov @GREETING, r1\n");
    defer p.deinit();
    try std.testing.expectEqualStrings(
        \\data8 GREETING = "Hi"
        \\
        \\main:
        \\  mov @GREETING, r1
        \\
    , p.text);
}

test "printProgram: standalone comment line preserved verbatim" {
    var p = try parseAndPrint("; hello world\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("; hello world\n", p.text);
}

test "printProgram: comment block before a label stays tight (no blank inserted)" {
    var p = try parseAndPrint("; section header\n; line two\nmain:\n  hlt\n");
    defer p.deinit();
    try std.testing.expectEqualStrings(
        \\; section header
        \\; line two
        \\main:
        \\  hlt
        \\
    , p.text);
}

test "printProgram: blank line preserved before a standalone comment block" {
    var p = try parseAndPrint("main:\n  hlt\n\n; trailing block\nfib:\n  ret\n");
    defer p.deinit();
    try std.testing.expectEqualStrings(
        \\main:
        \\  hlt
        \\
        \\; trailing block
        \\fib:
        \\  ret
        \\
    , p.text);
}

test "printProgram: trailing comment demotes to standalone (same line attachment preserved)" {
    // Trailing comment was inline with `hlt`; printer recognizes
    // the source-same-line proximity and skips the blank line,
    // so the comment stays tight to the instruction on the next
    // line.
    var p = try parseAndPrint("main:\n  hlt ; halt\n");
    defer p.deinit();
    try std.testing.expectEqualStrings("main:\n  hlt\n; halt\n", p.text);
}

test "printProgram: idempotence — second pass matches first" {
    const src = "const PRINT = $10\n\nmain:\n  mov $00, r1\n  int PRINT\n  hlt\n";
    var p1 = try parseAndPrint(src);
    defer p1.deinit();
    var p2 = try parseAndPrint(p1.text);
    defer p2.deinit();
    try std.testing.expectEqualStrings(p1.text, p2.text);
}

test "printProgram: idempotence on every examples/asm/* program" {
    const examples = [_][]const u8{
        @import("examples").hello_gas,
        @import("examples").fib_gas,
        @import("examples").counter_gas,
    };
    for (examples) |src| {
        var p1 = try parseAndPrint(src);
        defer p1.deinit();
        try std.testing.expect(!p1.pt.hasErrors());

        var p2 = try parseAndPrint(p1.text);
        defer p2.deinit();
        try std.testing.expect(!p2.pt.hasErrors());

        try std.testing.expectEqualStrings(p1.text, p2.text);
    }
}

test "printProgram: semantic preservation — asm(print(parse(src))) == asm(src)" {
    const examples = [_][]const u8{
        @import("examples").hello_gas,
        @import("examples").fib_gas,
        @import("examples").counter_gas,
    };
    for (examples) |src| {
        var p = try parseAndPrint(src);
        defer p.deinit();

        const opts: gero.asm_.CodegenOptions = .{ .debug_symbols = false };
        var cg1 = try gero.asm_.assemble(alloc, src, p.pt, opts);
        defer cg1.deinit();

        var pt2 = try gero.asm_.parse(alloc, p.text);
        defer pt2.deinit();
        var cg2 = try gero.asm_.assemble(alloc, p.text, pt2, opts);
        defer cg2.deinit();

        try std.testing.expectEqualSlices(u8, cg1.image, cg2.image);
    }
}

test "printProgram: handles include resolution markers cleanly" {
    // The parser eats `\f` form-feed markers used by the include
    // resolver — the printer just doesn't emit them.
    var p = try parseAndPrint("main:\n  hlt\n");
    defer p.deinit();
    try std.testing.expect(std.mem.indexOfScalar(u8, p.text, '\x0c') == null);
}

// ---------- ignore directives ----------

test "printProgram: file-level ignore disables all canonicalization" {
    const src =
        \\; gero-fmt-ignore-file
        \\const PRINT   = $10
        \\const NEWLINE = $0A
        \\main:
        \\  mov  $00, r1
        \\
    ;
    var p = try parseAndPrint(src);
    defer p.deinit();
    // No reformatting — output is byte-identical to input.
    try std.testing.expectEqualStrings(src, p.text);
}

test "printProgram: file-level ignore tolerates a leading non-directive comment" {
    const src =
        \\; copyright 2026
        \\; gero-fmt-ignore-file
        \\const PRINT   = $10
        \\
    ;
    var p = try parseAndPrint(src);
    defer p.deinit();
    try std.testing.expectEqualStrings(src, p.text);
}

test "printProgram: block ignore preserves contents verbatim" {
    const src =
        \\; gero-fmt-ignore-start
        \\const PRINT   = $10
        \\const NEWLINE = $0A
        \\; gero-fmt-ignore-end
        \\const TAIL = $FF
        \\
    ;
    var p = try parseAndPrint(src);
    defer p.deinit();
    // The block contents keep their hand-alignment; TAIL after the
    // block goes through canonicalization (single-space `= `).
    try std.testing.expectEqualStrings(
        \\; gero-fmt-ignore-start
        \\const PRINT   = $10
        \\const NEWLINE = $0A
        \\; gero-fmt-ignore-end
        \\const TAIL = $FF
        \\
    , p.text);
}

test "printProgram: ignore-next protects only the immediately-following statement" {
    const src =
        \\; gero-fmt-ignore-next
        \\const PRINT   = $10
        \\const NEWLINE = $0A
        \\
    ;
    var p = try parseAndPrint(src);
    defer p.deinit();
    // PRINT keeps its alignment; NEWLINE canonicalizes.
    try std.testing.expectEqualStrings(
        \\; gero-fmt-ignore-next
        \\const PRINT   = $10
        \\const NEWLINE = $0A
        \\
    , p.text);
}

test "printProgram: trailing ignore protects its host statement" {
    const src =
        \\const PRINT   = $10  ; gero-fmt-ignore
        \\const NEWLINE = $0A
        \\
    ;
    var p = try parseAndPrint(src);
    defer p.deinit();
    // PRINT line stays as-written (alignment + trailing comment
    // both preserved). NEWLINE canonicalizes (single space).
    try std.testing.expectEqualStrings(
        \\const PRINT   = $10  ; gero-fmt-ignore
        \\const NEWLINE = $0A
        \\
    , p.text);
}

test "printProgram: ignore-next idempotent across re-formats" {
    const src =
        \\; gero-fmt-ignore-next
        \\const PRINT   = $10
        \\const X = $20
        \\
    ;
    var p1 = try parseAndPrint(src);
    defer p1.deinit();
    var p2 = try parseAndPrint(p1.text);
    defer p2.deinit();
    try std.testing.expectEqualStrings(p1.text, p2.text);
}

test "printProgram: block ignore idempotent across re-formats" {
    const src =
        \\; gero-fmt-ignore-start
        \\const A   = $01
        \\const BBB = $02
        \\; gero-fmt-ignore-end
        \\
    ;
    var p1 = try parseAndPrint(src);
    defer p1.deinit();
    var p2 = try parseAndPrint(p1.text);
    defer p2.deinit();
    try std.testing.expectEqualStrings(p1.text, p2.text);
}
