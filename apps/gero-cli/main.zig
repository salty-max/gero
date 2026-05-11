/// `gero` CLI entry point. Parses argv, dispatches to the
/// per-subcommand modules, plumbs file-IO + stdio.
const std = @import("std");
const cli = @import("cli.zig");
const run_cmd = @import("run.zig");

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

    const parsed = cli.parse(args[1..]) catch |err| {
        switch (err) {
            error.UnknownCommand => try stderr.print("gero: unknown subcommand\nrun `gero --help` for the list\n", .{}),
            error.UnknownFlag => try stderr.print("gero: unknown flag\n", .{}),
            error.MissingFlagValue => try stderr.print("gero: flag is missing its value\n", .{}),
            error.InvalidEnumValue => try stderr.print("gero: flag value is not recognized\n", .{}),
            error.TooManyPositionals => try stderr.print("gero: too many positional args (max 16)\n", .{}),
        }
        return 2;
    };

    if (parsed.command == null) {
        try cli.topHelp(stdout);
        return 0;
    }
    const cmd = parsed.command.?;
    if (parsed.options.help) {
        try cli.commandHelp(stdout, cmd);
        return 0;
    }

    return switch (cmd) {
        .run => runDispatch(io, arena, parsed.options, stdout, stderr),
        else => blk: {
            try stderr.print("gero {s}: not yet implemented\n", .{cli.commandName(cmd)});
            break :blk 1;
        },
    };
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
    stderr: *std.Io.Writer,
) !u8 {
    const positionals = opts.positional();
    if (positionals.len < 1) {
        try stderr.print("gero run: missing .gx file path\n", .{});
        return 2;
    }
    const gx_path = positionals[0];

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, gx_path, arena, .unlimited) catch |err| {
        try stderr.print("gero run: cannot read {s} ({s})\n", .{ gx_path, @errorName(err) });
        return 1;
    };

    const sav_path = try savPathFor(arena, gx_path);
    var sav_sink = SavFileSink.init(io, std.Io.Dir.cwd(), sav_path);

    return run_cmd.execute(arena, opts, stdout, stderr, &sav_sink.sink, bytes);
}

fn savPathFor(arena: std.mem.Allocator, gx_path: []const u8) ![]u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, gx_path, '.')) |dot| gx_path[0..dot] else gx_path;
    return std.fmt.allocPrint(arena, "{s}.sav", .{stem});
}
