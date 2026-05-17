---
bump: minor
---

Closes #263. Adds a `sys` opcode (`0xFB`) to the VM ISA for
host-callback syscalls and wires the first family — `print_str` /
`print_int` / `print_char` / `print_newline`.

**Motivation**

The gero-lang spec's `print expr` statement (§4.9) needs a
runtime sink. The VM was a pure interpreter with no host I/O
mechanism — `int N` is interrupt-based and dispatches to
user-supplied bytecode handlers (no good for built-ins). This
issue lands a small, focused host-callback surface that lang
codegen can call into.

**New opcode**

`0xFB sys imm8` — reads the syscall id from the operand byte,
dispatches to a fixed handler in the VM. Unknown syscall ids
raise the `invalid_opcode` fault.

**Host hookup**

```zig
pub const Host = struct {
    /// Sink for `sys` output syscalls (print_str / print_int /
    /// print_char / print_newline). `null` makes the syscalls
    /// silent no-ops (test / CI scenarios).
    out: ?*std.Io.Writer = null,
};

pub const VM = struct {
    // ... existing fields ...
    host: Host = .{},
};
```

**Syscall set (initial)**

| ID    | Name            | Register convention |
|-------|-----------------|---------------------|
| `0x01`| `print_str`     | `acu` = address of a null-terminated byte string. |
| `0x02`| `print_int`     | `acu` = signed i16 value, written as decimal. |
| `0x03`| `print_char`    | low byte of `acu` written directly. |
| `0x04`| `print_newline` | writes a single `\n` byte. |

`SyscallId` is an open enum (`enum(u8) { ..., _, }`) so unknown
ids round-trip through `@enumFromInt` cleanly and route to the
fault handler.

**Out of scope**

- Input syscalls (`read_char`, `read_line`) — file when needed.
- File I/O syscalls — out of scope for a console VM.
- Time / RNG syscalls — file when needed.
- Formatted-output variants — the lang codegen layers those on
  top.

**Docs**

`docs/isa.md` §5.13 carries the new opcode row + a new §5.13.1
documenting the syscall table.

**Tests**

7 new tests in `tests/vm/handlers/system.test.zig` covering
each syscall's happy path + unknown-id fault + null-writer no-op.
Existing opcode table tests adjusted for the new entry (105 → 106
named entries; pre-system gap moved from `0xFB` to `0xFA`).
