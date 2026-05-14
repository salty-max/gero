/// `gero init` — scaffold a v0.2 asm project **into the current
/// directory**. Mirror of `gero new <name>` (see `new.zig`) but
/// in-place: the cwd's basename becomes the project name. Match
/// to cargo / poetry / yarn / zig: `new` creates a fresh
/// sub-directory, `init` initializes the cwd.
///
/// Refuses to overwrite if any of the scaffolded paths already
/// exist (per-file pre-flight, since the cwd itself is expected
/// to exist).
const std = @import("std");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const new_cmd = @import("new.zig");

/// Drive `gero init` end-to-end. Returns the CLI exit code.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len > 0) {
        try term.err("gero init: takes no positional args (use `gero new <name>` for a fresh sub-directory)", .{});
        return 2;
    }

    const cwd = std.Io.Dir.cwd();

    // `Dir.cwd().realPath` doesn't work on macOS — the AT_FDCWD
    // sentinel handle isn't fcntl-resolvable. `std.process.currentPath`
    // wraps the platform-specific `getcwd` syscall and is the
    // portable way to get the absolute cwd.
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch |err| {
        try term.err("gero init: cannot resolve current directory ({s})", .{@errorName(err)});
        return 1;
    };
    const name = std.fs.path.basename(cwd_buf[0..cwd_len]);

    if (!new_cmd.isValidProjectName(name)) {
        try term.err(
            "gero init: '{s}' (current directory basename) is not a valid project name — must be 1-{d} chars, start with a letter or _, and contain only letters, digits, _, or -. Rename the directory or `cd` into a parent and run `gero new`.",
            .{ name, new_cmd.max_name_len },
        );
        return 2;
    }

    // Pre-flight every target path so we never half-scaffold over
    // an existing file. The cwd itself is allowed to be non-empty
    // (mirrors `cargo init`) — we just refuse to clobber the
    // specific files we'd write.
    var conflicts: std.ArrayList([]const u8) = .empty;
    for (new_cmd.project_files) |rel| {
        if (cwd.statFile(io, rel, .{})) |_| {
            try conflicts.append(arena, rel);
        } else |_| {}
    }
    if (conflicts.items.len > 0) {
        try term.err("gero init: current directory has conflicting files (refusing to overwrite):", .{});
        // Same stream as the error label so the list never
        // interleaves with stdout buffer flushes.
        for (conflicts.items) |c| try term.out.print("  {s}\n", .{c});
        return 1;
    }

    try new_cmd.scaffold(io, arena, cwd, term, .{
        .name = name,
        .project_root = ".",
        .in_place = true,
    });

    if (!opts.quiet) {
        try term.success("    Initialized `{s}` project in current directory", .{name});
        try stdout.print("\n  gero build\n  gero run out/debug/{s}.gx\n", .{name});
    }
    return 0;
}

// ---------- tests ----------

const testing = std.testing;

test "init: reuses new.zig's project-name validator + file list" {
    // Sanity check that the cross-module imports compile + line up.
    // Real coverage lives in the smoke-test path (manual + CI via
    // `gero new` example flow) since the in-place flow needs a real
    // filesystem to exercise the conflict guard.
    try testing.expect(new_cmd.isValidProjectName("my-cart"));
    try testing.expect(!new_cmd.isValidProjectName(""));
    try testing.expect(new_cmd.project_files.len > 0);
    try testing.expect(new_cmd.max_name_len > 0);
}
