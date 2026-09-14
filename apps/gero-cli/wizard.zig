//! The interactive half of `gero new` / `gero init`.
//!
//! A scaffold has to know which language it is laying down, and the
//! answer is a one-word choice. When there is a terminal to ask, ask;
//! when there is not — a pipe, a CI step — the caller reports the
//! missing flag instead, so a script never gets a language nobody
//! chose (§3.10).

const std = @import("std");
const cli = @import("cli.zig");
const new_cmd = @import("new.zig");
const term_mod = @import("term.zig");

/// `true` when stdin is a terminal a person could answer from.
pub fn interactive(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

/// Ask which language to scaffold, re-prompting until the answer
/// parses.
///
/// Returns `null` when stdin ends first (Ctrl-D, or a pipe that
/// closed) — the caller treats that as a declined choice rather than
/// scaffolding something arbitrary.
pub fn askLang(
    io: std.Io,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !?new_cmd.Lang {
    const a = cli.HelpAnsi.pick(term.color);
    try stdout.print("\n  {s}Which language is this project written in?{s}\n\n", .{ a.bold, a.reset });
    try stdout.print("    {s}1{s}  gero-lang  {s}(.gr) — the high-level language{s}\n", .{ a.cyan, a.reset, a.dim, a.reset });
    try stdout.print("    {s}2{s}  asm        {s}(.gas) — the assembler{s}\n\n", .{ a.cyan, a.reset, a.dim, a.reset });

    var read_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &read_buf);

    while (true) {
        try stdout.print("  {s}>{s} ", .{ a.cyan, a.reset });
        try stdout.flush();

        const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch return null;
        if (parseAnswer(line)) |lang| {
            try stdout.print("\n", .{});
            return lang;
        }
        try term.err("answer 1 / 2, or gr / gas", .{});
    }
}

/// Map one line of input to a language. Accepts the menu numbers and
/// the same spellings `--lang` takes, so whichever the user reaches
/// for lands.
fn parseAnswer(line: []const u8) ?new_cmd.Lang {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0) return null;
    if (std.mem.eql(u8, t, "1")) return .gr;
    if (std.mem.eql(u8, t, "2")) return .gas;
    if (std.mem.eql(u8, t, "gero-lang")) return .gr;
    if (std.mem.eql(u8, t, "asm")) return .gas;
    return new_cmd.Lang.parse(t);
}

// ---------- tests ----------

const testing = std.testing;

test "parseAnswer: the menu numbers pick their language" {
    try testing.expectEqual(new_cmd.Lang.gr, parseAnswer("1").?);
    try testing.expectEqual(new_cmd.Lang.gas, parseAnswer("2").?);
}

test "parseAnswer: the `--lang` spellings work too" {
    // Whichever the user reaches for should land, since the flag and
    // the prompt are two routes to one choice.
    try testing.expectEqual(new_cmd.Lang.gr, parseAnswer("gr").?);
    try testing.expectEqual(new_cmd.Lang.gas, parseAnswer("gas").?);
    try testing.expectEqual(new_cmd.Lang.gr, parseAnswer("gero-lang").?);
    try testing.expectEqual(new_cmd.Lang.gas, parseAnswer("asm").?);
}

test "parseAnswer: surrounding whitespace is ignored" {
    try testing.expectEqual(new_cmd.Lang.gr, parseAnswer("  gr \r").?);
}

test "parseAnswer: anything else is refused rather than guessed" {
    try testing.expect(parseAnswer("") == null);
    try testing.expect(parseAnswer("3") == null);
    try testing.expect(parseAnswer("gero") == null);
    try testing.expect(parseAnswer("y") == null);
}
