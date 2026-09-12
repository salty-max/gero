# 4. Functions

Chapter 3 made a fight work, but its rules were buried inside `main`. The
number 7 meant Ryu's damage only because we remembered what it meant. A larger
program cannot rely on memory like that.

A **function** gives a name to an operation. It can receive values, perform
work, and return an answer.

## Declaring and calling a function

```gero
def damage_from(power: i16, defense: i16) -> i16
  return power - defense
end

def main()
  let damage = damage_from(12, 5)
  print damage
end
```

The first line declares a function named `damage_from`. Its two
**parameters**, `power` and `defense`, are names that receive values when the
function is called. Both must be `i16` values.

The arrow gives the return type. `-> i16` promises that the function will send
an `i16` answer back to its caller. `return power - defense` computes that
answer and immediately leaves the function.

The expression `damage_from(12, 5)` is a **call**. The values 12 and 5 are its
arguments. Execution moves into `damage_from` with `power` bound to 12 and
`defense` bound to 5, computes 7, then resumes in `main` with that answer.

The program prints `7`, but the named parameters let us read the meaning of
the calculation directly from the function.

## Functions that perform an action

Some functions do something without calculating a value for the caller. They
omit the return arrow:

```gero
def announce(name: str)
  print "$(name) enters the fight"
end

def main()
  announce("Ryu")
end
```

`announce` still returns control to `main` when it reaches `end`; it simply
does not return a value that can be stored or used in an expression.

Each function has its own local bindings. The parameter `name` exists inside
`announce`, while a binding declared inside `main` exists inside `main`. This
separation is called **scope**. It prevents unrelated functions from
accidentally changing each other's temporary state.

## Signatures are contracts

The function's name, parameters, and return type form its **signature**:

```text
damage_from(power: i16, defense: i16) -> i16
```

A caller can understand that contract without reading the body. Gero therefore
requires parameter types at function boundaries, even though it can infer the
types of many local bindings.

The following declaration deliberately does not compile because `power` has
no type:

```gero
def damage_from(power, defense: i16) -> i16
  return power - defense
end
```

The compiler points at the unannotated parameter:

```text
error: parameter `power` needs a type — write `power: i16` or whichever type it takes [E_TYPE_PARAM_UNANNOTATED]
```

This call also deliberately fails:

```gero
def damage_from(power: i16, defense: i16) -> i16
  return power - defense
end

def main()
  print damage_from("Ryu", 5)
end
```

```text
error: type mismatch: expected `i16`, found `str` [E_TYPE_MISMATCH]
```

The error appears at the call because the signature contains enough
information to reject the wrong argument before the function executes.

## Returning more than one answer

An attack can answer two questions: did it hit, and how much damage did it do?
A tuple groups a small fixed number of values, even when their types differ:

```gero
def attack(power: i16, defense: i16, roll: i16) -> (bool, i16)
  if roll < 20
    return (false, 0)
  end
  return (true, power - defense)
end

def main()
  let result = attack(12, 5, 75)
  print result.0
  print result.1
end
```

The return type `(bool, i16)` promises a pair. Position `.0` holds the first
value and `.1` holds the second.

When both positions have useful names, destructure the tuple as it arrives:

```gero
def attack(power: i16, defense: i16, roll: i16) -> (bool, i16)
  if roll < 20
    return (false, 0)
  end
  return (true, power - defense)
end

def main()
  let (hit, damage) = attack(12, 5, 75)
  if hit
    print "hit for $(damage)"
  else
    print "miss"
  end
end
```

The tuple lets the function return related answers together. The explicit
`if hit` at the call site makes the caller decide what each outcome means.

## Naming the fight's rules

```gero
const RYU_POWER = 12
const KEN_DEFENSE = 5

def damage_from(power: i16, defense: i16) -> i16
  let damage = power - defense
  if damage < 1
    return 1
  end
  return damage
end

def severity(hp: i16, max_hp: i16) -> str
  if hp <= 0
    return "fallen"
  else if hp < max_hp / 4
    return "critical"
  else if hp < max_hp / 2
    return "wounded"
  end
  return "healthy"
end

def main()
  let ken_hp = 35
  let damage = damage_from(RYU_POWER, KEN_DEFENSE)
  ken_hp -= damage

  print "Ryu deals $(damage) damage"
  print "Ken is $(severity(ken_hp, 35))"
end
```

`damage_from` owns the rule that damage cannot fall below one. `severity` owns
the words used for hit-point ranges. `main` coordinates them without needing
to know their internal decisions.

This separation is called **decomposition**: turning one large problem into
smaller operations with names and contracts. It makes a program easier to
read, test, and change.

## Recursion

A function may call itself. This is **recursion**:

```gero
def factorial(n: i16) -> i16
  if n <= 1
    return 1
  end
  return n * factorial(n - 1)
end

def main()
  print factorial(5)
end
```

Each call receives a smaller value until the condition reaches the **base
case**, which returns 1 without another call. The waiting calls then multiply
that result by 2, 3, 4, and 5, producing 120. Without a reachable base case,
calls would continue until the stack ran out of memory. Loops are usually
clearer for simple repetition; recursion becomes useful when a problem is
naturally defined in terms of smaller versions of itself.

## What you learned

A function names an operation. Parameters carry information in, a return value
carries information out, and the signature lets the compiler check the
boundary. Functions also create scopes and let a large program be decomposed
into rules that can be understood independently.

The fight now has named rules, but its data is still a loose group of values.

---

**Next:** [Collections](05-collections.md) — grouping values and choosing where
they live.
