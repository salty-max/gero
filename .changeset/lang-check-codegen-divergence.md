---
bump: patch
---

Three `gero check` / typecheck soundness fixes:

- `gero check <missing-path>` now prints a clean file-not-found
  diagnostic and exits 1, instead of laundering the error into
  `error.OutOfMemory` and dumping an internal Zig stack trace.
- An ordering comparison (`<` `<=` `>` `>=`) on an aggregate (struct /
  tuple / array / `Vec`) is now a type error (`E_TYPE_NOT_ORDERED`) at
  check time rather than a codegen-only `E_CODEGEN_UNSUPPORTED`.
  Aggregates still compare with `==` / `!=`; scalars (incl. `char`,
  `bool`, `str`) still order.
- A method call on a receiver with no methods — a scalar, `struct`,
  `enum`, tuple, or array value — is now `E_TYPE_UNDEFINED_METHOD` at
  check time rather than slipping through to a codegen failure. (A
  nullable class receiver narrowed to non-nil still resolves.)
