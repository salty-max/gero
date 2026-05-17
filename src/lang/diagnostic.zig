/// Gero-lang diagnostic — the rich shape consumed by the
/// renderer in `render.zig` and produced by `typecheck.zig` plus
/// (eventually) the parser retrofit.
///
/// Carries everything the spec mockup in `docs/lang-diagnostics.md`
/// needs to print one entry: severity prefix, stable code,
/// message body, span (for `(line, col)` + caret length), optional
/// `help:` and `note:` lines.
const std = @import("std");
const ast = @import("ast.zig");

/// Diagnostic severity. Maps to the `error:` / `warning:` /
/// `note:` prefix the renderer emits.
pub const Severity = enum {
    /// Hard error — typecheck failed for this source.
    fatal,
    /// Soft warning — code compiles, but the user should look.
    warning,
    /// Informational note — typically secondary; attaches help
    /// context to a fatal diagnostic from a different code site.
    note,
};

/// One diagnostic. The `span` covers the offending bytes in the
/// source buffer; `code` is the stable `E_TYPE_MISMATCH`-style
/// identifier from `docs/lang-diagnostics.md`.
pub const Diagnostic = struct {
    severity: Severity = .fatal,
    code: []const u8,
    message: []const u8,
    span: ast.Span,
    /// Optional `help: ...` block printed after the caret snippet.
    /// The renderer wraps long lines at 78 cols.
    help: ?[]const u8 = null,
};
