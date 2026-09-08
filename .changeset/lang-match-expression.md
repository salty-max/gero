---
bump: minor
---

feat(lang): `match` produces a value

`do … end` and `if` both evaluate to the branch they take. `match` did
not — the parser had no case for one in expression position at all,
which left the form most often written to produce one value per case as
the only block form that could not.

```gero
let label = match state
  case State.Idle => "idle"
  case State.Run  => "running"
  case State.Dead => "dead"
end
```

Two checks make the chain total: the arms must be exhaustive (§4.8.3,
already enforced for the statement form) and every arm must produce the
same type (`E_TYPE_MATCH_ARM_MISMATCH`). An arm ending in a statement
types as `nil` and fails the second, which catches an arm that forgot
its value.

Arms are blocks, so they may run statements before their value, they
may produce aggregates, and a trailing `match` is a value block's tail
the way a trailing `if` already was.

Payload binders are in scope for the arm's value — `case Potion(n) =>
n * 2` reads `n`. That also fixes the same gap in `if`: an `if let`
binding was not visible to its branch's value, so `let v = if let
Potion(n) = item n * 2 else 0 end` failed with an undefined symbol.
Both forms now type each branch inside the scope that holds its
bindings rather than walking the body a second time from outside.
