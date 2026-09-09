/// Package version (from `build.zig.zon`).
pub const VERSION: []const u8 = @import("build_options").version;

/// Why a `.gx` failed to load, in words a user can act on. Shared so
/// the same broken file explains itself the same way everywhere.
pub const load_error = @import("load_error.zig");

/// The JSON shape every diagnostic producer emits (lang-diagnostics.md
/// §9). Shared so a terminal, an editor, and the playground cannot
/// disagree about an error.
pub const diagnostics_json = @import("diagnostics_json.zig");

/// The `.gx` container format: header, layout, debug section. Shared
/// by both front-ends so one ISA yields one header, and the single
/// place a bytecode-format freeze has to lock.
pub const gx = @import("gx.zig");

/// Virtual machine: register file, memory, dispatch.
pub const vm = @import("vm/vm.zig");

/// How a set of source files is addressed. An embedder supplying a
/// virtual overlay builds its keys the way both front-ends resolve
/// them: POSIX-shaped, on every host.
pub const include_paths = @import("include_paths.zig");

/// Assembler: `.gas` source → `.gx` bytecode.
pub const asm_ = @import("asm.zig");

/// Disassembler: `.gx` bytecode → `.gas` source.
pub const disasm = @import("disasm.zig");

/// Gero-lang: `.gr` source → `.gx` bytecode.
pub const lang = @import("lang.zig");
