/// `gero repl` — interactive gero-lang prompt. Reads lines from
/// stdin into a session source buffer, recompiles on every
/// submission, runs the result on a fresh VM. Each input
/// classifies as either a top-level statement (let / const / def /
/// class / struct / enum / use / print / control-flow) or a bare
/// expression. Bare expressions get auto-wrapped in `print` so the
/// value lands on stdout.
///
/// Multi-line input is detected by lexer-balance: while the running
/// open-block count (def / do / if / while / for / repeat / class /
/// struct / enum) exceeds the running close count (end / until),
/// the prompt switches to `... ` and accumulates more lines.
///
/// Meta-commands:
///
///   `.help`       — usage summary
///   `.quit`       — leave the session (also reached via EOF)
///   `.reset`      — drop every binding
///   `.dump <n>`   — print the source text of a previously-defined
///                   name (`def`, `let`, `const`, etc.)
const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");

/// Drive `gero repl` end-to-end. Returns the exit code per the
/// loop's terminating reason — `0` on clean `.quit` / EOF.
pub fn execute(
    io: std.Io,
    arena: std.mem.Allocator,
    opts: cli.Options,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
) !u8 {
    _ = opts;
    var session = Session.init(arena, stdout, term);

    try session.banner();

    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(arena);
    var line_buf = std.ArrayList(u8).empty;
    defer line_buf.deinit(arena);

    // Stdin reader — same pattern as `gero fmt --stdin` (fmt.zig).
    var stdin_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buf);
    const stdin = &stdin_reader.interface;

    while (true) {
        try session.prompt(pending.items.len > 0);
        // Flush the prompt synchronously so users see it before
        // their typing lands on the same line.
        try stdout.flush();
        line_buf.clearRetainingCapacity();
        const eof = try readLine(stdin, arena, &line_buf);
        if (eof) {
            try stdout.writeAll("\n");
            return 0;
        }

        const line = line_buf.items;

        // Meta-commands fire only when we're not mid-block;
        // otherwise the `.help` text would land inside the user's
        // pending def body and confuse the parser later.
        if (pending.items.len == 0 and isMetaCommand(line)) {
            switch (try session.dispatchMeta(line)) {
                .quit => return 0,
                .continue_loop => continue,
            }
        }

        try pending.appendSlice(arena, line);
        try pending.append(arena, '\n');

        if (!blockBalanced(pending.items)) continue;

        try session.evaluate(pending.items);
        pending.clearRetainingCapacity();
    }
}

/// REPL session state. Two persistent buffers:
///
/// - `decls_source` — top-level `def` / `class` / `struct` / `enum`
///   / `use` / `bake def` decls. Each iteration's compile sees the
///   full set; commits append on success.
/// - `prelude_source` — `let` / `const` bindings. The
///   per-iteration `__repl_main` body re-runs the prelude so a
///   `let x = 10` from a prior input is visible to a subsequent
///   `x + 5`. This is the canonical REPL state model — bindings
///   re-initialize from source each compile, costing one rerun
///   per input.
///
/// Errors during evaluation print diagnostics + leave both
/// buffers untouched so the user's session survives mistakes.
///
/// Known limitations (deferred follow-ups, not in the v0.3 AC):
///
/// - The session arena grows monotonically — every parse /
///   typecheck / codegen accumulates and the REPL never resets.
///   Fine for typical interactive sessions; long-running editor
///   integrations may want a per-iteration scratch arena.
/// - `const X = bake do …` at REPL routes to the prelude
///   (local-const inside `__repl_main`). Bake codegen only
///   handles `bake do` at module-scope const-init, so the
///   compound surfaces `E_CODEGEN_UNSUPPORTED`. Workaround:
///   define a `bake def` separately, then `const X = my_def()`
///   at the prompt — the call dispatches through the bake-init
///   path correctly.
const Session = struct {
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    term: *term_mod.Term,
    decls_source: std.ArrayList(u8),
    prelude_source: std.ArrayList(u8),

    const MetaOutcome = enum { quit, continue_loop };

    fn init(arena: std.mem.Allocator, stdout: *std.Io.Writer, term: *term_mod.Term) Session {
        return .{
            .arena = arena,
            .stdout = stdout,
            .term = term,
            .decls_source = .empty,
            .prelude_source = .empty,
        };
    }

    fn banner(self: *Session) !void {
        try self.stdout.print("gero repl — v{s} (type `.help`, `.quit` to leave)\n", .{cli.version_string});
    }

    fn prompt(self: *Session, continuation: bool) !void {
        try self.stdout.writeAll(if (continuation) "... " else ">>> ");
    }

    /// Dispatch a `.` meta-command. Returns `.quit` on `.quit` /
    /// `.exit`; otherwise the loop continues.
    fn dispatchMeta(self: *Session, line: []const u8) !MetaOutcome {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, ".quit") or std.mem.eql(u8, trimmed, ".exit")) {
            return .quit;
        }
        if (std.mem.eql(u8, trimmed, ".help")) {
            try self.stdout.writeAll(
                "  .help          — this list\n" ++
                    "  .quit          — leave the session\n" ++
                    "  .reset         — drop every binding\n" ++
                    "  .dump <name>   — print the source of a defined name\n",
            );
            return .continue_loop;
        }
        if (std.mem.eql(u8, trimmed, ".reset")) {
            self.decls_source.clearRetainingCapacity();
            self.prelude_source.clearRetainingCapacity();
            try self.stdout.writeAll("session reset.\n");
            return .continue_loop;
        }
        if (std.mem.startsWith(u8, trimmed, ".dump")) {
            const rest = std.mem.trim(u8, trimmed[5..], " \t");
            if (rest.len == 0) {
                try self.stdout.writeAll("usage: .dump <name>\n");
                return .continue_loop;
            }
            try self.dumpName(rest);
            return .continue_loop;
        }
        try self.term.err("unknown meta-command `{s}` — try `.help`", .{trimmed});
        return .continue_loop;
    }

    /// Find a `def name(…)` / `let name` / `const NAME` / `class
    /// name` / `struct name` / `enum name` in the committed source
    /// and print the line range covering it. Best-effort textual
    /// match — sufficient for the REPL's introspection use case
    /// without standing up a real symbol table.
    fn dumpName(self: *Session, name: []const u8) !void {
        const buffers = [_][]const u8{ self.decls_source.items, self.prelude_source.items };
        const keywords = [_][]const u8{ "def ", "bake def ", "let ", "const ", "class ", "struct ", "enum " };
        for (buffers) |src| {
            for (keywords) |kw| {
                var scan: usize = 0;
                while (std.mem.indexOfPos(u8, src, scan, kw)) |hit| {
                    const after = hit + kw.len;
                    if (after < src.len and matchesIdent(src[after..], name)) {
                        try printSourceBlock(self.stdout, src, hit);
                        return;
                    }
                    scan = hit + kw.len;
                }
            }
        }
        try self.term.err("`{s}` not defined in this session", .{name});
    }

    /// Where one submit's input belongs in the session.
    const InputKind = enum { decl, prelude, body };

    /// One REPL submit: classify the leading token + route the
    /// input. Decls (def / class / struct / enum / use / bake def
    /// / @ann) join `decls_source` at module scope; `let` /
    /// `const` join `prelude_source` so they re-run on every
    /// subsequent submit and stay visible; everything else runs
    /// once in the current iteration's `__repl_main` body.
    fn evaluate(self: *Session, new_input: []const u8) !void {
        const stripped = std.mem.trim(u8, new_input, " \t\n");
        if (stripped.len == 0) return;

        const kind = classifyInput(stripped);

        const decl_input: []const u8 = if (kind == .decl) new_input else "";
        const body_input: []const u8 = if (kind == .body)
            try self.maybeWrapInPrint(new_input)
        else
            "";
        const prelude_extra: []const u8 = if (kind == .prelude) new_input else "";

        // Candidate source = committed decls + new decl +
        // `__repl_main { prelude + new_prelude + body_input }`.
        // Each piece is `\n`-terminated to keep the parser's
        // statement-boundary rules happy across joins.
        const source = try std.fmt.allocPrint(
            self.arena,
            "{s}{s}\ndef __repl_main()\n{s}{s}{s}\nend\n",
            .{
                self.decls_source.items,
                decl_input,
                self.prelude_source.items,
                prelude_extra,
                body_input,
            },
        );

        var stream = gero.lang.tokenize(self.arena, source) catch {
            try self.term.err("repl: tokenizer failure", .{});
            return;
        };
        defer stream.deinit();

        var tree = gero.lang.parse(self.arena, source, stream) catch {
            try self.term.err("repl: parse failure", .{});
            return;
        };
        defer tree.deinit();
        if (tree.errors.len > 0) {
            for (tree.errors) |e| {
                try self.term.err("parse: {s}", .{e.message});
            }
            return;
        }

        var checked = gero.lang.typecheck(self.arena, source, &tree.program) catch {
            try self.term.err("repl: typecheck failure", .{});
            return;
        };
        defer checked.deinit();
        if (checked.hasErrors()) {
            try self.renderLangDiagnostics(source, checked.diagnostics);
            return;
        }

        var compiled = gero.lang.compile(self.arena, source, &checked, .{ .entry_name = "__repl_main" }) catch {
            try self.term.err("repl: codegen failure", .{});
            return;
        };
        defer compiled.deinit();
        if (compiled.hasErrors()) {
            for (compiled.diagnostics) |d| try self.term.err("codegen: {s} [{s}]", .{ d.message, d.code });
            return;
        }

        // All clean — boot a VM, run until halt / fault, capture
        // print syscalls into our stdout.
        try self.runImage(compiled.image);

        // Commit on success. Decls join the module-scope buffer;
        // `let` / `const` join the prelude. Body statements
        // (`print`, control flow, bare exprs) don't persist by
        // design — they're per-iteration.
        switch (kind) {
            .decl => try self.decls_source.appendSlice(self.arena, decl_input),
            .prelude => try self.prelude_source.appendSlice(self.arena, prelude_extra),
            .body => {},
        }
    }

    /// Decide whether to wrap a body-shape input in `print`. The
    /// auto-wrap is for displaying *values* — function calls that
    /// already print or whose return is `nil` shouldn't get an
    /// extra `print` wrapping their return value. Pre-parses the
    /// input alone (sub-millisecond) to inspect the AST shape.
    fn maybeWrapInPrint(self: *Session, input: []const u8) ![]const u8 {
        const stripped = std.mem.trim(u8, input, " \t\n");
        if (stripped.len == 0) return try self.arena.dupe(u8, input);
        if (looksLikeMainBodyStatement(stripped)) return try self.arena.dupe(u8, input);

        // Best-effort AST inspection: if the input parses as a
        // single `expr_stmt` whose expression is a call or method
        // call, leave it alone (it executes for effect; the
        // user's own `print`s inside the callee surface the
        // value). Anything else gets the `print` wrap.
        if (try self.inputIsCallStatement(input)) return try self.arena.dupe(u8, input);
        return try std.fmt.allocPrint(self.arena, "print {s}", .{input});
    }

    fn inputIsCallStatement(self: *Session, input: []const u8) !bool {
        var stream = gero.lang.tokenize(self.arena, input) catch return false;
        defer stream.deinit();
        var tree = gero.lang.parse(self.arena, input, stream) catch return false;
        defer tree.deinit();
        if (tree.errors.len > 0) return false;
        if (tree.program.statements.len != 1) return false;
        const stmt = tree.program.statements[0];
        if (stmt != .expr_stmt) return false;
        return switch (stmt.expr_stmt.expr.*) {
            .call, .method_call => true,
            else => false,
        };
    }

    /// Format every lang diagnostic onto the REPL's stderr. Bare
    /// formatting — full caret rendering is overkill for an
    /// interactive prompt where the source is right above.
    fn renderLangDiagnostics(self: *Session, source: []const u8, diags: []const gero.lang.Diagnostic) !void {
        for (diags) |d| {
            const lc = gero.lang.render.lineColAt(source, d.span.start);
            // `term.err` already writes the `error:` prefix; we
            // append the rendered line / column + diagnostic
            // body without re-prefixing.
            switch (d.severity) {
                .fatal => try self.term.err("{d}:{d}: {s} [{s}]", .{ lc.line, lc.col, d.message, d.code }),
                .warning => try self.term.info("warning {d}:{d}: {s} [{s}]", .{ lc.line, lc.col, d.message, d.code }),
                .note => try self.term.info("note {d}:{d}: {s} [{s}]", .{ lc.line, lc.col, d.message, d.code }),
            }
        }
    }

    /// Boot a fresh VM on the compiled image and run until halt
    /// or fault. `int 0x10` (the canonical "print one byte" host
    /// callback the runtime uses) routes to the REPL's stdout.
    fn runImage(self: *Session, image: []const u8) !void {
        const loaded = gero.vm.parseGx(image) catch {
            try self.term.err("repl: invalid .gx produced by codegen", .{});
            return;
        };
        var vm = gero.vm.VM.init(self.arena);
        defer vm.deinit();
        try vm.boot(self.arena, loaded);
        vm.host = .{ .out = self.stdout };

        while (true) {
            const result = gero.vm.step(&vm);
            switch (result) {
                .cont, .branched => continue,
                .halted => break,
                .halted_on_fault => {
                    try self.term.err("repl: VM faulted at ip=0x{X:0>4}", .{vm.regs.read(.ip)});
                    break;
                },
                .breakpoint => break,
            }
        }
        // Flush so each input's output lands before the next
        // prompt prints. Print syscalls write through `vm.host.out`
        // (== `self.stdout`) which buffers internally.
        try self.stdout.flush();
    }
};

// ---------- lex-only block balance ----------

/// `true` when the open-block count in `source` equals the close
/// count. Used by the multi-line continuation prompt — while
/// imbalanced, we keep prompting the user for more input. Strings
/// + line comments are skipped so a `--` line or a "do" literal
/// inside `"…"` doesn't throw off the count.
fn blockBalanced(source: []const u8) bool {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == '-' and i + 1 < source.len and source[i + 1] == '-') {
            // Skip line comment.
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (c == '"') {
            // Skip string literal (respects `\"` escapes).
            i += 1;
            while (i < source.len and source[i] != '"') {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
                i += 1;
            }
            if (i < source.len) i += 1;
            continue;
        }
        if (isIdentStart(c) and !precededByIdent(source, i)) {
            const start = i;
            while (i < source.len and isIdentCont(source[i])) i += 1;
            const tok = source[start..i];
            depth += blockDelta(tok);
            continue;
        }
        i += 1;
    }
    return depth <= 0;
}

fn blockDelta(tok: []const u8) i32 {
    // `else` / `elif` are mid-block markers and the parser handles
    // them as part of the surrounding if-chain; ignored here.
    const opens = [_][]const u8{ "def", "do", "if", "while", "for", "repeat", "class", "struct", "enum", "match" };
    const closes = [_][]const u8{ "end", "until" };
    for (opens) |o| if (std.mem.eql(u8, tok, o)) return 1;
    for (closes) |c| if (std.mem.eql(u8, tok, c)) return -1;
    return 0;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn precededByIdent(source: []const u8, i: usize) bool {
    if (i == 0) return false;
    return isIdentCont(source[i - 1]);
}

// ---------- classify input ----------

/// Decide where one input lands in the session — see
/// `Session.evaluate` for the routing rules.
fn classifyInput(stripped: []const u8) Session.InputKind {
    if (stripped.len == 0) return .body;
    if (stripped[0] == '@') return .decl;
    if (startsWithToken(stripped, "let") or startsWithToken(stripped, "const")) {
        return .prelude;
    }
    // `bake def …` is a top-level decl; `bake do … end` is an
    // expression that should run in __repl_main body (the
    // auto-wrap then surfaces its value via `print`). Peek the
    // token after `bake` to pick.
    if (startsWithToken(stripped, "bake")) {
        const after = trimLeadingWhitespace(stripped["bake".len..]);
        return if (startsWithToken(after, "def")) .decl else .body;
    }
    const decl_heads = [_][]const u8{ "def", "class", "struct", "enum", "use", "local" };
    for (decl_heads) |h| {
        if (startsWithToken(stripped, h)) return .decl;
    }
    return .body;
}

fn trimLeadingWhitespace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
    return s[i..];
}

/// `true` when `stripped` is a statement-shape codegen handles
/// inside a `def` body — `print`, control flow, assignments,
/// etc. Anything else gets wrapped in `print` so the
/// expression's value lands on stdout.
fn looksLikeMainBodyStatement(stripped: []const u8) bool {
    if (stripped.len == 0) return false;
    if (stripped[0] == '_') return true;
    const heads = [_][]const u8{ "print", "if", "while", "for", "repeat", "match", "return", "break", "continue", "defer", "do" };
    for (heads) |h| {
        if (startsWithToken(stripped, h)) return true;
    }
    return false;
}

fn startsWithToken(s: []const u8, kw: []const u8) bool {
    if (!std.mem.startsWith(u8, s, kw)) return false;
    if (s.len == kw.len) return true;
    return !isIdentCont(s[kw.len]);
}

// ---------- meta-command + helpers ----------

fn isMetaCommand(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return trimmed.len > 0 and trimmed[0] == '.';
}

fn matchesIdent(text: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, text, name)) return false;
    if (text.len == name.len) return true;
    return !isIdentCont(text[name.len]);
}

/// Print the source block starting at `hit` — typically a
/// `def name(…) … end` or `let name = …` line. For multi-line
/// blocks we walk forward until block-balance closes.
fn printSourceBlock(stdout: *std.Io.Writer, source: []const u8, hit: usize) !void {
    var i = hit;
    var seen_open = false;
    var depth: i32 = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == '\n' and (seen_open and depth <= 0)) {
            try stdout.writeAll(source[hit..i]);
            try stdout.writeByte('\n');
            return;
        }
        if (isIdentStart(c) and !precededByIdent(source, i)) {
            const start = i;
            while (i < source.len and isIdentCont(source[i])) i += 1;
            const tok = source[start..i];
            const d = blockDelta(tok);
            if (d > 0) seen_open = true;
            depth += d;
            continue;
        }
        if (c == '\n' and !seen_open) {
            // Single-line let / const — print up to here.
            try stdout.writeAll(source[hit..i]);
            try stdout.writeByte('\n');
            return;
        }
        i += 1;
    }
    try stdout.writeAll(source[hit..]);
    try stdout.writeByte('\n');
}

// ---------- stdin reader ----------

fn readLine(reader: *std.Io.Reader, arena: std.mem.Allocator, out: *std.ArrayList(u8)) !bool {
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => return out.items.len == 0,
            else => return err,
        };
        if (byte == '\n') return false;
        if (byte == '\r') continue;
        try out.append(arena, byte);
    }
}

// ---------- tests ----------

const testing = std.testing;

test "repl/blockBalanced: balanced single-line is true" {
    try testing.expect(blockBalanced("let x = 10\n"));
    try testing.expect(blockBalanced("def foo() end\n"));
    try testing.expect(blockBalanced("if x do print x end\n"));
}

test "repl/blockBalanced: open `def` without `end` is false" {
    try testing.expect(!blockBalanced("def foo()\n"));
    try testing.expect(!blockBalanced("def foo()\n  print x\n"));
}

test "repl/blockBalanced: `do` / `end` count past nested blocks" {
    try testing.expect(blockBalanced("def foo()\n  if x do print x end\nend\n"));
    try testing.expect(!blockBalanced("def foo()\n  if x do print x\nend\n"));
}

test "repl/blockBalanced: `repeat` closes on `until`" {
    try testing.expect(blockBalanced("repeat\n  print x\nuntil x > 0\n"));
    try testing.expect(!blockBalanced("repeat\n  print x\n"));
}

test "repl/blockBalanced: string literals don't perturb the count" {
    try testing.expect(blockBalanced("let s = \"def end do\"\n"));
}

test "repl/blockBalanced: line comments don't perturb the count" {
    try testing.expect(blockBalanced("let x = 10 -- def end do\n"));
}

test "repl/classifyInput: top-level decls route to .decl" {
    try testing.expectEqual(Session.InputKind.decl, classifyInput("def foo() end"));
    try testing.expectEqual(Session.InputKind.decl, classifyInput("class Foo end"));
    try testing.expectEqual(Session.InputKind.decl, classifyInput("struct Stats x: i16 end"));
    try testing.expectEqual(Session.InputKind.decl, classifyInput("enum Color case Red"));
    try testing.expectEqual(Session.InputKind.decl, classifyInput("use mem"));
    try testing.expectEqual(Session.InputKind.decl, classifyInput("@cold"));
    try testing.expectEqual(Session.InputKind.decl, classifyInput("bake def t() -> i16 return 0 end"));
}

test "repl/classifyInput: `bake do` is an expression, routes to .body" {
    // `bake do … end` produces a value; the REPL's auto-wrap
    // surfaces it via `print`. Only `bake def` is a decl.
    try testing.expectEqual(Session.InputKind.body, classifyInput("bake do 1 + 2 end"));
    try testing.expectEqual(Session.InputKind.body, classifyInput("bake do"));
}

test "repl/classifyInput: `let` / `const` route to .prelude" {
    try testing.expectEqual(Session.InputKind.prelude, classifyInput("let x = 10"));
    try testing.expectEqual(Session.InputKind.prelude, classifyInput("const N = 42"));
}

test "repl/classifyInput: bare expressions + statements route to .body" {
    try testing.expectEqual(Session.InputKind.body, classifyInput("x + 5"));
    try testing.expectEqual(Session.InputKind.body, classifyInput("print x"));
    try testing.expectEqual(Session.InputKind.body, classifyInput("foo(42)"));
    try testing.expectEqual(Session.InputKind.body, classifyInput("if x do end"));
    try testing.expectEqual(Session.InputKind.body, classifyInput(""));
}

test "repl/startsWithToken: distinguishes prefix from identifier" {
    try testing.expect(startsWithToken("let x = 10", "let"));
    try testing.expect(!startsWithToken("letter", "let"));
    try testing.expect(startsWithToken("let", "let"));
}

test "repl/looksLikeMainBodyStatement: recognizes the body shapes" {
    try testing.expect(looksLikeMainBodyStatement("print x"));
    try testing.expect(looksLikeMainBodyStatement("if x do end"));
    try testing.expect(looksLikeMainBodyStatement("for i in 0..10 end"));
    try testing.expect(looksLikeMainBodyStatement("_ = x"));
    try testing.expect(!looksLikeMainBodyStatement("1 + 2"));
    try testing.expect(!looksLikeMainBodyStatement("greet(42)"));
}
