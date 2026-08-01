#!/usr/bin/env bash
# Create a scratch directory for one delegation and seed it with the prompt template.
#
# Usage:
#     new-run.sh
#
# Prints the directory path on stdout. Everything a run produces lives here, outside
# the target repository, so the post-run `git status` check stays meaningful.
set -euo pipefail

template="$(cd "$(dirname "${BASH_SOURCE[0]}")/../assets" && pwd)/prompt-template.md"

run=$(mktemp -d /tmp/ca-run-XXXXXX)
if [ -f "$template" ]; then
  cp "$template" "$run/prompt.md"
else
  : > "$run/prompt.md"
fi

printf '%s\n' "$run"
