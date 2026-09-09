---
bump: patch
---

`gero` builds and runs on Windows. The REPL's line editor drove POSIX
termios with no target guard, so the CLI failed to compile for Windows
entirely — `std.posix.termios` is `void` there, a stdin handle is a
`HANDLE` rather than an integer fd, and `tcgetattr` needs libc. It
failed for `wasm32-wasi` for the same reason.

Terminal control now goes through a small platform layer that picks by
capability rather than by OS: termios where it exists, console modes on
Windows (`ENABLE_VIRTUAL_TERMINAL_INPUT`, so arrow keys still arrive as
escape sequences), and nothing on a platform with no terminal at all,
where the REPL reads cooked. A terminal that refuses raw mode degrades
to a cooked prompt rather than failing the REPL.
