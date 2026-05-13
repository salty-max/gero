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
    optimize: Optimize = .debug,
    out: ?[]const u8 = null,
    color: ColorChoice = .auto,
    /// `--bank=N` for `gero disasm` — selects which bank slot to
    /// disassemble. `null` (default) = base image.
    bank: ?u8 = null,
    /// `--show-bytes` / `--no-show-bytes` for `gero disasm` —
    /// toggle the hex-bytes column between the address gutter and
    /// the asm line. `true` (default) keeps the objdump-style
    /// view; `false` strips the column for a cleaner asm-only
    /// output.
    show_bytes: bool = true,
    /// `--check-roundtrip` for `gero disasm` — drive the archive
    /// through `asm → disasm → asm` and exit non-zero if base +
    /// bank bytes don't match. No textual output is produced on
    /// success aside from a one-line ok summary (suppressed by
    /// `--quiet`). Intended for CI use against shipped examples.
    check_roundtrip: bool = false,
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

/// Optional out-of-band diagnostic that the parser fills before
/// returning a `ParseError`. Lets the caller include the
/// offending token in the human-facing error message
/// (e.g. "unknown flag: --not-show-bytes" instead of just
/// "unknown flag.").
pub const Diagnostic = struct {
    /// The argv token that triggered the error (e.g.
    /// `--not-show-bytes` for `UnknownFlag`, `frobnicate` for
    /// `UnknownCommand`, `--color=neon` for `InvalidEnumValue`).
    /// `null` until the parser hits an error.
    bad_token: ?[]const u8 = null,
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

/// True for subcommands that have a real implementation today.
/// The rest are intentionally listed in help so the surface is
/// discoverable, but split into a separate "planned" section.
fn commandIsImplemented(cmd: Command) bool {
    return switch (cmd) {
        .asm_, .run, .info, .disasm, .test_ => true,
        .compile, .bench, .fmt, .check, .build => false,
    };
}

/// ANSI helpers used only inside the help text. Kept inline so
/// `cli.zig` doesn't have to pull in the asm-side `Style` struct.
const HelpAnsi = struct {
    bold: []const u8,
    dim: []const u8,
    cyan: []const u8,
    yellow: []const u8,
    reset: []const u8,

    fn pick(color: bool) HelpAnsi {
        return if (color) .{
            .bold = "\x1b[1m",
            .dim = "\x1b[2m",
            .cyan = "\x1b[36m",
            .yellow = "\x1b[33m",
            .reset = "\x1b[0m",
        } else .{
            .bold = "",
            .dim = "",
            .cyan = "",
            .yellow = "",
            .reset = "",
        };
    }
};

/// Top-level help text. Printed for `gero` (no args) and
/// `gero --help`. `color` toggles ANSI escapes for section
/// headers and key terms.
pub fn topHelp(out: *std.Io.Writer, color: bool) std.Io.Writer.Error!void {
    const a = HelpAnsi.pick(color);

    try out.print("{s}gero{s} — 16-bit VM + asm + lang toolchain  {s}(v{s}){s}\n\n", .{ a.bold, a.reset, a.dim, version_string, a.reset });

    try out.print("{s}USAGE{s}\n", .{ a.yellow, a.reset });
    try out.print("  {s}gero{s} <subcommand> [flags] [args]\n", .{ a.cyan, a.reset });
    try out.print("  {s}gero{s} --version\n", .{ a.cyan, a.reset });
    try out.print("  {s}gero{s} --help\n\n", .{ a.cyan, a.reset });

    try out.print("{s}SUBCOMMANDS{s}\n", .{ a.yellow, a.reset });
    inline for (std.meta.fields(Command)) |f| {
        const cmd: Command = @enumFromInt(f.value);
        if (commandIsImplemented(cmd))
            try out.print("  {s}{s:<8}{s} {s}\n", .{ a.cyan, commandName(cmd), a.reset, commandSummary(cmd) });
    }

    try out.print("\n{s}PLANNED{s} {s}(not yet implemented){s}\n", .{ a.yellow, a.reset, a.dim, a.reset });
    inline for (std.meta.fields(Command)) |f| {
        const cmd: Command = @enumFromInt(f.value);
        if (!commandIsImplemented(cmd))
            try out.print("  {s}{s:<8}{s} {s}{s}{s}\n", .{ a.dim, commandName(cmd), a.reset, a.dim, commandSummary(cmd), a.reset });
    }

    try out.print("\n{s}EXAMPLES{s}\n", .{ a.yellow, a.reset });
    try out.print("  {s}gero asm prog.gas{s}                Assemble to prog.gx (next to source)\n", .{ a.cyan, a.reset });
    try out.print("  {s}gero asm prog.gas -o build/{s}      Output into a directory\n", .{ a.cyan, a.reset });
    try out.print("  {s}gero asm prog.gas -v{s}             Verbose — print per-phase timings\n", .{ a.cyan, a.reset });
    try out.print("  {s}gero info prog.gx{s}                Print the .gx header\n", .{ a.cyan, a.reset });
    try out.print("  {s}gero run prog.gx{s}                 Boot the VM and execute\n", .{ a.cyan, a.reset });

    try out.print("\nRun `{s}gero <subcommand> --help{s}` for per-command flags.\n", .{ a.cyan, a.reset });
}

/// Per-subcommand help. Implemented commands get a tailored
/// usage line + example; planned commands print a one-liner
/// reminder so the user isn't left wondering.
pub fn commandHelp(out: *std.Io.Writer, cmd: Command, color: bool) std.Io.Writer.Error!void {
    const a = HelpAnsi.pick(color);

    try out.print("{s}gero {s}{s} — {s}\n\n", .{ a.bold, commandName(cmd), a.reset, commandSummary(cmd) });

    if (!commandIsImplemented(cmd)) {
        try out.print("{s}Not yet implemented{s} in this build (v{s}).\n", .{ a.yellow, a.reset, version_string });
        try out.print("Track progress: {s}https://github.com/salty-max/gero/issues{s}\n", .{ a.cyan, a.reset });
        return;
    }

    try out.print("{s}USAGE{s}\n", .{ a.yellow, a.reset });
    switch (cmd) {
        .asm_ => {
            try out.print("  {s}gero asm{s} <file.gas> [-o <path>] [-v] [--quiet]\n\n", .{ a.cyan, a.reset });
            try out.print("{s}EXAMPLES{s}\n", .{ a.yellow, a.reset });
            try out.print("  {s}gero asm prog.gas{s}                {s}# → prog.gx{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
            try out.print("  {s}gero asm prog.gas -o build/{s}      {s}# → build/prog.gx{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
            try out.print("  {s}gero asm prog.gas -o named.gx{s}    {s}# → named.gx{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
            try out.print("  {s}gero asm prog.gas -v{s}             {s}# per-phase timings{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
        },
        .run => {
            try out.print("  {s}gero run{s} <file.gx> [--quiet]\n\n", .{ a.cyan, a.reset });
            try out.print("{s}EXAMPLES{s}\n", .{ a.yellow, a.reset });
            try out.print("  {s}gero run prog.gx{s}                 {s}# boot + execute until hlt{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
        },
        .info => {
            try out.print("  {s}gero info{s} <file.gx>\n\n", .{ a.cyan, a.reset });
            try out.print("{s}EXAMPLES{s}\n", .{ a.yellow, a.reset });
            try out.print("  {s}gero info prog.gx{s}                {s}# print the .gx header{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
        },
        .disasm => {
            try out.print("  {s}gero disasm{s} <file.gx> [--bank=N] [--no-show-bytes] [--check-roundtrip]\n\n", .{ a.cyan, a.reset });
            try out.print("{s}EXAMPLES{s}\n", .{ a.yellow, a.reset });
            try out.print("  {s}gero disasm prog.gx{s}              {s}# disassemble the base image to stdout{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
            try out.print("  {s}gero disasm prog.gx --bank=0{s}     {s}# disassemble bank slot 0{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
            try out.print("  {s}gero disasm prog.gx --no-show-bytes{s}  {s}# strip the hex-bytes column{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
            try out.print("  {s}gero disasm prog.gx --check-roundtrip{s}  {s}# verify asm → disasm → asm equality{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
        },
        .test_ => {
            try out.print("  {s}gero test{s} [pattern] [--verbose]\n\n", .{ a.cyan, a.reset });
            try out.print("{s}EXAMPLES{s}\n", .{ a.yellow, a.reset });
            try out.print("  {s}gero test{s}                    {s}# run every asm-level test under tests/asm/{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
            try out.print("  {s}gero test loop{s}               {s}# only tests whose name contains 'loop'{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
            try out.print("  {s}gero test --verbose{s}          {s}# show per-test duration{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
        },
        else => unreachable, // allow-strict: commandIsImplemented() filtered above
    }

    try out.print("\n{s}FLAGS{s}\n", .{ a.yellow, a.reset });
    for (flagsForCommand(cmd)) |f| {
        const h = flagHelpLine(f);
        try out.print("  {s}{s:<22}{s} {s}\n", .{ a.cyan, h.sig, a.reset, h.desc });
    }
}

/// One row of the per-command FLAGS block — the left-column
/// signature and the right-column description.
const FlagHelpLine = struct { sig: []const u8, desc: []const u8 };

fn flagHelpLine(kind: FlagKind) FlagHelpLine {
    return switch (kind) {
        .help => .{ .sig = "--help / -h", .desc = "Print this help." },
        .version => .{ .sig = "--version / -V", .desc = "Print build version." },
        .quiet => .{ .sig = "--quiet / -q", .desc = "Suppress non-error output." },
        .verbose => .{ .sig = "--verbose / -v", .desc = "Extra diagnostics + per-phase timings." },
        .optimize => .{ .sig = "--optimize / -O=<m>", .desc = "debug (default) / release / size." },
        .out => .{ .sig = "--out / -o=<path>", .desc = "Output destination." },
        .color => .{ .sig = "--color / -c=<m>", .desc = "auto (default) / always / never." },
        .no_color => .{ .sig = "--no-color", .desc = "Shortcut for --color=never." },
        .bank => .{ .sig = "--bank=<N>", .desc = "Pick a bank slot to disassemble (default: base image)." },
        .show_bytes => .{ .sig = "--show-bytes", .desc = "(default) Show the hex-bytes column." },
        .no_show_bytes => .{ .sig = "--no-show-bytes", .desc = "Strip the hex-bytes column for a cleaner view." },
        .check_roundtrip => .{ .sig = "--check-roundtrip", .desc = "Verify asm → disasm → asm yields identical bytes (CI gate)." },
    };
}

/// Which flags each subcommand actually consumes. The per-command
/// help block iterates this list — anything not here doesn't get
/// listed (and would be a no-op even if the parser accepted it).
fn flagsForCommand(cmd: Command) []const FlagKind {
    return switch (cmd) {
        .asm_ => &.{ .help, .out, .quiet, .verbose, .color, .no_color },
        .run => &.{ .help, .verbose, .color, .no_color },
        .info => &.{ .help, .color, .no_color },
        .disasm => &.{ .help, .bank, .no_show_bytes, .check_roundtrip, .quiet, .color, .no_color },
        .test_ => &.{ .help, .verbose, .color, .no_color },
        .compile, .bench, .fmt, .check, .build => &.{.help},
    };
}

/// Print the version line consumed by `gero --version` / `gero -V`.
pub fn printVersion(out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print("gero {s}\n", .{version_string});
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

const FlagKind = enum { help, version, quiet, verbose, optimize, out, color, no_color, bank, show_bytes, no_show_bytes, check_roundtrip };

fn longFlag(s: []const u8) ?FlagKind {
    if (std.mem.eql(u8, s, "help")) return .help;
    if (std.mem.eql(u8, s, "version")) return .version;
    if (std.mem.eql(u8, s, "quiet")) return .quiet;
    if (std.mem.eql(u8, s, "verbose")) return .verbose;
    if (std.mem.eql(u8, s, "optimize")) return .optimize;
    if (std.mem.eql(u8, s, "out")) return .out;
    if (std.mem.eql(u8, s, "color")) return .color;
    if (std.mem.eql(u8, s, "no-color")) return .no_color;
    if (std.mem.eql(u8, s, "bank")) return .bank;
    if (std.mem.eql(u8, s, "show-bytes")) return .show_bytes;
    if (std.mem.eql(u8, s, "no-show-bytes")) return .no_show_bytes;
    if (std.mem.eql(u8, s, "check-roundtrip")) return .check_roundtrip;
    return null;
}

fn shortFlag(s: []const u8) ?FlagKind {
    if (std.mem.eql(u8, s, "h")) return .help;
    if (std.mem.eql(u8, s, "V")) return .version; // upper-case — convention from rustc / clang
    if (std.mem.eql(u8, s, "q")) return .quiet;
    if (std.mem.eql(u8, s, "v")) return .verbose;
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
        .optimize => opts.optimize = try parseOptimize(value orelse return error.MissingFlagValue),
        .out => opts.out = value orelse return error.MissingFlagValue,
        .color => opts.color = try parseColor(value orelse return error.MissingFlagValue),
        .no_color => opts.color = .never,
        .bank => opts.bank = try parseBank(value orelse return error.MissingFlagValue),
        .show_bytes => opts.show_bytes = true,
        .no_show_bytes => opts.show_bytes = false,
        .check_roundtrip => opts.check_roundtrip = true,
    }
}

fn parseBank(s: []const u8) ParseError!u8 {
    return std.fmt.parseInt(u8, s, 10) catch error.InvalidEnumValue;
}

fn needsValue(kind: FlagKind) bool {
    return switch (kind) {
        .optimize, .out, .color, .bank => true,
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
/// `Options.help` and `command == null`. For richer error
/// messages (`unknown flag: --not-show-bytes`), use
/// `parseWithDiagnostic`.
pub fn parse(args: []const []const u8) ParseError!Parsed {
    return parseWithDiagnostic(args, null);
}

/// Same as `parse` but writes the offending argv token into
/// `diag.bad_token` before returning a `ParseError`. The caller
/// composes a helpful message instead of "unknown flag." with
/// no context.
pub fn parseWithDiagnostic(args: []const []const u8, diag: ?*Diagnostic) ParseError!Parsed {
    var opts: Options = .{};
    var cmd: ?Command = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (a.len == 0) continue;

        if (std.mem.eql(u8, a, "--")) {
            for (args[i + 1 ..]) |rest_arg| {
                if (opts.positional_count >= max_positionals) {
                    if (diag) |d| d.bad_token = rest_arg;
                    return error.TooManyPositionals;
                }
                opts.positional_buf[opts.positional_count] = rest_arg;
                opts.positional_count += 1;
            }
            break;
        }

        if (a[0] != '-') {
            if (cmd == null) {
                cmd = commandFromStr(a) orelse {
                    if (diag) |d| d.bad_token = a;
                    return error.UnknownCommand;
                };
                continue;
            }
            if (opts.positional_count >= max_positionals) {
                if (diag) |d| d.bad_token = a;
                return error.TooManyPositionals;
            }
            opts.positional_buf[opts.positional_count] = a;
            opts.positional_count += 1;
            continue;
        }

        if (std.mem.startsWith(u8, a, "--")) {
            const rest = a[2..];
            const eq = std.mem.indexOfScalar(u8, rest, '=');
            const name = if (eq) |p| rest[0..p] else rest;
            const inline_value: ?[]const u8 = if (eq) |p| rest[p + 1 ..] else null;
            const kind = longFlag(name) orelse {
                if (diag) |d| d.bad_token = a;
                return error.UnknownFlag;
            };
            if (needsValue(kind)) {
                const v = inline_value orelse blk: {
                    i += 1;
                    if (i >= args.len) {
                        if (diag) |d| d.bad_token = a;
                        return error.MissingFlagValue;
                    }
                    break :blk args[i];
                };
                applyFlag(&opts, kind, v) catch |err| {
                    if (diag) |d| d.bad_token = a;
                    return err;
                };
            } else {
                if (inline_value != null) {
                    if (diag) |d| d.bad_token = a;
                    return error.InvalidEnumValue;
                }
                applyFlag(&opts, kind, null) catch |err| {
                    if (diag) |d| d.bad_token = a;
                    return err;
                };
            }
        } else if (a.len > 1) {
            const rest = a[1..];
            const kind = shortFlag(rest) orelse {
                if (diag) |d| d.bad_token = a;
                return error.UnknownFlag;
            };
            if (needsValue(kind)) {
                i += 1;
                if (i >= args.len) {
                    if (diag) |d| d.bad_token = a;
                    return error.MissingFlagValue;
                }
                applyFlag(&opts, kind, args[i]) catch |err| {
                    if (diag) |d| d.bad_token = a;
                    return err;
                };
            } else {
                applyFlag(&opts, kind, null) catch |err| {
                    if (diag) |d| d.bad_token = a;
                    return err;
                };
            }
        } else {
            if (diag) |d| d.bad_token = a;
            return error.UnknownFlag;
        }
    }

    return .{ .command = cmd, .options = opts };
}

/// Drive a parsed invocation: emits help / runs the stub for
/// the requested subcommand / surfaces usage errors. Returns
/// the process exit code (0 = success, 1 = stub or file error,
/// 2 = bad usage).
pub fn run(parsed: Parsed, stdout: *std.Io.Writer, stderr: *std.Io.Writer) std.Io.Writer.Error!u8 {
    if (parsed.command == null) {
        try topHelp(stdout, false);
        return 0;
    }
    const cmd = parsed.command.?;
    if (parsed.options.help) {
        try commandHelp(stdout, cmd, false);
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
    const args = [_][]const u8{ "run", "--color", "never", "game.gx" };
    const p = try parse(&args);
    try testing.expectEqual(ColorChoice.never, p.options.color);
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

test "parseWithDiagnostic: populates bad_token on UnknownFlag" {
    var diag: Diagnostic = .{};
    const args = [_][]const u8{ "disasm", "--not-show-bytes", "x.gx" };
    try testing.expectError(error.UnknownFlag, parseWithDiagnostic(&args, &diag));
    try testing.expectEqualStrings("--not-show-bytes", diag.bad_token.?);
}

test "parseWithDiagnostic: populates bad_token on UnknownCommand" {
    var diag: Diagnostic = .{};
    const args = [_][]const u8{"frobnicate"};
    try testing.expectError(error.UnknownCommand, parseWithDiagnostic(&args, &diag));
    try testing.expectEqualStrings("frobnicate", diag.bad_token.?);
}

test "parseWithDiagnostic: populates bad_token on InvalidEnumValue" {
    var diag: Diagnostic = .{};
    const args = [_][]const u8{ "run", "--color=neon" };
    try testing.expectError(error.InvalidEnumValue, parseWithDiagnostic(&args, &diag));
    try testing.expectEqualStrings("--color=neon", diag.bad_token.?);
}

test "parse: --optimize=release accepted" {
    const args = [_][]const u8{ "asm", "--optimize=release" };
    const p = try parse(&args);
    try testing.expectEqual(Optimize.release, p.options.optimize);
}

test "parse: --show-bytes default is true, --no-show-bytes disables" {
    const default_p = try parse(&[_][]const u8{"disasm"});
    try testing.expect(default_p.options.show_bytes);

    const on_p = try parse(&[_][]const u8{ "disasm", "--show-bytes", "x.gx" });
    try testing.expect(on_p.options.show_bytes);

    const off_p = try parse(&[_][]const u8{ "disasm", "--no-show-bytes", "x.gx" });
    try testing.expect(!off_p.options.show_bytes);
}

test "parse: --check-roundtrip defaults off, opts in when set" {
    const default_p = try parse(&[_][]const u8{ "disasm", "x.gx" });
    try testing.expect(!default_p.options.check_roundtrip);

    const on_p = try parse(&[_][]const u8{ "disasm", "--check-roundtrip", "x.gx" });
    try testing.expect(on_p.options.check_roundtrip);
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
