---
bump: patch
---

A subcommand refuses a flag it does not take, instead of ignoring it.

The parser resolved flag names against one table for the whole CLI, so
every flag parsed under every subcommand and was then silently dropped
by any command that did not read it. `gero init --lang=gr` exited 0
having scaffolded an *asm* project — the flag is a reasonable guess for
"scaffold a gero-lang project", and the user got the opposite with no
signal. The same held for `gero check --stdin`, `gero disasm --lang=gr`
and every other cross-subcommand pairing.

Each is now a usage error naming both the flag and the subcommand:

```
error: --lang=gr is not a flag for `gero init` — run `gero init --help` for the ones it takes
```

Nothing is scaffolded, written, or run before the refusal.
