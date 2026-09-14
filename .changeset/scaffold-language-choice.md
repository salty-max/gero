---
bump: minor
---

`gero new` and `gero init` scaffold either language.

Both laid down an asm project and offered no way to ask for a Gero
one, though the rest of the toolchain has been bilingual for a while:
`gero build` picks its front-end from `[build].entry`'s extension and
`gero test` walks a project for both kinds. Writing a `.gr` project
meant scaffolding asm and rewriting it by hand.

`--lang=<gas|gr>` settles it. Run from a terminal without the flag,
the command asks; with no terminal to ask — a pipe, a CI step — it
exits 2 and names the flag rather than picking. A project is one
language or the other for its whole life, so a default would be the
one answer nobody chose.

The Gero scaffold ships `src/main.gr` and a `tests/smoke.gr` holding
a `@test` def, and no `.expected`: `gero test` judges a `@test` by
its own assertions where a `.gas` golden is diffed against captured
stdout. Both scaffolds pass `gero check`, `gero fmt --check` and
`gero test` the moment they are written.

`[build].entry` stays the only place a project's language is
recorded. Two places to say the same thing is two places to
disagree.

**Breaking**: `gero new <name>` and `gero init` with no `--lang` now
exit 2 when stdin is not a terminal, where they used to scaffold asm.
A script that relied on the old default needs `--lang=gas`.
