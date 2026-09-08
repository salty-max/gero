---
bump: patch
---

fix(wasm): `gero_files_clear` no longer hands the file set's storage out twice

A host replaces the whole virtual file set on every build, so
`gero_files_clear` runs constantly. It emptied the map with
`clearRetainingCapacity` and then rewound the store's bump cursor to
zero — leaving the map holding memory the next `gero_file_put` was
about to write a source buffer into. The buffer overwrote the live hash
table, and the next lookup indexed into it.

The damage needed several rounds to surface, since the first buffers
land below the metadata. A browser host driving a dozen builds through
one module met `memory access out of bounds` — a trap, from a module
whose whole point is reporting a status instead of dying.

The set gives up the map's storage on clear, so nothing survives the
rewind that could be aliased by what comes after it.
