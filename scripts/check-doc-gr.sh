#!/usr/bin/env bash
#
# Parse every ```gero block in the language docs and fail on any that
# doesn't. The spec's examples are what someone learning the language
# copies, so an example that can't parse teaches wrong syntax — the
# failure mode this gate exists to catch. Two shipped examples had
# never compiled before it existed.
#
# Only syntax is checked. Most blocks are fragments that reference
# symbols the surrounding prose defines, so type errors are expected
# and ignored; a syntax error never is.
#
# A block whose first line is `-- fragment: <why>` is skipped entirely,
# for the few that cannot parse on their own: an elided body (`...`),
# or a block that deliberately shows a compile error.
#
# Env knobs:
#   GERO_BIN — path to the `gero` binary (default ./zig-out/bin/gero)
#   DOCS     — space-separated documents to check
#
# Exit codes:
#   0 — every non-fragment block parses
#   1 — at least one block failed, or a precondition is missing

set -euo pipefail

GERO_BIN="${GERO_BIN:-./zig-out/bin/gero}"
DOCS="${DOCS:-docs/lang.md}"

# Expand the list once: entries may be globs, and a directory with no
# chapters in it yet is not an error. Keeping only what exists means
# the loops below never see an unmatched pattern.
expanded=""
for doc in $DOCS; do
    [[ -f "$doc" ]] && expanded="$expanded $doc"
done
DOCS="$expanded"


if [[ ! -x "$GERO_BIN" ]]; then
    printf 'check-doc-gr: %s not found — run `zig build install` first\n' "$GERO_BIN" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

checked=0
failed=0

for doc in $DOCS; do
    if [[ ! -f "$doc" ]]; then
        printf 'check-doc-gr: %s not found\n' "$doc" >&2
        exit 1
    fi

    rm -rf "$work/blocks"
    mkdir -p "$work/blocks"

    # Split the document into one file per ```gero block, named by the
    # line the block opens on so a failure points back at the source.
    awk -v dir="$work/blocks" '
        /^```gero$/ { inblock = 1; start = NR; n = 0; next }
        inblock && /^```$/ {
            f = dir "/" start ".gr"
            for (i = 0; i < n; i++) print buf[i] > f
            close(f)
            inblock = 0
            next
        }
        inblock { buf[n++] = $0 }
    ' "$doc"

    for f in "$work/blocks"/*.gr; do
        [[ -e "$f" ]] || continue
        line="$(basename "$f" .gr)"
        if head -n 1 "$f" | grep -q '^-- fragment:'; then
            continue
        fi
        checked=$((checked + 1))
        # Type errors are expected — a fragment names symbols the prose
        # defines. Only syntax diagnostics fail the gate.
        out="$("$GERO_BIN" check "$f" 2>&1 || true)"
        if printf '%s' "$out" | grep -q 'E_SYNTAX_'; then
            failed=$((failed + 1))
            printf '%s:%s: block does not parse\n' "$doc" "$line"
            printf '%s\n' "$out" | grep -m2 'error:' | sed 's/^ *//; s/^/    /'
        fi
    done
done

if [[ "$failed" -gt 0 ]]; then
    printf '\ncheck-doc-gr: %d of %d blocks failed\n' "$failed" "$checked" >&2
    exit 1
fi
printf 'check-doc-gr: %d blocks parsed, 0 failed\n' "$checked"
