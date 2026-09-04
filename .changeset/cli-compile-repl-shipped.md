---
bump: patch
---

`gero compile` is no longer advertised as unimplemented. The command
has been wired end-to-end since #198, but `commandIsImplemented`
still reported it as planned, so `gero compile --help` printed
"Not yet implemented in this build" and `gero --help` filed it under
the planned section. It now carries a real help arm with usage,
examples, and the output-path precedence rule.

Three flag signatures in the per-command FLAGS block advertised a
short form that never parsed: the value-taking short flags accept a
following argument (`-o out.gx`), not an inline `=` (`-o=out.gx`).
`--out`, `--optimize`, and `--color` now render as
`--out=<path> / -o <path>`, showing the form that works for each.

`docs/cli.md` §4 listed `gero compile` and `gero repl` as not shipped
while §3.13 documented the REPL in full from inside that same
section; §3.13 moves into subcommand order and both rows are gone.
The two remaining rows that blamed the missing gero-lang compiler
(`bench`, `lsp`) now name what they actually wait on.

README picks up `gero compile` and `gero repl`, notes that `gero fmt`
covers `.gr` as well as `.gas`, links `examples/lang/`, and stops
describing the gero-lang spec as a draft for an unimplemented
compiler.
