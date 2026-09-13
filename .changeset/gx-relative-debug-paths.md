---
bump: minor
---

A `.gx` records source paths relative to the entry file, not absolute.

The debug section stored the absolute path each source was read from,
so the same sources built in two checkouts produced different bytes.
That costs a build its reproducibility and puts the builder's directory
layout inside anything shipped — `tests/golden/asm-hello.gx` on `main`
contained a scratch worktree path from one machine.

Paths are now relative to the entry file's directory, with `/` as the
separator on every host, so an image built on Windows matches one built
anywhere else. A file outside that directory climbs out with `..`; a
virtual file set addressed by embedder-chosen keys stores those keys
unchanged, which is what a browser host already supplied.

A consumer resolves the stored path against the source tree it has,
which is the tree the reader is looking at — so a debugger keeps
working, and keeps working in a clone the image was not built in.

`docs/isa.md` §7.3 states the contract. The golden corpus is re-blessed
once to drop the absolute paths it carried, and its check now compares
recorded paths: two images with matching line rows and different paths
point at different sources, and nothing was catching that.
