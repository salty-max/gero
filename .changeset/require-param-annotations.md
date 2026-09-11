---
bump: minor
---

Every parameter needs a type annotation. Omitting one is
`E_TYPE_PARAM_UNANNOTATED`.

It used to be accepted, and it was not inferred — it was unchecked.
`def add(a, b) -> i16` called as `add("Ryu", 3)` compiled, ran, and
printed the address the string lived at plus three, with no error and
no warning, not even under `gero check --werror`. The annotation is
what gives the compiler something to compare an argument against, so a
signature without one promised less than it appeared to.

Two parameters legitimately carry no annotation and are unaffected: a
method's `self`, whose type is the class it is declared in, and a
variadic `name: ...`, whose form carries the intent.

`gero-lang.md` §3.5 described inference from call sites, including an
ambiguity error, that was never implemented. It now describes what the
language does — inference is local, signatures are written — and says
why call-site inference is not coming: declarations are exported by
default, so it would be whole-program, and the build cache hashes each
module's signatures to decide which importers are stale.
