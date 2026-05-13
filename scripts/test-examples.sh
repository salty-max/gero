#!/usr/bin/env bash
#
# Drive every example asm program under examples/asm/ through the
# `gero` CLI and diff its stdout against the golden `.expected`
# file alongside it. Wired into `zig build test-examples` and
# `zig build ci`.
#
# Env knobs:
#   GERO_BIN       — path to the `gero` binary (default ./zig-out/bin/gero)
#   EXAMPLES_DIR   — root to walk for *.gas (default examples/asm)
#   NO_COLOR       — disable ANSI colors (auto-off when stdout is not a TTY)
#
# Exit codes:
#   0 — every example passed
#   1 — at least one example failed, or a precondition is missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
EXAMPLES_DIR="${EXAMPLES_DIR:-examples/asm}"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'test-examples: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi

if [[ ! -d "$EXAMPLES_DIR" ]]; then
    printf 'test-examples: %s missing\n' "$EXAMPLES_DIR" >&2
    exit 1
fi

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; RED=''; BOLD=''; RESET=''
fi

tmp_root="$(mktemp -d -t gero-test-examples.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

mapfile -t -d '' gas_files < <(find "$EXAMPLES_DIR" -type f -name '*.gas' -print0 | sort -z)

if [[ ${#gas_files[@]} -eq 0 ]]; then
    printf 'test-examples: no .gas files under %s\n' "$EXAMPLES_DIR" >&2
    exit 1
fi

pass=0; fail=0; skip=0
for gas in "${gas_files[@]}"; do
    expected="${gas%.gas}.expected"
    if [[ ! -f "$expected" ]]; then
        # Sibling .gas with no golden file — include-only fragment
        # (e.g. examples/asm/banks/bank0_greet.gas). Drive these
        # through the entry program, not on their own.
        skip=$((skip+1))
        continue
    fi

    rel="${gas#$EXAMPLES_DIR/}"
    name="${rel//\//-}"; name="${name%.gas}"
    work="$tmp_root/$name"
    mkdir -p "$work"
    gx="$work/out.gx"
    actual="$work/stdout"

    printf '  %-24s ... ' "$rel"

    rc=0
    "$GERO_BIN" asm --quiet "$gas" -o "$gx" >"$work/asm.err" 2>&1 || rc=$?
    if (( rc != 0 )); then
        printf '%sFAIL%s (asm, exit=%d)\n' "$RED" "$RESET" "$rc"
        sed 's/^/      /' "$work/asm.err"
        fail=$((fail+1))
        continue
    fi

    rc=0
    "$GERO_BIN" run "$gx" >"$actual" 2>"$work/run.err" || rc=$?
    if (( rc != 0 )); then
        printf '%sFAIL%s (run, exit=%d)\n' "$RED" "$RESET" "$rc"
        sed 's/^/      /' "$work/run.err"
        fail=$((fail+1))
        continue
    fi

    if ! diff -u "$expected" "$actual" >"$work/diff" 2>&1; then
        printf '%sFAIL%s (stdout)\n' "$RED" "$RESET"
        sed 's/^/      /' "$work/diff"
        fail=$((fail+1))
        continue
    fi

    printf '%sok%s\n' "$GREEN" "$RESET"
    pass=$((pass+1))
done

printf '\n%sexamples:%s %d passed, %d failed' "$BOLD" "$RESET" "$pass" "$fail"
if (( skip > 0 )); then
    plural=""
    (( skip == 1 )) || plural="s"
    printf ', %d include-only file%s skipped' "$skip" "$plural"
fi
printf '\n'

(( fail == 0 )) || exit 1
