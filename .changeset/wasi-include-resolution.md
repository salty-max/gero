---
bump: patch
---

`include` and `use` resolve on wasm32-wasi. Both front-ends
canonicalized a path with `realpath`, which wasi does not have — it
returns `OperationUnsupported` there — so a wasi `gero` could compile a
single file and nothing that imported another.

Canonicalization now follows what the target can do: the filesystem's
answer where there is one, lexical normalization on wasi. Two paths
that reach one file through a symlink read as two files on wasi only;
everywhere else aliasing is still detected.
