---
bump: minor
---

feat(editors): both tree-sitter grammars ship a browser build

`web-tree-sitter` loads a prebuilt `.wasm`; it cannot compile a grammar
the way a native editor does. Neither grammar shipped one — four
`tree-sitter-gero-asm` releases and `tree-sitter-gero-lang` v0.1.0 all
carried the grammar and no browser artifact — so no browser consumer
could load either.

Both now build it in CI on tag, smoke-test that it loads and parses,
and attach it to the release:

```
tree-sitter-gero-asm  v0.3.1+  →  tree-sitter-gero_asm.wasm
tree-sitter-gero-lang v0.1.1+  →  tree-sitter-gero_lang.wasm
```

Building on tag rather than by hand is the point: an asset that depends
on someone remembering is an asset that goes missing.

Fixing it surfaced that `tree-sitter-gero-lang`'s `npm install` failed
for everyone — the scaffold declared a native binding without
`node-addon-api` or `node-gyp-build`, so its CI had been red since the
first commit. `docs/tooling.md` §2.6 names both artifacts and their URL
shape.
