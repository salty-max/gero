# 3. Control flow

Our character has stats. Now the program has to decide something.

## `if`

```gero
def main()
  let hp = 12

  if hp <= 0
    print "Ryu has fallen"
  else
    print "Ryu fights on"
  end
end
```

Two things to notice, and both are deliberate.

There is no `then`. The condition ends where the line ends, and the
body starts on the next one. There is also no parenthesis around the
condition — `if (hp <= 0)` parses, but the parentheses are grouping an
expression, not part of the `if`.

Every block closes with `end`. No braces, no significant indentation:
indentation is for you, `end` is for the compiler.

`else if` chains as you would expect:

```gero
def main()
  let hp = 12
  const MAX_HP = 30

  if hp <= 0
    print "fallen"
  else if hp < MAX_HP / 4
    print "critical"
  else if hp < MAX_HP / 2
    print "wounded"
  else
    print "healthy"
  end
end
```

That prints `wounded`. `MAX_HP / 4` is 7 and `MAX_HP / 2` is 15, so 12
falls in the third arm.

Integer division truncates: `30 / 4` is 7, not 7.5. There is no
rounding and no error. If that is not what you want, `fixed` is
the type with a fractional part.

## `while`

```gero
def main()
  let hp = 30
  let turns = 0

  while hp > 0
    hp -= 7
    turns += 1
  end

  print turns
end
```

`5`. Seven damage a turn against 30 hit points takes five turns, the
last one overshooting — after four turns hp is 2, and the fifth takes
it to -5.

`hp -= 7` is shorthand for `hp = hp - 7`. The compound assignments
(`+=`, `-=`, `*=`, `/=`) are statements, not expressions: you cannot
write `let x = hp -= 7`. Nor is there `++`. A standalone `++` is
fine; `x++ + ++x` is not a puzzle this language wants to set.

## `for` and ranges

Counting is common enough to have its own form:

```gero
def main()
  for i in 1..=5
    print i
  end
end
```

`1` through `5`, one per line. The `..=` is **inclusive** — it
includes 5. There is also `..`, which excludes it:

```gero
def main()
  for i in 0..3
    print i
  end
end
```

`0`, `1`, `2`. Three iterations.

The two forms exist because both are natural somewhere. `0..n` is
right for indexing a collection of `n` things; `1..=n` is right for
counting, which is what a person does out loud. Picking the wrong one
is the classic off-by-one, and having both spellings visible in the
source makes it easier to see which you meant.

## Leaving early

`break` stops a loop; `continue` skips to the next iteration.

```gero
def main()
  let hp = 30
  let potions = 2
  let turn = 0

  while true
    turn += 1
    hp -= 7

    if hp <= 0
      if potions > 0
        potions -= 1
        hp = 15
        continue
      end
      break
    end
  end

  print turn
end
```

`11`. Worth following, because the number is not obvious: 30 hit
points at 7 damage a turn runs out on turn 5, and the potion puts him
back to 15. Fifteen lasts until turn 8, and the second potion buys
another three turns. On turn 11 there is nothing left to drink and
`break` ends it.

`while true` with a `break` inside is idiomatic here. There is no
`repeat` / `until` and no `loop` keyword.

## Where the fight is now

```gero
def main()
  const MAX_HP = 30

  let name: str = "Ryu"
  let hp: i16 = MAX_HP
  let turn = 0

  while hp > 0
    turn += 1
    hp -= 7

    if hp < MAX_HP / 4
      print "critical"
    end
  end

  print name
  print turn
end
```

It works, and it is already showing the strain. The damage number `7`
is buried in the loop. The "how hurt is he" test is inline. If a second
character joins, all of it gets copied.

That is what functions are for.

---

**Next:** [Functions](04-functions.md) — naming the pieces, and
returning more than one thing.
