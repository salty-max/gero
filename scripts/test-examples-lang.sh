#!/usr/bin/env bash
#
# Drive every gero-lang example under examples/lang/ through the `gero`
# CLI — `compile` to a `.gx`, `run` it, and diff stdout against the
# golden `.expected` file alongside it. The lang counterpart to
# `test-examples.sh` (which covers asm); wired into `zig build
# test-examples-lang` and `zig build ci`.
#
# Env knobs:
#   GERO_BIN       — path to the `gero` binary (default ./zig-out/bin/gero)
#   EXAMPLES_DIR   — root to walk for *.gr (default examples/lang)
#   NO_COLOR       — disable ANSI colors (auto-off when stdout is not a TTY)
#
# Exit codes:
#   0 — every example compiled, ran, and matched its golden output
#   1 — at least one example failed, or a precondition is missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
EXAMPLES_DIR="${EXAMPLES_DIR:-examples/lang}"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'test-examples-lang: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi

if [[ ! -d "$EXAMPLES_DIR" ]]; then
    printf 'test-examples-lang: %s missing\n' "$EXAMPLES_DIR" >&2
    exit 1
fi

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; RED=''; BOLD=''; RESET=''
fi

tmp_root="$(mktemp -d -t gero-test-examples-lang.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

gr_files=()
while IFS= read -r -d '' path; do
    gr_files+=("$path")
done < <(find "$EXAMPLES_DIR" -type f -name '*.gr' -print0 | sort -z)

if [[ ${#gr_files[@]} -eq 0 ]]; then
    printf 'test-examples-lang: no .gr files under %s\n' "$EXAMPLES_DIR" >&2
    exit 1
fi

pass=0; fail=0; skip=0
for gr in "${gr_files[@]}"; do
    expected="${gr%.gr}.expected"
    if [[ ! -f "$expected" ]]; then
        # No golden file — an importable module fragment, not a
        # standalone program. Driven through its importer, not here.
        skip=$((skip+1))
        continue
    fi

    rel="${gr#$EXAMPLES_DIR/}"
    name="${rel//\//-}"; name="${name%.gr}"
    work="$tmp_root/$name"
    mkdir -p "$work"
    gx="$work/out.gx"
    actual="$work/stdout"

    printf '  %-28s ... ' "$rel"

    rc=0
    "$GERO_BIN" compile --quiet "$gr" -o "$gx" >"$work/compile.err" 2>&1 || rc=$?
    if (( rc != 0 )); then
        printf '%sFAIL%s (compile, exit=%d)\n' "$RED" "$RESET" "$rc"
        sed 's/^/      /' "$work/compile.err"
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

printf '\n%sexamples-lang:%s %d passed, %d failed' "$BOLD" "$RESET" "$pass" "$fail"
if (( skip > 0 )); then
    plural=""
    (( skip == 1 )) || plural="s"
    printf ', %d module-only file%s skipped' "$skip" "$plural"
fi
printf '\n'

(( fail == 0 )) || exit 1
