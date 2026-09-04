---
bump: minor
---

`gero fmt` no longer deletes comments inside `struct` bodies. Every
`;` comment in a struct block was dropped on format — trailing a
field, standalone between fields, on the opening-brace line, and
between the last field and `}`. Since `gero fmt` rewrites in place
and ships in the lefthook pre-commit hook, formatting a file
destroyed those comments with no diagnostic and exit 0.

The loss started at the parser: `StructField` had nowhere to record
a comment, so the struct-body separator skip discarded each one
before the printer ever saw it. `StructDecl` gains `open_comment`
and `tail_comments`; `StructField` gains `leading` and `trailing`.
All four default to empty, so existing construction sites are
unaffected. `writeStruct` emits them, aligning trailing comments to
`PrintOptions.comment_column` like every other host line.

Also fixes a formatter idempotence bug surfaced while gating the
example corpus: a `reserve N` value's span ran to the parse cursor
rather than the end of its count expression, so it swallowed the
blanks before a trailing comment. The printer re-emitted those
blanks and then padded on top, pushing the comment one column right
on every pass — `gero fmt` never reached a fixed point on a `data8
… reserve` line with a trailing comment, and `gero fmt --check`
could never go green on one.

`docs/examples/syntax_overview.gas` is canonical again (its struct
comment intact, assembled bytes unchanged), and
`fmt-check-examples.sh` now walks `docs/examples` alongside
`examples/asm` — no gate covered that directory's formatting
before, which is how the drift went unnoticed.
