# Examples

Hand-crafted `.gx` bytecode for poking at the VM before the assembler
lands. Each one ships with a Python generator that recreates the
binary — review the generator to see the bytecode breakdown.

## Run

After `zig build`:

```bash
./zig-out/bin/gero run examples/hello.gx
# Hello, gero!
```

## Regenerate

```bash
python3 examples/gen-hello.py > examples/hello.gx
```

## Programs

### `hello.gx`

Prints `Hello, gero!\n` then halts. Exercises a real loop —
pointer-walk through a null-terminated string in user RAM, byte-load,
`cmp` for the terminator, conditional `jeq` exit, `int 0x10` host
syscall for `stdout`, `inc` + `jmp` for the loop tail.

| Address  | Bytes              | Mnemonic                               |
|----------|--------------------|----------------------------------------|
| `0x0000` | `10 16 00 03`      | `mov 0x0016, r2` — `r2 ← string addr`  |
| `0x0004` | `24 03 02`         | `mov8 [r2], r1` — `r1.lo ← mem[r2]`    |
| `0x0007` | `60 02 00 00`      | `cmp r1, 0` — null check               |
| `0x000B` | `72 15 00`         | `jeq 0x0015` — branch to `hlt` on zero |
| `0x000E` | `FC 10`            | `int 0x10` — host: stdout ← `r1.lo`    |
| `0x0010` | `48 03`            | `inc r2` — advance the pointer         |
| `0x0012` | `70 04 00`         | `jmp 0x0004` — loop                    |
| `0x0015` | `FF`               | `hlt`                                  |
| `0x0016` | `Hello, gero!\n\0` | the string                             |
