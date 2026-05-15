#!/usr/bin/env bash
#
# Drive every `examples/asm/*.gas` (recursive) through `gero check`
# and fail on any non-zero exit. Lighter sibling of `test-examples`:
# no assemble/run/diff, just parse + codegen-validate. Catches asm
# spec drift faster than the round-trip pipeline.
#
# Env knobs:
#   GERO_BIN       — path to the `gero` binary (default ./zig-out/bin/gero)
#   EXAMPLES_DIR   — root to walk for *.gas (default examples/asm)
#   NO_COLOR       — disable ANSI colors (auto-off when stdout is not a TTY)
#
# Exit codes:
#   0 — every example checked clean
#   1 — at least one example failed, or a precondition is missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
EXAMPLES_DIR="${EXAMPLES_DIR:-examples/asm}"
# `docs/examples/` carries the syntax-overview showcase + its include
# stub. Gated alongside the runnable examples so any drift between
# tree-sitter grammar / docs and the actual assembler surfaces here.
DOC_EXAMPLES_DIR="${DOC_EXAMPLES_DIR:-docs/examples}"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'check-examples: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi

if [[ ! -d "$EXAMPLES_DIR" ]]; then
    printf 'check-examples: %s missing\n' "$EXAMPLES_DIR" >&2
    exit 1
fi

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; RED=''; BOLD=''; RESET=''
fi

mapfile -t -d '' gas_files < <(
    {
        find "$EXAMPLES_DIR" -type f -name '*.gas' -print0
        if [[ -d "$DOC_EXAMPLES_DIR" ]]; then
            # docs/examples/shared.gas is an include-only stub — exclude
            # it from the standalone-check walk; it's exercised via
            # syntax_overview.gas's include directive.
            find "$DOC_EXAMPLES_DIR" -type f -name '*.gas' ! -name 'shared.gas' -print0
        fi
    } | sort -z
)

if [[ ${#gas_files[@]} -eq 0 ]]; then
    printf 'check-examples: no .gas files under %s\n' "$EXAMPLES_DIR" >&2
    exit 1
fi

pass=0; fail=0
for gas in "${gas_files[@]}"; do
    rel="${gas#${PWD}/}"
    printf '  %-40s ... ' "$rel"

    rc=0
    out="$("$GERO_BIN" check --quiet "$gas" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        printf '%sFAIL%s (exit=%d)\n' "$RED" "$RESET" "$rc"
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out" | sed 's/^/      /'
        fi
        fail=$((fail+1))
        continue
    fi

    printf '%sok%s\n' "$GREEN" "$RESET"
    pass=$((pass+1))
done

printf '\n%scheck-examples:%s %d passed, %d failed\n' "$BOLD" "$RESET" "$pass" "$fail"
if (( fail > 0 )); then
    exit 1
fi
