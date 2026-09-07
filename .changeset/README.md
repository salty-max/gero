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

## What each level means

`bump:` describes **the change**, not the digit it moves. Pick the
level that honestly describes what you did, and let the release script
work out the version:

- `major` — a breaking change. An existing program, `.gx`, or API call
  stops working or starts behaving differently.
- `minor` — a new capability that breaks nothing.
- `patch` — a bug fix, or anything else consumers notice that fits
  neither of the above.

Below 1.0 those shift one place right when a release is cut: `major`
moves the minor, `minor` and `patch` move the patch. So a breaking
change today takes `0.2.0` to `0.3.0`, which is what semver means by a
0.x release promising nothing. The CHANGELOG still files it under
**Breaking** — the heading follows what you declared, not the digit.

Reaching `1.0.0` is a deliberate decision, never arithmetic. The
release script cannot produce it: at `0.9.3` a `major` changeset gives
`0.10.0`.

## When to add

**Add one** for: `feat`, `fix`, `perf`, breaking refactor, or anything
that affects published API or runtime behavior consumers will notice.

**Skip** for: `chore`, `docs`, `test`, `refactor` (internal-only),
`ci`, `build`, `style` — the `changeset-check` workflow auto-skips
these.

When in doubt, add one. They're cheap and easy to delete.
