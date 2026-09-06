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

Variadic call sites now record which module asked for each arity, and
specializations are emitted from the union of those sets at link time
rather than from a set accumulated program-wide during type-checking.
No module's specialization set depends on its dependents'.
`CheckedProgram.moduleArities` replaces `variadicArities`, and
`VariadicInfo` drops its `arities` field — the union is derived where
it is used instead of stored twice.

Codegen is also relocatable. Emission used to fold a buffer base into
the bytes as it wrote them, so a module's output depended on where it
sat; it now names positions — `CodeRef` for a symbol, `Relocation` for
a deferred address slot — and a link phase resolves them once the bases
are fixed. Emitted output is unchanged.
