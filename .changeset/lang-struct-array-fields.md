---
bump: minor
---

fix(lang): a struct may carry an array field

`P { v: [1, 2, 3] }` raised `E_CODEGEN_UNSUPPORTED`. Array fields
worked everywhere else — declaring them, `a.v[0] = 5`, the same field
on a class, `sizeof` reporting the array inline — but the struct
literal itself had no case for one and fell through to a scalar store,
writing a register's worth over a field that is usually wider.

`FieldInfo` now records an array field the way it already recorded a
tuple one, and the three places that treat a field as inline rather
than register-width — literal materialization, field load, field store
— cover all three aggregate kinds through one predicate.

That also settles the equality gap left open by the previous release:
`struct ==` with an array field compared nothing and answered "equal"
for every input, so it was rejected outright. It compares element-wise
now, and the rejection is gone.
