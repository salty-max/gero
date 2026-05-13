/// Disassembler — bytecode (`.gx`) → asm source (`.gas`). The
/// inverse of `asm_`. Reads bytes (no `knit` dependency), emits
/// text that the assembler can re-consume.
///
/// Module shape:
///   header.zig — strict `.gx` header parse + section slicing
///   decoder.zig — byte → `Instruction` AST (re-uses the VM's
///                 opcode schema table for the reverse mapping)
///   printer.zig — `Instruction` AST → asm syntax with aligned
///                 columns, hex literals, labels
const header_mod = @import("disasm/header.zig");
const decoder_mod = @import("disasm/decoder.zig");
const printer_mod = @import("disasm/printer.zig");
const roundtrip_mod = @import("disasm/roundtrip.zig");

/// Re-export: decoded `.gx` header + borrowed section slices.
pub const Header = header_mod.Header;
/// Re-export: failure modes when reading a `.gx`.
pub const DecodeError = header_mod.DecodeError;
/// Re-export: parse a `.gx` byte buffer.
pub const parseHeader = header_mod.parse;

/// Re-export: one decoded instruction (opcode + operands + size).
pub const Instruction = decoder_mod.Instruction;
/// Re-export: one decoded operand (reg / imm8 / imm16 / addr / etc.).
pub const Operand = decoder_mod.Operand;
/// Re-export: decode one instruction at `bytes[offset]`.
pub const decodeOne = decoder_mod.decodeOne;
/// Re-export: free the operand slice attached to an `Instruction`.
pub const freeInstruction = decoder_mod.freeInstruction;

/// Re-export: render one decoded instruction as asm syntax.
pub const writeInstruction = printer_mod.writeInstruction;
/// Re-export: walk a byte buffer and emit one asm line per
/// instruction. Unknown opcodes surface as `.byte` comments.
pub const writeBytes = printer_mod.writeBytes;

/// Re-export: drive the full asm → disasm → asm pipeline for
/// byte-equality round-trip tests. See `disasm/roundtrip.zig`
/// for the caveats around data sections.
pub const roundTripImage = roundtrip_mod.roundTripImage;
