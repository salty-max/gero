---
bump: patch
---

feat(cli): actionable messages for `.gx` load failures

A file the loader rejected reported the Zig error name and nothing
else — `invalid .gx file (UnsupportedVersion)` — which tells a user
neither what is wrong nor what to do. After a format freeze that is
precisely the message anyone gets when they open a cart built by a
newer toolchain.

Every `LoaderError` now renders a sentence, shared by `run`, `info`,
and `disasm` so the same file explains itself the same way:

```
gero run: built for .gx format 1.0, but this build supports up to 0.4
          — upgrade gero to open it
gero run: not a .gx file — it does not start with the `GERO` magic bytes
gero run: header declares a larger image than the file holds — it is
          truncated or corrupt
```

The wording separates a file from the *future*, where upgrading helps,
from one that is *wrong*, where it would not — so only the version
mismatch mentions upgrading. A test pins that distinction, and another
walks every variant of the error set to assert none leaks its own name.
