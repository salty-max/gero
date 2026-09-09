---
bump: patch
---

A virtual file set resolves its includes the same way on every host.
`include` and `use` joined paths with the host's separator, so a set
whose keys are `banks/bank0.gas` resolved on Linux and macOS and missed
on Windows, where the join produced `banks\bank0.gas` — a key no set
contains. The browser was unaffected (wasm32 separates with `/`), but a
native Windows embedder using the overlay API saw every multi-file
program fail with "include target file not found".

Paths now follow the grammar the file set is addressed by: the host's
for files on disk, POSIX for a virtual set, on every platform.
