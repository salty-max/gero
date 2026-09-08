---
bump: minor
---

feat(lang): a call's brackets must touch what they apply to

`foo (a, b)` parsed as a call, which meant a one-line block whose body
opened with a bracket was swallowed by its head — `if c (1, 2) else …`
called `c`.

The `(` opening an argument list and the `[` of an index must now be
attached to what they apply to:

```
foo(a, b)        -- a call
foo (a, b)       -- `foo`, then a parenthesized expression
grid[0]          -- an index
grid [0]         -- `grid`, then an array literal
```

That is the rule `--` already followed: attached to an operand it
decrements, detached it opens a comment. §2.1 claimed spaces were
insignificant within a line; it now names both exceptions.

Only the postfix forms are affected. Keyword-introduced parentheses —
`return (a, b)`, `case (a, b)`, `let (x, y) = …`, `sizeof(T)`,
`lambda (x) … end`, `@align(16)` — are unambiguous and may still be
spaced. Every `identifier (` in the repo was one of those, so no
existing code changes meaning, and a detached bracket where a call was
intended is a syntax error rather than a silent reinterpretation.
