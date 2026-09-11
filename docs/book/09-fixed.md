# 9. Numbers that are not integers

Chapter 2 said there are no floats. Here is why that matters in
the fight, not just in the type list.

Ryu crits a quarter of the time. A quarter of 7 damage is the
question. Integer arithmetic answers it like this:

```gero
def main()
  let dmg: i16 = 7
  print dmg * 25 / 100
end
```

`1`. Seven times 25 is 175, divided by 100 truncates to 1. The
0.75 is gone. He hits for 1 when he should have hit for 1.75, and
the missing fraction is the difference between a kill and a
linger.

`fixed` keeps the fraction:

```gero
def main()
  let dmg: fixed = 7.0
  let rate: fixed = 0.25
  print dmg * rate
end
```

`1.750`. Two bytes, same as an `i16`: eight bits of whole number,
eight bits of 256ths. Adding two of them is one instruction.
Multiplying is a multiply and a shift — the compiler does the
shift; you write `*`.

The range is roughly -128 to +128. A position that walks off that
does not belong in a `fixed`. Keep the whole units in an `i16` and
let a `fixed` hold the leftover:

```gero
def main()
  let x: i16 = 200
  let sub: fixed = 0.8
  sub = sub + 0.35
  while sub >= 1.0
    sub = sub - 1.0
    x += 1
  end
  print x
  print sub
end
```

`201` and `0.152`. The 0.35 was not exact — a `fixed` is 256ths, and
0.35 is not a whole number of them — so the leftover is 0.152, not
0.15. That is the bite. Another two steps like it still carry into
`x`. That is how 8- and 16-bit games walked a map wider than 128
tiles without a float.

Use `fixed` for rates, scales, and anything that lives in
`[-1.0, 1.0]`. Use integers plus a unit you chose — tenths of a
percent, pixels, frames — when the range is the point.

---

**Next:** [Testing](10-testing.md) — pinning `heal` so it cannot
quietly stop capping.
