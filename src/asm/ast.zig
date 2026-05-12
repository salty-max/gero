/// Assembler AST — what the unified knit parser emits, what the
/// symbol pass / codegen consume. Each node carries a `Span` so
/// diagnostics can resolve back to `(file, line, col)` via the
/// `SourceMap` from the include resolver.
const std = @import("std");
const lexer = @import("lexer.zig");

/// Byte range in the fused source buffer. The `SourceMap`
/// (`include.zig`) resolves these to per-file `(line, col)` at
/// diagnostic time.
pub const Span = struct {
    start: u32,
    end: u32,

    /// Span covering exactly one token.
    pub fn fromToken(t: lexer.Token) Span {
        return .{ .start = t.start, .end = t.end };
    }

    /// Smallest span covering both `a` and `b`.
    pub fn join(a: Span, b: Span) Span {
        return .{
            .start = @min(a.start, b.start),
            .end = @max(a.end, b.end),
        };
    }
};

/// Top-level node — every line of asm parses to one of these.
/// Directive + instruction variants land in subsequent PRs.
pub const Statement = union(enum) {
    label: Label,
    /// Catch-all for unrecognized lines — carries a span so the
    /// consumer can skip past it cleanly.
    unknown: Unknown,

    /// Smallest `Span` covering the whole statement.
    pub fn span(self: Statement) Span {
        return switch (self) {
            .label => |l| l.span,
            .unknown => |u| u.span,
        };
    }
};

/// `name:` — binds the current emit address to `name`.
/// Resolution (forward refs, duplicates) lives in #35.
pub const Label = struct {
    /// Span of the bare identifier (without the trailing colon).
    name: Span,
    /// Span covering both the identifier and the colon.
    span: Span,
};

/// Catch-all for lines the parser failed to recognize.
pub const Unknown = struct {
    span: Span,
};

/// Output of `parse` — owned statement list. Diagnostics live
/// alongside in the `ParseTree` wrapper at the parser-level.
pub const Program = struct {
    statements: []Statement,
    allocator: std.mem.Allocator,

    /// Release the owned statement list.
    pub fn deinit(self: *Program) void {
        self.allocator.free(self.statements);
    }
};
