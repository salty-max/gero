const header_mod = @import("disasm/header.zig");
const decoder_mod = @import("disasm/decoder.zig");
const printer_mod = @import("disasm/printer.zig");
const roundtrip_mod = @import("disasm/roundtrip.zig");

/// Decoded `.gx` header + borrowed section slices.
pub const Header = header_mod.Header;
/// Failure modes when reading a `.gx`.
pub const DecodeError = header_mod.DecodeError;
/// Parse a `.gx` byte buffer.
pub const parseHeader = header_mod.parse;
/// One debug-symbol entry (address + kind + name).
pub const Symbol = header_mod.Symbol;
/// Kind discriminator for a symbol (label / data).
pub const SymbolKind = header_mod.SymbolKind;
/// Parsed debug-symbol section (address → name lookup).
pub const Symbols = header_mod.Symbols;
/// Failure modes when parsing the debug-symbol section.
pub const SymbolsError = header_mod.SymbolsError;
/// Parse a debug-symbol blob (typically `Header.debug`) per ISA §7.3.
pub const parseSymbols = header_mod.parseSymbols;

/// One decoded instruction (opcode + operands + size).
pub const Instruction = decoder_mod.Instruction;
/// One decoded operand (reg / imm8 / imm16 / addr / …).
pub const Operand = decoder_mod.Operand;
/// Decode one instruction at `bytes[offset]`.
pub const decodeOne = decoder_mod.decodeOne;
/// Free the operand slice attached to an `Instruction`.
pub const freeInstruction = decoder_mod.freeInstruction;

/// Render one decoded instruction as asm syntax.
pub const writeInstruction = printer_mod.writeInstruction;
/// Walk a byte buffer and emit one asm line per instruction.
/// Unknown opcodes surface as `.byte` comments. Round-trip-friendly
/// for all-code programs.
pub const writeBytes = printer_mod.writeBytes;

/// Pretty view with address + hex-bytes columns. Human-facing only;
/// not round-trip-friendly.
pub const writeBytesPretty = printer_mod.writeBytesPretty;
/// Options for `writeBytesPretty`.
pub const PrintOptions = printer_mod.PrintOptions;
/// ANSI palette for the disasm pretty view.
pub const Style = printer_mod.Style;

/// Drive the full asm → disasm → asm pipeline for byte-equality
/// round-trip tests. See `disasm/roundtrip.zig` for caveats around
/// data sections.
pub const roundTripImage = roundtrip_mod.roundTripImage;

/// Round-trip a full `.gx` archive (header + base + banks + debug).
/// Reads the contained debug-symbol section so data blocks render
/// as `data8 NAME = …` rather than fake instructions.
pub const roundTripArchive = roundtrip_mod.roundTripArchive;
