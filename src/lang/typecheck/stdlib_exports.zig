// Which stdlib module exports a given name. Backs the import a
// diagnostic suggests when an unresolved name is one the stdlib has
// but the file never imported.
//
// The names come from the same tables that type-check the calls, so a
// module gaining a function offers it here without a second list to
// keep in step.

const std = @import("std");
const diag_mod = @import("../diagnostic.zig");
const stdlib = @import("stdlib.zig");
const mem_builtin = @import("mem_builtin.zig");
const str_builtin = @import("str_builtin.zig");

/// The import that would bring `name` into scope, or `null` when no
/// stdlib module exports it.
///
/// No two modules export the same name, so the answer is unambiguous
/// and a caller never has to choose.
pub fn importFor(name: []const u8) ?diag_mod.Fix.Import {
    for (stdlib.module_names) |module| {
        if (stdlib.isMember(module, name)) return .{ .module = module, .name = name };
    }
    if (mem_builtin.lookupMemBuiltin(name) != null) return .{ .module = "mem", .name = name };
    if (str_builtin.isModuleFunction(name)) return .{ .module = "str", .name = name };
    return null;
}
