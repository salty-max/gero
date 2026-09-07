#!/usr/bin/env bash
#
# Build and run every example through `gero.wasm` and diff stdout
# against the same `.expected` files the native gates use.
#
# This is what turns "wasm32 compiles" into "wasm32 runs". The
# cross-target matrix proves the library builds for wasm; nothing
# else proves it *behaves* there, because every other runtime test
# runs natively. A difference here is a real native-vs-wasm
# divergence, not a fixture mismatch — the fixtures are shared.
#
# Env knobs:
#   GERO_WASM      — path to the module (default ./zig-out/bin/gero.wasm)
#   EXAMPLES_DIRS  — space-separated roots to walk (default the two corpora)
#   NO_COLOR       — disable ANSI colors (auto-off when not a TTY)
#
# Exit codes:
#   0 — every example built, ran to `hlt`, and matched its golden output
#   1 — at least one differed, or a precondition is missing

set -euo pipefail

GERO_WASM="${GERO_WASM:-./zig-out/bin/gero.wasm}"
EXAMPLES_DIRS="${EXAMPLES_DIRS:-examples/asm examples/lang}"
DRIVER="scripts/wasm-run-example.mjs"

if ! command -v node >/dev/null 2>&1; then
    printf 'test-wasm-examples: node is required to execute the wasm module.\n' >&2
    printf '  The Zig gates cannot run wasm on their own; a JS host stands in\n' >&2
    printf '  for the browser this module is built for.\n' >&2
    exit 1
fi

if [[ ! -f "$GERO_WASM" ]]; then
    printf 'test-wasm-examples: %s not found — run `zig build wasm` first\n' "$GERO_WASM" >&2
    exit 1
fi

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; RED=''; BOLD=''; RESET=''
fi

tmp_root="$(mktemp -d -t gero-test-wasm-examples.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

passed=0
failed=0

# An example is anything with a golden `.expected` beside it. That is
# also what makes the corpus self-registering: adding an example with
# its expected output adds it here, with no list to update.
while IFS= read -r expected; do
    dir="$(dirname "$expected")"
    stem="$(basename "$expected" .expected)"

    entry=""
    for candidate in "$dir/$stem.gr" "$dir/$stem.gas"; do
        [[ -f "$candidate" ]] && entry="$candidate" && break
    done
    if [[ -z "$entry" ]]; then
        printf '  %-40s ... %sno source beside it%s\n' "$stem" "$RED" "$RESET"
        failed=$((failed + 1))
        continue
    fi

    actual="$tmp_root/$stem.out"
    if ! node "$DRIVER" "$GERO_WASM" "$entry" >"$actual" 2>"$tmp_root/$stem.err"; then
        printf '  %-40s ... %sFAIL%s\n' "${entry#./}" "$RED" "$RESET"
        sed 's/^/      /' "$tmp_root/$stem.err" >&2
        failed=$((failed + 1))
        continue
    fi

    if diff -u "$expected" "$actual" >"$tmp_root/$stem.diff" 2>&1; then
        printf '  %-40s ... %sok%s\n' "${entry#./}" "$GREEN" "$RESET"
        passed=$((passed + 1))
    else
        printf '  %-40s ... %sDIFFERS%s\n' "${entry#./}" "$RED" "$RESET"
        printf '      native and wasm disagree about this program:\n' >&2
        sed 's/^/      /' "$tmp_root/$stem.diff" >&2
        failed=$((failed + 1))
    fi
done < <(for root in $EXAMPLES_DIRS; do find "$root" -name '*.expected' | sort; done)

printf '\n%stest-wasm-examples%s: %d passed, %d failed\n' "$BOLD" "$RESET" "$passed" "$failed"
[[ "$failed" -eq 0 ]]
