# 3. Control flow

The programs so far execute every statement once, from top to bottom. A fight
needs more control. It must choose what happens when hit points reach zero and
repeat turns while both fighters can act.

The order in which statements execute is called **control flow**.

## Making a decision with `if`

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

The expression `hp <= 0` is a **condition**. It produces a `bool`: either
`true` or `false`. Because 12 is not less than or equal to zero, the condition
is false and the `else` branch runs.

```text
Ryu fights on
```

Only one branch runs. The other is skipped. If you change `hp` to `0` and run
the program again, the first branch runs instead.

There is no `then` keyword. The condition ends at the newline and the body
begins on the next line. Parentheses are unnecessary because `if` already
expects a condition. Every branch closes at the shared `end`.

More than two outcomes can be expressed with an `else if` chain:

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

Conditions are checked from top to bottom. The first true condition wins.
Here, `30 / 4` is 7 and `30 / 2` is 15. Twelve is not at most zero and not
less than seven, but it is less than fifteen, so the program prints
`wounded`.

Integer division discards the fractional remainder: `30 / 4` is 7. That rule
will matter when we introduce fixed-point arithmetic.

## Combining conditions

Use `and` when both conditions must be true, `or` when either is enough, and
`not` to reverse a Boolean value:

```gero
def main()
  let hp = 8
  let potions = 1

  if hp > 0 and hp <= 10 and potions > 0
    print "drink a potion"
  end
end
```

This program prints because all three facts are true. Conditions let the
program turn state into behavior.

## Repeating work with `while`

A `while` loop checks a condition, runs its body when the condition is true,
then checks again:

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

The loop changes two pieces of state. Tracing them makes the repetition
visible:

| After turn | `hp` | `turns` | Will the loop continue? |
|---:|---:|---:|---|
| 1 | 23 | 1 | yes |
| 2 | 16 | 2 | yes |
| 3 | 9 | 3 | yes |
| 4 | 2 | 4 | yes |
| 5 | -5 | 5 | no |

The program prints `5`. The fifth subtraction overshoots zero, but the loop
does not check again until the body has finished.

`hp -= 7` and `turns += 1` are **compound assignments**. They update a binding
using its current value. Gero also has `*=`, `/=`, and `%=`. These are
statements, so `let result = hp -= 7` is invalid. The `++` and `--` operators
are statements too: `turn++` can stand on its own, but it cannot be embedded
inside a larger expression.

A loop must eventually make its condition false or leave in some other way.
If the body above never changed `hp`, `hp > 0` would remain true forever. That
is an **infinite loop**.

## Counting with `for` and ranges

When the program needs a sequence of values, a `for` loop is clearer:

```gero
def main()
  for turn in 1..=5
    print turn
  end
end
```

`1..=5` is an inclusive range, so it produces 1, 2, 3, 4, and 5. The loop
binds each value to `turn` and runs once for each value.

The range `0..3` excludes its upper bound:

```gero
def main()
  for index in 0..3
    print index
  end
end
```

It produces 0, 1, and 2. Half-open ranges are useful for indexes because a
collection with three elements has exactly those three positions.

## Leaving a loop early

`break` ends the nearest loop. `continue` skips the rest of the current
iteration and starts the next one.

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

This loop has no condition that can become false: `true` is always true.
Instead, `break` supplies its exit. Following the state explains the result.
Ryu reaches zero on turn 5, drinks, reaches zero again on turn 8, drinks again,
and finally falls on turn 11 with no potion left.

```text
11
```

Use this shape when the decision to stop naturally happens in the middle of a
loop. When a simple condition describes the whole lifetime of the loop, put it
after `while` instead.

## The fight so far

```gero
def main()
  let ryu_hp = 30
  let ken_hp = 35
  let turn = 0

  while ryu_hp > 0 and ken_hp > 0
    turn += 1
    ken_hp -= 7

    if ken_hp > 0
      ryu_hp -= 6
    end
  end

  print "the fight lasted $(turn) turns"
  print "Ryu: $(ryu_hp) hp"
  print "Ken: $(ken_hp) hp"
end
```

The program now has a real process: each iteration is one turn. It also has a
problem. The damage rules are loose arithmetic inside `main`, where they will
become hard to find and harder to reuse. We need to give operations names.

## What you learned

An `if` selects one path using a Boolean condition. A loop repeats a path while
a condition remains true or across the values in a range. Both forms derive
behavior from state, and tracing how that state changes is the reliable way to
understand them.

---

**Next:** [Functions](04-functions.md) — naming the rules of the fight and
passing values into them.
