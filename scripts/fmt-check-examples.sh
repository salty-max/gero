#!/usr/bin/env bash
#
# Run `gero fmt --check` over the in-tree example roots and fail if
# any file would be reformatted. Mirrors `check-examples.sh` but on
# the formatting layer — guards the canonical shape so the in-tree
# examples stay an idempotent reference for users.
#
# `gero fmt` walks a directory for both `.gas` and `.gr`, so this
# covers every example under the roots below. `docs/examples` joins
# `examples/asm` here because `check-examples.sh` already validates
# it — a showcase shouldn't be gated in one and drifted in the other.
#
# Env knobs:
#   GERO_BIN       — path to the `gero` binary (default ./zig-out/bin/gero)
#   EXAMPLES_DIRS  — roots to walk (default "examples/asm docs/examples")
#   NO_COLOR       — disable ANSI colors (auto-off when stdout is not a TTY)
#
# Exit codes:
#   0 — every example is canonical
#   1 — at least one example would change, or a precondition missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
EXAMPLES_DIRS="${EXAMPLES_DIRS:-examples/asm docs/examples}"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'fmt-check-examples: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi

present_dirs=()
for dir in $EXAMPLES_DIRS; do
    [[ -d "$dir" ]] && present_dirs+=("$dir")
done

if [[ ${#present_dirs[@]} -eq 0 ]]; then
    printf 'fmt-check-examples: none of [%s] exist\n' "$EXAMPLES_DIRS" >&2
    exit 1
fi

if "$GERO_BIN" fmt --check "${present_dirs[@]}"; then
    exit 0
fi
exit 1
