/// Mirror file for `src/lang/typecheck/stdlib_exports.zig` — which
/// stdlib module exports a name, for the import a diagnostic suggests.
const std = @import("std");
const gero = @import("gero");

const exports = gero.lang.internal.typechecker.stdlib_exports;

test "importFor: a math function names its module" {
    const imp = exports.importFor("abs") orelse return error.NoImport;
    try std.testing.expectEqualStrings("math", imp.module);
    try std.testing.expectEqualStrings("abs", imp.name);
}

test "importFor: each module is reachable" {
    try std.testing.expectEqualStrings("bank", (exports.importFor("switch_to") orelse return error.NoImport).module);
    try std.testing.expectEqualStrings("test", (exports.importFor("assert_eq") orelse return error.NoImport).module);
    try std.testing.expectEqualStrings("mem", (exports.importFor("poke") orelse return error.NoImport).module);
    try std.testing.expectEqualStrings("str", (exports.importFor("format") orelse return error.NoImport).module);
}

test "importFor: a name no module exports has no import" {
    try std.testing.expect(exports.importFor("definitely_not_a_builtin") == null);
    // `len` / `at` / `cmp` are methods on a `str` value, not functions
    // of the module, so importing them would not compile.
    try std.testing.expect(exports.importFor("len") == null);
}
