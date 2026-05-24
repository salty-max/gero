---
bump: minor
---

`gero check --werror` escalates warning-severity diagnostics to
a fatal exit code (4). Without the flag, warning-only files now
print their diagnostics but exit `0` — previously every
diagnostic, regardless of severity, escalated to exit 4 because
the check loop didn't distinguish severities for `.gr` files.

The lang-side summary header now names severities honestly:
`N warnings in M files` for warning-only reports,
`N errors + M warnings in K files` for mixed reports, and the
existing `N errors in M files` for fatal-only reports.

Asm-side diagnostics have no warning severity today, so
`--werror` is a no-op for `.gas` inputs (documented in cli.md
§3.9). Closes #255.
