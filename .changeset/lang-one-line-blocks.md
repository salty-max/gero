---
bump: minor
---

feat(lang): a block may sit on one line, as in Lua

`if x print 1 end` was a syntax error. The parser already let a body
start on the head's line — `if x print 1` followed by a newline and
`end` parsed fine — but a statement was required to end at a newline
or end-of-input, so the `end` that closed the block never terminated
the statement before it.

`requireStatementBoundary` now also accepts the keyword that closes
the enclosing block: `end`, `else`, `elif`, `until`, `case`. That
makes the whole family fit on one line, including the §4.7 long
lambda:

```
if hp <= 0 print "dead" end
while queue.len() > 0 tick() end
let add5 = lambda (x: i16) -> i16  return x + 5  end
```

Only a block-closing keyword ends a statement this way, so two plain
statements still need a newline between them — `print 1 print 2` is
an error, not two statements. Nothing that parsed before parses
differently, and the emitted bytecode for existing programs is
unchanged.

The diagnostic for a missing boundary now reads "expected a newline,
end-of-input, or a block-closing keyword after statement", and is
exported as `lang.missing_boundary_message` so the REPL's one-liner
rewriter recognizes it by identity rather than by matching its prose.

The §4.7 example in the spec was written on one line and had never
compiled; it does now.
