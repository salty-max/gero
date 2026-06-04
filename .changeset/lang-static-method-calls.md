---
bump: minor
---

`@static` method calls now lower (§3.7) — `ClassName.method(args)` is
compiled as a direct call with no receiver, and previously only
type-checked-by-accident (it produced no diagnostic *and* no code). The
call is now fully type-checked (arguments, return type, variadic arity)
and emitted, including struct / tuple (sret) returns and variadic
`@static` methods.

Call-form and scope mismatches that used to slip through are now caught:

- An instance method invoked as `ClassName.method(...)` →
  `E_INSTANCE_AS_STATIC`; a `@static` method invoked on an instance →
  `E_STATIC_ON_INSTANCE` (it previously leaked the receiver into the
  first parameter).
- `self` / `super` referenced in a `@static` body → `E_STATIC_SELF`
  (previously passed `gero check` and only failed at compile).
- A value binding that shadows a class name (`let M = …`) is now honored
  in receiver position instead of being silently bypassed.

Adversarial review also surfaced pre-existing gaps in the shared method-
call ABI, fixed here (they affect instance and variadic methods too):

- A tuple passed by value to any method was pushed as only its base
  address — now copied by value, like struct / array / `Vec` args.
- A tuple- (and, latently, struct-) returning method didn't always pass
  its hidden sret destination pointer — the returns-sret test now
  includes tuple returns and resolves through the inheritance chain
  rather than the vtable layout (which omits non-virtual methods).
