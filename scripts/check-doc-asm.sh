#!/usr/bin/env bash
#
# Assemble every ```asm block in docs/asm.md and fail on any that
# doesn't. The spec's examples are what someone learning the assembler
# copies, so an example that can't assemble teaches wrong syntax — the
# failure mode this gate exists to catch.
#
# A block whose first line is `; fragment: <why>` is skipped: it names
# symbols the surrounding prose defines and cannot stand alone.
#
# Env knobs:
#   GERO_BIN  — path to the `gero` binary (default ./zig-out/bin/gero)
#   DOCS      — space-separated documents to check
#               (default docs/asm.md)
#
# Exit codes:
#   0 — every non-fragment block assembles
#   1 — at least one block failed, or a precondition is missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
# `DOC` stays accepted so an existing caller keeps working.
DOCS="${DOCS:-${DOC:-docs/asm.md}}"

if [[ ! -x "$GERO_BIN" ]]; then
    printf 'check-doc-asm: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi
for doc in $DOCS; do
    if [[ ! -f "$doc" ]]; then
        printf 'check-doc-asm: %s not found\n' "$doc" >&2
        exit 1
    fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

checked=0
failed=0

for doc in $DOCS; do
    blocks="$work/blocks"
    rm -rf "$blocks"
    mkdir -p "$blocks"

    # Split the document into one file per ```asm block, named by the
    # line the block opens on so a failure points back at the source.
    awk -v dir="$blocks" '
        /^```asm$/ { inblock = 1; start = NR; n = 0; next }
        inblock && /^```$/ {
            f = dir "/" start ".gas"
            for (i = 0; i < n; i++) print buf[i] > f
            close(f)
            inblock = 0
            next
        }
        inblock { buf[n++] = $0 }
    ' "$doc"

    for f in "$blocks"/*.gas; do
        [[ -e "$f" ]] || continue
        line="$(basename "$f" .gas)"
        if head -n 1 "$f" | grep -q '^; fragment:'; then
            continue
        fi
        # A block without a label is a body: give it an entry point so
        # it stands alone, the way the surrounding prose implies.
        src="$work/wrapped.gas"
        if grep -qE '^[A-Za-z_][A-Za-z0-9_.]*:' "$f"; then
            cp "$f" "$src"
        else
            { printf 'main:\n'; cat "$f"; printf '  hlt\n'; } > "$src"
        fi
        checked=$((checked + 1))
        if ! out="$("$GERO_BIN" asm "$src" -o "$work/out.gx" 2>&1)"; then
            failed=$((failed + 1))
            printf '%s:%s: block does not assemble\n' "$doc" "$line"
            printf '%s\n' "$out" | grep -E '^[[:space:]]*[0-9]+:[0-9]+' | head -n 2 | sed 's/^/    /'
        fi
    done
done

if [[ "$failed" -gt 0 ]]; then
    printf '\ncheck-doc-asm: %d of %d blocks failed\n' "$failed" "$checked" >&2
    exit 1
fi
printf 'check-doc-asm: %d blocks assembled, 0 failed\n' "$checked"
