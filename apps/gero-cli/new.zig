/// `gero new` — scaffold a minimal v0.2 asm project.
///
/// Lays out the canonical project shape:
///
/// ```text
/// <name>/
/// ├── gero.toml              # filled with `name`, version 0.1.0, vm target
/// ├── src/main.gas           # hello-world entry, hlt's clean
/// ├── tests/smoke.gas        # template golden-file test
/// ├── tests/smoke.expected   # paired expected stdout
/// └── README.md              # build / test / run pointers
/// ```
///
/// Templates are bundled into the binary via `@embedFile`, so
/// `gero new` works without a network call or external assets.
///
/// Philosophy: guide, don't force. The scaffold ships no CI /
/// pre-commit config — the README points users to the upstream
/// tooling guide where opt-in recipes for GitHub Actions, GitLab,
/// lefthook, and plain git hooks live.
const std = @import("std");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");

/// Embedded template bodies. `*.tmpl` files use `{name}` as the
/// only placeholder; pure-asset files (`main.gas`, `smoke.gas`,
/// `smoke.expected`) are written verbatim.
const gero_toml_tmpl: []const u8 = @embedFile("templates/gero.toml.tmpl");
const main_gas_body: []const u8 = @embedFile("templates/main.gas");
const smoke_gas_body: []const u8 = @embedFile("templates/smoke.gas");
const smoke_expected_body: []const u8 = @embedFile("templates/smoke.expected");
const readme_md_tmpl: []const u8 = @embedFile("templates/README.md.tmpl");

/// Hard cap on project-name length. Mirrors what cargo / npm
/// allow — keeps things sane on every filesystem we target.
const max_name_len: usize = 64;

/// Drive `gero new <name>` end-to-end. Returns the CLI exit code.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len < 1) {
        try term.err("gero new: missing project name (use `.` to scaffold into the current directory)", .{});
        return 2;
    }
    if (positionals.len > 1) {
        try term.err("gero new: too many positional args (expected just <name> or `.`)", .{});
        return 2;
    }
    const arg = positionals[0];

    const cwd = std.Io.Dir.cwd();
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_basename: ?[]const u8 = if (std.mem.eql(u8, arg, ".")) blk: {
        // `Dir.cwd().realPath` doesn't work on macOS — the AT_FDCWD
        // sentinel handle isn't fcntl-resolvable. `std.process.currentPath`
        // wraps the platform-specific `getcwd` syscall and is the
        // portable way to get the absolute cwd.
        const len = std.process.currentPath(io, &cwd_buf) catch |err| {
            try term.err("gero new: cannot resolve current directory ({s})", .{@errorName(err)});
            return 1;
        };
        break :blk std.fs.path.basename(cwd_buf[0..len]);
    } else null;

    const target = resolveTarget(arg, cwd_basename) orelse {
        if (cwd_basename) |base| {
            try term.err(
                "gero new: '{s}' (current directory basename) is not a valid project name — must be 1-{d} chars, start with a letter or _, and contain only letters, digits, _, or -. Rename the directory or pass an explicit name.",
                .{ base, max_name_len },
            );
        } else {
            try term.err(
                "gero new: invalid project name '{s}' — must be 1-{d} chars, start with a letter or _, and contain only letters, digits, _, or -",
                .{ arg, max_name_len },
            );
        }
        return 2;
    };

    // Fresh mode: create the project root. Errors cleanly if the
    // directory already exists — that's the safety guard against
    // clobbering an existing project. In-place mode skips this; the
    // conflict guard below catches per-file collisions instead.
    if (!target.in_place) {
        cwd.createDir(io, target.project_root, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {
                try term.err("gero new: '{s}' already exists", .{target.project_root});
                return 1;
            },
            else => {
                try term.err("gero new: cannot create '{s}' ({s})", .{ target.project_root, @errorName(err) });
                return 1;
            },
        };
    } else {
        // In-place mode: pre-flight every target path so we never
        // half-scaffold over an existing file.
        var conflicts: std.ArrayList([]const u8) = .empty;
        for (project_files) |pf| {
            if (cwd.statFile(io, pf.rel, .{})) |_| {
                try conflicts.append(arena, pf.rel);
            } else |_| {}
        }
        if (conflicts.items.len > 0) {
            try term.err("gero new: current directory has conflicting files (refusing to overwrite):", .{});
            // Same stream as the error label so the list never
            // interleaves with stdout buffer flushes.
            for (conflicts.items) |c| try term.out.print("  {s}\n", .{c});
            return 1;
        }
    }

    // Sub-directories: src/, tests/. `createDirPath` is idempotent
    // — safe for both modes (cwd already exists in in-place).
    try ensureSubdir(io, term, cwd, arena, target.project_root, "src");
    try ensureSubdir(io, term, cwd, arena, target.project_root, "tests");

    // Render the two templates that take a name placeholder.
    const gero_toml_body = try renderTemplate(arena, gero_toml_tmpl, target.name);
    const readme_body = try renderTemplate(arena, readme_md_tmpl, target.name);

    try writeProjectFile(io, term, cwd, arena, target.project_root, "gero.toml", gero_toml_body);
    try writeProjectFile(io, term, cwd, arena, target.project_root, "src/main.gas", main_gas_body);
    try writeProjectFile(io, term, cwd, arena, target.project_root, "tests/smoke.gas", smoke_gas_body);
    try writeProjectFile(io, term, cwd, arena, target.project_root, "tests/smoke.expected", smoke_expected_body);
    try writeProjectFile(io, term, cwd, arena, target.project_root, "README.md", readme_body);

    if (!opts.quiet) {
        if (target.in_place) {
            try term.success("    Created `{s}` project in current directory", .{target.name});
            try stdout.print("\n  gero build\n  gero run out/{s}.gx\n", .{target.name});
        } else {
            try term.success("    Created `{s}` project", .{target.name});
            try stdout.print("\n  cd {s}\n  gero build\n  gero run out/{s}.gx\n", .{ target.name, target.name });
        }
    }
    return 0;
}

/// Resolved scaffold target — what name to bake into templates and
/// where to write the files.
pub const ResolvedTarget = struct {
    /// Project name written into `gero.toml` and the README. For
    /// `gero new .` this is the cwd basename.
    name: []const u8,
    /// Path prefix for every emitted file: a fresh subdir name in
    /// fresh mode, `"."` in in-place mode.
    project_root: []const u8,
    /// True when scaffolding into the current directory.
    in_place: bool,
};

/// Resolve the positional `arg` against an optional `cwd_basename`
/// (pre-fetched by the caller when `arg == "."`). Returns null if
/// the effective name fails validation — the caller renders an
/// error tailored to which mode triggered the failure.
pub fn resolveTarget(arg: []const u8, cwd_basename: ?[]const u8) ?ResolvedTarget {
    if (std.mem.eql(u8, arg, ".")) {
        const base = cwd_basename orelse return null;
        if (!isValidProjectName(base)) return null;
        return .{ .name = base, .project_root = ".", .in_place = true };
    }
    if (!isValidProjectName(arg)) return null;
    return .{ .name = arg, .project_root = arg, .in_place = false };
}

/// Canonical list of files the scaffolder writes — single source
/// of truth for both write loop and the in-place conflict guard.
const ProjectFile = struct { rel: []const u8 };
const project_files = [_]ProjectFile{
    .{ .rel = "gero.toml" },
    .{ .rel = "src/main.gas" },
    .{ .rel = "tests/smoke.gas" },
    .{ .rel = "tests/smoke.expected" },
    .{ .rel = "README.md" },
};

fn ensureSubdir(
    io: std.Io,
    term: *term_mod.Term,
    cwd: std.Io.Dir,
    arena: std.mem.Allocator,
    project_root: []const u8,
    sub: []const u8,
) !void {
    const path = if (std.mem.eql(u8, project_root, "."))
        sub
    else
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_root, sub });
    cwd.createDirPath(io, path) catch |err| {
        try term.err("gero new: cannot create {s} ({s})", .{ path, @errorName(err) });
        return err;
    };
}

/// Validate a project name. Rules:
///
/// - Non-empty, ≤ `max_name_len` chars
/// - First char is ASCII letter or `_`
/// - Remaining chars are ASCII alphanumeric, `_`, or `-`
///
/// Rejects names starting with `-` so they can't be confused with
/// a flag, and names with `/`, `.`, etc. so callers can't escape
/// the cwd.
pub fn isValidProjectName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_len) return false;
    const head = name[0];
    if (!((head >= 'a' and head <= 'z') or (head >= 'A' and head <= 'Z') or head == '_')) return false;
    for (name[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Substitute every `{name}` occurrence in `body` with `name`.
/// Templates use this one placeholder only — no full template
/// engine needed. Returns a freshly allocated buffer on `arena`.
pub fn renderTemplate(
    arena: std.mem.Allocator,
    body: []const u8,
    name: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.mem.replaceOwned(u8, arena, body, "{name}", name);
}

fn writeProjectFile(
    io: std.Io,
    term: *term_mod.Term,
    cwd: std.Io.Dir,
    arena: std.mem.Allocator,
    project_root: []const u8,
    rel: []const u8,
    body: []const u8,
) !void {
    const full = if (std.mem.eql(u8, project_root, "."))
        rel
    else
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_root, rel });
    cwd.writeFile(io, .{ .sub_path = full, .data = body }) catch |err| {
        try term.err("gero new: cannot write {s} ({s})", .{ full, @errorName(err) });
        return err;
    };
}

// ---------- tests ----------

const testing = std.testing;

test "resolveTarget: explicit name → fresh mode" {
    const r = resolveTarget("my-cart", null).?;
    try testing.expectEqualStrings("my-cart", r.name);
    try testing.expectEqualStrings("my-cart", r.project_root);
    try testing.expect(!r.in_place);
}

test "resolveTarget: `.` with valid basename → in-place mode" {
    const r = resolveTarget(".", "my-cart").?;
    try testing.expectEqualStrings("my-cart", r.name);
    try testing.expectEqualStrings(".", r.project_root);
    try testing.expect(r.in_place);
}

test "resolveTarget: `.` with invalid basename → null" {
    try testing.expect(resolveTarget(".", "1-bad") == null);
    try testing.expect(resolveTarget(".", "has space") == null);
    try testing.expect(resolveTarget(".", ".") == null);
}

test "resolveTarget: explicit invalid name → null" {
    try testing.expect(resolveTarget("1-bad", null) == null);
    try testing.expect(resolveTarget("has space", null) == null);
}

test "resolveTarget: `.` without a cwd basename → null" {
    try testing.expect(resolveTarget(".", null) == null);
}

test "isValidProjectName: accepts simple lowercase" {
    try testing.expect(isValidProjectName("my-cart"));
    try testing.expect(isValidProjectName("hello"));
    try testing.expect(isValidProjectName("_underscore"));
    try testing.expect(isValidProjectName("game123"));
    try testing.expect(isValidProjectName("A"));
}

test "isValidProjectName: rejects empty / too long" {
    try testing.expect(!isValidProjectName(""));
    var long_buf: [max_name_len + 1]u8 = undefined;
    @memset(&long_buf, 'a');
    try testing.expect(!isValidProjectName(&long_buf));
}

test "isValidProjectName: rejects leading digit / dash / dot" {
    try testing.expect(!isValidProjectName("1cart"));
    try testing.expect(!isValidProjectName("-cart"));
    try testing.expect(!isValidProjectName(".cart"));
}

test "isValidProjectName: rejects path separators and shell metacharacters" {
    try testing.expect(!isValidProjectName("foo/bar"));
    try testing.expect(!isValidProjectName("foo bar"));
    try testing.expect(!isValidProjectName("foo$bar"));
    try testing.expect(!isValidProjectName("foo.gas"));
    try testing.expect(!isValidProjectName(".."));
}

test "renderTemplate: substitutes {name} once" {
    const out = try renderTemplate(testing.allocator, "hello {name}!", "world");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello world!", out);
}

test "renderTemplate: substitutes every {name} occurrence" {
    const out = try renderTemplate(testing.allocator, "{name}/{name}.gx — for {name}", "cart");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("cart/cart.gx — for cart", out);
}

test "renderTemplate: passes bodies without {name} through unchanged" {
    const out = try renderTemplate(testing.allocator, "no placeholder here", "ignored");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("no placeholder here", out);
}

test "renderTemplate: gero.toml template renders into a parseable manifest" {
    const out = try renderTemplate(testing.allocator, gero_toml_tmpl, "demo");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "name = \"demo\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[package]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[build]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[test]") != null);
    // No leftover `{name}` placeholder after rendering.
    try testing.expect(std.mem.indexOf(u8, out, "{name}") == null);
}

test "renderTemplate: README template references docs/tooling.md" {
    const out = try renderTemplate(testing.allocator, readme_md_tmpl, "demo");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "# demo") != null);
    try testing.expect(std.mem.indexOf(u8, out, "docs/tooling.md") != null);
    try testing.expect(std.mem.indexOf(u8, out, "{name}") == null);
}

test "embedded asm templates: smoke pair stays consistent" {
    // Smoke test asserts the canned program/output pair stays
    // in sync — if either changes, this test catches the drift.
    try testing.expectEqualStrings("ok\n", smoke_expected_body);
    try testing.expect(std.mem.indexOf(u8, smoke_gas_body, "mov $6F") != null);
    try testing.expect(std.mem.indexOf(u8, smoke_gas_body, "mov $6B") != null);
    try testing.expect(std.mem.indexOf(u8, smoke_gas_body, "mov $0A") != null);
    try testing.expect(std.mem.indexOf(u8, smoke_gas_body, "hlt") != null);
}

test "embedded asm templates: main.gas halts cleanly" {
    try testing.expect(std.mem.indexOf(u8, main_gas_body, "hlt") != null);
    try testing.expect(std.mem.indexOf(u8, main_gas_body, "main:") != null);
}
