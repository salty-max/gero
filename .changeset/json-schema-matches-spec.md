---
bump: minor
---

`gero check --format=json` emits its documented schema.

The report had drifted from `lang-diagnostics.md` §9, the contract
editors and CI consume. It wrote the help text under `note` where the
spec says `help`, and omitted `span` and `notes` entirely — so a
diagnostic's byte range and its secondary spans never reached a
machine-readable consumer at all.

The key is now `help`, from both front-ends. `span: {start, end}`
carries the range as byte offsets, and `notes` carries one entry per
secondary span, each located in its own file. `suggestion` joins them:
the name `help` names, kept as itself, so a tool can apply the fix
without parsing English.

`end_line` / `end_col` shipped but were never documented; §9 now
describes them rather than dropping fields consumers may rely on, and
says which fields are always present versus conditional.

Breaking for anything reading `note` from the JSON report.
