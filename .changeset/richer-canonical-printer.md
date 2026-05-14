---
bump: patch
---

`gero fmt` graduates to a richer canonical form — trailing
comments stay **inline** with their host (no more demote-to-
standalone), padded to column 32 by default for vertical
alignment across a block. Three additional knobs in
`PrintOptions`:

- `comment_column: usize = 32` — column the trailing `;` lands
  on (0 disables alignment, single-space inline fallback)
- `align_kv: bool = true` — align the `=` column of consecutive
  `const` / `data8` / `data16` decls to the block's longest name
- `hex_case: HexCase = .upper` — `$ABCD` / `&FFFF` re-emitted
  from the parsed `u16` value with `upper` / `lower` / `preserve`
  case policy. Only applies to direct `HexLit` / `AddrLit` nodes;
  literals nested inside compound expressions still source-slice.

Per-project overrides via a `gero.toml [fmt]` section land in a
follow-up sub-issue (depends on the manifest parser).
