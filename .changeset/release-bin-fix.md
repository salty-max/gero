---
bump: patch
---

Release tarballs now ship the `gero` CLI binary. v0.1.0 artifacts
shipped `zig-out/lib/libgero.a` only — the executable was built but
not copied into the dist archive, so the GitHub Release tarballs were
unusable end-to-end. The packaging step now copies `zig-out/bin/`
alongside `zig-out/lib/` and `zig-out/include/`.
