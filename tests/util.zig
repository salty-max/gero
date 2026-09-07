/// Shared test helpers for gero specs. Populate as patterns emerge.
const std = @import("std");
const gero = @import("gero");

/// A throwaway directory of `.gr` modules, compiled and run through
/// the real multi-file path — include resolution, per-module
/// type-check, codegen, VM. Specs that need more than one module
/// share this rather than each growing its own tmpdir plumbing.
pub const ModuleFixture = struct {
    tmp: std.testing.TmpDir,
    alloc: std.mem.Allocator = std.testing.allocator,

    pub fn init() !ModuleFixture {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    pub fn deinit(self: *ModuleFixture) void {
        self.tmp.cleanup();
    }

    pub fn write(self: *ModuleFixture, name: []const u8, body: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = body });
    }

    /// Canonical path of a file written into the fixture. Caller owns
    /// the result.
    pub fn pathOf(self: *ModuleFixture, name: []const u8) ![:0]u8 {
        return self.tmp.dir.realPathFileAlloc(std.testing.io, name, self.alloc);
    }

    /// Compile `entry` with its `use` graph and run it, asserting on
    /// what the program printed.
    pub fn expectRuns(self: *ModuleFixture, entry: []const u8, expected: []const u8) !void {
        const path = try self.tmp.dir.realPathFileAlloc(std.testing.io, entry, self.alloc);
        defer self.alloc.free(path);

        var fused = try gero.lang.resolveUseImports(std.testing.io, self.alloc, path);
        defer fused.deinit();
        try std.testing.expectEqual(@as(usize, 0), fused.errors.len);

        var stream = try gero.lang.tokenize(self.alloc, fused.source);
        defer stream.deinit();
        var tree = try gero.lang.parse(self.alloc, fused.source, stream);
        defer tree.deinit();
        try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

        const graph: gero.lang.ModuleGraph = .{
            .source_map = &fused.source_map,
            .imports = fused.imports,
        };
        var checked = try gero.lang.typecheckGraph(self.alloc, fused.source, &tree.program, &fused.import_aliases, graph);
        defer checked.deinit();
        try std.testing.expectEqual(@as(usize, 0), checked.diagnostics.len);

        var compiled = try gero.lang.compile(self.alloc, fused.source, &checked, .{
            .import_aliases = &fused.import_aliases,
            .graph = graph,
        });
        defer compiled.deinit();
        try std.testing.expect(!compiled.hasErrors());

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        var out = std.Io.Writer.Allocating.fromArrayList(self.alloc, &buf);
        defer out.deinit();

        const loaded = try gero.vm.parseGx(compiled.image);
        var vm = gero.vm.VM.init(self.alloc);
        defer vm.deinit();
        try vm.boot(self.alloc, loaded);
        vm.host = .{ .out = &out.writer };
        _ = gero.vm.run(&vm);

        try std.testing.expectEqualStrings(expected, out.written());
    }
};

test "util module loads" {
    _ = std;
    _ = gero;
}
