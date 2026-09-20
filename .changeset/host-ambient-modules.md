---
bump: minor
---

`resolveUseImportsVirtualAmbient` and `resolveUseImportsFromAmbient`
resolve a module the entry imports without saying so, for a host that
hands a program an environment rather than making it import one. The
module's exports are in scope unqualified, and a name the entry
declares itself wins silently — which a prelude of top-level `def`s
cannot do, since it collides instead.
