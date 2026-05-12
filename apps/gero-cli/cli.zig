/// Argument parser + subcommand dispatcher for the `gero`
/// binary. The parser doesn't allocate — it borrows from the
/// caller's argv slice. Each known subcommand is currently a
/// stub that prints "not yet implemented" and exits 1; flag
/// parsing is fully wired so the eventual implementations only
/// need to read `Options`.
const std = @import("std");

/// Recognized subcommands.
pub const Command = enum {
    asm_,
    compile,
    run,
    test_,
    bench,
    fmt,
    check,
    build,
    disasm,
    info,
};

/// `--target` values per `cli.md` §2.
pub const Target = enum { vm, gtx_16 };

/// `--optimize` values per `cli.md` §2.
pub const Optimize = enum { debug, release, size };

/// `--color` values: `auto` (TTY + `NO_COLOR`), `always`, `never`.
pub const ColorChoice = enum { auto, always, never };

/// Maximum positional args a single invocation can hold. v0.1
/// commands top out at 1-2; keep it generous to absorb future
/// `gero build` multi-source forms without re-architecting.
pub const max_positionals: usize = 16;

/// Parsed common flags + the collected positional tail.
pub const Options = struct {
    help: bool = false,
    version: bool = false,
    quiet: bool = false,
    verbose: bool = false,
    target: Target = .vm,
    optimize: Optimize = .debug,
    out: ?[]const u8 = null,
    color: ColorChoice = .auto,
    positional_buf: [max_positionals][]const u8 = undefined,
    positional_count: usize = 0,

    /// Borrow the slice of positional args actually written.
    pub fn positional(self: *const Options) []const []const u8 {
        return self.positional_buf[0..self.positional_count];
    }
};

/// Result of `parse`.
pub const Parsed = struct {
    command: ?Command,
    options: Options,
};

/// Errors the parser can emit.
pub const ParseError = error{
    UnknownCommand,
    UnknownFlag,
    MissingFlagValue,
    InvalidEnumValue,
    /// More than `max_positionals` non-flag tokens after the
    /// subcommand. Real commands shouldn't hit this.
    TooManyPositionals,
};

fn commandFromStr(s: []const u8) ?Command {
    if (std.mem.eql(u8, s, "asm")) return .asm_;
    if (std.mem.eql(u8, s, "compile")) return .compile;
    if (std.mem.eql(u8, s, "run")) return .run;
    if (std.mem.eql(u8, s, "test")) return .test_;
    if (std.mem.eql(u8, s, "bench")) return .bench;
    if (std.mem.eql(u8, s, "fmt")) return .fmt;
    if (std.mem.eql(u8, s, "check")) return .check;
    if (std.mem.eql(u8, s, "build")) return .build;
    if (std.mem.eql(u8, s, "disasm")) return .disasm;
    if (std.mem.eql(u8, s, "info")) return .info;
    return null;
}

pub fn commandName(cmd: Command) []const u8 {
    return switch (cmd) {
        .asm_ => "asm",
        .compile => "compile",
        .run => "run",
        .test_ => "test",
        .bench => "bench",
        .fmt => "fmt",
        .check => "check",
        .build => "build",
        .disasm => "disasm",
        .info => "info",
    };
}

fn commandSummary(cmd: Command) []const u8 {
    return switch (cmd) {
        .asm_ => "Assemble a .gas file into a .gx image",
        .compile => "Compile a gero-lang module into a .gx",
        .run => "Execute a .gx",
        .test_ => "Run asm-level tests",
        .bench => "Run benchmarks",
        .fmt => "Format .gas / .gr source",
        .check => "Type-check without producing output",
        .build => "Resolve + asm + compile a project",
        .disasm => "Disassemble a .gx into asm",
        .info => "Print the .gx file header",
    };
}

/// Top-level help text. Printed for `gero` (no args) and
/// `gero --help`.
pub fn topHelp(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("gero — VM + asm + lang toolchain\n\n", .{});
    try out.print("USAGE\n  gero <subcommand> [flags] [args]\n\n", .{});
    try out.print("SUBCOMMANDS\n", .{});
    inline for (std.meta.fields(Command)) |f| {
        const cmd: Command = @enumFromInt(f.value);
        try out.print("  {s:<8} {s}\n", .{ commandName(cmd), commandSummary(cmd) });
    }
    try out.print("\nRun `gero <subcommand> --help` for per-command flags.\n", .{});
    try out.print("Run `gero --version` to print the build version.\n", .{});
}

/// Per-subcommand help. Currently the same template; concrete
/// flag lists land with each subcommand's real implementation.
pub fn commandHelp(out: *std.Io.Writer, cmd: Command) std.Io.Writer.Error!void {
    try out.print("gero {s} — {s}\n\n", .{ commandName(cmd), commandSummary(cmd) });
    try out.print("USAGE\n  gero {s} [flags] [args]\n\n", .{commandName(cmd)});
    try out.print("COMMON FLAGS\n", .{});
    try out.print("  --help / -h         Print this help.\n", .{});
    try out.print("  --version / -V      Print build version.\n", .{});
    try out.print("  --quiet / -q        Suppress non-error output.\n", .{});
    try out.print("  --verbose / -v      Extra diagnostics + per-phase timings.\n", .{});
    try out.print("  --target / -t=<s>   vm (default) or gtx-16.\n", .{});
    try out.print("  --optimize / -O=<m> debug (default) / release / size.\n", .{});
    try out.print("  --out / -o=<path>   Output destination for file-producing commands.\n", .{});
    try out.print("  --color / -c=<m>    auto (default) / always / never.\n", .{});
    try out.print("  --no-color          Shortcut for --color=never.\n", .{});
}

/// Print the version line consumed by `gero --version` / `gero -V`.
pub fn printVersion(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("gero {s}\n", .{version_string});
}

fn parseTarget(s: []const u8) ParseError!Target {
    if (std.mem.eql(u8, s, "vm")) return .vm;
    if (std.mem.eql(u8, s, "gtx-16")) return .gtx_16;
    return error.InvalidEnumValue;
}

fn parseOptimize(s: []const u8) ParseError!Optimize {
    if (std.mem.eql(u8, s, "debug")) return .debug;
    if (std.mem.eql(u8, s, "release")) return .release;
    if (std.mem.eql(u8, s, "size")) return .size;
    return error.InvalidEnumValue;
}

fn parseColor(s: []const u8) ParseError!ColorChoice {
    if (std.mem.eql(u8, s, "auto")) return .auto;
    if (std.mem.eql(u8, s, "always")) return .always;
    if (std.mem.eql(u8, s, "never")) return .never;
    return error.InvalidEnumValue;
}

const FlagKind = enum { help, version, quiet, verbose, target, optimize, out, color, no_color };

fn longFlag(s: []const u8) ?FlagKind {
    if (std.mem.eql(u8, s, "help")) return .help;
    if (std.mem.eql(u8, s, "version")) return .version;
    if (std.mem.eql(u8, s, "quiet")) return .quiet;
    if (std.mem.eql(u8, s, "verbose")) return .verbose;
    if (std.mem.eql(u8, s, "target")) return .target;
    if (std.mem.eql(u8, s, "optimize")) return .optimize;
    if (std.mem.eql(u8, s, "out")) return .out;
    if (std.mem.eql(u8, s, "color")) return .color;
    if (std.mem.eql(u8, s, "no-color")) return .no_color;
    return null;
}

fn shortFlag(s: []const u8) ?FlagKind {
    if (std.mem.eql(u8, s, "h")) return .help;
    if (std.mem.eql(u8, s, "V")) return .version; // upper-case — convention from rustc / clang
    if (std.mem.eql(u8, s, "q")) return .quiet;
    if (std.mem.eql(u8, s, "v")) return .verbose;
    if (std.mem.eql(u8, s, "t")) return .target;
    if (std.mem.eql(u8, s, "O")) return .optimize; // upper-case — convention from clang / gcc
    if (std.mem.eql(u8, s, "o")) return .out;
    if (std.mem.eql(u8, s, "c")) return .color;
    return null;
}

fn applyFlag(opts: *Options, kind: FlagKind, value: ?[]const u8) ParseError!void {
    switch (kind) {
        .help => opts.help = true,
        .version => opts.version = true,
        .quiet => opts.quiet = true,
        .verbose => opts.verbose = true,
        .target => opts.target = try parseTarget(value orelse return error.MissingFlagValue),
        .optimize => opts.optimize = try parseOptimize(value orelse return error.MissingFlagValue),
        .out => opts.out = value orelse return error.MissingFlagValue,
        .color => opts.color = try parseColor(value orelse return error.MissingFlagValue),
        .no_color => opts.color = .never,
    }
}

fn needsValue(kind: FlagKind) bool {
    return switch (kind) {
        .target, .optimize, .out, .color => true,
        else => false,
    };
}

/// Build-time-captured semver from `build.zig.zon`. Stamped into
/// `gero --version` output. Bumped via `zig build version`.
pub const version_string: []const u8 = "0.0.0";

/// Parse `argv[1..]` into a `Parsed`. The first non-flag token
/// is the subcommand; everything after it is forwarded to the
/// command (positional args / its own flags get re-parsed by
/// the subcommand). The first argument may also be `--help` /
/// `-h` to request top-level help — that's surfaced via
/// `Options.help` and `command == null`.
pub fn parse(args: []const []const u8) ParseError!Parsed {
    var opts: Options = .{};
    var cmd: ?Command = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len == 0) continue;

        if (std.mem.eql(u8, a, "--")) {
            // Everything after `--` is positional, even tokens
            // that look like flags.
            for (args[i + 1 ..]) |rest_arg| {
                if (opts.positional_count >= max_positionals) return error.TooManyPositionals;
                opts.positional_buf[opts.positional_count] = rest_arg;
                opts.positional_count += 1;
            }
            break;
        }

        if (a[0] != '-') {
            if (cmd == null) {
                cmd = commandFromStr(a) orelse return error.UnknownCommand;
                continue;
            }
            if (opts.positional_count >= max_positionals) return error.TooManyPositionals;
            opts.positional_buf[opts.positional_count] = a;
            opts.positional_count += 1;
            continue;
        }

        if (std.mem.startsWith(u8, a, "--")) {
            const rest = a[2..];
            const eq = std.mem.indexOfScalar(u8, rest, '=');
            const name = if (eq) |p| rest[0..p] else rest;
            const inline_value: ?[]const u8 = if (eq) |p| rest[p + 1 ..] else null;
            const kind = longFlag(name) orelse return error.UnknownFlag;
            if (needsValue(kind)) {
                const v = inline_value orelse blk: {
                    i += 1;
                    if (i >= args.len) return error.MissingFlagValue;
                    break :blk args[i];
                };
                try applyFlag(&opts, kind, v);
            } else {
                if (inline_value != null) return error.InvalidEnumValue;
                try applyFlag(&opts, kind, null);
            }
        } else if (a.len > 1) {
            const rest = a[1..];
            const kind = shortFlag(rest) orelse return error.UnknownFlag;
            if (needsValue(kind)) {
                i += 1;
                if (i >= args.len) return error.MissingFlagValue;
                try applyFlag(&opts, kind, args[i]);
            } else {
                try applyFlag(&opts, kind, null);
            }
        } else return error.UnknownFlag;
    }

    return .{ .command = cmd, .options = opts };
}

/// Drive a parsed invocation: emits help / runs the stub for
/// the requested subcommand / surfaces usage errors. Returns
/// the process exit code (0 = success, 1 = stub or file error,
/// 2 = bad usage).
pub fn run(parsed: Parsed, stdout: *std.Io.Writer, stderr: *std.Io.Writer) std.Io.Writer.Error!u8 {
    if (parsed.command == null) {
        try topHelp(stdout);
        return 0;
    }
    const cmd = parsed.command.?;
    if (parsed.options.help) {
        try commandHelp(stdout, cmd);
        return 0;
    }
    try stderr.print("gero {s}: not yet implemented\n", .{commandName(cmd)});
    return 1;
}

// ---------- tests ----------

const testing = std.testing;

test "parse: no args → no command, help false" {
    const args = [_][]const u8{};
    const p = try parse(&args);
    try testing.expect(p.command == null);
    try testing.expect(!p.options.help);
}

test "parse: --help with no subcommand" {
    const args = [_][]const u8{"--help"};
    const p = try parse(&args);
    try testing.expect(p.command == null);
    try testing.expect(p.options.help);
}

test "parse: subcommand recognized" {
    const args = [_][]const u8{"run"};
    const p = try parse(&args);
    try testing.expectEqual(@as(?Command, .run), p.command);
}

test "parse: unknown subcommand" {
    const args = [_][]const u8{"frobnicate"};
    try testing.expectError(error.UnknownCommand, parse(&args));
}

test "parse: --help after subcommand routes to per-command help" {
    const args = [_][]const u8{ "run", "--help" };
    const p = try parse(&args);
    try testing.expectEqual(@as(?Command, .run), p.command);
    try testing.expect(p.options.help);
}

test "parse: long flag with =value" {
    const args = [_][]const u8{ "asm", "--out=build/", "src.gas" };
    const p = try parse(&args);
    try testing.expectEqual(@as(?Command, .asm_), p.command);
    try testing.expectEqualStrings("build/", p.options.out.?);
    try testing.expectEqual(@as(usize, 1), p.options.positional().len);
    try testing.expectEqualStrings("src.gas", p.options.positional()[0]);
}

test "parse: long flag with separate value" {
    const args = [_][]const u8{ "run", "--target", "gtx-16", "game.gx" };
    const p = try parse(&args);
    try testing.expectEqual(Target.gtx_16, p.options.target);
    try testing.expectEqualStrings("game.gx", p.options.positional()[0]);
}

test "parse: short flags" {
    const args = [_][]const u8{ "run", "-q", "-v", "-o", "out.gx", "game.gx" };
    const p = try parse(&args);
    try testing.expect(p.options.quiet);
    try testing.expect(p.options.verbose);
    try testing.expectEqualStrings("out.gx", p.options.out.?);
    try testing.expectEqualStrings("game.gx", p.options.positional()[0]);
}

test "parse: -- terminator captures trailing positionals" {
    const args = [_][]const u8{ "run", "--", "--game.gx" };
    const p = try parse(&args);
    try testing.expectEqual(@as(?Command, .run), p.command);
    try testing.expectEqual(@as(usize, 1), p.options.positional().len);
    try testing.expectEqualStrings("--game.gx", p.options.positional()[0]);
}

test "parse: unknown flag errors" {
    const args = [_][]const u8{ "run", "--zoinks" };
    try testing.expectError(error.UnknownFlag, parse(&args));
}

test "parse: --target with bad value errors" {
    const args = [_][]const u8{ "run", "--target=mainframe" };
    try testing.expectError(error.InvalidEnumValue, parse(&args));
}

test "parse: --target without a value errors" {
    const args = [_][]const u8{ "run", "--target" };
    try testing.expectError(error.MissingFlagValue, parse(&args));
}

test "parse: --optimize=release accepted" {
    const args = [_][]const u8{ "asm", "--optimize=release" };
    const p = try parse(&args);
    try testing.expectEqual(Optimize.release, p.options.optimize);
}

test "run: no command prints top help, exit 0" {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    const code = try run(.{ .command = null, .options = .{} }, &out, &err);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out_buf[0..out.end], "USAGE") != null);
}

test "run: --help on a subcommand prints per-command help, exit 0" {
    var out_buf: [4096]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    const opts: Options = .{ .help = true };
    const code = try run(.{ .command = .run, .options = opts }, &out, &err);
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expect(std.mem.indexOf(u8, out_buf[0..out.end], "gero run") != null);
}

test "run: subcommand stub exits 1" {
    var out_buf: [256]u8 = undefined;
    var err_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var err: std.Io.Writer = .fixed(&err_buf);
    const code = try run(.{ .command = .run, .options = .{} }, &out, &err);
    try testing.expectEqual(@as(u8, 1), code);
    try testing.expect(std.mem.indexOf(u8, err_buf[0..err.end], "not yet implemented") != null);
}
