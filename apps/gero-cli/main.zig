/// `gero` CLI entry point. Parses argv, dispatches to the
/// per-subcommand modules, plumbs file-IO + stdio.
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const run_cmd = @import("run.zig");
const info_cmd = @import("info.zig");
const asm_cmd = @import("asm.zig");
const disasm_cmd = @import("disasm.zig");
const test_cmd = @import("test.zig");
const check_cmd = @import("check.zig");
const fmt_cmd = @import("fmt.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const raw_args = try init.minimal.args.toSlice(arena);
    const args = try arena.alloc([]const u8, raw_args.len);
    for (raw_args, 0..) |a, i| args[i] = a;

    var diag: cli.Diagnostic = .{};
    const parsed = cli.parseWithDiagnostic(args[1..], &diag) catch |err| {
        // Color isn't known yet, so write a plain error.
        var fallback = term_mod.Term{ .out = stderr, .color = false };
        const bad = diag.bad_token orelse "?";
        switch (err) {
            error.UnknownCommand => try fallback.err("unknown subcommand: {s}. Run `gero --help` for the list.", .{bad}),
            error.UnknownFlag => try fallback.err("unknown flag: {s}", .{bad}),
            error.MissingFlagValue => try fallback.err("flag is missing its value: {s}", .{bad}),
            error.InvalidEnumValue => try fallback.err("flag value is not recognized: {s}", .{bad}),
            error.TooManyPositionals => try fallback.err("too many positional args (max 16): {s}", .{bad}),
        }
        return 2;
    };

    const stderr_color = term_mod.resolve(
        toTermChoice(parsed.options.color),
        envFlag(init.environ_map, "NO_COLOR"),
        std.Io.File.stderr().isTty(io) catch false,
    );
    var term = term_mod.Term{ .out = stderr, .color = stderr_color };

    // Help + version write to stdout, so resolve color against
    // stdout's TTY (a user piping to less expects no escapes).
    const stdout_color = term_mod.resolve(
        toTermChoice(parsed.options.color),
        envFlag(init.environ_map, "NO_COLOR"),
        std.Io.File.stdout().isTty(io) catch false,
    );

    if (parsed.options.version) {
        try cli.printVersion(stdout);
        return 0;
    }
    if (parsed.command == null) {
        try cli.topHelp(stdout, stdout_color);
        return 0;
    }
    const cmd = parsed.command.?;
    if (parsed.options.help) {
        try cli.commandHelp(stdout, cmd, stdout_color);
        return 0;
    }

    return switch (cmd) {
        .asm_ => asm_cmd.execute(io, arena, parsed.options, stdout, &term),
        .run => runDispatch(io, arena, parsed.options, stdout, &term),
        .info => infoDispatch(io, arena, parsed.options, stdout, &term),
        .disasm => disasm_cmd.execute(io, arena, parsed.options, stdout, &term),
        .test_ => test_cmd.execute(io, arena, parsed.options, stdout, &term),
        .check => check_cmd.execute(io, arena, parsed.options, stdout, &term),
        .fmt => fmt_cmd.execute(io, arena, parsed.options, stdout, &term),
        else => blk: {
            try term.err("gero {s}: not yet implemented", .{cli.commandName(cmd)});
            break :blk 1;
        },
    };
}

fn infoDispatch(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len < 1) {
        try term.err("gero info: missing .gx file path", .{});
        return 2;
    }
    const gx_path = positionals[0];

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, gx_path, arena, .unlimited) catch |err| {
        try term.err("gero info: cannot read {s} ({s})", .{ gx_path, @errorName(err) });
        return 1;
    };

    const loaded = gero.vm.parseGx(bytes) catch |err| {
        try term.err("gero info: invalid .gx file ({s})", .{@errorName(err)});
        return 1;
    };

    try info_cmd.format(stdout, .{ .path = gx_path, .file_size = bytes.len }, loaded);
    return 0;
}

fn toTermChoice(c: cli.ColorChoice) term_mod.ColorChoice {
    return switch (c) {
        .auto => .auto,
        .always => .always,
        .never => .never,
    };
}

fn envFlag(env: *std.process.Environ.Map, key: []const u8) bool {
    return env.get(key) != null;
}

const SavFileSink = struct {
    sink: run_cmd.SramSink,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,

    const vtable: run_cmd.SramSink.VTable = .{ .write = writeImpl };

    fn writeImpl(s: *run_cmd.SramSink, bytes: []const u8) anyerror!void {
        // safety: `s` points at the `sink` field of a *SavFileSink
        const self: *SavFileSink = @fieldParentPtr("sink", s);
        try self.dir.writeFile(self.io, .{ .sub_path = self.path, .data = bytes });
    }

    fn init(io: std.Io, dir: std.Io.Dir, path: []const u8) SavFileSink {
        return .{
            .sink = .{ .vtable = &vtable },
            .io = io,
            .dir = dir,
            .path = path,
        };
    }
};

fn runDispatch(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len < 1) {
        try term.err("gero run: missing .gx file path", .{});
        return 2;
    }
    const gx_path = positionals[0];

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, gx_path, arena, .unlimited) catch |err| {
        try term.err("gero run: cannot read {s} ({s})", .{ gx_path, @errorName(err) });
        return 1;
    };

    const sav_path = try savPathFor(arena, gx_path);
    var sav_sink = SavFileSink.init(io, std.Io.Dir.cwd(), sav_path);

    return run_cmd.execute(arena, opts, stdout, term, &sav_sink.sink, bytes);
}

fn savPathFor(arena: std.mem.Allocator, gx_path: []const u8) ![]u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, gx_path, '.')) |dot| gx_path[0..dot] else gx_path;
    return std.fmt.allocPrint(arena, "{s}.sav", .{stem});
}
