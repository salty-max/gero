---
bump: minor
---

`gero.lang.tokenize` lands — knit-driven `.gr` lexer that ships
37 reserved keywords, identifiers, `@`-annotations, integer
literals (decimal / hex / binary with underscore separators and
operand-position-aware negative sign), char literals (`'A'` →
u8 byte, mirroring asm's `'A'`), strings with `$( … )`
interpolation (paren-depth tracked across nesting), `--` line
comments (disambiguated from `--` decrement by leading
whitespace), every binary / comparison / bitwise / shift / range
operator, `++` / `--` as statement-only increment / decrement,
and multi-error recovery via `core.ParseError`. First brick of
the gero-lang compiler frontend.
