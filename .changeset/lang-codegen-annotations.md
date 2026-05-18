---
bump: minor
---

Annotation enforcement — full OOP semantics + every codegen-control
annotation now wired end-to-end. Closes #262.

**OOP annotations (§3.7.6).** The typechecker now enforces every
OOP rule the spec promised:

- `@final` on a class blocks `extends` (`E_CLASS_FINAL_EXTENDS`).
- `@final` on a method blocks subclass override
  (`E_METHOD_FINAL_OVERRIDE`).
- `@override` requires a parent method with the same name
  (`E_OVERRIDE_NO_PARENT`).
- `@abstract` on a class blocks `ClassName(args)` instantiation
  (`E_CLASS_ABSTRACT_INSTANTIATE`); the parser already drops
  the method body for `@abstract def`, so the "no body" rule
  needs no extra typecheck.
- Concrete subclasses must override every inherited `@abstract`
  method (`E_ABSTRACT_NOT_IMPLEMENTED`). A class with any
  `@abstract` method is implicitly `@abstract` per spec.
- `@private` fields / methods are visible only inside the
  declaring class — even subclasses can't see them
  (`E_PRIVATE_ACCESS`).
- `@static` methods can't take a `self` parameter
  (`E_STATIC_HAS_SELF`).

**Codegen-control annotations (§3.7.2 / §3.7.3 / §3.7.4).**

- `@inline` — every call site to an annotated def splices the
  body in place; the standalone def never emits. Args evaluate
  into fresh local slots in the caller's frame, body `return`s
  redirect to a jmp past the inlined site, and the spliced
  bytes get disassembled afterward to count instructions. Over
  the 32-instruction spec cap → `E_ANN_INLINE_TOO_LARGE`.
  Reentrancy past depth 8 → `E_ANN_INLINE_RECURSIVE`.
- `@cold` — emit order is `[hot defs in source order, cold defs
  in source order]`, deterministic per spec.
- `@no_capture` — closure analysis short-circuits heap promotion
  inside annotated defs so the typecheck-only `@no_capture`
  guarantee doesn't leak through a read-only escape path.
- `@noreturn` — call sites omit the post-call `add <args>, sp`
  cleanup (the callee never resumes, by contract).
- `@interrupt N` — entry-def prologue writes each handler's
  resolved address into the IVT slot `mem[$1000 + 2 * N]` (ISA
  §6.1) before any user code runs; handler bodies emit `rti`
  instead of `ret` for both implicit and explicit returns
  (§6.3).

**Debug-symbol section (ISA §7.3).** `Options.debug_symbols`
(default `true`) now actually populates the section. Every fn
address lands as `kind = 0` label, every global as `kind = 1`
data; compiler-internal labels (lambda mangles, vtable storage)
are filtered out. Header flag bit 1 is set when the section is
present, so the disassembler and any external debugger can
detect it.

Eight new diagnostic codes registered in `lang-diagnostics.md`
§5.6 / §6: `E_CLASS_FINAL_EXTENDS`, `E_METHOD_FINAL_OVERRIDE`,
`E_OVERRIDE_NO_PARENT`, `E_CLASS_ABSTRACT_INSTANTIATE`,
`E_ABSTRACT_NOT_IMPLEMENTED`, `E_PRIVATE_ACCESS`,
`E_STATIC_HAS_SELF`, plus the codegen-side `E_ANN_INLINE_RECURSIVE`.

Tests: 12 new typecheck tests cover every OOP enforcement
(happy + sad paths), plus 7 new codegen tests for the codegen-
control annotations (size cap, ordering, ISR shape, inline
splice, debug section gated on the flag).
