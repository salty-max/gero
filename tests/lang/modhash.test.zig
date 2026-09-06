//! Mirror file for `src/lang/modhash.zig`.

const std = @import("std");
const gero = @import("gero");
const util = @import("util");

const alloc = std.testing.allocator;

/// Parse `src` standalone and hash what it exports.
fn ifaceHash(src: []const u8) !u64 {
    var stream = try gero.lang.tokenize(alloc, src);
    defer stream.deinit();
    var tree = try gero.lang.parse(alloc, src, stream);
    defer tree.deinit();
    return gero.lang.moduleInterfaceHash(src, tree.program.statements);
}

test "interfaceHash: a body edit leaves the interface unchanged" {
    // The property the whole cache rests on — a dependent's cached work
    // stays valid when a dependency's body changes.
    const before = try ifaceHash("def helper(n: i16) -> i16\n  return n + 1\nend\n");
    const after = try ifaceHash("def helper(n: i16) -> i16\n  let t = n * 2\n  return t - n + 1\nend\n");
    try std.testing.expectEqual(before, after);
}

test "interfaceHash: a signature change is visible" {
    const before = try ifaceHash("def helper(n: i16) -> i16\n  return n\nend\n");
    const ret = try ifaceHash("def helper(n: i16) -> u8\n  return 0\nend\n");
    const param = try ifaceHash("def helper(n: u8) -> i16\n  return 0\nend\n");
    const name = try ifaceHash("def other(n: i16) -> i16\n  return n\nend\n");
    try std.testing.expect(before != ret);
    try std.testing.expect(before != param);
    try std.testing.expect(before != name);
}

test "interfaceHash: a `local` declaration is not part of the interface" {
    // `local` means importers can't see it, so its shape can't matter
    // to them.
    const a = try ifaceHash("def shared() -> i16\n  return 1\nend\n");
    const b = try ifaceHash("local def hidden(x: i16) -> u8\n  return 0\nend\ndef shared() -> i16\n  return 1\nend\n");
    try std.testing.expectEqual(a, b);
}

test "interfaceHash: a new exported declaration is visible" {
    const a = try ifaceHash("def shared() -> i16\n  return 1\nend\n");
    const b = try ifaceHash("def shared() -> i16\n  return 1\nend\ndef added() -> i16\n  return 2\nend\n");
    try std.testing.expect(a != b);
}

test "interfaceHash: a method body edit leaves the class interface unchanged" {
    const before = try ifaceHash("class Box\n  let v: i16\n  def get(self) -> i16\n    return self.v\n  end\nend\n");
    const after = try ifaceHash("class Box\n  let v: i16\n  def get(self) -> i16\n    let t = self.v\n    return t\n  end\nend\n");
    try std.testing.expectEqual(before, after);
}

test "dirtySet: an importer of a changed module is dirty" {
    // Edges run importer → imported: module 0 imports 1, 1 imports 2.
    const imports = [_]gero.lang.ImportEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 1, .to = 2 },
    };
    const changed = [_]bool{ false, false, true };
    const dirty = try gero.lang.dirtyModules(alloc, 3, &imports, &changed);
    defer alloc.free(dirty);
    // The change reaches 0 through 1, so both importers are dirty.
    try std.testing.expect(dirty[0] and dirty[1] and dirty[2]);
}

test "dirtySet: a module the change cannot reach stays clean" {
    const imports = [_]gero.lang.ImportEdge{
        .{ .from = 0, .to = 1 },
        .{ .from = 0, .to = 2 },
    };
    const changed = [_]bool{ false, true, false };
    const dirty = try gero.lang.dirtyModules(alloc, 3, &imports, &changed);
    defer alloc.free(dirty);
    // 2 is a sibling of the changed module, not an importer of it.
    try std.testing.expect(dirty[0] and dirty[1]);
    try std.testing.expect(!dirty[2]);
}

test "dirtySet: nothing changed leaves everything clean" {
    const imports = [_]gero.lang.ImportEdge{.{ .from = 0, .to = 1 }};
    const changed = [_]bool{ false, false };
    const dirty = try gero.lang.dirtyModules(alloc, 2, &imports, &changed);
    defer alloc.free(dirty);
    try std.testing.expect(!dirty[0] and !dirty[1]);
}

test "contentHash: it tracks the file's own text" {
    var fx = try util.ModuleFixture.init();
    defer fx.deinit();
    try fx.write("lib.gr", "def helper() -> i16\n  return 1\nend\n");
    try fx.write("main.gr", "use \"./lib\"\ndef main()\n  print helper()\nend\n");
    const path = try fx.tmp.dir.realPathFileAlloc(std.testing.io, "main.gr", alloc);
    defer alloc.free(path);

    var before = try gero.lang.resolveUseImports(std.testing.io, alloc, path);
    const lib_id = idOf(before.source_map, "lib.gr");
    const main_id = idOf(before.source_map, "main.gr");
    const lib_before = gero.lang.moduleContentHash(&before.source_map, lib_id);
    const main_before = gero.lang.moduleContentHash(&before.source_map, main_id);
    before.deinit();

    try fx.write("lib.gr", "def helper() -> i16\n  return 2\nend\n");
    var after = try gero.lang.resolveUseImports(std.testing.io, alloc, path);
    defer after.deinit();
    const lib_after = gero.lang.moduleContentHash(&after.source_map, idOf(after.source_map, "lib.gr"));
    const main_after = gero.lang.moduleContentHash(&after.source_map, idOf(after.source_map, "main.gr"));

    // Only the edited file's hash moves — an untouched module must stay
    // a cache hit however its neighbours change.
    try std.testing.expect(lib_before != lib_after);
    try std.testing.expectEqual(main_before, main_after);
}

fn idOf(map: gero.lang.SourceMap, basename: []const u8) u16 {
    for (map.files.items, 0..) |f, i| {
        // safety: file count is bounded by the include walk; fits u16.
        if (std.mem.endsWith(u8, f.path, basename)) return @intCast(i);
    }
    return 0;
}
