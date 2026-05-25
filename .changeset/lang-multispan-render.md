---
bump: minor
---

`Diagnostic` now carries a `secondary: []const SpanLabel` slice
for the annotated context spans the spec mockups in
`docs/lang-diagnostics.md` §5.2 / §5.3 / §5.9 describe — same-
line secondaries draw a `---` underline under the source line
plus a stacked `|` pointer + label below; cross-line secondaries
get their own `--> path:line:col` excerpt block under the
primary. Decoration enum (`.underline` / `.point`) picks dashes
vs carets per span.

Three typechecker sites attach the new shape per the issue:

- `E_TYPE_MISMATCH` on `let x: T = …` — annotation span as the
  secondary, label `"expected \`T\` because of this annotation"`.
- `E_TYPE_REDEFINED` — prior decl span as the secondary, label
  `"previous definition here"`.
- `E_TYPE_UNDEFINED_FIELD` — the type's declaration span as the
  secondary, label `"type \`T\` defined here"`.

Other diagnostics keep an empty `secondary` slice — existing
behavior is unchanged. Closes #254.
