---
bump: minor
---

Type-checking is now per module. Each module sees its own top-level
declarations plus the exported ones of the modules it imports, and
nothing else — the enum, struct, class, and def registries became
per-module views swapped as the checker enters each module, rather
than one flat program-wide set.

Two consequences:

`local` now covers types, not just functions. A `local struct` or
`local enum` was still reachable from an importer because the type
registries were program-wide even after the scopes were split.

A dependency's *bodies* can no longer influence how a dependent
checks. A module's view holds declarations — signatures — so a body
edit is invisible across a module boundary. That is the property a
per-module build cache needs.

Variadic call sites now also record which module asked for each
arity. `CheckedProgram.module_variadic_arities` carries the
breakdown; the program-wide union stays the input to specialization,
taken once every module is walked.
