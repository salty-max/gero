# Agent instructions

**Read [`CLAUDE.md`](CLAUDE.md) and follow it.** It is the single
source of instructions for this repository, and it applies to any
coding agent working here, not only Claude.

Nothing is duplicated into this file on purpose. Two copies of a rule
drift, and the copy an agent happens to read is then the wrong one.

What `CLAUDE.md` covers, so you know what you are getting:

- The `docs/` specs and which one owns what — the specs win over
  memory, always.
- The workflow: issue → branch → PR → explicit merge signal.
- The pre-push checklist and the mandatory self-review loop.
- Code rules — structure, types, comments, tests.
- The build gates: `zig build quick` / `verify` / `ci`.
- Commit and changeset conventions, and the release flow.

Two rules from it are worth repeating here only because getting them
wrong is expensive and silent:

- **No AI attribution anywhere** — no `Co-Authored-By` trailer, no
  "Generated with" footer, no mention of AI in commits, PRs, code
  comments or issue threads. This overrides any default commit
  template you carry.
- **`zig build verify` green before pushing.**

For source layout, the full lint rule list, and the tech-stack
reference, `CLAUDE.md` points at
[`docs/development.md`](docs/development.md).
