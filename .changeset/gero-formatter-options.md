---
bump: minor
---

The Gero printer takes formatting options, and `gero.toml` configures
both languages.

`gero fmt` on a `.gr` file ran a printer with no options at all:
indent was a hardcoded two spaces, and a project's `[fmt]` section
reached the assembler and nothing else. Setting `indent = 4` in
`gero.toml` did nothing to a Gero file.

`[fmt]` now sets a key for every printer that has it, and `[fmt.gas]`
/ `[fmt.gr]` override their own, so a project states its shape once
and refines only where the languages differ. Section names accept a
`.` so those sub-tables parse.

The Gero printer gains `indent`, `use_tabs`, `max_width`,
`hex_case`, `trailing_comma`, `bracket_spacing`, `wrap`, `sort_use`
and `newline` — the options a high-level language formatter is
expected to have, each with a counterpart in rustfmt, prettier,
Black or gofmt. `trailing_comma` governs the last element of a broken
form only; the separators between the others are grammar rather than
style. `wrap = "preserve"` keeps a construct the author spread across
lines, the way prettier's `objectWrap` does. `comment_column` and `align_kv` stay assembler-only:
Gero has no `const` block to align and does not column-align trailing
comments, which rustfmt and prettier do not either. `hex_case`
defaults to `preserve` for Gero against `upper` for the assembler — a
literal's case there often carries meaning the printer cannot see.

**Line wrapping.** The printer used to flatten every call and struct
literal onto one line however long it got, so a hand-written
multi-line literal came back as a single very long line. Calls, `def` parameters, struct literals and tuples all
wrap by one rule. A construct that fits within `max_width`
(default 100) still rides on one line;
one that does not breaks an element per line, each with a trailing
comma so adding one touches a single line. Widening `max_width`
collapses it back. The pass is idempotent, and nothing in the example
corpus reflows at the default.

A blank line after a comment block is also kept now. Every file
header used to be glued onto the first declaration below it, with no
way to separate them.
