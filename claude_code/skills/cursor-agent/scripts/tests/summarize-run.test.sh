#!/usr/bin/env bash
# Tests for summarize-run.sh. Run it directly:
#
#     scripts/tests/summarize-run.test.sh
#
# Each case writes a log (and, where it applies, the marker await-run.sh leaves)
# into a scratch directory. Nothing here invokes the real CLI.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
summarize=$here/../summarize-run.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/summarize-run-test-XXXXXX")
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
check() {  # check <name> <expected exit> <actual exit>
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf 'ok   %s\n' "$1"
  else
    fail=$((fail + 1)); printf 'FAIL %s: expected exit %s, got %s\n' "$1" "$2" "$3"
  fi
}
note() {  # note <name> <condition description> <0|1 result>
  if [ "$3" = 0 ]; then
    pass=$((pass + 1)); printf 'ok   %s: %s\n' "$1" "$2"
  else
    fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"
  fi
}

work_event() { printf '{"type":"assistant","session_id":"s1"}\n'; }
result_event() { printf '{"type":"result","is_error":false,"session_id":"s1","result":"done","usage":{"inputTokens":1,"outputTokens":2}}\n'; }
limit_marker() { printf 'TOOL_LIMIT: the run started 2 or more tool calls and was killed\n'; }

# --- 1. cut off after it began working: resume it ---
log=$tmp/interrupted.ndjson
work_event > "$log"
out=$("$summarize" "$log" 2>&1); rc=$?
check "cut off, no marker" 4 $rc
case $out in *INTERRUPTED*) r=0 ;; *) r=1 ;; esac
note "cut off, no marker" "says INTERRUPTED" $r

# --- 2. the same log, stopped at its tool-call limit: do not resume ---
log=$tmp/limit.ndjson
work_event > "$log"
limit_marker > "$log.tool-limit"
out=$("$summarize" "$log" 2>&1); rc=$?
check "stopped at the limit" 5 $rc
case $out in *TOOL_LIMIT:*) r=0 ;; *) r=1 ;; esac
note "stopped at the limit" "relays the TOOL_LIMIT verdict" $r
case $out in *INTERRUPTED*|*"resume it"*) r=1 ;; *) r=0 ;; esac
note "stopped at the limit" "does not say to resume" $r

# --- 3. a result event written while being stopped does not hide the limit ---
log=$tmp/limit-with-result.ndjson
{ work_event; result_event; } > "$log"
limit_marker > "$log.tool-limit"
"$summarize" "$log" >/dev/null 2>&1
check "stopped at the limit, result present" 5 $?

# --- 4. a finished run without the marker is unchanged ---
log=$tmp/finished.ndjson
{ work_event; result_event; } > "$log"
"$summarize" "$log" >/dev/null 2>&1
check "finished" 0 $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
