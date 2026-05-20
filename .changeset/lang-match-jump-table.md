---
bump: minor
---

`match` on a nullary enum scrutinee now lowers to a jump table
indexed by tag byte (spec §4.8.5 "single-arm tag dispatch") when
every arm is a bare `EnumName.Variant` and no guard is present.
Trailing `_` / ident wildcards remain supported as the default
target for unmapped tags. Mixed-shape matches (guards, payload
binders, OR-patterns, literal arms) keep the existing sequential
cmp-chain. Exhaustiveness checking also extends to `bool` —
`match` on a bool scrutinee must cover both `true` and `false`
(or carry a wildcard), and redundant arms emit
`E_MATCH_UNREACHABLE_ARM`. Closes #195.
