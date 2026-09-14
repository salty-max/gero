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

/// Every stdlib module, in the order a name is searched.
pub const module_names = stdlib.module_names ++ [_][]const u8{ "mem", "str" };

/// Every name `module` provides, for completion after `module.`.
/// Empty for a name that is not a stdlib module.
pub fn memberNames(module: []const u8) []const []const u8 {
    if (std.mem.eql(u8, module, "mem")) return &mem_builtin.member_names;
    if (std.mem.eql(u8, module, "str")) return &str_builtin.module_functions;
    return stdlib.memberNames(module);
}

/// `true` when `name` is a stdlib module a `use` can name.
pub fn isModule(name: []const u8) bool {
    return memberNames(name).len > 0;
}

/// The import that would bring `name` into scope, or `null` when no
/// stdlib module exports it.
///
/// No two modules export the same name, so the answer is unambiguous
/// and a caller never has to choose.
pub fn importFor(name: []const u8) ?diag_mod.Fix.Import {
    for (module_names) |module| {
        for (memberNames(module)) |member| {
            if (std.mem.eql(u8, member, name)) return .{ .module = module, .name = name };
        }
    }
    return null;
}
