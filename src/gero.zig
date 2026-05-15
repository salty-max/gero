/// Gero — 16-bit virtual machine + assembler + Lua-style language
/// ecosystem in Zig. Public barrel.
/// Package version — sourced from `build.zig.zon` via `build_options`
/// so library consumers don't need a second site to bump.
pub const VERSION: []const u8 = @import("build_options").version;

/// VM kernel — register file, memory, and the composing `VM` type.
pub const vm = @import("vm/vm.zig");

/// Assembler — text `.gas` source → `.gx` bytecode. Re-exports
/// `parse` / `assemble`, the `ParseTree` / `Codegen` types, and
/// `ErrorCode` (asm spec §7).
pub const asm_ = @import("asm.zig");

/// Disassembler — `.gx` bytecode → `.gas` source. Inverse of
/// `asm_`; consumes the same `.gx` shape the VM loads.
pub const disasm = @import("disasm.zig");

/// Gero-lang — text `.gr` source → `.gx` bytecode. Re-exports
/// the lexer's `Token` / `TokenStream` / `tokenize` today;
/// parser + codegen land in subsequent issues per the
/// `feat(lang)` series.
pub const lang = @import("lang.zig");
