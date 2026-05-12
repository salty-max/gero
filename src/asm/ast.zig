/// Assembler AST — what the parser emits, what the symbol pass /
/// codegen consume. Each node carries a `Span` so diagnostics can
/// point back at the right `(file_id, line, col)`.
const std = @import("std");
const lexer = @import("lexer.zig");

/// Byte range in a specific source file. Equivalent to the
/// `Token` shape but kept as a separate type so it composes
/// across nodes (e.g., a Label spans two tokens).
pub const Span = struct {
    file_id: u16,
    start: u32,
    end: u32,

    /// Span covering exactly one token.
    pub fn fromToken(t: lexer.Token) Span {
        return .{ .file_id = t.file_id, .start = t.start, .end = t.end };
    }

    /// Smallest span covering both `a` and `b`. Caller's job to
    /// pass spans from the same `file_id` — joining across files
    /// keeps `a`'s file_id and the inclusive bounds (a degenerate
    /// case that should only arise inside the include resolver).
    pub fn join(a: Span, b: Span) Span {
        return .{
            .file_id = a.file_id,
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
        };
    }
};

/// Top-level node — every line of asm parses to one of these.
/// `instruction` and the directive subtypes land in subsequent
/// PRs; `label` and `unknown` are the v0.1-scaffold shapes.
pub const Statement = union(enum) {
    label: Label,
    /// Unknown statement — the parser couldn't classify the line.
    /// Carries a span so the diagnostic can point at it, but
    /// otherwise opaque. Lets later passes skip without crashing.
    unknown: Unknown,

    /// Smallest `Span` that covers the whole statement.
    pub fn span(self: Statement) Span {
        return switch (self) {
            .label => |l| l.span,
            .unknown => |u| u.span,
        };
    }
};

/// `name:` — binds the current emit address to `name`. Resolution
/// (forward refs, duplicates) lives in the symbol-table pass.
pub const Label = struct {
    /// Span of the bare identifier (without the trailing colon).
    name: Span,
    /// Span covering the identifier plus the colon.
    span: Span,
};

/// Catch-all for lines the parser failed to recognize. Stores
/// just the bounding span so the consumer can skip past it.
pub const Unknown = struct {
    span: Span,
};

/// Output of `parse` — owned statement list. Diagnostics live
/// alongside in the `ParseTree` wrapper at `parser.zig` level.
pub const Program = struct {
    statements: []Statement,
    allocator: std.mem.Allocator,

    /// Release the owned statement list.
    pub fn deinit(self: *Program) void {
        self.allocator.free(self.statements);
    }
};
