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
note "result event while the process is alive" "the run process is gone" $([ $r -ne 0 ] && echo 0 || echo 1)
kill -0 "$(cat "$d/child.pid")" 2>/dev/null; r=$?
note "result event while the process is alive" "the leaked child is gone" $([ $r -ne 0 ] && echo 0 || echo 1)

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

# --- 8. usage errors ---
"$await" >/dev/null 2>&1;                            check "no arguments" 64 $?
"$await" a b >/dev/null 2>&1;                        check "two logs" 64 $?
"$await" a --stall-seconds x >/dev/null 2>&1;        check "non-numeric stall" 64 $?
"$await" a --poll-seconds 0 >/dev/null 2>&1;         check "zero poll interval" 64 $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
