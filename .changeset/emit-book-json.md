---
bump: patch
---

`zig build wasm` now packs The Gero Book into `book.json` beside
`samples.json`, so the lab can fetch the chapters rather than vendor
them. Front matter and chapters 1–4 are the current contents; a
chapter added under `docs/book/` is included without a build change.
