# Examples

Runnable gero programs, each verified in CI by compiling, running, and
diffing stdout against a golden `.expected` file alongside it.

## Layout

| Directory | Language | Gate |
|---|---|---|
| [`asm/`](asm) | gero-asm (`.gas`) | `zig build test-examples` — assemble → run → diff → disasm round-trip |
| [`lang/`](lang) | gero-lang (`.gr`) | `zig build test-examples-lang` — compile → run → diff |

Both suites are also format-checked: `*.gas` via `zig build
fmt-check-examples`, `*.gr` via `zig build check-examples-gr` (which
also type-checks them).

The exhaustive *syntax tours* — one per language, embedded in the
language docs — live under [`../docs/examples/`](../docs/examples),
not here. Those are reference material (`gero check` / `gero fmt`
clean) rather than standalone programs.

## Running one

```bash
# asm
gero asm asm/counter.gas && gero run counter.gx

# lang
gero compile lang/fizzbuzz.gr -o fizzbuzz.gx && gero run fizzbuzz.gx
```

## Adding an example

1. Drop `<name>.gas` / `<name>.gr` in the matching directory with a
   header comment: what it does, what it exercises, and how to run it.
2. Generate the golden output: run it and save stdout to
   `<name>.expected`.
3. `zig build ci` — the example must compile, run, match its golden
   output, and (for `.gr`) format + type-check clean.

## Scope of the `lang/` suite

The `.gr` examples stay within what the codegen backend executes today
— functions, recursion, `for` / `while`, `if` / `elif` / `else`,
`match` over enums, integer arithmetic, and `print`. Data-structure
programs (arrays, structs, classes, compound assignment) aren't here
yet because the backend doesn't lower them; they'll join as codegen
grows.
