#!/usr/bin/env bash
# Wait for one detached cursor-agent run to finish, judging by its stream log.
#
# Usage:
#     await-run.sh <log.ndjson> [--pid-file <path>] [--stall-seconds N] [--poll-seconds N]
#                  [--max-tool-calls N]
#
# A run is over when its log carries a `result` event — not when the process
# exits. cursor-agent keeps running while it holds a foreground child it started
# (a dev server, a watcher), so waiting on process liveness can block long after
# the work is done. This waits for the event, then kills whatever is left over.
#
# --max-tool-calls N stops the run once its log holds N `tool_call` / `started`
# events. It is checked once per poll, so a run can overshoot N by the calls it
# starts within one poll interval. Unset, there is no limit.
#
# Exit: 0 finished / 3 stalled (no log activity) / 4 process gone before its
#       result event / 5 tool-call limit reached / 64 bad usage
set -euo pipefail

usage() { sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

log=""
pid_file=""
stall_seconds=600     # cursor-agent streams thinking and tool events well inside this
poll_seconds=10
max_tool_calls=""
max_tool_calls_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pid-file) pid_file=${2:-}; shift 2 || usage ;;
    --stall-seconds) stall_seconds=${2:-}; shift 2 || usage ;;
    --poll-seconds) poll_seconds=${2:-}; shift 2 || usage ;;
    --max-tool-calls) max_tool_calls=${2:-}; max_tool_calls_set=1; shift 2 || usage ;;
    -h|--help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage ;;
    *) [ -z "$log" ] || usage; log=$1; shift ;;
  esac
done
[ -n "$log" ] || usage
# An empty value is an unset variable on the caller's side, not "no limit".
case $stall_seconds in ''|*[!0-9]*) usage ;; esac
case $poll_seconds in ''|*[!0-9]*) usage ;; esac
[ "$poll_seconds" -gt 0 ] || usage
if [ "$max_tool_calls_set" = 1 ]; then
  case $max_tool_calls in ''|*[!0-9]*) usage ;; esac
  [ "$max_tool_calls" -gt 0 ] || usage
fi

# Default to the pid file new-run.sh's layout puts beside the log. A follow-up run
# logs to ca-followup-N.ndjson and must name its own pid file explicitly.
if [ -z "$pid_file" ] && [ -f "$(dirname "$log")/ca.pid" ]; then
  pid_file="$(dirname "$log")/ca.pid"
fi

pid=""
[ -n "$pid_file" ] && [ -f "$pid_file" ] && pid=$(tr -dc '0-9' < "$pid_file")

mtime() {  # GNU coreutils and BSD/macOS spell this differently
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}
has_result() { [ -f "$log" ] && grep -q '"type":"result"' "$log"; }
alive() { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
tool_calls() {
  [ -f "$log" ] || { echo 0; return; }
  grep '"type":"tool_call"' "$log" | grep -c '"subtype":"started"' || true
}

# How many tools the run started, by kind, and the token usage once there is a
# result event — what the caller needs to judge whether the task was sized right.
# A line cut off mid-write is skipped rather than fatal: it is exactly what a killed
# run leaves behind, and the exit code must still say how the run ended. Calls the
# breakdown cannot name (a cut-off line, an unfamiliar shape) are shown as "other",
# so the parts always add up to the count the limit is checked against.
report() {
  local n kinds=""
  n=$(tool_calls)
  if [ "$n" -gt 0 ] && command -v jq >/dev/null; then
    kinds=$( { grep '"type":"tool_call"' "$log" | jq -R -r 'fromjson?
          | select(.type == "tool_call" and .subtype == "started")
          | .tool_call | objects | keys[] | select(endswith("ToolCall")) | sub("ToolCall$"; "")' \
          2>/dev/null || true; } \
      | sort | uniq -c \
      | awk -v n="$n" '{ a = a (NR > 1 ? ", " : "") $2 " " $1; s += $1 }
          END { if (n - s > 0) a = a (NR > 0 ? ", " : "") "other " (n - s); printf "%s", a }') || kinds=""
  fi
  if [ -n "$kinds" ]; then echo "tool calls: $n ($kinds)"; else echo "tool calls: $n"; fi
  if has_result && command -v jq >/dev/null; then
    grep '"type":"result"' "$log" | tail -1 | jq -R -r 'fromjson? | .usage // empty | "usage: \(tojson)"' 2>/dev/null || true
  fi
}

# The verdict line comes first and the report follows it on the same stream:
# stdout when the run finished, stderr otherwise.
finish() {  # finish <exit> <verdict line>
  if [ "$1" = 0 ]; then
    echo "$2"; report
  else
    { echo "$2"; report; } >&2
  fi
  exit "$1"
}

# Kill the run and every process it started. setsid made it a group leader, so the
# whole group goes down with one signal — that is what clears a leaked dev server.
# Signal the lone pid when it is not a leader, so an unrelated group is never hit.
reap() {
  local pgid
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -dc '0-9' || true)
  local target=$pid
  [ "$pgid" = "$pid" ] && target="-$pid"
  kill -TERM "$target" 2>/dev/null || true
  local i=0
  while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$target" 2>/dev/null || true
}

# Nothing has been written yet on the first poll, so the stall clock starts here.
last_activity=$(date +%s)
[ -f "$log" ] && last_activity=$(mtime "$log")

while :; do
  if has_result; then
    if alive; then
      reap
      finish 0 "FINISHED: result event present; the process outlived it and was killed with its group (pid $pid)"
    fi
    finish 0 "FINISHED: result event present"
  fi

  # Checked before the dead-process case: a run over its limit must not be resumed,
  # even when it happened to exit on its own before this poll saw it.
  if [ -n "$max_tool_calls" ] && [ "$(tool_calls)" -ge "$max_tool_calls" ]; then
    if alive; then
      reap
      how="was killed"
    elif [ -n "$pid" ]; then
      how="had already exited"
    else
      how="was NOT stopped (no pid file) — stop it before anything else"
    fi
    # The run may have written its result while it was being stopped.
    sleep 1
    has_result && finish 0 "FINISHED: result event present"
    finish 5 "TOOL_LIMIT: the run started $max_tool_calls or more tool calls and $how. Do not resume it; narrow the task and delegate the rest as a new run"
  fi

  # Only conclusive once the log is caught up: check the result again after the
  # process is gone, since its last write can land after the exit we observed.
  if [ -n "$pid" ] && ! alive; then
    sleep 1
    has_result && finish 0 "FINISHED: result event present"
    finish 4 "INTERRUPTED: the process exited before its result event — run summarize-run.sh, then resume the session"
  fi

  now=$(date +%s)
  [ -f "$log" ] && last_activity=$(mtime "$log")
  if [ $((now - last_activity)) -ge "$stall_seconds" ]; then
    finish 3 "STALLED: no log activity for ${stall_seconds}s — inspect $log before killing or resuming"
  fi

  sleep "$poll_seconds"
done
