/// Asm parser — consumes the fused `[]Token` stream from
/// `include.resolveIncludes` and emits an `ast.Program`.
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
/// parser recovers to the next statement boundary and keeps
/// going so a single run drains every problem at once.
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

/// Mutable cursor over the token stream. The parser only ever
/// moves forward; `peek` looks at the current token without
/// consuming it, `take` consumes and returns it.
const Cursor = struct {
    tokens: []const lexer.Token,
    index: usize,

    /// Token currently under the cursor (or `null` past EOF).
    fn peek(self: Cursor) ?lexer.Token {
        if (self.index >= self.tokens.len) return null;
        return self.tokens[self.index];
    }

    /// Token at `index + n` without advancing; `null` past EOF.
    fn peekAt(self: Cursor, n: usize) ?lexer.Token {
        const idx = self.index + n;
        if (idx >= self.tokens.len) return null;
        return self.tokens[idx];
    }

    /// Consume the current token and advance.
    fn take(self: *Cursor) ?lexer.Token {
        const t = self.peek() orelse return null;
        self.index += 1;
        return t;
    }
};

/// Parse a fused token stream into an `ast.Program` + diagnostics.
/// Never fails on grammar errors — those go into `errors`. The
/// only `Allocator.Error` path is OOM.
pub fn parse(allocator: std.mem.Allocator, tokens: []const lexer.Token) !ParseTree {
    var statements: std.ArrayList(ast.Statement) = .empty;
    errdefer statements.deinit(allocator);
    var errors: std.ArrayList(include.Diagnostic) = .empty;
    errdefer errors.deinit(allocator);

    var cur = Cursor{ .tokens = tokens, .index = 0 };

    while (cur.peek()) |t| {
        if (t.kind == .eof) break;
        // Blank lines + EOF tokens between statements are just skipped.
        if (t.kind == .newline) {
            _ = cur.take();
            continue;
        }
        try parseStatement(allocator, &cur, &statements, &errors);
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

/// Dispatch one statement-shape. The contract: on entry the
/// cursor points at the first non-newline token of a statement;
/// on exit the cursor has advanced past the statement (and any
/// trailing newline for non-label statements).
fn parseStatement(
    allocator: std.mem.Allocator,
    cur: *Cursor,
    statements: *std.ArrayList(ast.Statement),
    errors: *std.ArrayList(include.Diagnostic),
) !void {
    const first = cur.peek() orelse return;

    // Label: `ident ":"`. The colon is what marks it as a label
    // rather than the start of an instruction / directive.
    if (first.kind == .ident) {
        if (cur.peekAt(1)) |second| {
            if (second.kind == .colon) {
                _ = cur.take(); // ident
                const colon = cur.take().?; // colon
                try statements.append(allocator, .{ .label = .{
                    .name = ast.Span.fromToken(first),
                    .span = ast.Span.join(ast.Span.fromToken(first), ast.Span.fromToken(colon)),
                } });
                return;
            }
        }
    }

    // Anything else: not yet a known statement. Record the line as
    // an `unknown` and recover to the next newline. Subsequent PRs
    // teach the parser about directives + instructions and shrink
    // this fallback to just genuine syntax errors.
    const start_idx = cur.index;
    try errors.append(allocator, .{
        .file_id = first.file_id,
        .parse_error = core.parseError(
            "statement",
            first.start,
            "unrecognized statement shape (directives + instructions arrive in follow-up PRs)",
            .{ .kind = .syntactic },
        ),
    });
    var last = first;
    while (cur.peek()) |tk| {
        if (tk.kind == .newline or tk.kind == .eof) break;
        last = tk;
        _ = cur.take();
    }
    // Eat the terminating newline if present, so the outer loop
    // can pick up at the next statement.
    if (cur.peek()) |tk| {
        if (tk.kind == .newline) _ = cur.take();
    }
    try statements.append(allocator, .{ .unknown = .{
        .span = ast.Span.join(
            ast.Span.fromToken(cur.tokens[start_idx]),
            ast.Span.fromToken(last),
        ),
    } });
}
