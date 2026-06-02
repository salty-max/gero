---
bump: minor
---

Pattern destructuring now lowers at every binding site — `let`, `if let`,
`while let`, and `match` arms share one matcher.

`let` binds an irrefutable pattern: `let (a, b) = pt`, `let Pos { x, y } =
p`, and a single-variant `let Wrap.Of(n) = w`. A refutable pattern in a
`let` (a literal / range / or-pattern, or a multi-variant enum) is a
compile error (`E_TYPE_REFUTABLE_LET`) — use `if let` / `match` for a
pattern that can fail.

`if let` / `while let` test any pattern in conditional / loop position,
binding on a match and skipping (running the `else`, or exiting the loop)
otherwise: `if let Event.Click(x, y) = e when x < 128`, `while let
Item.Potion(n) = inv.next()`. `when` guards run after the bind. Inline
binders (tuple elements, struct fields) alias the materialized scrutinee
slot; an enum payload — behind the value's `[tag | payload]` pointer —
loads into its own slot.

The destructuring matcher also gives `match` tuple and struct patterns
(`case (a, b) =>`, `case Player { hp, mp } =>`), which previously only
lowered enum-variant and literal arms.

Enum variants now carry aggregate payloads (`case At(Coord)`): the value
is stored inline in the `[tag | payload]` slot (the enum owns a copy, so
mutating the source can't change it), and `if let At(c) = loc` /
`if let At(Coord { x, y }) = loc` bind or further destructure it.

Payload / element / field binders are now typed from the matched value
(the variant's payload type, the tuple's slot type, the struct's field
type) rather than left untyped — `if let E.Hit(n) = e` gives `n` the
payload type, so the body type-checks under the strong-typing rule.
