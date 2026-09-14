---
bump: minor
---

Completion after a `.` offers the receiver's members.

It previously offered whatever was in scope, which is worse than
offering nothing: none of it can legally follow a dot. The type-checker
now exposes `CheckedProgram.members` — every struct field, class field
and method, and enum variant — and the receiver's type picks the set. A
container named directly (`Colour.`) offers its own members; a value
(`p.`) offers its type's.

The parser recovers from a trailing dot instead of stopping there. An
incomplete member access is precisely what a buffer holds at the moment
completion is requested, so `p.` now parses as a member access with an
empty name: still reported as the error it is, and still producing a
tree that types the receiver. Before this, asking for completion after
a dot also lost every local in the enclosing function, because the
parse stopped.

A class scope now carries its own range, so a method is no longer
offered where a free function would go. Suggesting `hurt` at module
level is a suggestion that cannot be acted on.
