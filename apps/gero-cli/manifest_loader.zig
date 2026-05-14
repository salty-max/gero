/// Project-aware glue for `gero check` / `gero fmt` / `gero test`:
/// walk ancestors for `gero.toml`, parse it, and expand
/// manifest-relative include lists into a flat `.gas` file list.
///
/// `load` is the thin wrapper that does manifest discovery + parse
/// + read-error reporting; `expandIncludes` walks each entry like
/// a positional path would be walked (single `.gas` file or a
/// directory recursed for `.gas`). Errors are printed via `term`
/// with a `<command_name>: …` prefix so each consuming subcommand
/// keeps its diagnostic voice.
///
/// Lives next to the consuming subcommands (under `apps/gero-cli/`)
/// because it pulls in `term.zig` for diagnostics. `project.zig`
/// stays pure-parser; this module is the CLI flavor.
const std = @import("std");
const project = @import("project.zig");
const term_mod = @import("term.zig");

/// Successfully loaded manifest + the paths used to resolve it.
/// `project_root` is `dirname(manifest_path)`, empty when
/// `gero.toml` lives in the cwd.
pub const Loaded = struct {
    manifest: project.Manifest,
    manifest_path: []const u8,
    project_root: []const u8,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        self.manifest.deinit(allocator);
    }
};

/// What `load` returned. `failed` means a read or parse error was
/// already printed via `term`; the caller picks the exit code.
pub const Outcome = union(enum) {
    ok: Loaded,
    not_found,
    failed,
};

/// Find + read + parse `gero.toml`. Prints read / parse diagnostics
/// via `term` with the given `command_name` prefix. Returns the
/// `Outcome` for the caller to pattern-match on.
pub fn load(
    io: std.Io,
    arena: std.mem.Allocator,
    term: *term_mod.Term,
    command_name: []const u8,
) !Outcome {
    const manifest_path = (try project.findManifest(io, arena)) orelse return .not_found;

    const source = std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .unlimited) catch |err| {
        try term.err("{s}: cannot read {s} ({s})", .{ command_name, manifest_path, @errorName(err) });
        return .failed;
    };

    const parse_result = project.parseWithDiagnostic(arena, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseFailed => {
            try term.err("{s}: {s}: malformed manifest", .{ command_name, manifest_path });
            return .failed;
        },
    };

    switch (parse_result) {
        .ok => |m| {
            const project_root = std.fs.path.dirname(manifest_path) orelse "";
            return .{ .ok = .{
                .manifest = m,
                .manifest_path = manifest_path,
                .project_root = project_root,
            } };
        },
        .err => |diag| {
            try term.err(
                "{s}: {s}:{d}:{d}: {s}",
                .{ command_name, manifest_path, diag.line, diag.col, diag.message() },
            );
            return .failed;
        },
    }
}

/// Resolve a manifest-relative path under the project root. Empty
/// root means cwd — return `rel` verbatim so we don't sprinkle
/// `./` prefixes on every invocation from the project root.
pub fn joinUnderRoot(
    arena: std.mem.Allocator,
    project_root: []const u8,
    rel: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (project_root.len == 0) return arena.dupe(u8, rel);
    return std.fs.path.join(arena, &.{ project_root, rel });
}

/// For each entry in `includes` (manifest-relative path), append
/// to `out` either the single `.gas` file it points to or every
/// `.gas` found by walking the directory recursively. Errors are
/// printed via `term` and propagated as `error.LoadFailed`.
///
/// Mirrors the in-place `.gas` collector each subcommand has for
/// its own positional args — same file-or-directory semantics, so
/// users can drop either path shape into `[test].include`.
pub fn expandIncludes(
    io: std.Io,
    arena: std.mem.Allocator,
    term: *term_mod.Term,
    command_name: []const u8,
    project_root: []const u8,
    includes: []const []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    for (includes) |rel| {
        const full = try joinUnderRoot(arena, project_root, rel);
        const stat = std.Io.Dir.cwd().statFile(io, full, .{}) catch |err| {
            try term.err("{s}: cannot stat {s} ({s})", .{ command_name, full, @errorName(err) });
            return error.LoadFailed;
        };
        if (stat.kind == .directory) {
            var dir = std.Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err| {
                try term.err("{s}: cannot open dir {s} ({s})", .{ command_name, full, @errorName(err) });
                return error.LoadFailed;
            };
            defer dir.close(io);
            var walker = try dir.walk(arena);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.path, ".gas")) continue;
                const joined = try std.fs.path.join(arena, &.{ full, entry.path });
                try out.append(arena, joined);
            }
        } else if (stat.kind == .file) {
            if (!std.mem.endsWith(u8, full, ".gas")) {
                try term.err(
                    "{s}: include entry '{s}' is not a .gas file or directory",
                    .{ command_name, full },
                );
                return error.LoadFailed;
            }
            try out.append(arena, full);
        } else {
            try term.err(
                "{s}: include entry '{s}' is neither a file nor a directory",
                .{ command_name, full },
            );
            return error.LoadFailed;
        }
    }
}

/// Sentinel for `expandIncludes` after a host IO / shape
/// diagnostic has already been printed — the caller maps it to
/// its own exit code rather than printing again.
pub const LoadFailedError = error{LoadFailed};

// ---------- tests ----------

const testing = std.testing;

test "joinUnderRoot: empty root keeps the path verbatim" {
    const out = try joinUnderRoot(testing.allocator, "", "src/main.gas");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("src/main.gas", out);
}

test "joinUnderRoot: parent root prefixes correctly" {
    const out = try joinUnderRoot(testing.allocator, "..", "tests/");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("../tests/", out);
}

test "Outcome union: pattern-matches cleanly" {
    const a: Outcome = .not_found;
    const b: Outcome = .failed;
    try testing.expectEqual(@as(std.meta.Tag(Outcome), .not_found), a);
    try testing.expectEqual(@as(std.meta.Tag(Outcome), .failed), b);
}
