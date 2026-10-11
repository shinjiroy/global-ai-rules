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
# Every call is bounded, so a regression that loops forever fails its case instead
# of hanging the suite.
aw() { timeout 120 "$await" "$@"; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/await-run-test-XXXXXX")

# A case that fails may leave its sleeper running, and the suite must still end.
cleanup() {
  for f in "$tmp"/*/*.await.pid "$tmp"/*/ca.pid "$tmp"/*/child.pid "$tmp"/*/other.pid; do
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
aw "$d/ca.ndjson" >/dev/null 2>&1
check "result event, no pid file" 0 $?

# --- 2. the bug this script exists for: result present, process still alive ---
# The old `while kill -0` loop never returns here. Every leaked process must die.
d=$(new_run leaked-process)
start_leaky_run "$d" || exit 1
{ work_event; result_event; } > "$d/ca.ndjson"
out=$(aw "$d/ca.ndjson" 2>&1); rc=$?
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
aw "$d/ca.ndjson" --poll-seconds 1 >/dev/null 2>&1
check "result event arriving mid-wait" 0 $?

# --- 4. the process exits before writing a result event ---
d=$(new_run interrupted)
work_event > "$d/ca.ndjson"
setsid bash -c 'echo $$ > "'"$d"'/ca.pid"; exec sleep 2' </dev/null >/dev/null 2>&1 &
while [ ! -s "$d/ca.pid" ]; do sleep 0.1; done
aw "$d/ca.ndjson" --poll-seconds 1 >/dev/null 2>&1
check "process gone before its result event" 4 $?

# --- 5. no result event and a log nobody is writing to ---
d=$(new_run stalled)
work_event > "$d/ca.ndjson"
start_leaky_run "$d" || exit 1
touch -d '@0' "$d/ca.ndjson" 2>/dev/null || touch -t 197001020000 "$d/ca.ndjson"
aw "$d/ca.ndjson" --stall-seconds 5 --poll-seconds 1 >/dev/null 2>&1
check "stalled log" 3 $?
kill -TERM -"$(cat "$d/ca.pid")" 2>/dev/null

# --- 6. an active log holds the stall check off ---
# Guards against a stall rule that fires on any run slower than its threshold.
d=$(new_run stall-not-triggered)
work_event > "$d/ca.ndjson"
start_leaky_run "$d" || exit 1
( for _ in 1 2 3 4; do sleep 1; work_event >> "$d/ca.ndjson"; done; result_event >> "$d/ca.ndjson" ) &
aw "$d/ca.ndjson" --stall-seconds 3 --poll-seconds 1 >/dev/null 2>&1
check "an active log is not a stall" 0 $?

# --- 7. a follow-up log with its own pid file ---
d=$(new_run followup)
result_event > "$d/ca-followup-1.ndjson"
work_event > "$d/ca.ndjson"          # the first run's log must not be consulted
aw "$d/ca-followup-1.ndjson" >/dev/null 2>&1
check "follow-up log named explicitly" 0 $?

# --- 8. the tool-call limit stops a live run and everything it started ---
d=$(new_run tool-limit)
start_leaky_run "$d" || exit 1
{ work_event; tool_started read; tool_started edit; tool_started shell; } > "$d/ca.ndjson"
out=$(aw "$d/ca.ndjson" --max-tool-calls 3 --poll-seconds 1 2>&1); rc=$?
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
out=$(aw "$d/ca.ndjson" --max-tool-calls 3 --poll-seconds 1 2>&1); rc=$?
check "completed events are not counted" 0 $rc
case $out in *"tool calls: 2 (edit 1, read 1)"*) r=0 ;; *) r=1 ;; esac
note "completed events are not counted" "reports 2 calls" $r
note "completed events are not counted" "leaves no tool-limit marker" "$([ ! -e "$d/ca.ndjson.tool-limit" ] && echo 0 || echo 1)"

# --- 10. without the flag, no count stops a run ---
d=$(new_run tool-limit-unset)
start_leaky_run "$d" || exit 1
for _ in 1 2 3 4 5 6 7 8; do tool_started read; done > "$d/ca.ndjson"
( sleep 3; result_event >> "$d/ca.ndjson" ) &
aw "$d/ca.ndjson" --poll-seconds 1 >/dev/null 2>&1
check "no limit without --max-tool-calls" 0 $?

# --- 11. a run that finished is finished, even past the limit ---
d=$(new_run tool-limit-after-result)
{ tool_started read; tool_started edit; result_event; } > "$d/ca.ndjson"
aw "$d/ca.ndjson" --max-tool-calls 1 >/dev/null 2>&1
check "result event wins over the limit" 0 $?

# --- 12. a line cut off mid-write must not change how the run is judged ---
# A killed run leaves exactly this behind. Before the fix, parsing it failed the
# report and every path exited 5, telling the caller not to resume a run it should.
d=$(new_run cut-off-line)
{ tool_started read; printf '{"type":"tool_call","subtype":"started","call_id":"c","tool_call":{"editToo\n'; } > "$d/ca.ndjson"
bash -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$d/ca.pid"
out=$(aw "$d/ca.ndjson" --poll-seconds 1 2>&1); rc=$?
check "cut-off line, process gone" 4 $rc
case $out in *"tool calls: 2 (read 1, other 1)"*) r=0 ;; *) r=1 ;; esac
note "cut-off line, process gone" "counts the cut-off call as other" $r

# --- 13. over the limit after exiting on its own: still not to be resumed ---
d=$(new_run tool-limit-dead)
{ tool_started read; tool_started edit; } > "$d/ca.ndjson"
bash -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$d/ca.pid"
out=$(aw "$d/ca.ndjson" --max-tool-calls 2 --poll-seconds 1 2>&1); rc=$?
check "over the limit, process already gone" 5 $rc
case $out in *"had already exited"*) r=0 ;; *) r=1 ;; esac
note "over the limit, process already gone" "says it was not killed here" $r

# --- 14. over the limit with no pid file: nothing was stopped, and it says so ---
d=$(new_run tool-limit-no-pid)
{ tool_started read; tool_started edit; } > "$d/ca.ndjson"
out=$(aw "$d/ca.ndjson" --max-tool-calls 2 --poll-seconds 1 2>&1); rc=$?
check "over the limit, no pid file" 5 $rc
case $out in *"NOT stopped"*) r=0 ;; *) r=1 ;; esac
note "over the limit, no pid file" "says the run was not stopped" $r
note "over the limit, no pid file" "leaves the tool-limit marker beside the log" "$([ -f "$d/ca.ndjson.tool-limit" ] && echo 0 || echo 1)"
out=$(aw "$d/ca.ndjson" --max-tool-calls 2 --poll-seconds 1 2>/dev/null)
note "over the limit, no pid file" "prints nothing on stdout" "$([ -z "$out" ] && echo 0 || echo 1)"

# --- 15. the result event's usage is reported, after the verdict line ---
d=$(new_run usage-reported)
{ tool_started read; printf '{"type":"result","is_error":false,"session_id":"s1","usage":{"inputTokens":1,"outputTokens":2}}\n'; } > "$d/ca.ndjson"
out=$(aw "$d/ca.ndjson" 2>/dev/null)
expected=$(printf '%s\n' 'FINISHED: result event present' 'tool calls: 1 (read 1)' 'usage: {"inputTokens":1,"outputTokens":2}')
note "usage reported" "verdict, count, usage, in that order on stdout" "$([ "$out" = "$expected" ] && echo 0 || echo 1)"

# --- 16. a child that ignores TERM is killed too, not only the leader ---
d=$(new_run tool-limit-term-ignored)
setsid bash -c 'echo $$ > "'"$d"'/ca.pid"; (trap "" TERM; exec sleep 300) & echo $! > "'"$d"'/child.pid"; exec sleep 300' \
  </dev/null >/dev/null 2>&1 &
while [ ! -s "$d/ca.pid" ] || [ ! -s "$d/child.pid" ]; do sleep 0.1; done
sleep 0.2
tool_started read > "$d/ca.ndjson"
aw "$d/ca.ndjson" --max-tool-calls 1 --poll-seconds 1 >/dev/null 2>&1
check "child ignoring TERM" 5 $?
kill -0 "$(cat "$d/child.pid")" 2>/dev/null; r=$?
note "child ignoring TERM" "the child is gone" "$([ $r -ne 0 ] && echo 0 || echo 1)"

# --- 17. a follow-up log does not borrow the first run's pid file ---
# Borrowed, the first run's dead pid made a live follow-up look already exited.
d=$(new_run followup-no-pid-file)
bash -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$d/ca.pid"
tool_started read > "$d/ca-followup-1.ndjson"
out=$(aw "$d/ca-followup-1.ndjson" --max-tool-calls 1 --poll-seconds 1 2>&1); rc=$?
check "follow-up over the limit without --pid-file" 5 $rc
case $out in *"NOT stopped"*) r=0 ;; *) r=1 ;; esac
note "follow-up over the limit without --pid-file" "says the run was not stopped" $r

# --- 18. one event naming two tools counts once in the breakdown ---
d=$(new_run two-tool-keys)
{ printf '{"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{},"editToolCall":{}}}\n'; result_event; } > "$d/ca.ndjson"
out=$(aw "$d/ca.ndjson" 2>&1)
case $out in *"tool calls: 1 (edit 1)"*) r=0 ;; *) r=1 ;; esac
note "two tool keys in one event" "the breakdown adds up to the count" $r

# --- 19. a NUL byte in the log does not hide the calls around it ---
d=$(new_run nul-byte)
{ tool_started read; printf '\0\n'; tool_started edit; } > "$d/ca.ndjson"
bash -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$d/ca.pid"
aw "$d/ca.ndjson" --max-tool-calls 2 --poll-seconds 1 >/dev/null 2>&1
check "NUL byte in the log" 5 $?

# --- 20. a result written in answer to the kill does not erase the limit ---
d=$(new_run tool-limit-result-on-term)
tool_started read > "$d/ca.ndjson"
cat > "$d/run.sh" <<'RUN'
d=$1
echo $$ > "$d/ca.pid"
trap 'printf "%s\n" "{\"type\":\"result\",\"is_error\":true}" >> "$d/ca.ndjson"; exit 0' TERM
sleep 300 & wait
RUN
setsid bash "$d/run.sh" "$d" </dev/null >/dev/null 2>&1 &
while [ ! -s "$d/ca.pid" ]; do sleep 0.1; done
sleep 0.2
out=$(aw "$d/ca.ndjson" --max-tool-calls 1 --poll-seconds 1 2>&1); rc=$?
check "result written while being stopped" 5 $rc
case $out in *"wrote a result event while being stopped"*) r=0 ;; *) r=1 ;; esac
note "result written while being stopped" "says the result came during the stop" $r
grep -q '"type":"result"' "$d/ca.ndjson"; r=$?
note "result written while being stopped" "the fixture did write the result" $r

# --- 21. over the limit and exited, with its result landing just after the exit ---
d=$(new_run tool-limit-late-result)
{ tool_started read; tool_started edit; } > "$d/ca.ndjson"
bash -c 'exit 0' & dead=$!; wait "$dead"; echo "$dead" > "$d/ca.pid"
( sleep 0.3; result_event >> "$d/ca.ndjson" ) & writer=$!
aw "$d/ca.ndjson" --max-tool-calls 2 --poll-seconds 1 >/dev/null 2>&1; rc=$?
wait "$writer"
check "result landing after the exit, over the limit" 0 $rc

# --- 22. usage errors ---
aw >/dev/null 2>&1;                            check "no arguments" 64 $?
aw a b >/dev/null 2>&1;                        check "two logs" 64 $?
aw a --stall-seconds x >/dev/null 2>&1;        check "non-numeric stall" 64 $?
aw a --poll-seconds 0 >/dev/null 2>&1;         check "zero poll interval" 64 $?
aw a --max-tool-calls x >/dev/null 2>&1;       check "non-numeric tool-call limit" 64 $?
aw a --max-tool-calls 0 >/dev/null 2>&1;       check "zero tool-call limit" 64 $?
aw a --max-tool-calls "" >/dev/null 2>&1;      check "empty tool-call limit" 64 $?
aw a --stall-seconds "" >/dev/null 2>&1;       check "empty stall" 64 $?
aw a --stall-seconds 0 >/dev/null 2>&1;        check "zero stall" 64 $?
aw a --poll-seconds "" >/dev/null 2>&1;        check "empty poll interval" 64 $?

# --- detached watcher (--detach / --result) ---
gone_pid() { ! kill -0 "$1" 2>/dev/null && echo 0 || echo 1; }
watchers_of() { pgrep -fc -- "await-run.sh $1 " || true; }
wait_until() {  # wait_until <seconds> <command...> -> 0 once the command succeeds
  local i=0
  until "${@:2}"; do i=$((i + 1)); [ $i -le $(($1 * 10)) ] || return 1; sleep 0.1; done
}

# --- 23. detached: the verdict and report come back through --result ---
d=$(new_run detach-finished)
start_leaky_run "$d" || exit 1
work_event > "$d/ca.ndjson"
aw "$d/ca.ndjson" --detach --poll-seconds 1 >/dev/null 2>&1
check "detach: start" 0 $?
( sleep 2; result_event >> "$d/ca.ndjson" ) &
out=$(aw "$d/ca.ndjson" --result --poll-seconds 1 2>/dev/null); rc=$?
check "detach: run finishes" 0 $rc
case $out in "FINISHED:"*"tool calls: 0"*) r=0 ;; *) r=1 ;; esac
note "detach: run finishes" "prints the watcher's verdict and report on stdout" $r
note "detach: run finishes" "the verdict files are named after the log" "$([ -f "$d/ca.ndjson.await.rc" ] && [ -f "$d/ca.ndjson.await.out" ] && echo 0 || echo 1)"
sleep 1
note "detach: run finishes" "the leaked child is gone" "$(gone_pid "$(cat "$d/child.pid")")"
out2=$(aw "$d/ca.ndjson" --result 2>/dev/null); rc=$?
check "detach: --result repeated after the watcher exited" 0 $rc
note "detach: --result repeated after the watcher exited" "prints the same output" "$([ "$out" = "$out2" ] && echo 0 || echo 1)"

# --- 24. --detach returns only once the watcher is recorded ---
# Returning earlier let a --result right after it read the run as unwatched.
d=$(new_run detach-recorded)
start_leaky_run "$d" || exit 1
work_event > "$d/ca.ndjson"
aw "$d/ca.ndjson" --detach --poll-seconds 1 >/dev/null 2>&1
p=$(cat "$d/ca.ndjson.await.pid" 2>/dev/null)
note "detach: recorded on return" "the pid file names a live watcher" "$([ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo 0 || echo 1)"
timeout 3 "$await" "$d/ca.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: --result right after start keeps waiting" 124 $?

# --- 25. detached: the tool-call limit stops the run with no caller waiting ---
d=$(new_run detach-tool-limit)
start_leaky_run "$d" || exit 1
work_event > "$d/ca.ndjson"
aw "$d/ca.ndjson" --detach --max-tool-calls 3 --poll-seconds 1 >/dev/null 2>&1
{ tool_started read; tool_started edit; tool_started shell; } >> "$d/ca.ndjson"
wait_until 15 test -f "$d/ca.ndjson.await.rc"
note "detach: tool-call limit" "the watcher acts with nobody waiting" $?
out=$(aw "$d/ca.ndjson" --result --poll-seconds 1 2>&1); rc=$?
check "detach: tool-call limit" 5 $rc
case $out in TOOL_LIMIT:*) r=0 ;; *) r=1 ;; esac
note "detach: tool-call limit" "prints TOOL_LIMIT" $r
sleep 1
note "detach: tool-call limit" "the run process is gone" "$(gone_pid "$(cat "$d/ca.pid")")"
note "detach: tool-call limit" "leaves the tool-limit marker" "$([ -f "$d/ca.ndjson.tool-limit" ] && echo 0 || echo 1)"

# --- 26. a follow-up never reads the first run's verdict ---
d=$(new_run detach-followup)
echo 0 > "$d/ca.ndjson.await.rc"; echo "FINISHED: result event present" > "$d/ca.ndjson.await.out"
work_event > "$d/ca-followup-1.ndjson"
aw "$d/ca-followup-1.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: follow-up with no watcher of its own" 8 $?

# --- 27. a watcher killed before its verdict: reported, and restartable once ---
d=$(new_run detach-killed)
start_leaky_run "$d" || exit 1
work_event > "$d/ca.ndjson"
aw "$d/ca.ndjson" --detach --poll-seconds 1 >/dev/null 2>&1
kill -KILL "$(cat "$d/ca.ndjson.await.pid")"
aw "$d/ca.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: watcher killed" 8 $?
aw "$d/ca.ndjson" --detach --poll-seconds 1 >/dev/null 2>&1
check "detach: restart after the watcher was killed" 0 $?
note "detach: restart after the watcher was killed" "exactly one watcher runs" "$([ "$(watchers_of "$d/ca.ndjson")" = 1 ] && echo 0 || echo 1)"

# --- 28. a second --detach while a watcher runs is refused ---
aw "$d/ca.ndjson" --detach --poll-seconds 1 >/dev/null 2>&1
check "detach: second watcher refused" 6 $?
note "detach: second watcher refused" "still exactly one watcher" "$([ "$(watchers_of "$d/ca.ndjson")" = 1 ] && echo 0 || echo 1)"

# --- 29. a verdict left by an earlier watcher does not answer the new one ---
d=$(new_run detach-stale-verdict)
start_leaky_run "$d" || exit 1
work_event > "$d/ca.ndjson"
echo 0 > "$d/ca.ndjson.await.rc"; echo "FINISHED: result event present" > "$d/ca.ndjson.await.out"
aw "$d/ca.ndjson" --detach --poll-seconds 1 >/dev/null 2>&1
timeout 3 "$await" "$d/ca.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: stale verdict cleared" 124 $?

# --- 30. after a stall the watcher keeps holding the limit ---
# Exiting on the stall left a run that started moving again unwatched, and it then
# finished past its limit looking like a normal finish.
d=$(new_run detach-stall-resumes)
start_leaky_run "$d" || exit 1
work_event > "$d/ca.ndjson"
touch -d '@0' "$d/ca.ndjson" 2>/dev/null || touch -t 197001020000 "$d/ca.ndjson"
aw "$d/ca.ndjson" --detach --stall-seconds 2 --poll-seconds 1 --max-tool-calls 2 >/dev/null 2>&1
out=$(aw "$d/ca.ndjson" --result --poll-seconds 1 2>&1); rc=$?
check "detach: stall reported" 3 $rc
case $out in STALLED:*"keeps watching"*) r=0 ;; *) r=1 ;; esac
note "detach: stall reported" "says the watcher keeps watching" $r
note "detach: stall reported" "the watcher is still running" "$([ "$(watchers_of "$d/ca.ndjson")" = 1 ] && echo 0 || echo 1)"
work_event >> "$d/ca.ndjson"
wait_until 5 test ! -e "$d/ca.ndjson.await.rc"
note "detach: stall reported" "the verdict is withdrawn once the log grows" $?
{ tool_started read; tool_started edit; } >> "$d/ca.ndjson"
aw "$d/ca.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: limit reached after a stall" 5 $?
sleep 1
note "detach: limit reached after a stall" "the run process is gone" "$(gone_pid "$(cat "$d/ca.pid")")"

# --- 31. a stall with no process to watch ends the watcher ---
d=$(new_run detach-stall-no-pid)
work_event > "$d/ca-followup-1.ndjson"
touch -d '@0' "$d/ca-followup-1.ndjson" 2>/dev/null || touch -t 197001020000 "$d/ca-followup-1.ndjson"
aw "$d/ca-followup-1.ndjson" --detach --stall-seconds 2 --poll-seconds 1 >/dev/null 2>&1
aw "$d/ca-followup-1.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: stall with no pid file" 3 $?
wait_until 3 test "$(watchers_of "$d/ca-followup-1.ndjson")" = 0
note "detach: stall with no pid file" "the watcher exited" $?

# --- 32. nothing to wait on: --result returns at once ---
aw "$tmp/no-such-run/ca.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: --result for a run directory that is gone" 8 $?
aw "$tmp/no-such-run/ca.ndjson" --detach >/dev/null 2>&1
check "detach: --detach for a run directory that is gone" 7 $?

# --- 33. a watcher that cannot start fails --detach instead of leaving --result to spin ---
d=$(new_run detach-setsid-fails)
mkdir -p "$d/bin"; printf '#!/bin/sh
exit 1
' > "$d/bin/setsid"; chmod +x "$d/bin/setsid"
work_event > "$d/ca.ndjson"
PATH="$d/bin:$PATH" timeout 5 "$await" "$d/ca.ndjson" --detach >/dev/null 2>&1
check "detach: setsid fails" 7 $?
aw "$d/ca.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: --result after a failed start" 8 $?

# --- 34. a pid file whose pid now belongs to something else ---
d=$(new_run detach-pid-reused)
work_event > "$d/ca.ndjson"
setsid sleep 300 </dev/null >/dev/null 2>&1 & echo $! > "$d/other.pid"
sleep 0.2
cp "$d/other.pid" "$d/ca.ndjson.await.pid"
aw "$d/ca.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: pid reused by another process" 8 $?
aw "$d/ca.ndjson" --detach --poll-seconds 1 >/dev/null 2>&1
check "detach: start over a reused pid" 0 $?

# --- 35. a run directory with a space in it ---
d=$(new_run "detach with space")
result_event > "$d/ca.ndjson"
aw "$d/ca.ndjson" --detach --poll-seconds 1 >/dev/null 2>&1
check "detach: path with a space" 0 $?
aw "$d/ca.ndjson" --result --poll-seconds 1 >/dev/null 2>&1
check "detach: --result on a path with a space" 0 $?

# --- 36. usage errors specific to the detached forms ---
aw a --detach --result >/dev/null 2>&1;           check "--detach with --result" 64 $?
aw a --result --max-tool-calls 3 >/dev/null 2>&1; check "--result with a wait flag" 64 $?
aw a --result --pid-file p >/dev/null 2>&1;       check "--result with --pid-file" 64 $?
aw a --detach --max-tool-calls 0 >/dev/null 2>&1; check "--detach validates before starting" 64 $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
