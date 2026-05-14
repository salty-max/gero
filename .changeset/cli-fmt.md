---
bump: patch
---

`gero fmt <file.gas | dir>` ships — canonical formatter for `.gas`
source. Parses each file directly (no include resolution → `include
"..."` lines round-trip verbatim), re-emits through the v0.2 asm
printer, compares against the source, and either rewrites in-place
or reports diffs.

Modes:

- Default — rewrite each file in place if not canonical. Per-file
  `✓ <path>` (unchanged) / `↻ <path> (reformatted)` line.
- `--check` — non-destructive. Exits 8 on any would-reformat (CI
  gate use case).
- Directory positionals recurse for `*.gas`. Multi-path mixing
  files and dirs works (`gero fmt a.gas b.gas src/`).

Exit codes per cli.md §3.8 + §5: `0` clean, `8` `--check`-and-
would-modify, `3` genuine parse error, `1` host IO, `2` usage.
`.gr` sources stub "not yet implemented" until v0.3.
