const std = @import("std");
const gero = @import("gero");
const cli = @import("cli.zig");
const term_mod = @import("term.zig");
const line_editor = @import("line_editor.zig");

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

    var editor = line_editor.Editor.init(arena, io, stdout);
    defer editor.deinit();

    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(arena);

    while (true) {
        const prompt_text = session.promptText(pending.items.len > 0);
        const action = try editor.readLine(prompt_text);
        switch (action) {
            .eof => return 0,
            .cancel => {
                // Ctrl-C: drop any pending multi-line accumulation
                // and prompt fresh.
                pending.clearRetainingCapacity();
                continue;
            },
            .submit => |line| {
                try editor.pushHistory(line);

                // Meta-commands fire only when we're not mid-block;
                // otherwise the `.help` text would land inside the
                // user's pending def body and confuse the parser.
                if (pending.items.len == 0 and isMetaCommand(line)) {
                    switch (try session.dispatchMeta(line)) {
                        .quit => return 0,
                        .continue_loop => continue,
                    }
                }

                try pending.appendSlice(arena, line);
                try pending.append(arena, '\n');

                if (!blockBalanced(pending.items)) continue;

                // Restore the cooked terminal while the program runs
                // so its own stdout / signals behave normally.
                editor.restoreTerminal();
                try session.evaluate(pending.items);
                pending.clearRetainingCapacity();
            },
        }
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
/// `evaluate` runs every parse / typecheck / codegen against a
/// per-iteration scratch arena so the session arena stays
/// bounded to the committed source buffers — long sessions
/// won't accumulate stale allocator pages.
///
/// `const X = bake do …` and `const X = my_bake_def(…)` route
/// to `decls_source` instead of `prelude_source` so the
/// bake codegen handles them at module-scope. Other `const`
/// initializers stay in the prelude where local-const init is
/// the right model.
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
        if (self.term.color) {
            try self.stdout.print(
                "\x1b[36;1mgero repl\x1b[0m  \x1b[2mv{s}\x1b[0m\n" ++
                    "\x1b[2mtype `help` for commands, `quit` to leave.\x1b[0m\n\n",
                .{cli.version_string},
            );
        } else {
            try self.stdout.print(
                "gero repl  v{s}\n" ++
                    "type `help` for commands, `quit` to leave.\n\n",
                .{cli.version_string},
            );
        }
    }

    /// Prompt text to print before each input line. Caller writes
    /// it to stdout (or hands it to the line editor for redraw).
    fn promptText(self: *Session, continuation: bool) []const u8 {
        if (self.term.color) {
            return if (continuation) "\x1b[2m...\x1b[0m " else "\x1b[36;1m>>>\x1b[0m ";
        }
        return if (continuation) "... " else ">>> ";
    }

    /// Dispatch a REPL meta-command. Returns `.quit` on `quit` /
    /// `exit`; otherwise the loop continues. Meta-commands match
    /// only when the input is a bare keyword (or `dump <name>`),
    /// so a regular `print quit` expression still runs through the
    /// pipeline.
    fn dispatchMeta(self: *Session, line: []const u8) !MetaOutcome {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.eql(u8, trimmed, "quit") or std.mem.eql(u8, trimmed, "exit")) {
            return .quit;
        }
        if (std.mem.eql(u8, trimmed, "help")) {
            try self.stdout.writeAll(
                "  help          — this list\n" ++
                    "  quit / exit   — leave the session\n" ++
                    "  reset         — drop every binding\n" ++
                    "  dump <name>   — print the source of a defined name\n",
            );
            return .continue_loop;
        }
        if (std.mem.eql(u8, trimmed, "reset")) {
            self.decls_source.clearRetainingCapacity();
            self.prelude_source.clearRetainingCapacity();
            try self.stdout.writeAll("session reset.\n");
            return .continue_loop;
        }
        if (startsWithToken(trimmed, "dump")) {
            const rest = std.mem.trim(u8, trimmed["dump".len..], " \t");
            if (rest.len == 0) {
                try self.stdout.writeAll("usage: dump <name>\n");
                return .continue_loop;
            }
            try self.dumpName(rest);
            return .continue_loop;
        }
        // Unreachable in practice — `isMetaCommand` guards entry.
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
    /// / @ann / `const X = bake …`) join `decls_source` at
    /// module scope; non-bake `let` / `const` join
    /// `prelude_source` so they re-run on every subsequent submit
    /// and stay visible; everything else runs once in the current
    /// iteration's `__repl_main` body.
    ///
    /// Per-iteration work allocates from a fresh scratch arena
    /// that releases at the end of this call — the long-lived
    /// session arena keeps only the committed source buffers.
    fn evaluate(self: *Session, new_input: []const u8) !void {
        const stripped = std.mem.trim(u8, new_input, " \t\n");
        if (stripped.len == 0) return;

        // Scratch arena — every parse / typecheck / codegen
        // alloc lands here so the session arena doesn't grow
        // unboundedly across submits. Released on every return.
        var scratch = std.heap.ArenaAllocator.init(self.arena);
        defer scratch.deinit();
        const sa = scratch.allocator();

        // The lang is newline-significant: statements terminate on
        // `\n`. A single-line REPL submit like `def add(x,y) return
        // x + y end` would parse-fail with "expected newline" at
        // every statement boundary. Pre-pass the input alone and
        // inject `\n` at each missing-boundary site so common
        // one-liners work without forcing the user to multi-line.
        const fixed_input = try fixupNewlines(sa, new_input);

        const kind = try self.classifyForRoute(sa, std.mem.trim(u8, fixed_input, " \t\n"));

        const decl_input: []const u8 = if (kind == .decl) fixed_input else "";
        const body_input: []const u8 = if (kind == .body)
            try self.maybeWrapInPrint(sa, fixed_input)
        else
            "";
        const prelude_extra: []const u8 = if (kind == .prelude) fixed_input else "";

        // Candidate source = committed decls + new decl +
        // `__repl_main { prelude + new_prelude + body_input }`.
        // Each piece is `\n`-terminated to keep the parser's
        // statement-boundary rules happy across joins.
        const source = try std.fmt.allocPrint(
            sa,
            "{s}{s}\ndef __repl_main()\n{s}{s}{s}\nend\n",
            .{
                self.decls_source.items,
                decl_input,
                self.prelude_source.items,
                prelude_extra,
                body_input,
            },
        );

        // Where the user-typed bytes land inside `source` — used to
        // translate diagnostic spans back to `fixed_input` so the
        // renderer shows the user's input, not the synthetic
        // wrapper / auto-`print` prefix. `fixed_input` is the
        // newline-normalized form; spans translate cleanly into it.
        const wrapper_prefix = "\ndef __repl_main()\n";
        const user_start: usize = switch (kind) {
            .decl => self.decls_source.items.len,
            .prelude => self.decls_source.items.len + wrapper_prefix.len + self.prelude_source.items.len,
            .body => self.decls_source.items.len + wrapper_prefix.len + self.prelude_source.items.len + (body_input.len - fixed_input.len),
        };
        const view: UserView = .{ .source = fixed_input, .start_in_synth = user_start };

        var diags: std.ArrayList(gero.lang.Diagnostic) = .empty;

        var stream = gero.lang.tokenize(sa, source) catch {
            try self.term.err("repl: tokenizer failure", .{});
            return;
        };
        defer stream.deinit();
        for (stream.errors) |e| try appendParseError(sa, &diags, e);

        var tree = gero.lang.parse(sa, source, stream) catch {
            try self.term.err("repl: parse failure", .{});
            return;
        };
        defer tree.deinit();
        for (tree.errors) |e| try appendParseError(sa, &diags, e);

        if (diags.items.len > 0) {
            try self.renderDiagnostics(view, diags.items, sa);
            return;
        }

        var checked = gero.lang.typecheck(sa, source, &tree.program) catch {
            try self.term.err("repl: typecheck failure", .{});
            return;
        };
        defer checked.deinit();
        for (checked.diagnostics) |d| try diags.append(sa, d);
        if (checked.hasErrors()) {
            try self.renderDiagnostics(view, diags.items, sa);
            return;
        }

        var compiled = gero.lang.compile(sa, source, &checked, .{ .entry_name = "__repl_main" }) catch {
            try self.term.err("repl: codegen failure", .{});
            return;
        };
        defer compiled.deinit();
        for (compiled.diagnostics) |d| try diags.append(sa, d);
        if (compiled.hasErrors()) {
            try self.renderDiagnostics(view, diags.items, sa);
            return;
        }

        // Warnings (no fatal) — show them, but proceed to run.
        if (diags.items.len > 0) try self.renderDiagnostics(view, diags.items, sa);

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
    /// State-free; takes the scratch allocator directly.
    fn maybeWrapInPrint(_: *Session, sa: std.mem.Allocator, input: []const u8) ![]const u8 {
        return wrapInPrintIfBareExpr(sa, input);
    }

    /// Route `const X = bake do …` / `const X = bake_def(…)` to
    /// `.decl` even though the leading token is `const`. Module-
    /// scope is where the bake codegen evaluates + serializes the
    /// result into static data; routing these through the prelude
    /// would land them inside `__repl_main` as locals where bake
    /// init isn't supported.
    fn classifyForRoute(self: *Session, sa: std.mem.Allocator, stripped: []const u8) !Session.InputKind {
        const base = classifyInput(stripped);
        if (base != .prelude) return base;
        if (!startsWithToken(stripped, "const")) return base;
        if (try constInitIsBake(self, sa, stripped)) return .decl;
        return base;
    }

    /// `true` when `stripped` parses as a single `const X = …`
    /// whose init is `bake do …` or a call to a known bake def.
    fn constInitIsBake(self: *Session, sa: std.mem.Allocator, stripped: []const u8) !bool {
        var stream = gero.lang.tokenize(sa, stripped) catch return false;
        defer stream.deinit();
        var tree = gero.lang.parse(sa, stripped, stream) catch return false;
        defer tree.deinit();
        if (tree.errors.len > 0) return false;
        if (tree.program.statements.len != 1) return false;
        const stmt = tree.program.statements[0];
        if (stmt != .const_decl) return false;
        const init_expr = stmt.const_decl.init;
        return switch (init_expr.*) {
            .do_expr => |de| de.is_bake,
            .call => |c| blk: {
                if (c.callee.* != .ident) break :blk false;
                const name = stripped[c.callee.ident.span.start..c.callee.ident.span.end];
                break :blk self.committedHasBakeDef(name);
            },
            else => false,
        };
    }

    /// Cheap textual scan for a `bake def <name>` in the
    /// committed decls. Used by `constInitIsBake` to decide
    /// whether a `const X = my_fn()` call hits a known bake def
    /// and should route to module scope.
    fn committedHasBakeDef(self: *Session, name: []const u8) bool {
        var scan: usize = 0;
        const src = self.decls_source.items;
        while (std.mem.indexOfPos(u8, src, scan, "bake def ")) |hit| {
            const after = hit + "bake def ".len;
            if (after < src.len and matchesIdent(src[after..], name)) return true;
            scan = hit + "bake def ".len;
        }
        return false;
    }

    /// Render diagnostics with caret-style snippets via
    /// `gero.lang.render.prettyOne`. Spans are translated from
    /// the synthetic source back into the user's literal input so
    /// the snippet shows what the user actually typed; diagnostics
    /// whose primary span falls outside `view.source` are dropped.
    fn renderDiagnostics(
        self: *Session,
        view: UserView,
        diags: []const gero.lang.Diagnostic,
        sa: std.mem.Allocator,
    ) !void {
        var visible: std.ArrayList(gero.lang.Diagnostic) = .empty;
        for (diags) |d| {
            if (translateDiag(d, view, sa)) |td| try visible.append(sa, td) else |_| {}
        }
        if (visible.items.len == 0) return;
        const style: gero.lang.render.Style = if (self.term.color) .ansi else .none;
        try gero.lang.render.prettyOne(self.stdout, .{
            .path = "<repl>",
            .source = view.source,
            .diagnostics = visible.items,
        }, style);
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

// ---------- newline fixup ----------

/// Pre-parse `input` and inject `\n` at every position the parser
/// flagged with "expected newline or end-of-input". Iterates: the
/// parser recovers from each missing-newline by skipping to the
/// next newline, so one pass only catches the first miss per
/// stretch. Re-parsing after each round surfaces the next ones.
/// Lets REPL one-liners like `def add(x,y) return x + y end` or
/// `while n < 3 print n n = n + 1 end` succeed without the user
/// having to type each statement on its own line.
///
/// Returns `input` unchanged when:
/// - it already contains an internal `\n` (caller is multi-lining),
/// - tokenize fails (lex error — let the main pipeline surface it),
/// - no missing-newline errors ever fire.
fn fixupNewlines(sa: std.mem.Allocator, input: []const u8) ![]const u8 {
    const trailing = input.len > 0 and input[input.len - 1] == '\n';
    const body = if (trailing) input[0 .. input.len - 1] else input;
    if (std.mem.indexOfScalar(u8, body, '\n') != null) return input;

    var current = input;
    // Cap iteration so a pathological input can't loop. 16 is far
    // more than any reasonable REPL one-liner needs.
    var round: u8 = 0;
    while (round < 16) : (round += 1) {
        var stream = gero.lang.tokenize(sa, current) catch return current;
        defer stream.deinit();
        if (stream.errors.len > 0) return current;

        var tree = gero.lang.parse(sa, current, stream) catch return current;
        defer tree.deinit();

        var positions: std.ArrayList(usize) = .empty;
        for (tree.errors) |e| {
            if (isMissingNewlineMsg(e.message)) try positions.append(sa, e.index);
        }
        if (positions.items.len == 0) return current;

        std.mem.sort(usize, positions.items, {}, std.sort.desc(usize));
        var write: usize = 1;
        for (positions.items[1..]) |p| {
            if (p != positions.items[write - 1]) {
                positions.items[write] = p;
                write += 1;
            }
        }
        positions.shrinkRetainingCapacity(write);

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(sa, current);
        for (positions.items) |p| try out.insert(sa, p, '\n');
        current = try out.toOwnedSlice(sa);
    }
    return current;
}

fn isMissingNewlineMsg(msg: []const u8) bool {
    return std.mem.indexOf(u8, msg, "expected newline") != null;
}

// ---------- diagnostic glue ----------

/// Where the user's literal input lives inside the synthetic
/// source. Spans on diagnostics index into the synthetic source;
/// translating them by `start_in_synth` reprojects onto `source`
/// so the renderer shows what the user typed.
const UserView = struct {
    source: []const u8,
    start_in_synth: usize,
};

/// Convert a knit `core.ParseError` (from lexer / parser) into the
/// `Diagnostic` shape the renderer expects. The `expected` field
/// doubles as the diagnostic code (`E_SYNTAX_*` per
/// `docs/lang-diagnostics.md`); falls back to `E_SYNTAX_GENERIC`.
fn appendParseError(
    sa: std.mem.Allocator,
    out: *std.ArrayList(gero.lang.Diagnostic),
    e: anytype,
) !void {
    // safety: ParseError.index fits in u32 — bounded by input size.
    const idx: u32 = @intCast(e.index);
    try out.append(sa, .{
        .severity = .fatal,
        .code = e.expected orelse "E_SYNTAX_GENERIC",
        .message = try sa.dupe(u8, e.message),
        .span = .{ .start = idx, .end = idx },
    });
}

/// Reproject `d`'s spans from synthetic-source coordinates onto
/// `view.source`. Returns `error.OutOfRange` when the primary
/// span doesn't fall inside the user's input — the caller drops
/// the diagnostic in that case. Secondary spans that fall outside
/// are silently filtered.
fn translateDiag(
    d: gero.lang.Diagnostic,
    view: UserView,
    sa: std.mem.Allocator,
) !gero.lang.Diagnostic {
    const primary = translateSpan(d.span, view) orelse return error.OutOfRange;
    var secondary: []const gero.lang.SpanLabel = &.{};
    if (d.secondary.len > 0) {
        var kept: std.ArrayList(gero.lang.SpanLabel) = .empty;
        for (d.secondary) |s| {
            if (translateSpan(s.span, view)) |ts| {
                try kept.append(sa, .{ .span = ts, .message = s.message, .decoration = s.decoration });
            }
        }
        secondary = try kept.toOwnedSlice(sa);
    }
    return .{
        .severity = d.severity,
        .code = d.code,
        .message = d.message,
        .span = primary,
        .help = d.help,
        .secondary = secondary,
    };
}

fn translateSpan(span: anytype, view: UserView) ?@TypeOf(span) {
    // safety: spans are byte offsets into synthetic source; `start_in_synth`
    // is bounded by the same buffer length so subtraction stays in usize range.
    const start_synth: usize = span.start;
    const end_synth: usize = span.end;
    if (start_synth < view.start_in_synth) return null;
    const start = start_synth - view.start_in_synth;
    const end = if (end_synth < view.start_in_synth) start else end_synth - view.start_in_synth;
    if (start > view.source.len or end > view.source.len) return null;
    // @as: spans use u32 — translated offsets stay bounded by user input length.
    return .{ .start = @intCast(start), .end = @intCast(end) };
}

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

/// Wrap `input` in `print …` when it's a bare expression so the
/// expression's value lands on stdout. Statement shapes (`print
/// …`, control flow, etc.) and function-call expr_stmts pass
/// through untouched — the latter would otherwise double-print.
fn wrapInPrintIfBareExpr(sa: std.mem.Allocator, input: []const u8) ![]const u8 {
    const stripped = std.mem.trim(u8, input, " \t\n");
    if (stripped.len == 0) return try sa.dupe(u8, input);
    if (looksLikeMainBodyStatement(stripped)) return try sa.dupe(u8, input);
    if (try inputIsCallStatement(sa, input)) return try sa.dupe(u8, input);
    return try std.fmt.allocPrint(sa, "print {s}", .{input});
}

/// `true` when `input` parses as a single `expr_stmt(.call |
/// .method_call)`. Used by the print-wrap heuristic — calls
/// already execute for effect; wrapping them would print their
/// return value on top of any `print` inside the callee.
fn inputIsCallStatement(sa: std.mem.Allocator, input: []const u8) !bool {
    var stream = gero.lang.tokenize(sa, input) catch return false;
    defer stream.deinit();
    var tree = gero.lang.parse(sa, input, stream) catch return false;
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

/// `true` when the line is one of the bare REPL meta-keywords
/// (`help`, `quit`, `exit`, `reset`, `dump <name>`). Matches only
/// when the keyword is the entire input (or `dump <name>` form),
/// so multi-statement gero code never gets intercepted.
fn isMetaCommand(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return false;
    const bare = [_][]const u8{ "help", "quit", "exit", "reset" };
    for (bare) |kw| if (std.mem.eql(u8, trimmed, kw)) return true;
    return startsWithToken(trimmed, "dump");
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

test "repl/classifyForRoute: `const X = bake do …` re-routes to .decl" {
    // Without the re-route a bake-do const would land inside
    // __repl_main as a local; the bake codegen only handles
    // module-scope const-init.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var session = Session.init(arena.allocator(), undefined, undefined);
    const kind = try session.classifyForRoute(arena.allocator(), "const X = bake do 1 + 2 end");
    try testing.expectEqual(Session.InputKind.decl, kind);
}

test "repl/classifyForRoute: plain `const X = 42` stays in the prelude" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var session = Session.init(arena.allocator(), undefined, undefined);
    const kind = try session.classifyForRoute(arena.allocator(), "const X = 42");
    try testing.expectEqual(Session.InputKind.prelude, kind);
}

test "repl/classifyForRoute: `const X = my_bake_def()` re-routes to .decl" {
    // The session has to know `my_fn` is a bake def — seed the
    // committed decls with the source text the textual scan
    // looks for.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var session = Session.init(arena.allocator(), undefined, undefined);
    try session.decls_source.appendSlice(arena.allocator(), "bake def my_fn() -> i16\n  return 7\nend\n");
    const kind = try session.classifyForRoute(arena.allocator(), "const X = my_fn()");
    try testing.expectEqual(Session.InputKind.decl, kind);
}

test "repl/classifyForRoute: `const X = unknown_fn()` stays in .prelude" {
    // Unknown callee → not a bake def → keep prelude routing so
    // the regular const-init path runs.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var session = Session.init(arena.allocator(), undefined, undefined);
    const kind = try session.classifyForRoute(arena.allocator(), "const X = unknown_fn()");
    try testing.expectEqual(Session.InputKind.prelude, kind);
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

test "repl/appendParseError: uses `expected` field as diagnostic code" {
    var diags: std.ArrayList(gero.lang.Diagnostic) = .empty;
    defer diags.deinit(testing.allocator);
    try appendParseError(testing.allocator, &diags, .{
        .index = 7,
        .message = "expected expression",
        .expected = @as(?[]const u8, "E_SYNTAX_MISSING_TOKEN"),
    });
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqualStrings("E_SYNTAX_MISSING_TOKEN", diags.items[0].code);
    try testing.expectEqualStrings("expected expression", diags.items[0].message);
    try testing.expectEqual(@as(u32, 7), diags.items[0].span.start);
    try testing.expectEqual(@as(u32, 7), diags.items[0].span.end);
    // appendParseError dupes the message string; free it.
    testing.allocator.free(diags.items[0].message);
}

test "repl/fixupNewlines: expands a one-line def into multi-line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try fixupNewlines(arena.allocator(), "def add(x, y) return x + y end\n");
    try testing.expect(std.mem.indexOfScalar(u8, out, '\n') != null);
    // Re-parse the rewritten input — it should now succeed.
    var stream = try gero.lang.tokenize(arena.allocator(), out);
    defer stream.deinit();
    var tree = try gero.lang.parse(arena.allocator(), out, stream);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "repl/fixupNewlines: leaves multi-line input untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "def add(x, y)\n  return x + y\nend\n";
    const out = try fixupNewlines(arena.allocator(), input);
    try testing.expectEqual(input.ptr, out.ptr);
}

test "repl/fixupNewlines: iterates through multiple missing newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try fixupNewlines(arena.allocator(), "let n = 0\n");
    // Single trivial statement — no rewrite, but exercising the
    // iteration path with a clean input shouldn't loop.
    try testing.expectEqualStrings("let n = 0\n", out);
}

test "repl/fixupNewlines: expands one-line while body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try fixupNewlines(arena.allocator(), "while n < 3 print n n = n + 1 end\n");
    var stream = try gero.lang.tokenize(arena.allocator(), out);
    defer stream.deinit();
    var tree = try gero.lang.parse(arena.allocator(), out, stream);
    defer tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "repl/fixupNewlines: leaves clean single-line input untouched" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "let x = 42\n";
    const out = try fixupNewlines(arena.allocator(), input);
    try testing.expectEqual(input.ptr, out.ptr);
}

test "repl/translateSpan: shifts spans by user_start" {
    const view: UserView = .{ .source = "in x", .start_in_synth = 27 };
    const span = gero.lang.ast.Span{ .start = 27, .end = 31 };
    const out = translateSpan(span, view).?;
    try testing.expectEqual(@as(u32, 0), out.start);
    try testing.expectEqual(@as(u32, 4), out.end);
}

test "repl/translateSpan: rejects spans before user input" {
    const view: UserView = .{ .source = "x", .start_in_synth = 20 };
    const span = gero.lang.ast.Span{ .start = 5, .end = 6 };
    try testing.expect(translateSpan(span, view) == null);
}

test "repl/translateSpan: rejects spans past user input" {
    const view: UserView = .{ .source = "x", .start_in_synth = 20 };
    const span = gero.lang.ast.Span{ .start = 22, .end = 25 };
    try testing.expect(translateSpan(span, view) == null);
}

test "repl/appendParseError: falls back to E_SYNTAX_GENERIC when expected is null" {
    var diags: std.ArrayList(gero.lang.Diagnostic) = .empty;
    defer diags.deinit(testing.allocator);
    try appendParseError(testing.allocator, &diags, .{
        .index = 0,
        .message = "weird input",
        .expected = @as(?[]const u8, null),
    });
    try testing.expectEqualStrings("E_SYNTAX_GENERIC", diags.items[0].code);
    testing.allocator.free(diags.items[0].message);
}

test "repl/looksLikeMainBodyStatement: recognizes the body shapes" {
    try testing.expect(looksLikeMainBodyStatement("print x"));
    try testing.expect(looksLikeMainBodyStatement("if x do end"));
    try testing.expect(looksLikeMainBodyStatement("for i in 0..10 end"));
    try testing.expect(looksLikeMainBodyStatement("_ = x"));
    try testing.expect(!looksLikeMainBodyStatement("1 + 2"));
    try testing.expect(!looksLikeMainBodyStatement("greet(42)"));
}
