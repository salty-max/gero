---
bump: minor
---

`gero fmt --stdin` and `gero check --format=json` ship — two
small CLI surfaces that unblock first-class editor integration
**without** needing the LSP server.

## `gero fmt --stdin`

Read source from stdin, write canonical-formatted bytes to
stdout. Standard editor format-on-save pattern (gofmt, `rustfmt
--emit=stdout`, `black -`).

```bash
cat main.gas | gero fmt --stdin           # → canonical output
cat main.gas | gero fmt --stdin --check   # exit 8 if non-canonical
```

- Mutually exclusive with positional paths (`--stdin foo.gas` →
  exit 2 with usage message).
- Manifest `[fmt]` overrides are not consulted — no project root
  context. Compile-time defaults apply.
- Parse errors render plain `<line>:<col>: <message>` on stderr,
  exit 3. No file-path prefix (there's no file).
- `--check` mode: exit 0 silent if canonical, 8 silent otherwise,
  no stdout written.

## `gero check --format=json`

Emit a single JSON object to stdout (instead of the caret-style
human report). Stable schema for editor integration.

```bash
gero check --format=json src/      # one JSON object covering every file
```

```json
{
  "version": 1,
  "diagnostics": [
    {
      "file": "src/main.gas",
      "line": 12,
      "column": 5,
      "severity": "error",
      "code": "E004",
      "message": "undefined symbol"
    }
  ],
  "files_checked": 4,
  "files_failed": 1
}
```

- `code` omitted for syntax errors without an E-code.
- `note` omitted when absent.
- Exit codes preserved from `human` mode (0 / 4 / 1 / 2) — editors
  branch on exit code, then `JSON.parse(stdout)`.
- Stderr is reserved for host I/O failures (file missing).

## Why now

The LSP server (#122) blocks on the gero-lang front-end, which
won't ship for several minor versions. `fmt --stdin` +
`check --format=json` give editors enough surface to wire
**format-on-save** and **inline diagnostics** through plain pipe
plumbing — no protocol, no daemon. Same idiom every major
editor already supports for gofmt / prettier / black.
