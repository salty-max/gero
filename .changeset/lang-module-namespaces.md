---
bump: minor
---

Each `.gr` file is now its own module namespace. Every reachable file
was fused into one buffer and type-checked as a single flat scope, so
two modules declaring the same top-level name collided:

```
error: `helper` is already defined in this scope [E_TYPE_REDEFINED]
```

That is a module system's job to prevent. Declarations now register
into the scope of the file that declares them, and a module sees its
own declarations plus those of the modules it `use`s. A local
declaration always wins over an imported one.

Codegen follows: a def name declared by more than one module gets a
module-qualified symbol, so each call reaches its own. Without it the
second registration overwrote the first and both call sites landed on
one address — a program that had been rejected outright would have
compiled to silently wrong code.

When two of a module's imports provide the same name, an unqualified
reference can't say which is meant; that is now
`E_TYPE_AMBIGUOUS_IMPORT`, pointing at `use <name> as <other> from
"..."`. Previously it was the redefinition error above.

`FusedSource` carries the module graph — one edge per `use`, recorded
even when the target was already fused through another path — and
`SourceMap` gains `fileIdAt` to map a fused offset back to its module.
