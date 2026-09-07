---
bump: minor
---

feat(wasm): a `wasm32-freestanding` module with a C-ABI boundary

`zig build wasm` produces `gero.wasm` — the surface browser hosts call
(`docs/gero-lab.md` §2). Freestanding rather than wasi: the consumer
wants a narrow purpose-built surface, not a POSIX shim.

This ships the two conventions every later export depends on. Memory
crosses as `(ptr, len)` into a module-owned bump arena reset per
operation, where a pointer is an offset from the arena's base — uniform
across wasm32 and the 64-bit host the tests run on. Results come back
as five little-endian `u32`s at fixed offsets, decodable with no schema.

Exhaustion is reported rather than trapped: a host raises its ceiling
and retries instead of meeting an instance that has to be discarded.

The diagnostic JSON shape moves into the library as
`gero.diagnostics_json`, so `gero check --format=json`, the language
server, and the module all emit the same objects. An error's wording,
code, and span are now identical in a terminal and in a browser by
construction rather than by review.
