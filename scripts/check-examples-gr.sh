#!/usr/bin/env bash
#
# Gate the `docs/examples/*.gr` showcases so they stay valid + canonical
# references. Every `.gr` example must be canonical under `gero fmt
# --check`. Examples also pass `gero check` (parse + typecheck clean)
# unless they carry the `gero-example: fmt-only` marker in a comment —
# that opts a syntax-only fragment (one that references illustrative
# externals) out of the type-check, keeping just the formatting gate.
#
# Env knobs:
#   GERO_BIN       — path to the `gero` binary (default ./zig-out/bin/gero)
#   EXAMPLES_DIR   — root to walk for *.gr (default docs/examples)
#   NO_COLOR       — disable ANSI colors (auto-off when stdout is not a TTY)
#
# Exit codes:
#   0 — every example is canonical (and type-checks, unless fmt-only)
#   1 — at least one example failed, or a precondition is missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
# Space-separated roots: the doc tours plus the runnable lang suite.
EXAMPLES_DIRS="${EXAMPLES_DIRS:-docs/examples examples/lang}"
FMT_ONLY_MARKER="gero-example: fmt-only"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'check-examples-gr: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; RED=''; DIM=''; BOLD=''; RESET=''
fi

present_dirs=()
for d in $EXAMPLES_DIRS; do
    [[ -d "$d" ]] && present_dirs+=("$d")
done
if [[ ${#present_dirs[@]} -eq 0 ]]; then
    printf 'check-examples-gr: none of [%s] exist\n' "$EXAMPLES_DIRS" >&2
    exit 1
fi

mapfile -t -d '' gr_files < <(find "${present_dirs[@]}" -type f -name '*.gr' -print0 | sort -z)

if [[ ${#gr_files[@]} -eq 0 ]]; then
    printf 'check-examples-gr: no .gr files under [%s]\n' "$EXAMPLES_DIRS" >&2
    exit 1
fi

pass=0; fail=0
for gr in "${gr_files[@]}"; do
    rel="${gr#./}"
    fmt_only=0
    grep -qF "$FMT_ONLY_MARKER" "$gr" && fmt_only=1

    if (( fmt_only )); then
        printf '  %-44s %s(fmt-only)%s ... ' "$rel" "$DIM" "$RESET"
    else
        printf '  %-44s ... ' "$rel"
    fi

    rc=0
    out="$("$GERO_BIN" fmt --check "$gr" 2>&1)" || rc=$?
    if (( rc != 0 )); then
        printf '%sFAIL%s (fmt --check, exit=%d)\n' "$RED" "$RESET" "$rc"
        [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail+1))
        continue
    fi

    if (( ! fmt_only )); then
        rc=0
        out="$("$GERO_BIN" check --quiet "$gr" 2>&1)" || rc=$?
        if (( rc != 0 )); then
            printf '%sFAIL%s (check, exit=%d)\n' "$RED" "$RESET" "$rc"
            [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/      /'
            fail=$((fail+1))
            continue
        fi
    fi

    printf '%sok%s\n' "$GREEN" "$RESET"
    pass=$((pass+1))
done

printf '\n%scheck-examples-gr:%s %d passed, %d failed\n' "$BOLD" "$RESET" "$pass" "$fail"
(( fail == 0 ))
