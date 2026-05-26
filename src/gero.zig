/// Package version (from `build.zig.zon`).
pub const VERSION: []const u8 = @import("build_options").version;

/// Virtual machine: register file, memory, dispatch.
pub const vm = @import("vm/vm.zig");

/// Assembler: `.gas` source → `.gx` bytecode.
pub const asm_ = @import("asm.zig");

/// Disassembler: `.gx` bytecode → `.gas` source.
pub const disasm = @import("disasm.zig");

/// Gero-lang: `.gr` source → `.gx` bytecode.
pub const lang = @import("lang.zig");
