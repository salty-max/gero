---
bump: minor
---

The typechecker now attaches a `help: did you mean \`X\`?` line
to `E_UNDEFINED_SYMBOL`, `E_TYPE_UNDEFINED`,
`E_TYPE_UNDEFINED_FIELD`, and `E_TYPE_UNDEFINED_METHOD` when a
known name is within Levenshtein distance 2 of the user's
spelling. No help line fires when no candidate qualifies — a
missing suggestion beats a misleading one.

The candidate pool varies per emission site: full scope chain
for symbols, registry-plus-primitives for type names, the
type's own field list (inheritance-walked for classes) for
fields, the class's method list (inheritance-walked) for
methods.

`tc_suggestions` (Levenshtein + bestMatch helpers) lives under
`gero.lang.internal.typechecker.suggestions` — same `internal.*`
seam pattern as the other typecheck sub-modules. Closes #257.
