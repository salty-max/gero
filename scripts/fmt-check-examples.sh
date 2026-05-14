#!/usr/bin/env bash
#
# Run `gero fmt --check` over every `examples/asm/*.gas` and fail
# if any file would be reformatted. Mirrors `check-examples.sh`
# but on the formatting layer — guards the canonical shape so the
# in-tree examples stay an idempotent reference for users.
#
# Env knobs:
#   GERO_BIN       — path to the `gero` binary (default ./zig-out/bin/gero)
#   EXAMPLES_DIR   — root to walk for *.gas (default examples/asm)
#   NO_COLOR       — disable ANSI colors (auto-off when stdout is not a TTY)
#
# Exit codes:
#   0 — every example is canonical
#   1 — at least one example would change, or a precondition missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
EXAMPLES_DIR="${EXAMPLES_DIR:-examples/asm}"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'fmt-check-examples: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi

if [[ ! -d "$EXAMPLES_DIR" ]]; then
    printf 'fmt-check-examples: %s missing\n' "$EXAMPLES_DIR" >&2
    exit 1
fi

if "$GERO_BIN" fmt --check "$EXAMPLES_DIR"; then
    exit 0
fi
exit 1
