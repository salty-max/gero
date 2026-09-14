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

/// One annotated secondary span attached to a diagnostic. Used for
/// the "expected `i16` because of this annotation" / "previous
/// definition here" pattern: a primary diagnostic with the actual
/// error site plus one or more context spans that explain *why*.
/// The renderer decorates the span underneath the source excerpt
/// and prints `message` next to it (same line as the primary when
/// they share a line, otherwise in its own `--> path:line:col`
/// block).
pub const SpanLabel = struct {
    span: ast.Span,
    message: []const u8,
    /// Visual decoration drawn under the span. `.underline` mirrors
    /// the spec mockup (dashes under the secondary, carets under
    /// the primary); `.point` reuses caret characters for an
    /// emphasis tier that visually matches the primary.
    decoration: Decoration = .underline,

    /// Glyph used to underline the secondary span. `.underline`
    /// draws `-` characters (the spec default — visually distinct
    /// from the primary's `^`); `.point` draws `^` to give the
    /// secondary the same emphasis tier as the primary.
    pub const Decoration = enum { underline, point };
};

/// A correction the checker worked out while reporting a diagnostic.
///
/// Each variant says what to change, not how to write it: the edit a
/// tool builds from one is the tool's own business, because where an
/// import belongs depends on the file's existing `use` lines.
pub const Fix = union(enum) {
    /// Replace what the diagnostic's `span` covers with this name —
    /// the near-spelling match behind `did you mean …?`.
    rename: []const u8,
    /// Bind `name` by importing it, which puts the undefined name the
    /// diagnostic reports into scope.
    import: Import,
    /// Remove the import the diagnostic's span sits on, line and all.
    /// Carries nothing: the line to drop is the one reported.
    remove_import,

    /// The import a `Fix.import` asks for.
    pub const Import = struct {
        /// The module to take the name from, written as a `use`
        /// spells it: a bare name for the stdlib, a quoted path for a
        /// file.
        module: []const u8,
        /// The name to bind, as the target module declares it.
        name: []const u8,
    };
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
    /// What the checker decided would fix this diagnostic, when it
    /// decided anything.
    ///
    /// The same correction the `help` text spells into a sentence,
    /// kept structured rather than only as prose. A tool offering to
    /// apply it would otherwise have to parse it back out of English,
    /// and the checker already worked it out.
    fix: ?Fix = null,
    /// Annotated context spans (e.g. annotation declarations,
    /// prior definitions). Empty for diagnostics that don't need
    /// secondary context. Per spec §4.x rendering rules:
    /// same-line secondaries draw on the primary's caret line +
    /// stack labels under it; cross-line secondaries emit their
    /// own `--> path:line:col` excerpt block.
    secondary: []const SpanLabel = &.{},
};
