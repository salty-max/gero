---
bump: minor
---

`str.format_into(dst, fmt, args…) -> u16` formats into a buffer the
caller owns and returns the byte count written, excluding the
terminator. It allocates nothing.

The heap never reclaims — `sys alloc` bumps a cursor and there is no
`free` and no collector — so the allocating `str.format` cannot survive
a game loop. Roughly 700 short formatted strings exhaust the default
heap, about twelve seconds at 60 fps for a cart that draws its score
each frame. `format_into` is the form that loop wants.

`gero-lang.md` gains §5.4, which states the lifetime rule plainly and
lists what allocates and what does not. The heap-exhausted fault now
names the fix rather than only the symptom.
