---
bump: minor
---

fix(lang): newlines are insignificant inside a bracket group

§2.1 documented parentheses as the way to break a long expression
across lines, and gave this example:

```
let total = (
  player.hp +
  player.mp
)
```

It did not parse. Newlines were skipped only at the specific points
the list parsers call `skipNewlines` — right after an opening bracket
and around commas — so comma-separated lists wrapped but expressions
did not. `(a +⏎ b)`, `(a + b⏎)` and the example above all failed, and
since §2.1 also rules out trailing-operator continuation, there was no
way at all to break a long expression across lines.

The parser now tracks how many bracket groups the expression parser
has open and skips newlines while inside one, so §2.1's sentence is
true as written rather than at a few call sites.

A block nested inside a group keeps its own statement boundaries:
`parseStatement` zeroes the depth for the body it parses, so the
statements in `(do … end)` still need separate lines and
`print 1 print 2` in there is still an error.
