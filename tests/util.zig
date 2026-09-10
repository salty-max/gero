/// Shared test helpers for gero specs. Populate as patterns emerge.
const std = @import("std");
const builtin = @import("builtin");
const gero = @import("gero");

/// The `n`th word pushed onto the boot stack.
///
/// `push` pre-decrements, so the first push lands at `sp_boot - 2`.
/// Expressed against the constant rather than as an address, so a test
/// asserting on stack contents does not also pin where the stack
/// starts — that is boot state, and it has moved before.
pub fn stackSlot(n: u16) u16 {
    return gero.vm.sp_boot -% (2 * n);
}

/// The path a fixture's file will canonicalize to.
///
/// This mirrors the resolver's own rule, and has to: an overlay is
/// keyed by canonical path, so a key built any other way silently
/// misses.
///
/// - Where the target has `realpath`, that is the canonical form.
/// - wasi has none — `realPathFileAlloc` returns
///   `OperationUnsupported` there — and the resolver normalizes
///   lexically instead. `std.testing.tmpDir` roots at
///   `.zig-cache/tmp/<sub_path>`, which wasmtime preopens as part of
///   the working directory, so the same path can be built from the
///   directory's own name.
pub fn tmpPath(
    allocator: std.mem.Allocator,
    tmp: *const std.testing.TmpDir,
    name: []const u8,
) ![:0]u8 {
    if (builtin.os.tag == .wasi) {
        return std.fmt.allocPrintSentinel(
            allocator,
            ".zig-cache/tmp/{s}/{s}",
            .{ &tmp.sub_path, name },
            0,
        );
    }
    return tmp.dir.realPathFileAlloc(std.testing.io, name, allocator);
}

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

    /// Path of a file written into the fixture. Caller owns the result.
    pub fn pathOf(self: *ModuleFixture, name: []const u8) ![:0]u8 {
        return tmpPath(self.alloc, &self.tmp, name);
    }

    /// Compile `entry` with its `use` graph and run it, asserting on
    /// what the program printed.
    pub fn expectRuns(self: *ModuleFixture, entry: []const u8, expected: []const u8) !void {
        const path = try self.pathOf(entry);
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
