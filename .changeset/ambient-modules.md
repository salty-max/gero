---
bump: minor
---

A host can start a program with stdlib modules already in scope.

```zig
const ambient = [_][]const u8{ "math", "mem" };
var checked = try gero.lang.typecheckAmbient(
    alloc, src, &tree.program, null, null, &ambient);
var compiled = try gero.lang.compile(
    alloc, src, &checked, .{ .ambient_modules = &ambient });
```

The program then calls `min(a, b)` having written no `use` line. This
is off by default and changes nothing about an ordinary build: with no
ambient modules named, every stdlib name is still reached through
`use` or a module qualifier, exactly as before.

**An ambient name is shadowed silently**, which is the point and the
whole difference from an import. After `use min from math`, declaring
`min` is `E_TYPE_REDEFINED` — you wrote both, so one of them is a
mistake. An ambient `min` arrived without the program asking, so a
declaration of that name simply wins, and nothing is reported:

```gero
def min(a: i16, b: i16) -> i16     -- no error; this `min` wins
  return a
end
```

The rule holds at any depth — a local, a parameter or a capture
shadows an ambient name inside its scope — because resolution finds
what is in scope first and falls back to the ambient set only when it
finds nothing.

The five always-in-scope builtins (`assert`, `debug_assert`, `panic`,
`unreachable`, `todo`) stay reserved. Shadowing those is still
`E_BUILTIN_SHADOW`, because the language guarantees what they mean.

This exists for a host that supplies an environment rather than a
library: a console handing a program the arithmetic it will obviously
need, where an import at the top of every file is ceremony its author
did not choose and cannot see a reason for.
