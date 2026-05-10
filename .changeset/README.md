# Changesets

Every PR with a user-visible change drops a markdown file here.

## Format

`.changeset/<random-hex>.md`:

```markdown
---
bump: patch | minor | major
---

Human-readable summary for the CHANGELOG.
```

## Workflow

- `zig build changeset` — scaffold a new changeset interactively
- `zig build version` — consume every pending changeset, bump
  `build.zig.zon`'s version, and prepend a CHANGELOG.md section

## When to add

**Add one** for: `feat`, `fix`, `perf`, breaking refactor, or anything
that affects published API or runtime behavior consumers will notice.

**Skip** for: `chore`, `docs`, `test`, `refactor` (internal-only),
`ci`, `build`, `style` — the `changeset-check` workflow auto-skips
these.

When in doubt, add one. They're cheap and easy to delete.
