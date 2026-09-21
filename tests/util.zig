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

/// Append `count` no-op defs to `source`, each writing to low RAM so
/// nothing in the static-data region is touched. Calling them all from
/// `main` is how a spec pushes the code buffer past a chosen size.
pub fn appendFillerDefs(allocator: std.mem.Allocator, source: *std.ArrayList(u8), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const def = try std.fmt.allocPrint(allocator,
            \\def f{d}(a: u16, b: u16, c: u16)
            \\  mem.write_u16($0300, a + b + c)
            \\  mem.write_u16($0302, a)
            \\  mem.write_u16($0304, b)
            \\end
            \\
        , .{i});
        defer allocator.free(def);
        try source.appendSlice(allocator, def);
    }
}

/// Append one call per def `appendFillerDefs` wrote.
pub fn appendFillerCalls(allocator: std.mem.Allocator, source: *std.ArrayList(u8), count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const call = try std.fmt.allocPrint(allocator, "  f{d}(1, 2, 3)\n", .{i});
        defer allocator.free(call);
        try source.appendSlice(allocator, call);
    }
}

/// Enough filler defs to carry the code buffer past `data_base`, so the
/// static-data region has to move above it.
pub const filler_past_data_base = 60;

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

    /// Check `entry` with its `use` graph and append every diagnostic
    /// code it produced to `out`. For tests about what the import
    /// graph accepts, where the program need not run.
    ///
    /// Caller frees each appended code.
    pub fn collectCodes(
        self: *ModuleFixture,
        entry: []const u8,
        out: *std.ArrayList([]const u8),
    ) !void {
        const path = try self.pathOf(entry);
        defer self.alloc.free(path);

        var fused = try gero.lang.resolveUseImports(std.testing.io, self.alloc, path);
        defer fused.deinit();
        for (fused.errors) |e| try out.append(self.alloc, try self.alloc.dupe(u8, gero.lang.includeErrorCode(e.kind)));

        var stream = try gero.lang.tokenize(self.alloc, fused.source);
        defer stream.deinit();
        var tree = try gero.lang.parse(self.alloc, fused.source, stream);
        defer tree.deinit();

        var checked = try gero.lang.typecheckGraph(self.alloc, fused.source, &tree.program, &fused.import_aliases, .{
            .source_map = &fused.source_map,
            .imports = fused.imports,
        });
        defer checked.deinit();
        for (checked.diagnostics) |d| try out.append(self.alloc, try self.alloc.dupe(u8, d.code));
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
