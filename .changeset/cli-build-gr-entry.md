---
bump: minor
---

`gero build` compiles `.gr` projects. It previously ran the asm
pipeline unconditionally, so a `gero.toml` with
`entry = "src/main.gr"` fed gero-lang source to the assembler and
failed with parse errors. The entry's extension now picks the
front-end: `.gr` runs the gero-lang pipeline and resolves the `use`
graph from that file, anything else runs the asm pipeline and its
`include` directives.

Both paths share `gero compile`'s pipeline, so a diagnostic reads
identically whether it surfaced from `gero compile` or `gero build`,
and the artifact still lands at
`<out>/<optimize>/<[build].name ?? [package].name>.gx` — the entry
file's own stem never names it.
