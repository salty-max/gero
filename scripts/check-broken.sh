#!/usr/bin/env bash
#
# Sad-path companion to `check-examples.sh`. Drives every
# `tests/asm/check-broken/*.gas` through `gero check` and asserts
# **each one exits non-zero** with a diagnostic — verifies that
# the validator actually catches what it's supposed to catch.
#
# Each fixture targets a distinct diagnostic category (lexical
# parse error, [E001] unknown mnemonic, [E004] undefined symbol,
# [E005] duplicate label). If any fixture starts passing the
# check, this script fails — that's a regression in `gero check`
# (or a fixture that's drifted into validity and needs updating).
#
# Env knobs:
#   GERO_BIN       — path to the `gero` binary (default ./zig-out/bin/gero)
#   FIXTURES_DIR   — root to walk (default tests/asm/check-broken)
#   NO_COLOR       — disable ANSI colors (auto-off when stdout is not a TTY)
#
# Exit codes:
#   0 — every fixture failed as expected
#   1 — at least one fixture unexpectedly passed, or a precondition missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
FIXTURES_DIR="${FIXTURES_DIR:-tests/asm/check-broken}"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'check-broken: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi

if [[ ! -d "$FIXTURES_DIR" ]]; then
    printf 'check-broken: %s missing\n' "$FIXTURES_DIR" >&2
    exit 1
fi

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; RED=''; BOLD=''; RESET=''
fi

mapfile -t -d '' fixtures < <(find "$FIXTURES_DIR" -type f -name '*.gas' -print0 | sort -z)

if [[ ${#fixtures[@]} -eq 0 ]]; then
    printf 'check-broken: no .gas fixtures under %s\n' "$FIXTURES_DIR" >&2
    exit 1
fi

caught=0; missed=0
for gas in "${fixtures[@]}"; do
    rel="${gas#$FIXTURES_DIR/}"
    printf '  %-32s ... ' "$rel"

    rc=0
    "$GERO_BIN" check --quiet "$gas" >/dev/null 2>&1 || rc=$?
    if (( rc == 0 )); then
        printf '%sMISSED%s (gero check passed, expected failure)\n' "$RED" "$RESET"
        missed=$((missed+1))
    else
        printf '%scaught%s (exit=%d)\n' "$GREEN" "$RESET" "$rc"
        caught=$((caught+1))
    fi
done

printf '\n%scheck-broken:%s %d caught, %d missed\n' "$BOLD" "$RESET" "$caught" "$missed"
if (( missed > 0 )); then
    exit 1
fi
