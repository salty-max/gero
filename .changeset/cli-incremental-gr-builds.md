---
bump: minor
---

`gero build` now caches `.gr` builds. A build records one entry per
module under `<build.out>/.cache/` — its content hash, its interface
hash, and the relocatable code it lowered to — and a later build does
only the work the record does not already cover.

A rebuild with nothing changed reports `(unchanged)` and stops after
reading the sources. A module whose own text changed is re-checked and
re-lowered. A module whose *interface* changed — anything it exports,
function and method bodies excluded — takes everything that
transitively imports it with it. A module whose body changed but whose
interface did not leaves its dependents' cached code alone, because
nothing they could have relied on moved.

Anything that makes the record untrustworthy — missing, corrupt,
written under a different format version, entry point, or optimize
mode — is treated as no cache, and the build runs in full. Deleting
the cache directory is always safe.
