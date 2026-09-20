---
bump: patch
---

`mem` members now resolve when called bare — ambient (§5.3.5) or
selectively imported. The module's signatures live in their own table
rather than the stdlib one, and only the qualified `mem.peek(a)` form
consulted it, so `poke(a, v)` after `use poke from mem` reported that
`mem` has no member `poke`.
