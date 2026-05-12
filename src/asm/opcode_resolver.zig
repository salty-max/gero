/// Resolves a parsed `ast.Instruction` to an ISA opcode + total
/// encoded size. The matching is done by classifying each
/// operand into a `Kind` (operand-encoding category) and looking
/// up `(mnemonic, kinds...)` in a hand-written shape table.
///
/// ZP-form auto-selection is intentionally NOT implemented yet
/// (PR #36 first cut — keep it simple). All address operands
/// emit as 2-byte `addr`, never as 1-byte `zp`. A future
/// peephole pass can downgrade `Addr` to `ZP` when the value
/// fits in 0..0xFF.
const std = @import("std");
const ast = @import("ast.zig");
const symtab = @import("symtab.zig");

/// Operand-encoding category. Maps to one row in the ISA's
/// opcode-schema. Each Kind has a known byte width.
pub const Kind = enum {
    /// 1-byte register index (`Reg` operand).
    reg,
    /// 1-byte immediate (`Imm8`).
    imm8,
    /// 2-byte little-endian immediate (`Imm16`).
    imm16,
    /// 2-byte little-endian address (`Addr`).
    addr,
    /// 1-byte zero-page address (`ZP`).
    zp,
    /// `[reg]` — indirect via register. Encodes as 1 reg byte.
    reg_indirect,
    /// `[addr + reg]` — indexed. Encodes as 2 addr bytes + 1 reg byte.
    indexed,

    /// Byte width when encoded.
    pub fn width(self: Kind) u8 {
        return switch (self) {
            .reg, .imm8, .zp, .reg_indirect => 1,
            .imm16, .addr => 2,
            .indexed => 3,
        };
    }
};

/// One row of the dispatch table — what opcode matches a given
/// mnemonic + operand-kinds tuple.
const Shape = struct {
    mnemonic: []const u8,
    kinds: []const Kind,
    opcode: u8,
};

/// Maximum operand count per instruction in v0.1 (`mov` indexed
/// has 2 source-level operands; bcpy/bset have 3 register operands).
const max_operands: usize = 3;

/// The dispatch table. Order matters: more-specific shapes go
/// first when shapes share a prefix (none in v0.1, but the rule
/// is good hygiene). Mnemonics use lowercase, matching the lexer.
const shapes: []const Shape = &.{
    // mov family
    .{ .mnemonic = "mov", .kinds = &.{ .imm16, .reg }, .opcode = 0x10 },
    .{ .mnemonic = "mov", .kinds = &.{ .reg, .reg }, .opcode = 0x11 },
    .{ .mnemonic = "mov", .kinds = &.{ .reg, .addr }, .opcode = 0x12 },
    .{ .mnemonic = "mov", .kinds = &.{ .addr, .reg }, .opcode = 0x13 },
    .{ .mnemonic = "mov", .kinds = &.{ .imm16, .addr }, .opcode = 0x14 },
    .{ .mnemonic = "mov", .kinds = &.{ .reg, .reg_indirect }, .opcode = 0x15 },
    .{ .mnemonic = "mov", .kinds = &.{ .reg_indirect, .reg }, .opcode = 0x16 },
    .{ .mnemonic = "mov", .kinds = &.{ .indexed, .reg }, .opcode = 0x17 },
    .{ .mnemonic = "mov", .kinds = &.{ .imm16, .reg_indirect }, .opcode = 0x18 },

    // mov8 / movh / movl
    .{ .mnemonic = "mov8", .kinds = &.{ .imm8, .addr }, .opcode = 0x20 },
    .{ .mnemonic = "mov8", .kinds = &.{ .imm8, .reg }, .opcode = 0x21 },
    .{ .mnemonic = "mov8", .kinds = &.{ .addr, .reg }, .opcode = 0x22 },
    .{ .mnemonic = "mov8", .kinds = &.{ .reg, .reg_indirect }, .opcode = 0x23 },
    .{ .mnemonic = "mov8", .kinds = &.{ .reg_indirect, .reg }, .opcode = 0x24 },
    .{ .mnemonic = "mov8", .kinds = &.{ .indexed, .reg }, .opcode = 0x29 },
    .{ .mnemonic = "movh", .kinds = &.{ .reg, .addr }, .opcode = 0x25 },
    .{ .mnemonic = "movl", .kinds = &.{ .reg, .addr }, .opcode = 0x26 },

    // block memory ops
    .{ .mnemonic = "bcpy", .kinds = &.{ .reg, .reg, .reg }, .opcode = 0x27 },
    .{ .mnemonic = "bset", .kinds = &.{ .reg, .reg, .reg }, .opcode = 0x28 },

    // stack
    .{ .mnemonic = "push", .kinds = &.{.imm16}, .opcode = 0x30 },
    .{ .mnemonic = "push", .kinds = &.{.reg}, .opcode = 0x31 },
    .{ .mnemonic = "pop", .kinds = &.{.reg}, .opcode = 0x32 },

    // arithmetic
    .{ .mnemonic = "add", .kinds = &.{ .imm16, .reg }, .opcode = 0x40 },
    .{ .mnemonic = "add", .kinds = &.{ .reg, .reg }, .opcode = 0x41 },
    .{ .mnemonic = "add", .kinds = &.{.reg}, .opcode = 0x42 },
    .{ .mnemonic = "sub", .kinds = &.{ .imm16, .reg }, .opcode = 0x43 },
    .{ .mnemonic = "sub", .kinds = &.{ .reg, .reg }, .opcode = 0x44 },
    .{ .mnemonic = "sub", .kinds = &.{.reg}, .opcode = 0x45 },
    .{ .mnemonic = "mul", .kinds = &.{ .imm16, .reg }, .opcode = 0x46 },
    .{ .mnemonic = "mul", .kinds = &.{ .reg, .reg }, .opcode = 0x47 },
    .{ .mnemonic = "inc", .kinds = &.{.reg}, .opcode = 0x48 },
    .{ .mnemonic = "dec", .kinds = &.{.reg}, .opcode = 0x49 },
    .{ .mnemonic = "neg", .kinds = &.{.reg}, .opcode = 0x4A },
    .{ .mnemonic = "div", .kinds = &.{ .imm16, .reg }, .opcode = 0x4B },
    .{ .mnemonic = "div", .kinds = &.{ .reg, .reg }, .opcode = 0x4C },
    .{ .mnemonic = "divs", .kinds = &.{ .imm16, .reg }, .opcode = 0x4D },
    .{ .mnemonic = "divs", .kinds = &.{ .reg, .reg }, .opcode = 0x4E },
    .{ .mnemonic = "adc", .kinds = &.{ .imm16, .reg }, .opcode = 0x64 },
    .{ .mnemonic = "adc", .kinds = &.{ .reg, .reg }, .opcode = 0x65 },
    .{ .mnemonic = "sbc", .kinds = &.{ .imm16, .reg }, .opcode = 0x66 },
    .{ .mnemonic = "sbc", .kinds = &.{ .reg, .reg }, .opcode = 0x67 },

    // logical
    .{ .mnemonic = "and", .kinds = &.{ .reg, .imm16 }, .opcode = 0x50 },
    .{ .mnemonic = "and", .kinds = &.{ .reg, .reg }, .opcode = 0x51 },
    .{ .mnemonic = "or", .kinds = &.{ .reg, .imm16 }, .opcode = 0x52 },
    .{ .mnemonic = "or", .kinds = &.{ .reg, .reg }, .opcode = 0x53 },
    .{ .mnemonic = "xor", .kinds = &.{ .reg, .imm16 }, .opcode = 0x54 },
    .{ .mnemonic = "xor", .kinds = &.{ .reg, .reg }, .opcode = 0x55 },
    .{ .mnemonic = "not", .kinds = &.{.reg}, .opcode = 0x56 },

    // shifts + rotates
    .{ .mnemonic = "shl", .kinds = &.{ .reg, .imm8 }, .opcode = 0x58 },
    .{ .mnemonic = "shl", .kinds = &.{ .reg, .reg }, .opcode = 0x59 },
    .{ .mnemonic = "shr", .kinds = &.{ .reg, .imm8 }, .opcode = 0x5A },
    .{ .mnemonic = "shr", .kinds = &.{ .reg, .reg }, .opcode = 0x5B },
    .{ .mnemonic = "rol", .kinds = &.{ .reg, .imm8 }, .opcode = 0x5C },
    .{ .mnemonic = "rol", .kinds = &.{ .reg, .reg }, .opcode = 0x5D },
    .{ .mnemonic = "ror", .kinds = &.{ .reg, .imm8 }, .opcode = 0x5E },
    .{ .mnemonic = "ror", .kinds = &.{ .reg, .reg }, .opcode = 0x5F },

    // compare / test
    .{ .mnemonic = "cmp", .kinds = &.{ .reg, .imm16 }, .opcode = 0x60 },
    .{ .mnemonic = "cmp", .kinds = &.{ .reg, .reg }, .opcode = 0x61 },
    .{ .mnemonic = "tst", .kinds = &.{ .reg, .imm16 }, .opcode = 0x62 },
    .{ .mnemonic = "tst", .kinds = &.{ .reg, .reg }, .opcode = 0x63 },

    // control flow
    .{ .mnemonic = "jmp", .kinds = &.{.addr}, .opcode = 0x70 },
    .{ .mnemonic = "jmp", .kinds = &.{.reg}, .opcode = 0x71 },
    .{ .mnemonic = "jeq", .kinds = &.{.addr}, .opcode = 0x72 },
    .{ .mnemonic = "jne", .kinds = &.{.addr}, .opcode = 0x73 },
    .{ .mnemonic = "jlt", .kinds = &.{.addr}, .opcode = 0x74 },
    .{ .mnemonic = "jle", .kinds = &.{.addr}, .opcode = 0x75 },
    .{ .mnemonic = "jgt", .kinds = &.{.addr}, .opcode = 0x76 },
    .{ .mnemonic = "jge", .kinds = &.{.addr}, .opcode = 0x77 },
    .{ .mnemonic = "jcc", .kinds = &.{.addr}, .opcode = 0x78 },
    .{ .mnemonic = "jcs", .kinds = &.{.addr}, .opcode = 0x79 },
    .{ .mnemonic = "jvc", .kinds = &.{.addr}, .opcode = 0x7A },
    .{ .mnemonic = "jvs", .kinds = &.{.addr}, .opcode = 0x7B },
    .{ .mnemonic = "jz", .kinds = &.{.addr}, .opcode = 0x7C },
    .{ .mnemonic = "jnz", .kinds = &.{.addr}, .opcode = 0x7D },
    .{ .mnemonic = "djnz", .kinds = &.{ .reg, .addr }, .opcode = 0x7E },
    .{ .mnemonic = "jr", .kinds = &.{.imm8}, .opcode = 0x7F },

    // subroutines
    .{ .mnemonic = "call", .kinds = &.{.addr}, .opcode = 0x80 },
    .{ .mnemonic = "call", .kinds = &.{.reg}, .opcode = 0x81 },
    .{ .mnemonic = "ret", .kinds = &.{}, .opcode = 0x82 },

    // misc
    .{ .mnemonic = "swap", .kinds = &.{ .reg, .reg }, .opcode = 0x90 },
    .{ .mnemonic = "nop", .kinds = &.{}, .opcode = 0x91 },

    // flag manipulation
    .{ .mnemonic = "clc", .kinds = &.{}, .opcode = 0xA0 },
    .{ .mnemonic = "sec", .kinds = &.{}, .opcode = 0xA1 },
    .{ .mnemonic = "cli", .kinds = &.{}, .opcode = 0xA2 },
    .{ .mnemonic = "sei", .kinds = &.{}, .opcode = 0xA3 },
    .{ .mnemonic = "clv", .kinds = &.{}, .opcode = 0xA4 },

    // system
    .{ .mnemonic = "int", .kinds = &.{.imm8}, .opcode = 0xFC },
    .{ .mnemonic = "rti", .kinds = &.{}, .opcode = 0xFD },
    .{ .mnemonic = "brk", .kinds = &.{}, .opcode = 0xFE },
    .{ .mnemonic = "hlt", .kinds = &.{}, .opcode = 0xFF },
};

/// Classify a parsed operand to its encoding `Kind`. Most
/// operands map one-to-one; the exception is `.label_ref`
/// (bare identifier) which can be either a `const` (encodes as
/// `imm16`) or a label / data symbol (encodes as `addr`). The
/// symbol table tells us which — pass `null` when the table
/// isn't available yet (sizing pass with no label resolution)
/// and `label_ref` falls back to `.addr` (size-equivalent to
/// `.imm16`, so layout is correct either way).
pub fn classify(op: ast.Operand, symbols: ?*const symtab.SymbolTable) Kind {
    return switch (op) {
        .register => .reg,
        .immediate => .imm16,
        .addr_lit, .sym_ref, .addr_expr, .cast => .addr,
        .indirect => .reg_indirect,
        .indexed => .indexed,
        .label_ref => |l| classifyLabelRef(l, symbols),
    };
}

fn classifyLabelRef(l: ast.LabelRef, symbols: ?*const symtab.SymbolTable) Kind {
    if (symbols) |s| {
        // The lexeme is stored by span; we don't have source bytes
        // here. Caller uses the `*SymbolTable` directly via name.
        // We can't extract the name without source — fall through
        // to the default. (The `classifyByName` variant below
        // takes the resolved lexeme.)
        _ = s;
    }
    _ = l;
    return .addr;
}

/// Resolve a `label_ref` operand's `Kind` given its lexeme and
/// the populated `SymbolTable`. A `const` resolves to `imm8` when
/// its value fits in `u8`, otherwise `imm16`; a label or data
/// symbol resolves to `addr`; an unknown name (forward reference
/// or genuine miss) defaults to `addr`. The same narrowing rule
/// that `codegen.narrowImm` applies to literal `.immediate`
/// operands also applies here so symbolic ergonomics (`int PRINT`
/// where `PRINT = $10`) work with imm8-only opcodes.
pub fn labelRefKind(name: []const u8, symbols: symtab.SymbolTable) Kind {
    if (symbols.get(name)) |sym| {
        return switch (sym.kind) {
            .const_value, .struct_field => if (sym.value <= 0xFF) .imm8 else .imm16,
            .label, .data => .addr,
        };
    }
    return .addr;
}

/// Result of `resolve` — the opcode byte, total encoded size
/// (1 byte for the opcode + sum of operand widths), and the
/// matched shape's kinds so emit can write each operand at the
/// canonical width even when widening kicked in.
pub const Resolution = struct {
    opcode: u8,
    size: u8,
    /// The matched shape's kinds. May differ from the caller's
    /// kinds when an `.imm8` user-kind widened to `.imm16` to
    /// match a shape that only has the wider form.
    kinds: []const Kind,
};

/// Resolve an instruction's mnemonic + operand kinds to an
/// opcode. Tries exact match first; if none, retries with each
/// user-side `.imm8` widened to `.imm16` (safe — every `Imm8`
/// value fits in `Imm16`). Narrowing in the other direction is
/// never attempted — a caller-supplied `.imm16` only matches a
/// shape's `.imm16`. Returns `null` if no matching shape exists —
/// the caller surfaces `E001` (unknown mnemonic) or `E003`
/// (operand type mismatch) as appropriate.
pub fn resolve(mnemonic: []const u8, kinds: []const Kind) ?Resolution {
    // Pass 1: exact match.
    for (shapes) |s| {
        if (!std.mem.eql(u8, s.mnemonic, mnemonic)) continue;
        if (s.kinds.len != kinds.len) continue;
        var match = true;
        for (s.kinds, kinds) |a, b| {
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return resolutionFor(s);
    }
    // Pass 2: allow `.imm8` → `.imm16` widening at each position.
    for (shapes) |s| {
        if (!std.mem.eql(u8, s.mnemonic, mnemonic)) continue;
        if (s.kinds.len != kinds.len) continue;
        var match = true;
        for (s.kinds, kinds) |a, b| {
            if (a == b) continue;
            if (a == .imm16 and b == .imm8) continue;
            match = false;
            break;
        }
        if (match) return resolutionFor(s);
    }
    return null;
}

fn resolutionFor(s: Shape) Resolution {
    var size: u8 = 1;
    for (s.kinds) |k| size += k.width();
    return .{ .opcode = s.opcode, .size = size, .kinds = s.kinds };
}

/// Check whether `mnemonic` is in the table at all (regardless
/// of operand-kind match). Used to distinguish E001 from E003.
pub fn isKnownMnemonic(mnemonic: []const u8) bool {
    for (shapes) |s| {
        if (std.mem.eql(u8, s.mnemonic, mnemonic)) return true;
    }
    return false;
}
