/// Gero — 16-bit virtual machine + assembler + Lua-style language
/// ecosystem in Zig. Public barrel.
pub const VERSION = "0.0.0";

/// VM kernel — register file, memory, and the composing `VM` type.
pub const vm = @import("vm/vm.zig");

/// Assembler — text `.gas` source → `.gx` bytecode. Scaffold;
/// real parser / codegen lands in follow-up PRs.
pub const asm_ = @import("asm.zig");

/// Disassembler — `.gx` bytecode → `.gas` source. Inverse of
/// `asm_`; consumes the same `.gx` shape the VM loads.
pub const disasm = @import("disasm.zig");
