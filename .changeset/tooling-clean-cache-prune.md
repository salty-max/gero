---
bump: patch
---

`zig build clean-cache` prunes stale Zig build outputs without a full
wipe. Zig content-hashes every output into `.zig-cache/o/<hash>` and
never reclaims old ones, so a cross-target / multi-mode workflow
(`zig build ci` — 4 release modes × 5 targets) grows the cache without
bound across commits; left alone it reaches tens of GB.

The new step (`scripts/clean-cache.sh`) drops only output dirs not
modified in the last `MAX_AGE_DAYS` (default 3), leaving the warm
working set intact — so the next build is *not* cold, unlike the
existing full-wipe `zig build clean`. A pruned output is just a cache
miss; Zig rebuilds it on demand. Override the window with
`MAX_AGE_DAYS=N zig build clean-cache`, or point a scheduled job at the
script for hands-off upkeep. Documented under "Cache maintenance" in
`docs/development.md`.
