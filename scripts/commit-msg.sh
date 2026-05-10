#!/usr/bin/env bash
# commit-msg hook wrapper.
#
# Runs convco for type/scope/description validation, AND adds an explicit
# scope-mandatory check on top — convco's scopeRegex only fires when a scope
# is present, so a `feat: foo` (no scope) commit passes convco silently.
#
# Usage:
#   bash scripts/commit-msg.sh <commit-msg-file>
#
# Exits non-zero on any violation; the message is left unchanged.
set -e

msg_file="$1"
if [[ -z "$msg_file" || ! -f "$msg_file" ]]; then
  echo "commit-msg.sh: expected commit message file as \$1" >&2
  exit 2
fi

first_line="$(head -n 1 "$msg_file")"

# Skip auto-generated commits that don't follow conventional format.
case "$first_line" in
  Merge*|Revert*|"fixup! "*|"squash! "*|"amend! "*) exit 0 ;;
esac

# Enforce scope presence: <type>(<scope>)[!]: <subject>
if ! [[ "$first_line" =~ ^[a-z]+\([a-zA-Z0-9/_-]+\)\!?:[[:space:]] ]]; then
  cat >&2 <<EOF
❌ Commit subject must include a scope.

   Format:    <type>(<scope>)[!]: <subject>
   Got:       $first_line

   Allowed scopes: parser, core, util, tooling, ci, docs, meta, parsers/<name>
   See CLAUDE.md "Commit Convention".
EOF
  exit 1
fi

# Defer the rest (type allowed, scope-regex enum, length, description, etc.)
# to convco, which reads .versionrc.
convco check --from-stdin <"$msg_file"
