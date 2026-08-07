#!/usr/bin/env bash
# Wait for one detached cursor-agent run to finish, judging by its stream log.
#
# Usage:
#     await-run.sh <log.ndjson> [--pid-file <path>] [--stall-seconds N] [--poll-seconds N]
#
# A run is over when its log carries a `result` event — not when the process
# exits. cursor-agent keeps running while it holds a foreground child it started
# (a dev server, a watcher), so waiting on process liveness can block long after
# the work is done. This waits for the event, then kills whatever is left over.
#
# Exit: 0 finished / 3 stalled (no log activity) / 4 process gone before its
#       result event / 64 bad usage
set -euo pipefail

usage() { sed -n '3,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

log=""
pid_file=""
stall_seconds=600     # cursor-agent streams thinking and tool events well inside this
poll_seconds=10
while [ $# -gt 0 ]; do
  case "$1" in
    --pid-file) pid_file=${2:-}; shift 2 || usage ;;
    --stall-seconds) stall_seconds=${2:-}; shift 2 || usage ;;
    --poll-seconds) poll_seconds=${2:-}; shift 2 || usage ;;
    -h|--help) sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage ;;
    *) [ -z "$log" ] || usage; log=$1; shift ;;
  esac
done
[ -n "$log" ] || usage
case "$stall_seconds$poll_seconds" in *[!0-9]*) usage ;; esac
[ "$poll_seconds" -gt 0 ] || usage

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
      echo "FINISHED: result event present; the process outlived it and was killed with its group (pid $pid)"
    else
      echo "FINISHED: result event present"
    fi
    exit 0
  fi

  # Only conclusive once the log is caught up: check the result again after the
  # process is gone, since its last write can land after the exit we observed.
  if [ -n "$pid" ] && ! alive; then
    sleep 1
    has_result && { echo "FINISHED: result event present"; exit 0; }
    echo "INTERRUPTED: the process exited before its result event — run summarize-run.sh, then resume the session" >&2
    exit 4
  fi

  now=$(date +%s)
  [ -f "$log" ] && last_activity=$(mtime "$log")
  if [ $((now - last_activity)) -ge "$stall_seconds" ]; then
    echo "STALLED: no log activity for ${stall_seconds}s — inspect $log before killing or resuming" >&2
    exit 3
  fi

  sleep "$poll_seconds"
done
