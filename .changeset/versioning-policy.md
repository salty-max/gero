---
bump: patch
---

docs: a bytecode versioning policy

`isa.md` §10 stated the rule in two sentences — additive bumps the
minor, breaking bumps the major — which is correct and too little to
act on. `docs/versioning.md` says which concrete edits land on which
side, with worked examples drawn from this repository's own four
format versions rather than hypotheticals.

It settles three things that were genuinely open:

- What the version field governs. It is a promise about *execution*;
  debug-section changes are additive only when an older reader detects
  them rather than silently misreading.
- That tightening a validity rule is breaking unless every file that
  could exist already satisfies it — the case that looks additive and
  is not.
- That fixing an implementation to match the spec is not a format
  change, however visible the fix.

Also removes a drift: `loader.version_target` was a second hand-kept
copy of the format version and had fallen a version behind what
producers stamp. It now reads from `gx.version`, with a test pinning
them together.
