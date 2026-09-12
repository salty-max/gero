---
bump: patch
---

Accept correctly cased relative imports and assembly includes on Windows when the source path uses forward slashes and the filesystem returns backslashes. Compare path components without a directory-depth limit while continuing to reject case mismatches.
