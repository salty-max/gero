---
bump: patch
---

`src/asm/printer.zig` lands — the asm AST → canonical `.gas` text
re-emitter. Walks an `ast.Program` and emits a fixed layout (2-space
instruction indent, blank-line discipline around top-level decls,
canonical operand separators). Expression and operand contents are
sliced verbatim from `source` so literal forms (`$10`, `'A'`, `&FFFF`)
round-trip exactly; only the layout between statements is normalized.
The parser now surfaces `; ...` comments as first-class `Statement.
comment` nodes so the printer can preserve them — trailing comments
on the same line as a statement demote to standalone lines, then stay
stable across re-formats. Public API: `printProgram` + `PrintOptions`.
Foundation for the upcoming `gero fmt` subcommand.
