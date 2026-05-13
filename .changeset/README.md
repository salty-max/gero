# Changesets

Every PR with a user-visible change drops a markdown file here.

## Format

`.changeset/<random-hex>.md`:

```markdown
---
bump: patch | minor | major
---

First paragraph — this is the CHANGELOG bullet. Hard line breaks are
collapsed into spaces. End it with a blank line.

Anything past the first paragraph is dropped from the CHANGELOG —
keep extra detail (motivation, design notes, follow-ups) in the PR
description, not here.
```

## Workflow

- `zig build changeset` — scaffold a new changeset interactively
- `zig build version` — consume every pending changeset, bump
  `build.zig.zon`'s version, and prepend a CHANGELOG.md section
  grouped by bump level (Breaking → Added → Fixed)

`zig build version` is mechanical: it produces a flat per-bump bullet
list. Edit the resulting CHANGELOG.md section by hand before
committing if the release deserves a narrative pass (sub-sections per
area, grouped highlights, deprecation callouts).

## When to add

**Add one** for: `feat`, `fix`, `perf`, breaking refactor, or anything
that affects published API or runtime behavior consumers will notice.

**Skip** for: `chore`, `docs`, `test`, `refactor` (internal-only),
`ci`, `build`, `style` — the `changeset-check` workflow auto-skips
these.

When in doubt, add one. They're cheap and easy to delete.
