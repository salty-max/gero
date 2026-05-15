/// Gero — 16-bit virtual machine + assembler + Lua-style language
/// ecosystem in Zig. Public barrel.
pub const VERSION = "0.0.0";

/// VM kernel — register file, memory, and the composing `VM` type.
pub const vm = @import("vm/vm.zig");

/// Assembler — text `.gas` source → `.gx` bytecode. Re-exports
/// `parse` / `assemble`, the `ParseTree` / `Codegen` types, and
/// `ErrorCode` (asm spec §7).
pub const asm_ = @import("asm.zig");

/// Disassembler — `.gx` bytecode → `.gas` source. Inverse of
/// `asm_`; consumes the same `.gx` shape the VM loads.
pub const disasm = @import("disasm.zig");
