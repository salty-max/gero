---
bump: patch
---

A module whose file does not end in a newline no longer runs into the
file fused after it. Its last line joined the next module's first, and
the syntax error that produced was reported against the importing
file, which did not contain it.
