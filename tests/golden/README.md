# Golden bytecode corpus

One blessed `.gx` per program in `examples/asm/` and `examples/lang/`.
`zig build golden` recompiles each and compares; `zig build
bless-golden` rewrites them.

These files exist because nothing else notices a codegen change that
alters emitted bytes while leaving behavior intact. The example gates
assemble, type-check, run, and diff stdout — all of which stay green
through an accidental ABI change.

**What is compared**

- The header, base image, and bank pool, **byte for byte**. These are
  the bytes a VM executes.
- The debug section by **content**, not bytes: symbol order is an
  emission detail and reordering alone must not fail the gate, while a
  changed symbol or line-table row must.

**Do not re-bless to clear a red gate.** Find out which change moved
the bytes first, and say so in the PR. A diff here is either a
deliberate codegen improvement or the regression the corpus was added
to catch, and telling them apart is the whole point.
