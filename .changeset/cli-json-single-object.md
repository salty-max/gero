---
bump: minor
---

`gero check --format=json` now emits what cli.md §3.9 documents: one
JSON object, with every diagnostic in its `diagnostics` array. A `.gr`
diagnostic previously trailed the object as a separate NDJSON line
under different field names, so the object reported `files_failed: 1`
beside an empty `diagnostics` array and `JSON.parse(stdout)` — the
documented editor integration — threw on the second line. Both
front-ends now report into the same array, with `.gr` diagnostics
carrying `end_line` / `end_col` for the span they cover.

`gero.lang.render.json` is removed; it wrote the trailing-lines shape
and has no remaining caller.
