/// Shared test helpers for gero specs. Populate as patterns emerge.
const std = @import("std");
const builtin = @import("builtin");
const gero = @import("gero");

/// wasi has preopened directories and no `realpath`, so a fixture that
/// canonicalizes a path it just wrote cannot work there. Every helper
/// below needs one, so they report a skip rather than a failure — the
/// gap itself is tracked separately, and a skipped test says "not
/// measured here" where a passing one would lie.
const needs_real_paths = builtin.os.tag != .wasi;

/// Skip unless this target can canonicalize a path it just wrote.
///
/// Every fixture that writes files and resolves them by path needs
/// `realpath`, which wasi does not have. Skipping says "not measured
/// here"; passing would say something untrue.
pub fn requireRealPaths() error{SkipZigTest}!void {
    if (!needs_real_paths) return error.SkipZigTest;
}

/// A throwaway directory of `.gr` modules, compiled and run through
/// the real multi-file path — include resolution, per-module
/// type-check, codegen, VM. Specs that need more than one module
/// share this rather than each growing its own tmpdir plumbing.
pub const ModuleFixture = struct {
    tmp: std.testing.TmpDir,
    alloc: std.mem.Allocator = std.testing.allocator,

    pub fn init() !ModuleFixture {
        try requireRealPaths();
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
