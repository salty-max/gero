#!/usr/bin/env bash
#
# Compare the bench corpus against its committed baselines.
#
# Two measurements per program, gated differently because they are
# different kinds of number:
#
#   cycles — exact. The VM is deterministic, so a change means the
#            emitted program changed, not the machine.
#   rate   — a floor. Wall-clock throughput varies by machine, so the
#            gate only catches a collapse.
#
# Exit codes: 0 all within baseline, 1 otherwise.
set -euo pipefail

GERO_BIN="${GERO_BIN:-zig-out/bin/gero}"
BASELINES="${BASELINES:-benches/baselines.txt}"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'check-benches: no gero at %s — run `zig build` first\n' "$GERO_BIN" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failed=0
checked=0

while read -r name want_cycles floor; do
    [[ -z "${name:-}" || "$name" == \#* ]] && continue
    src="benches/$name"
    gx="$work/${name%.gas}.gx"

    if ! "$GERO_BIN" asm "$src" -o "$gx" >/dev/null 2>&1; then
        printf '  %-14s does not assemble\n' "$name"
        failed=$((failed + 1))
        continue
    fi

    got_cycles="$("$GERO_BIN" run --cycles "$gx" 2>&1 | grep -oE '[0-9]+$' | tail -n 1)"

    start="$(python3 -c 'import time; print(time.time())')"
    "$GERO_BIN" run "$gx" >/dev/null 2>&1
    end="$(python3 -c 'import time; print(time.time())')"
    rate="$(python3 -c "print(f'{$got_cycles/(($end-$start)*1e6):.2f}')")"

    checked=$((checked + 1))
    status=ok
    if [[ "$got_cycles" != "$want_cycles" ]]; then
        status="CYCLES $want_cycles -> $got_cycles"
        failed=$((failed + 1))
    elif python3 -c "import sys; sys.exit(0 if $rate < $floor else 1)"; then
        status="SLOW ${rate} M/s below floor ${floor}"
        failed=$((failed + 1))
    fi
    printf '  %-14s %10s cycles  %6s M/s  %s\n' "$name" "$got_cycles" "$rate" "$status"
done < "$BASELINES"

if [[ "$failed" -gt 0 ]]; then
    cat >&2 <<'EOF'

check-benches: a baseline moved.

A cycle count changing means the emitted program changed — deliberate
or not, say which in the PR and re-bless the row. A rate below the
floor means something in the hot path collapsed; profile before
re-blessing, because the floor is set low enough that reaching it is
a real regression rather than a slow machine.
EOF
    exit 1
fi
printf 'check-benches: %d benches within baseline\n' "$checked"
