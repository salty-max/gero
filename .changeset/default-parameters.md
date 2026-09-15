---
bump: minor
---

A trailing parameter can declare the value a call may leave out.

```gero
def rect(x: i16, y: i16, w: i16 = 8, h: i16 = 8, color: u8 = 7)
  -- ...
end

rect(10, 20)          -- w=8, h=8, color=7
rect(10, 20, 32)      -- h=8, color=7
```

Every argument had to be written at the call site, so a function with
one interesting parameter and four settings made every caller restate
the settings. The pattern the language left was a second `def` that
forwarded to the first.

A default is any expression valid where the call is written — a
literal, a `const`, a struct literal — and it is evaluated **at the
call site**, as if the argument had been typed there. It answers to its
parameter's type exactly as a written argument would, and it cannot
read the function's own parameters, which do not exist yet —
`def f(a: i16, b: i16 = a)` says so:

```
error: a default cannot read parameter `a` — it is evaluated at the
       call site, before any parameter exists [E_UNDEFINED_SYMBOL]
```

Once a parameter carries a default, every parameter after it must too
— otherwise a short call could not say which argument it omitted. A
variadic parameter takes none; it already accepts zero arguments. Both
are `E_SYNTAX_PARAM_DEFAULT`, a new code.

Methods take defaults on the same terms, `@static` ones included. The
default is written into the call site, so it comes from the **static**
type of the receiver while the body still comes from the vtable — an
override that changes the default changes it only for calls written
against the subclass, and `super.m()` takes the ancestor's.

Nothing costs anything at runtime: the declared expression is emitted
at each call that omits it, so `rect(10, 20)` compiles to exactly what
`rect(10, 20, 8, 8, 7)` compiles to. The golden corpus matches byte
for byte.
