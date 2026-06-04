---
bump: minor
---

`gero check` now validates every `.gr` file end-to-end, not just ones
with a `main`. It resolves `use` imports and runs codegen in a new
validation mode (`compile` gained `require_entry`), so a library file
with no entry point still has its bodies lowered and its codegen-only
errors surfaced at check time instead of only at `gero compile`.

A `use` that can't be resolved (missing / cyclic file) is now a check
diagnostic too. The `docs/examples` tours that import an illustrative,
unshipped `./io` module are marked `gero-example: fmt-only` accordingly.

For a multi-file check, each diagnostic is attributed back to the
original source file (via the fused source map) — an error inside an
imported file renders against *that* file's path, line, and excerpt,
not the fused buffer's.
