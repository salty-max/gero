/// Asm parser — consumes the fused source string from
/// `include.resolveIncludes` and emits an `ast.Program` in one
/// unified pass via knit combinators. The byte-level token
/// parsers from `lexer.zig` are reused as leaf parsers in the
/// statement grammar.
///
/// Scaffolding PR scope: top-level loop + label statements +
/// unknown-line recovery. Directives and instructions land in
/// follow-up PRs (each adds one variant to `ast.Statement`).
const std = @import("std");
const knit = @import("knit");
const core = knit.core;
const lexer = @import("lexer.zig");
const include = @import("include.zig");
const ast = @import("ast.zig");

/// Output of `parse` — the program AST plus any diagnostics
/// raised while building it. Errors don't abort parsing; the
/// parser recovers to the next statement boundary so a single
/// run drains every problem at once.
pub const ParseTree = struct {
    program: ast.Program,
    errors: []include.Diagnostic,
    allocator: std.mem.Allocator,

    /// Release the owned statements list and the diagnostics buffer.
    pub fn deinit(self: *ParseTree) void {
        self.program.deinit();
        self.allocator.free(self.errors);
    }

    /// `true` when at least one diagnostic was recorded.
    pub fn hasErrors(self: ParseTree) bool {
        return self.errors.len > 0;
    }
};

// ---------- whitespace + comment skipping ----------

/// Skip ASCII whitespace (' ', '\t') and `;`-comments to EOL.
/// Newlines are statement terminators, not whitespace, so we
/// stop before them.
fn skipBlanksThunk(state: *core.ParseState) core.ParseResult(void) {
    while (state.index < state.input.len) {
        const b = state.input[state.index];
        if (b == ' ' or b == '\t') {
            state.advance(1);
        } else if (b == ';') {
            while (state.index < state.input.len and state.input[state.index] != '\n') state.advance(1);
        } else {
            break;
        }
    }
    return core.ok({}, state.index);
}

const blanksP: core.Parser(void) = .{ .parseFn = skipBlanksThunk };

/// Skip blanks/comments AND any number of newlines. Used between
/// statements to consume blank lines.
fn skipSeparatorsThunk(state: *core.ParseState) core.ParseResult(void) {
    while (state.index < state.input.len) {
        const b = state.input[state.index];
        if (b == ' ' or b == '\t' or b == '\n') {
            state.advance(1);
        } else if (b == ';') {
            while (state.index < state.input.len and state.input[state.index] != '\n') state.advance(1);
        } else {
            break;
        }
    }
    return core.ok({}, state.index);
}

const separatorsP: core.Parser(void) = .{ .parseFn = skipSeparatorsThunk };

// ---------- label parser ----------

/// `name:` — knit chain reusing the lexer's `identP` + `colonP`
/// leaves. blanksP between them lets `start  :` parse the same
/// as `start:`.
fn buildLabel(seq: core.ParseResult(struct { lexer.Token, void, lexer.Token }).Ok) ast.Statement {
    _ = seq;
    // unused — we map below
    unreachable;
}

fn mapLabel(seq: struct { lexer.Token, void, lexer.Token }) ast.Statement {
    const ident = seq[0];
    const colon = seq[2];
    return .{ .label = .{
        .name = ast.Span.fromToken(ident),
        .span = ast.Span.join(ast.Span.fromToken(ident), ast.Span.fromToken(colon)),
    } };
}

const labelP: core.Parser(ast.Statement) = blk: {
    const seq = knit.sequenceOf(.{ lexer.identP, blanksP, lexer.colonP });
    break :blk seq.map(ast.Statement, mapLabel);
};

// ---------- unknown-line recovery ----------

/// Catch-all: when no real statement matches, consume to the
/// next newline and emit an `unknown` AST node so the consumer
/// can keep walking the program. Always succeeds (so it can be
/// the last alternative in a `choice`).
fn unknownThunk(state: *core.ParseState) core.ParseResult(ast.Statement) {
    const start = state.index;
    // safety: byte offsets bounded by max_file_size (16 MiB) in include.zig.
    const start_u32: u32 = @intCast(start);
    var end_u32: u32 = start_u32;
    while (state.index < state.input.len and state.input[state.index] != '\n') {
        state.advance(1);
        end_u32 = @intCast(state.index);
    }
    // Don't consume the newline itself — the outer loop separator does.
    return core.ok(ast.Statement{ .unknown = .{
        .span = .{ .start = start_u32, .end = end_u32 },
    } }, state.index);
}

const unknownP: core.Parser(ast.Statement) = .{ .parseFn = unknownThunk };

// ---------- statement dispatch ----------

const statementP: core.Parser(ast.Statement) = knit.choice(ast.Statement, &.{ labelP, unknownP });

// ---------- driver ----------

/// Parse a fused source string into an `ast.Program` + diagnostics.
/// Never fails on grammar errors — those go into `errors` (one per
/// `unknown` statement). The only error path is OOM.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !ParseTree {
    var statements: std.ArrayList(ast.Statement) = .empty;
    errdefer statements.deinit(allocator);
    var errors: std.ArrayList(include.Diagnostic) = .empty;
    errdefer errors.deinit(allocator);

    var state = core.ParseState.init(source, allocator);

    while (state.index < source.len) {
        // Eat blank lines / leading whitespace / comments.
        _ = separatorsP.parseFn(&state);
        if (state.index >= source.len) break;

        const before = state.index;
        const r = statementP.parseFn(&state);
        switch (r) {
            .ok => |ok| {
                // If statement matched `unknown`, record a diagnostic.
                if (ok.value == .unknown) {
                    try errors.append(allocator, .{
                        .parse_error = core.parseError(
                            "statement",
                            before,
                            "unrecognized statement shape (directives + instructions arrive in follow-up PRs)",
                            .{ .kind = .syntactic },
                        ),
                    });
                }
                try statements.append(allocator, ok.value);
            },
            .err => {
                // statementP includes unknownP which always succeeds,
                // so this shouldn't fire. But if it does, advance one
                // byte to guarantee forward progress.
                state.index = @min(state.index + 1, source.len);
            },
        }
    }

    return .{
        .program = .{
            .statements = try statements.toOwnedSlice(allocator),
            .allocator = allocator,
        },
        .errors = try errors.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}
