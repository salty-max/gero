/// Package version (from `build.zig.zon`).
pub const VERSION: []const u8 = @import("build_options").version;

/// The `.gx` container format: header, layout, debug section. Shared
/// by both front-ends so one ISA yields one header, and the single
/// place a bytecode-format freeze has to lock.
pub const gx = @import("gx.zig");

/// Virtual machine: register file, memory, dispatch.
pub const vm = @import("vm/vm.zig");

/// Assembler: `.gas` source → `.gx` bytecode.
pub const asm_ = @import("asm.zig");

/// Disassembler: `.gx` bytecode → `.gas` source.
pub const disasm = @import("disasm.zig");

/// Gero-lang: `.gr` source → `.gx` bytecode.
pub const lang = @import("lang.zig");
