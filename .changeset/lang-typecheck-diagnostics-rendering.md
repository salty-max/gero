---
bump: minor
---

Eighth (final) slice of the gero-lang typechecker. Lands the
diagnostic rendering pipeline documented in
`docs/lang-diagnostics.md` and wires `gero check` to handle `.gr`
files end-to-end.

**Rich `Diagnostic` shape**

New `src/lang/diagnostic.zig` defines the canonical lang
`Diagnostic` carried through the front-end:

- `severity: Severity { fatal, warning, note }`
- `code: []const u8` — stable `E_TYPE_MISMATCH`-style identifier.
- `message: []const u8`
- `span: ast.Span` — full byte range, so the renderer can underline
  the offending source slice with as many `^` carets as needed.
- `help: ?[]const u8` — optional `help:` line printed after the
  caret snippet.

`CheckedProgram.diagnostics` changes type from
`[]core.ParseError` to `[]Diagnostic`. The typechecker's `emit`
helper is gone; everything goes through `emitSpan(code, span, msg)`
(or `emitSpanHelp` for the rare diagnostic that ships actionable
guidance).

**Rendering**

New `src/lang/render.zig` exposes:

- `pretty(writer, []FileDiagnostics, Style)` — Cargo-style
  per-file grouped output with summary header
  (`3 errors in 2 files`), per-file path section, and the spec
  layout (severity prefix + `[code]` + `--> path:line:col` +
  excerpt with line-number gutter + `^^^` caret line + optional
  `help:` block).
- `prettyOne(writer, FileDiagnostics, Style)` — same body, no
  per-file header (single-file mode).
- `json(writer, []FileDiagnostics)` — line-delimited JSON, one
  object per diagnostic, matching the schema in the diagnostics
  doc.
- `Style.none` / `Style.ansi` for plain vs colorized output.
- `LineCol` + `lineColAt` + `lineAt` helpers (also used by the
  CLI to format read-error fallback messages).

**`gero check` wiring (`.gr` end-to-end)**

`apps/gero-cli/check.zig`:

- `collectGasFiles` → `collectSourceFiles` (now also picks up
  `*.gr` during directory walks).
- Per-file dispatch: `.gr` paths route through `checkOneGr` which
  reads + tokenizes + parses + (when parsing succeeds)
  typechecks, folds every parser / typechecker diagnostic into a
  unified `Diagnostic` slice, and renders via
  `gero.lang.render.pretty` / `.json`.
- Exit code remains `4` when any diagnostic fires across either
  pipeline (asm or lang).
- Mixed-extension input is handled: asm and lang diagnostics
  render in separate sections.

**Parser-side diagnostics (interim shape)**

The parser still emits human-prose messages via
`core.ParseError`. The CLI converts them to `Diagnostic` with
`code = "E_SYNTAX_GENERIC"` at the rendering boundary so the
output is uniform. Per-error stable codes
(`E_SYNTAX_UNEXPECTED_TOKEN` / `…_MISSING_TOKEN` / etc.) stay a
follow-up — the rendering pipeline is the load-bearing piece and
codes can be wired through later without changing the renderer.

**Public surface**

Three new re-exports on `gero.lang`:

- `gero.lang.Diagnostic` (struct)
- `gero.lang.Severity` (enum)
- `gero.lang.render` (module — `pretty`, `prettyOne`, `json`,
  `Style`, `FileDiagnostics`, `LineCol`, `lineColAt`, `lineAt`)

`CheckedProgram.diagnostics` is the only breaking change: its
element type went from `core.ParseError` to `Diagnostic`. Tests
that scanned `d.expected` now scan `d.code`.

**Tests**

- 7 new tests in `tests/lang/render.test.zig` covering pretty +
  JSON for single-diagnostic, with-help, with-warning-severity,
  empty input, and the `lineColAt` / `lineAt` math.
- 1 stub test in `tests/lang/diagnostic.test.zig` pinning the
  mirror-layout rule.
- All 148 existing typechecker tests pass against the new
  `Diagnostic` shape.

**Out of scope (future work)**

- Parser-side `E_SYNTAX_*` code retrofit — separate follow-up
  issue.
- Multi-span diagnostics (the spec mockup has secondary spans
  with their own labels — "expected because of this annotation"
  etc.). The current renderer prints one span per diagnostic.
- `--quiet` / `--no-color` flag plumbing on the CLI (the renderer
  honors `Style.none` already).
