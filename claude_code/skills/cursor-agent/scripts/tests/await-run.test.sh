#!/usr/bin/env bash
# Tests for await-run.sh. Run it directly:
#
#     scripts/tests/await-run.test.sh
#
# Each case builds a scratch run directory, and where the case needs a live run,
# a detached sleeper standing in for cursor-agent. Nothing here invokes the real
# CLI or touches the network.
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
await=$here/../await-run.sh
tmp=$(mktemp -d "${TMPDIR:-/tmp}/await-run-test-XXXXXX")

# A case that fails may leave its sleeper running, and the suite must still end.
cleanup() {
  for f in "$tmp"/*/ca.pid "$tmp"/*/child.pid; do
    [ -s "$f" ] || continue
    kill -TERM -"$(cat "$f")" 2>/dev/null || kill -TERM "$(cat "$f")" 2>/dev/null || true
  done
  rm -rf "$tmp"
}
trap cleanup EXIT

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

new_run() {  # new_run <name> -> prints the run dir
  local d=$tmp/$1
  mkdir -p "$d"
  printf '%s\n' "$d"
}
result_event() { printf '{"type":"result","is_error":false,"session_id":"s1","result":"done"}\n'; }
work_event() { printf '{"type":"assistant","session_id":"s1"}\n'; }
tool_started() {  # tool_started <kind>, e.g. read -> readToolCall
  printf '{"type":"tool_call","subtype":"started","call_id":"c","tool_call":{"%sToolCall":{"args":{}},"hookAdditionalContexts":[]}}\n' "$1"
}
tool_completed() {
  printf '{"type":"tool_call","subtype":"completed","call_id":"c","tool_call":{"%sToolCall":{"args":{},"result":{}},"hookAdditionalContexts":[]}}\n' "$1"
}

# A stand-in for a cursor-agent run that leaks a child: the group leader sleeps,
# and so does a child it started. Both must be gone once await-run.sh returns.
start_leaky_run() {  # start_leaky_run <run dir>
  local d=$1
  # Detached from this suite's stdio: a sleeper that survives a failing case would
  # otherwise hold the suite's output pipe open and hang whatever reads it.
  setsid bash -c 'echo $$ > "'"$d"'/ca.pid"; sleep 300 & echo $! > "'"$d"'/child.pid"; exec sleep 300' \
    </dev/null >/dev/null 2>&1 &
  local i=0
  while [ ! -s "$d/ca.pid" ] || [ ! -s "$d/child.pid" ]; do
    sleep 0.1; i=$((i + 1)); [ $i -gt 50 ] && { echo "sleeper did not start" >&2; return 1; }
  done
  sleep 0.2   # let the leader exec before anything reads its pgid
}

# --- 1. the result event alone ends the wait, with no process to check ---
d=$(new_run result-only)
result_event > "$d/ca.ndjson"
"$await" "$d/ca.ndjson" >/dev/null 2>&1
check "result event, no pid file" 0 $?

# --- 2. the bug this script exists for: result present, process still alive ---
# The old `while kill -0` loop never returns here. Every leaked process must die.
d=$(new_run leaked-process)
start_leaky_run "$d" || exit 1
{ work_event; result_event; } > "$d/ca.ndjson"
out=$("$await" "$d/ca.ndjson" 2>&1); rc=$?
check "result event while the process is alive" 0 $rc
case $out in *"was killed"*) r=0 ;; *) r=1 ;; esac
note "result event while the process is alive" "reports the kill" $r
sleep 1
kill -0 "$(cat "$d/ca.pid")" 2>/dev/null; r=$?
note "result event while the process is alive" "the run process is gone" "$([ $r -ne 0 ] && echo 0 || echo 1)"
kill -0 "$(cat "$d/child.pid")" 2>/dev/null; r=$?
note "result event while the process is alive" "the leaked child is gone" "$([ $r -ne 0 ] && echo 0 || echo 1)"

# --- 3. a result event that only arrives partway through the wait ---
d=$(new_run result-later)
work_event > "$d/ca.ndjson"
start_leaky_run "$d" || exit 1
( sleep 3; result_event >> "$d/ca.ndjson" ) &
"$await" "$d/ca.ndjson" --poll-seconds 1 >/dev/null 2>&1
check "result event arriving mid-wait" 0 $?

# --- 4. the process exits before writing a result event ---
d=$(new_run interrupted)
work_event > "$d/ca.ndjson"
setsid bash -c 'echo $$ > "'"$d"'/ca.pid"; exec sleep 2' </dev/null >/dev/null 2>&1 &
while [ ! -s "$d/ca.pid" ]; do sleep 0.1; done
"$await" "$d/ca.ndjson" --poll-seconds 1 >/dev/null 2>&1
check "process gone before its result event" 4 $?

# --- 5. no result event and a log nobody is writing to ---
d=$(new_run stalled)
work_event > "$d/ca.ndjson"
start_leaky_run "$d" || exit 1
touch -d '@0' "$d/ca.ndjson" 2>/dev/null || touch -t 197001020000 "$d/ca.ndjson"
"$await" "$d/ca.ndjson" --stall-seconds 5 --poll-seconds 1 >/dev/null 2>&1
check "stalled log" 3 $?
kill -TERM -"$(cat "$d/ca.pid")" 2>/dev/null

# --- 6. an active log holds the stall check off ---
# Guards against a stall rule that fires on any run slower than its threshold.
d=$(new_run stall-not-triggered)
work_event > "$d/ca.ndjson"
start_leaky_run "$d" || exit 1
( for _ in 1 2 3 4; do sleep 1; work_event >> "$d/ca.ndjson"; done; result_event >> "$d/ca.ndjson" ) &
"$await" "$d/ca.ndjson" --stall-seconds 3 --poll-seconds 1 >/dev/null 2>&1
check "an active log is not a stall" 0 $?

# --- 7. a follow-up log with its own pid file ---
d=$(new_run followup)
result_event > "$d/ca-followup-1.ndjson"
work_event > "$d/ca.ndjson"          # the first run's log must not be consulted
"$await" "$d/ca-followup-1.ndjson" >/dev/null 2>&1
check "follow-up log named explicitly" 0 $?

# --- 8. the tool-call limit stops a live run and everything it started ---
d=$(new_run tool-limit)
start_leaky_run "$d" || exit 1
{ work_event; tool_started read; tool_started edit; tool_started shell; } > "$d/ca.ndjson"
out=$("$await" "$d/ca.ndjson" --max-tool-calls 3 --poll-seconds 1 2>&1); rc=$?
check "tool-call limit reached" 5 $rc
case $out in *TOOL_LIMIT:*) r=0 ;; *) r=1 ;; esac
note "tool-call limit reached" "reports TOOL_LIMIT" $r
case $out in *"tool calls: 3 (edit 1, read 1, shell 1)"*) r=0 ;; *) r=1 ;; esac
note "tool-call limit reached" "reports the count and its breakdown" $r
sleep 1
kill -0 "$(cat "$d/ca.pid")" 2>/dev/null; r=$?
note "tool-call limit reached" "the run process is gone" "$([ $r -ne 0 ] && echo 0 || echo 1)"
kill -0 "$(cat "$d/child.pid")" 2>/dev/null; r=$?
note "tool-call limit reached" "the leaked child is gone" "$([ $r -ne 0 ] && echo 0 || echo 1)"

# --- 9. only `started` events count; `completed` ones for the same calls do not ---
d=$(new_run tool-limit-completed-not-counted)
start_leaky_run "$d" || exit 1
{ tool_started read; tool_completed read; tool_started edit; tool_completed edit; } > "$d/ca.ndjson"
( sleep 3; result_event >> "$d/ca.ndjson" ) &
out=$("$await" "$d/ca.ndjson" --max-tool-calls 3 --poll-seconds 1 2>&1); rc=$?
check "completed events are not counted" 0 $rc
case $out in *"tool calls: 2 (edit 1, read 1)"*) r=0 ;; *) r=1 ;; esac
note "completed events are not counted" "reports 2 calls" $r

# --- 10. without the flag, no count stops a run ---
d=$(new_run tool-limit-unset)
start_leaky_run "$d" || exit 1
for _ in 1 2 3 4 5 6 7 8; do tool_started read; done > "$d/ca.ndjson"
( sleep 3; result_event >> "$d/ca.ndjson" ) &
"$await" "$d/ca.ndjson" --poll-seconds 1 >/dev/null 2>&1
check "no limit without --max-tool-calls" 0 $?

# --- 11. a run that finished is finished, even past the limit ---
d=$(new_run tool-limit-after-result)
{ tool_started read; tool_started edit; result_event; } > "$d/ca.ndjson"
"$await" "$d/ca.ndjson" --max-tool-calls 1 >/dev/null 2>&1
check "result event wins over the limit" 0 $?

# --- 12. a line cut off mid-write must not change how the run is judged ---
# A killed run leaves exactly this behind. Before the fix, parsing it failed the
# report and every path exited 5, telling the caller not to resume a run it should.
d=$(new_run cut-off-line)
{ tool_started read; printf '{"type":"tool_call","subtype":"started","call_id":"c","tool_call":{"editToo\n'; } > "$d/ca.ndjson"
bash -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$d/ca.pid"
out=$("$await" "$d/ca.ndjson" --poll-seconds 1 2>&1); rc=$?
check "cut-off line, process gone" 4 $rc
case $out in *"tool calls: 2 (read 1, other 1)"*) r=0 ;; *) r=1 ;; esac
note "cut-off line, process gone" "counts the cut-off call as other" $r

# --- 13. over the limit after exiting on its own: still not to be resumed ---
d=$(new_run tool-limit-dead)
{ tool_started read; tool_started edit; } > "$d/ca.ndjson"
bash -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$d/ca.pid"
out=$("$await" "$d/ca.ndjson" --max-tool-calls 2 --poll-seconds 1 2>&1); rc=$?
check "over the limit, process already gone" 5 $rc
case $out in *"had already exited"*) r=0 ;; *) r=1 ;; esac
note "over the limit, process already gone" "says it was not killed here" $r

# --- 14. over the limit with no pid file: nothing was stopped, and it says so ---
d=$(new_run tool-limit-no-pid)
{ tool_started read; tool_started edit; } > "$d/ca.ndjson"
out=$("$await" "$d/ca.ndjson" --max-tool-calls 2 --poll-seconds 1 2>&1); rc=$?
check "over the limit, no pid file" 5 $rc
case $out in *"NOT stopped"*) r=0 ;; *) r=1 ;; esac
note "over the limit, no pid file" "says the run was not stopped" $r

# --- 15. the result event's usage is reported, after the verdict line ---
d=$(new_run usage-reported)
{ tool_started read; printf '{"type":"result","is_error":false,"session_id":"s1","usage":{"inputTokens":1,"outputTokens":2}}\n'; } > "$d/ca.ndjson"
out=$("$await" "$d/ca.ndjson" 2>/dev/null)
expected=$(printf '%s\n' 'FINISHED: result event present' 'tool calls: 1 (read 1)' 'usage: {"inputTokens":1,"outputTokens":2}')
note "usage reported" "verdict, count, usage, in that order on stdout" "$([ "$out" = "$expected" ] && echo 0 || echo 1)"

# --- 16. usage errors ---
"$await" >/dev/null 2>&1;                            check "no arguments" 64 $?
"$await" a b >/dev/null 2>&1;                        check "two logs" 64 $?
"$await" a --stall-seconds x >/dev/null 2>&1;        check "non-numeric stall" 64 $?
"$await" a --poll-seconds 0 >/dev/null 2>&1;         check "zero poll interval" 64 $?
"$await" a --max-tool-calls x >/dev/null 2>&1;       check "non-numeric tool-call limit" 64 $?
"$await" a --max-tool-calls 0 >/dev/null 2>&1;       check "zero tool-call limit" 64 $?
"$await" a --max-tool-calls "" >/dev/null 2>&1;      check "empty tool-call limit" 64 $?
"$await" a --stall-seconds "" >/dev/null 2>&1;       check "empty stall" 64 $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
