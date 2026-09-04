#!/usr/bin/env bash
#
# Prune stale build outputs from `.zig-cache/o/` without nuking the
# warm working set. Zig content-hashes every build output into its own
# `o/<hash>` dir and never reclaims old ones, so a cross-target /
# multi-mode workflow (`zig build ci`) grows the cache without bound
# across commits. This drops output dirs not modified in the last
# MAX_AGE_DAYS; Zig treats a missing output as a cache miss and rebuilds
# it on demand, so pruning is always safe. Dirs touched by recent builds
# keep a fresh mtime and survive — only stale commits' artifacts go.
#
# Unlike `zig build clean` (full wipe → next build is cold), this keeps
# active work warm. Run it periodically, or wire a scheduled job to it.
#
# Env knobs:
#   CACHE_DIR      — cache root to prune (default ./.zig-cache)
#   MAX_AGE_DAYS   — prune o/ dirs older than this many days (default 3)
#   NO_COLOR       — disable ANSI colors (auto-off when stdout is not a TTY)
#
# Exit codes:
#   0 — pruned cleanly, or nothing to prune (cache absent)
#   1 — a precondition is missing (bad MAX_AGE_DAYS)

set -euo pipefail

CACHE_DIR="${CACHE_DIR:-./.zig-cache}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-3}"

if ! [[ "$MAX_AGE_DAYS" =~ ^[0-9]+$ ]]; then
    printf 'clean-cache: MAX_AGE_DAYS must be a non-negative integer, got %q\n' "$MAX_AGE_DAYS" >&2
    exit 1
fi

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[32m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    GREEN=''; BOLD=''; RESET=''
fi

outputs_dir="$CACHE_DIR/o"
if [[ ! -d "$outputs_dir" ]]; then
    printf '%sclean-cache:%s no %s — nothing to prune\n' "$BOLD" "$RESET" "$outputs_dir"
    exit 0
fi

# `du -sk` is portable across macOS/Linux; KiB avoids float math in bash.
before_kb="$(du -sk "$CACHE_DIR" 2>/dev/null | cut -f1)"

# -mtime +N matches dirs last modified strictly more than N days ago.
# -maxdepth 1 keeps us at the o/<hash> granularity — never descends to
# prune individual files out from under an otherwise-warm output dir.
stale=()
while IFS= read -r -d '' path; do
    stale+=("$path")
done < <(
    find "$outputs_dir" -mindepth 1 -maxdepth 1 -type d -mtime "+$MAX_AGE_DAYS" -print0
)

pruned=${#stale[@]}
if (( pruned > 0 )); then
    rm -rf "${stale[@]}"
fi

after_kb="$(du -sk "$CACHE_DIR" 2>/dev/null | cut -f1)"
freed_mb=$(( (before_kb - after_kb) / 1024 ))

printf '%sclean-cache:%s pruned %d stale output dir(s) older than %d day(s), freed %s%d MB%s\n' \
    "$BOLD" "$RESET" "$pruned" "$MAX_AGE_DAYS" "$GREEN" "$freed_mb" "$RESET"
