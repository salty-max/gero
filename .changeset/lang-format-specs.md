---
bump: minor
---

`$(expr:fmt)` format specs (§3.2.2) now lower. The compiler parses the
spec — `[[fill]align][0][width][.precision][type]` — at compile time and
formats the value through the new `format_spec_to_buf` syscall: width,
left / right / center alignment, fill (incl. zero-pad, sign-aware for
negatives), precision, and the type letters `d x X b o s c` (decimal,
hex lower / upper, binary, octal, string, char). Works in both `let s =
"…"` (heap buffer) and `print "…"`. Previously any spec was a hard
compile error.

The typechecker validates each spec against the value's type: a
malformed spec, a spec on a non-scalar, or a type letter / precision
that doesn't fit the value (e.g. `s` on an integer) is the new
`E_TYPE_BAD_FORMAT_SPEC`.
