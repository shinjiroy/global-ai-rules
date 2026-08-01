#!/usr/bin/env bash
# Check everything that can abort a delegation, before anything expensive happens.
#
# Usage:
#     preflight.sh [<target repo>] [--implementation]
#
# Checks that cursor-agent is installed and logged in. With a repository and
# --implementation, also requires a clean working tree. Prints the evidence a
# failure report needs, so no second diagnostic round is necessary.
#
# Exit: 0 ready / 1 not installed / 2 not logged in / 3 dirty tree / 64 bad usage
set -euo pipefail

repo=""
implementation=0
for a in "$@"; do
  case "$a" in
    --implementation) implementation=1 ;;
    -h|--help) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) repo=$a ;;
  esac
done

command -v cursor-agent >/dev/null || { echo "NOT_INSTALLED: cursor-agent is not on PATH"; exit 1; }

status=$(cursor-agent status 2>&1)
# Match on the output: `cursor-agent status` exits 0 even when logged out.
grep -q "Logged in" <<<"$status" || { echo "NOT_LOGGED_IN: $status"; exit 2; }

if [ "$implementation" -eq 1 ]; then
  [ -n "$repo" ] || { echo "--implementation needs a repository path" >&2; exit 64; }
  [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || { echo "not a git repository: $repo" >&2; exit 64; }
  dirty=$(git -C "$repo" status --porcelain)
  if [ -n "$dirty" ]; then
    echo "DIRTY_TREE: the working tree already carries changes"
    printf '%s\n' "$dirty"
    exit 3
  fi
fi

echo "GATE_OK: $(command -v cursor-agent) / $status"
