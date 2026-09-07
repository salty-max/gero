---
bump: patch
---

Release versions below 1.0 now shift one place right: a breaking
change moves the minor, everything else moves the patch. `zig build
version` previously took a `bump: major` changeset straight to
`1.0.0` regardless of the current version, so a release would have
declared the API stable by arithmetic rather than by decision. The
script can no longer produce `1.0.0` at all — at `0.9.3` a breaking
change gives `0.10.0`. CHANGELOG headings still follow the level each
changeset declared.
