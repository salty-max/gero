//! Mirror file for `src/lang/include.zig`.
//! Unit tests for `matchUseQuotedLine` live alongside the source;
//! `use`-resolution behavior (fusing, include-once) is covered here
//! against real temp files, and end-to-end through the `gero check`
//! / `compile` integration tests.

const std = @import("std");
const gero = @import("gero");
const util = @import("util");

const alloc = std.testing.allocator;

const Fixture = struct {
    tmp: std.testing.TmpDir,

    fn init() Fixture {
        return .{ .tmp = std.testing.tmpDir(.{}) };
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, name: []const u8, body: []const u8) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = body });
    }

    fn pathOf(self: *Fixture, name: []const u8) ![:0]u8 {
        return util.tmpPath(alloc, &self.tmp, name);
    }
};

/// Count non-overlapping occurrences of `needle` in `haystack`.
fn occurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            count += 1;
            i += needle.len;
        } else {
            i += 1;
        }
    }
    return count;
}

test "include: module reachable through the barrel" {
    _ = gero.lang.resolveUseImports;
    _ = gero.lang.FusedSource;
    _ = gero.lang.SourceMap;
}

test "resolveUseImports: a file reached by two `use` sites fuses once" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("io.gr",
        \\class display
        \\  @static
        \\  def clear()
        \\  end
        \\end
        \\class input
        \\  @static
        \\  def pressed() -> bool
        \\    return false
        \\  end
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use display from "./io"
        \\use input from "./io"
        \\def main()
        \\  display.clear()
        \\end
        \\
    );

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    // The shared file's bodies are spliced once, not once per `use`
    // site — a second splice would redefine its top-level decls.
    try std.testing.expectEqual(@as(usize, 1), occurrences(fused.source, "class display"));
    try std.testing.expectEqual(@as(usize, 1), occurrences(fused.source, "class input"));
}

test "resolveUseImports: a `use X as Y from` rename is captured as an alias" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("io.gr",
        \\class input
        \\  @static
        \\  def pressed() -> bool
        \\    return false
        \\  end
        \\end
        \\
    );
    try fx.write("main.gr",
        \\use input as keys from "./io"
        \\def main()
        \\  print 0
        \\end
        \\
    );

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    // The directive is elided from the fused source, but its `as keys`
    // rename survives in the alias table for the front-ends to apply.
    const real = fused.import_aliases.get("keys");
    try std.testing.expect(real != null);
    try std.testing.expectEqualStrings("input", real.?);
}

/// First include-error of `kind` in `fused`, or null.
fn firstError(fused: gero.lang.FusedSource, kind: gero.lang.IncludeErrorKind) ?gero.lang.IncludeError {
    for (fused.errors) |e| if (e.kind == kind) return e;
    return null;
}

test "resolveUseImports: a `use` cycle is reported, not silently fused" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("a.gr", "use \"./b\"\ndef fa() -> i16\n  return 1\nend\n");
    try fx.write("b.gr", "use \"./a\"\ndef fb() -> i16\n  return 2\nend\n");
    try fx.write("main.gr", "use \"./a\"\ndef main()\n  print 0\nend\n");

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(firstError(fused, .cycle) != null);
}

test "resolveUseImports: `from` inside a trailing comment isn't parsed as a directive" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("io.gr", "class display\n  @static\n  def clear()\n  end\nend\n");
    try fx.write("main.gr",
        \\use display from "./io" -- borrowed from the runtime
        \\def main()
        \\  display.clear()
        \\end
        \\
    );

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    // The module resolved despite the comment's `from`.
    try std.testing.expectEqual(@as(usize, 1), occurrences(fused.source, "class display"));
}

test "resolveUseImports: a tab-delimited `use ... from` resolves" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("io.gr", "class display\n  @static\n  def clear()\n  end\nend\n");
    try fx.write("main.gr", "use display\tfrom\t\"./io\"\ndef main()\n  display.clear()\nend\n");

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), occurrences(fused.source, "class display"));
}

test "resolveUseImports: one alias bound to two different targets errors" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("m1.gr", "def one() -> i16\n  return 1\nend\n");
    try fx.write("m2.gr", "def two() -> i16\n  return 2\nend\n");
    try fx.write("main.gr",
        \\use one as h from "./m1"
        \\use two as h from "./m2"
        \\def main()
        \\  print h()
        \\end
        \\
    );

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    const dup = firstError(fused, .duplicate_alias);
    try std.testing.expect(dup != null);
    try std.testing.expectEqualStrings("h", dup.?.requested);
}

// ---------- module graph (§5) ----------

test "resolveUseImports: a `use` records an edge from importer to imported" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr", "def helper() -> i16\n  return 1\nend\n");
    try fx.write("main.gr", "use \"./lib\"\ndef main()\n  print helper()\nend\n");

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    try std.testing.expectEqual(@as(usize, 1), fused.imports.len);
    try std.testing.expect(fused.imports[0].from != fused.imports[0].to);
}

test "resolveUseImports: fileIdAt maps an offset back to its module" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr", "def helper() -> i16\n  return 1\nend\n");
    try fx.write("main.gr", "use \"./lib\"\ndef main()\n  print helper()\nend\n");

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    // The two bodies live in different files, so their offsets must
    // not report the same module.
    const lib_at = std.mem.indexOf(u8, fused.source, "return 1").?;
    const main_at = std.mem.indexOf(u8, fused.source, "print helper").?;
    // safety: both index the fused buffer, bounded well under 4 GiB.
    const lib_id = fused.source_map.fileIdAt(@intCast(lib_at));
    const main_id = fused.source_map.fileIdAt(@intCast(main_at));
    try std.testing.expect(lib_id != null and main_id != null);
    try std.testing.expect(lib_id.? != main_id.?);
}

test "resolveUseImports: a diamond records an edge for each importer" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("base.gr", "def shared() -> i16\n  return 1\nend\n");
    try fx.write("a.gr", "use \"./base\"\ndef from_a() -> i16\n  return shared()\nend\n");
    try fx.write("b.gr", "use \"./base\"\ndef from_b() -> i16\n  return shared()\nend\n");
    try fx.write("main.gr", "use \"./a\"\nuse \"./b\"\ndef main()\n  print from_a()\nend\n");

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer fused.deinit();

    // `base` is fused once but both `a` and `b` still import it, so
    // resolution can see it from either.
    try std.testing.expectEqual(@as(usize, 4), fused.imports.len);
}

test "resolveUseImportsOverlaid: an overlaid file is read instead of the one on disk" {
    var fx = Fixture.init();
    defer fx.deinit();
    // The two versions differ only in the body, so the marker found
    // in the fused source says which one was read.
    try fx.write("lib.gr", "def helper() -> i16\n  return 111\nend\n");
    try fx.write("main.gr", "use \"./lib\"\ndef main()\n  print helper()\nend\n");

    const lib_path = try fx.pathOf("lib.gr");
    defer alloc.free(lib_path);
    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var overlay: gero.lang.Overlay = .{};
    defer overlay.deinit(alloc);
    try overlay.put(alloc, lib_path, "def helper() -> i16\n  return 222\nend\n");

    var fused = try gero.lang.resolveUseImportsOverlaid(std.testing.io, alloc, main_path, &overlay);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    // The buffer's text is what the program sees, so an editor's
    // unsaved edit reaches the importer's type-check.
    try std.testing.expectEqual(@as(usize, 1), occurrences(fused.source, "return 222"));
    try std.testing.expectEqual(@as(usize, 0), occurrences(fused.source, "return 111"));
}

test "resolveUseImportsOverlaid: the entry file itself can be overlaid" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr", "def helper() -> i16\n  return 1\nend\n");
    try fx.write("main.gr", "def main()\n  print 0\nend\n");

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    // The buffer adds a `use` the saved file does not have; resolution
    // must follow the buffer's import, not the file's.
    var overlay: gero.lang.Overlay = .{};
    defer overlay.deinit(alloc);
    try overlay.put(alloc, main_path, "use \"./lib\"\ndef main()\n  print helper()\nend\n");

    var fused = try gero.lang.resolveUseImportsOverlaid(std.testing.io, alloc, main_path, &overlay);
    defer fused.deinit();

    try std.testing.expect(!fused.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), occurrences(fused.source, "def helper"));
}

test "resolveUseImportsOverlaid: a null overlay resolves exactly as `resolveUseImports`" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr", "def helper() -> i16\n  return 1\nend\n");
    try fx.write("main.gr", "use \"./lib\"\ndef main()\n  print helper()\nend\n");

    const main_path = try fx.pathOf("main.gr");
    defer alloc.free(main_path);

    var plain = try gero.lang.resolveUseImports(std.testing.io, alloc, main_path);
    defer plain.deinit();
    var overlaid = try gero.lang.resolveUseImportsOverlaid(std.testing.io, alloc, main_path, null);
    defer overlaid.deinit();

    try std.testing.expectEqualStrings(plain.source, overlaid.source);
}

test "resolveUseImports: a mis-cased target is refused, not resolved" {
    // The same rule as asm, for the same reason: a case-insensitive
    // volume would resolve this and Linux would not, so a program that
    // compiles here has to compile there.
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr", "def helper() -> i16\n  return 1\nend\n");
    try fx.write("main.gr", "use \"./Lib\"\ndef main()\n  print helper()\nend\n");

    const path = try fx.pathOf("main.gr");
    defer alloc.free(path);
    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, path);
    defer fused.deinit();

    try std.testing.expect(fused.errors.len > 0);
    const kind = fused.errors[0].kind;
    try std.testing.expect(kind == .case_mismatch or kind == .not_found);
}

test "resolveUseImports: the spelling the file actually has still resolves" {
    var fx = Fixture.init();
    defer fx.deinit();
    try fx.write("lib.gr", "def helper() -> i16\n  return 1\nend\n");
    try fx.write("main.gr", "use \"./lib\"\ndef main()\n  print helper()\nend\n");

    const path = try fx.pathOf("main.gr");
    defer alloc.free(path);
    var fused = try gero.lang.resolveUseImports(std.testing.io, alloc, path);
    defer fused.deinit();

    try std.testing.expectEqual(@as(usize, 0), fused.errors.len);
}
