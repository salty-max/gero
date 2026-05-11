/// `gero` CLI entry point. Wires argv + stdio into the
/// dispatcher in `cli.zig`, which carries all the testable
/// logic.
const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

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
        try stderr.flush();
        return 2;
    };

    const code = try cli.run(parsed, stdout, stderr);
    try stdout.flush();
    try stderr.flush();
    return code;
}
