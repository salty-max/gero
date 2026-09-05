# gero-lab — Browser Playground Spec

The web playground for the Gero toolchain: write `.gas` or `.gr` in
the browser, assemble or compile it, and run it on the Gero VM with a
full debugger cockpit — registers, memory, stack, disassembly,
breakpoints, single-step.

> **Layer separation:** gero-lab is a web application. It depends on
> the `gero` library, compiled to WebAssembly, for every toolchain
> operation — it reimplements nothing. This file lives in `gero/docs/`
> because the engine boundary is a contract between the two, and gero
> authors need it at hand when changing the public surface.

gero-lab is a **toolchain cockpit**, not a game runtime. The
peripherals — display, audio, input — belong to
[gtx-16](./gtx-16.md), which is a separate consumer of the same VM.

---

## 1. Layers

Three layers, two boundaries. Each boundary is a contract that can be
versioned and tested independently.

```
┌─────────────────────────────────────────────┐
│  UI (main thread)                           │
│  editor · panes · transport controls        │
└───────────────┬─────────────────────────────┘
                │  worker protocol (§3)
┌───────────────┴─────────────────────────────┐
│  Engine worker                              │
│  session state · run loop · event batching  │
└───────────────┬─────────────────────────────┘
                │  wasm exports (§2)
┌───────────────┴─────────────────────────────┐
│  gero.wasm                                  │
│  asm · lang · vm · disasm                   │
└─────────────────────────────────────────────┘
```

The UI never touches the wasm module directly. The worker owns the VM
instance and every allocation inside the module; the UI owns nothing
but plain serializable messages. This keeps the run loop off the main
thread, so a tight `while` loop in a user program cannot freeze the
page.

---

## 2. The wasm surface

`gero` builds to `wasm32-freestanding` with an explicit C-ABI export
set. Freestanding rather than `wasm32-wasi`: the lab needs a narrow,
purpose-built surface, not a POSIX shim. Print syscalls already route
through `vm.host.out`, so the binding captures them into a ring buffer
instead of needing stdout. The `wasm32-wasi` target stays as-is for
CLI use.

### 2.1 Memory ownership

The module owns a bump arena reset per operation. Every export that
returns variable-length data writes into a module-owned buffer and
returns `(ptr, len)`; the caller copies out before the next call. No
JS-side frees, no leaks across the boundary.

### 2.2 Exports

**Toolchain**

| Export | Purpose |
|---|---|
| `gero_assemble(src_ptr, src_len) -> Result` | `.gas` → `.gx` |
| `gero_compile(src_ptr, src_len) -> Result` | `.gr` → `.gx`, resolving `use` imports from the virtual file set (§4.2) |
| `gero_check(src_ptr, src_len, lang) -> Result` | Diagnostics only, no image — the editor's fast path |
| `gero_format(src_ptr, src_len, lang) -> Result` | Canonical formatting, matching `gero fmt` |
| `gero_disasm(gx_ptr, gx_len, bank) -> Result` | `.gx` → annotated assembly |

A `Result` carries a status, an optional payload (`.gx` bytes or
formatted text), and a diagnostics array (§5). Both source languages
use one shape, keyed by a `lang` discriminant, so the UI has one code
path.

**VM**

| Export | Purpose |
|---|---|
| `gero_vm_create()` / `gero_vm_destroy(h)` | Session lifecycle |
| `gero_vm_load(h, gx_ptr, gx_len)` | Parse the archive and boot |
| `gero_vm_reset(h)` | Re-boot the loaded image |
| `gero_vm_step(h, n) -> StepOutcome` | Execute up to `n` instructions |
| `gero_vm_regs(h) -> ptr` | Register file snapshot |
| `gero_vm_peek(h, addr, len) -> ptr` | Read memory through the mapper |
| `gero_vm_poke(h, addr, ptr, len)` | Write memory through the mapper |
| `gero_vm_set_reg(h, reg, value)` | Poke a register |
| `gero_vm_raise_irq(h, vector)` | Inject a maskable interrupt |
| `gero_vm_take_output(h) -> ptr` | Drain the print ring buffer |
| `gero_vm_sram(h) -> ptr` / `gero_vm_load_sram(h, ptr, len)` | Persistence (§7) |

Multiple sessions coexist — `gero_vm_create` returns a handle, and
neither the VM nor the toolchain holds module-level mutable state, so
sessions are independent.

`StepOutcome` maps `vm.StepResult` — `cont`, `branched`, `halted`,
`halted_on_fault`, `breakpoint` — plus the instruction count actually
retired, which is under `n` when the run stopped early.

### 2.3 Breakpoints

Breakpoints use the ISA's `brk` opcode rather than a worker-side
address set. Setting one patches the byte at the address and stores
the original; clearing restores it. `vm.step` already returns
`.breakpoint` for `brk`, so the run loop needs no per-instruction
address comparison — the cost of a breakpoint is zero when it isn't
hit.

Patched bytes are invisible to the UI: `gero_vm_peek` restores the
originals in its returned copy, so the memory pane and the
disassembly show the user's program, not the instrumentation.

---

## 3. Worker protocol

A versioned message protocol over comlink. `PROTOCOL_VERSION` is a
single integer; the UI refuses to connect to a worker whose version it
doesn't recognize, which turns a stale service-worker cache into a
clear error instead of silent misbehavior.

### 3.1 Commands

| Command | Payload |
|---|---|
| `init` | memory size, entry override |
| `build` | source set + entry file + language |
| `load` | `.gx` bytes (skips the toolchain — for a shared image) |
| `reset` | — |
| `run` | starting `ip` |
| `pause` | — |
| `step` | instruction count |
| `breakpoints` | add / remove address lists |
| `peek` | address, length, request id |
| `poke` | address, bytes |
| `setReg` | register, value |
| `irq` | vector |

### 3.2 Events

| Event | Payload |
|---|---|
| `ready` | protocol version, gero version |
| `built` | `.gx` size, entry, debug info (§6), diagnostics |
| `paused` | reason (`breakpoint` / `manual` / `fault` / `halt`), `ip`, fault detail |
| `snapshot` | register file |
| `mem` | address, bytes, request id |
| `output` | text drained from the print buffer |
| `trace` | `ip`, before / after snapshots |
| `irq` | phase (`enter` / `exit`), `ip` |
| `bp` | added / removed / total |

### 3.3 Run loop and back-pressure

`run` executes in slices — a fixed instruction budget per turn — and
yields between them so `pause` is honored promptly. Events coalesce
per slice: one `snapshot`, one `output`, one `mem` per outstanding
request. A program printing in a tight loop produces a bounded event
rate regardless of how fast it runs.

The UI's speed control sets the slice budget. At the lowest setting
one instruction per turn drives the step-through visualization; at the
highest the loop runs uninterrupted until a breakpoint, fault, or
`hlt`.

---

## 4. Source languages

Both `.gas` and `.gr` are first-class. Neither is a later addition:
the language discriminant is present in every toolchain export, every
`build` command, and the editor configuration.

### 4.1 Per-language behavior

| | `.gas` | `.gr` |
|---|---|---|
| Toolchain entry | `gero_assemble` | `gero_compile` |
| Comment syntax | `;` | `--` |
| Multi-file | `include` (textual splice) | `use` (module import) |
| Formatter | `gero_format(…, gas)` | `gero_format(…, gr)` |

### 4.2 The virtual file set

A session holds a named set of source buffers, not a single string.
`include` and `use` resolve against that set, so a multi-file program
works in the browser exactly as it does on disk. The entry file is
explicit; unreferenced buffers are still checked, matching
`gero check`'s behavior of validating every file rather than only the
reachable ones.

Resolution is closed: a path that escapes the set is a diagnostic, not
a network fetch. The lab never loads code from a URL at build time.

---

## 5. Diagnostics

One contract across the CLI, the editor, and the lab. The wasm
diagnostics array is the same shape `gero check --format=json` emits —
code, severity, message, file, span, and any secondary spans and
notes.

This is a deliberate single source of truth: an error's wording and
code are identical whether a user hits it in a terminal, in an
editor's problem list, or in the lab's gutter. A change to a
diagnostic surfaces in all three, and `docs/lang-diagnostics.md`
remains the one registry.

Rendering is the lab's own: spans become inline squiggles and gutter
markers rather than the CLI's caret art.

---

## 6. Debug information

The cockpit maps machine state back to source. Two tables, both
carried in the `.gx` debug section and returned by `built`:

- **Symbols** — address → name, for labels, functions, and globals.
  Drives the disassembly's label column and the memory pane's
  annotations.
- **Lines** — address range → (file, line, column). Drives
  source-level stepping, the current-line highlight, and setting a
  breakpoint by clicking a source line rather than typing an address.

Both tables live in the `.gx` debug section, emitted only when the
image is built with debug symbols, so release images carry neither.

Without debug information the lab still functions — the disassembly,
memory, and register panes need none of it. Source-level features
degrade to address-level ones.

---

## 7. Persistence

Three kinds of state, three lifetimes:

- **Source buffers** — the working set, saved to browser storage on
  edit and restored on load. Losing a tab must not lose work.
- **SRAM** — a program's `.sav` banks, exposed through
  `gero_vm_sram`. Stored per program identity so a cart's saved game
  survives a reload, matching what the CLI writes to a `.sav` file.
- **Session state** — breakpoints, pane layout, speed, theme. Local
  to the browser; never part of a shared link.

## 8. Sharing

A program shares as a URL carrying the compressed source set and entry
point — not a `.gx`. Sharing source means the link stays readable, and
the recipient assembles with their own toolchain version rather than
running an opaque blob from a stranger.

Links are self-contained: no server, no stored state, no account. A
shared link that exceeds a practical URL length is refused with a
message suggesting file download instead of silently truncating.

---

## 9. Samples

The lab ships a sample set covering both languages, drawn from the
repository's own example corpus so samples cannot drift from what CI
proves works: the `.gas` programs under `examples/asm/` and the `.gr`
programs under `examples/lang/`.

A sample that fails to build is a build failure, not a runtime
surprise — the sample set is gated the same way the example corpus is.

---

## 10. Build and gating

gero-lab lives in the gero repository and builds against the working
tree, not a published release. That is the point: a change to the ISA,
the assembler, or the language compiler updates the playground in the
same commit, and the playground can never lag the toolchain it
demonstrates.

- The wasm module is a `zig build` artifact like any other target.
- The web application has its own toolchain and its own CI lane,
  parallel to the Zig lane rather than blocking it.
- The Zig gates (`zig build verify` / `ci`) remain authoritative for
  `src/`, `apps/`, and `tools/`. The lab's lane covers the lab.
- A smoke test builds each sample through the wasm module and runs it
  to `hlt`, comparing output against the same `.expected` files the
  CLI example gate uses. This is what turns "wasm32 compiles" into
  "wasm32 runs" — a runtime check on a target that otherwise only
  gets a compile check.

`build.zig.zon`'s `paths` allowlist excludes the lab, so nothing here
reaches consumers who fetch gero as a library.

---

## 11. What gero-lab explicitly does NOT do

These absences are deliberate.

- **No peripherals.** No display, audio, or input. That is gtx-16's
  layer; a lab that grew a framebuffer would become a second, worse
  console.
- **No server.** No accounts, no stored programs, no build queue.
  Everything runs in the browser; sharing is a URL.
- **No second implementation.** Every toolchain and VM operation goes
  through the wasm module. The lab holds no opcode table, no
  instruction semantics, no assembler. A prior TypeScript
  implementation demonstrated the failure mode: it drifted to a
  different `ret` encoding than the ISA and silently stopped being
  able to run current programs.
- **No editing of `.gx` bytes.** The lab is a source-level tool.
  Memory poking during a session is a debugger affordance, not an
  image editor.
- **No network fetches at build time.** Imports resolve within the
  session's file set.

---

## 12. Why this shape

**Why a worker rather than the main thread?** A user program is
arbitrary code, including an infinite loop. On the main thread that
hangs the page and loses the user's source. In a worker it is a
`pause` away from recovery.

**Why `brk` rather than an address set?** Address comparison costs
something on every instruction, forever, to support a feature used
rarely. Patching costs something once per breakpoint toggle. The ISA
already defines the opcode and the VM already reports it.

**Why compile in the browser rather than on a server?** The toolchain
is a few hundred kilobytes of wasm and runs in milliseconds. A server
would add latency, an availability dependency, and an attack surface,
to do work the client can do locally.

**Why share source rather than images?** A `.gx` is opaque and
version-bound. Source is readable, diffable, and rebuilt by the
recipient's toolchain — so a shared link keeps working across format
changes that would invalidate a blob.

**Why both languages from the start?** The lang compiler is the
larger half of the project. A playground that demonstrates only the
assembler would misrepresent what Gero is, and retrofitting a second
language into a UI built around one is more work than accommodating
both from the beginning.
