#!/usr/bin/env bash
# Wait for one detached cursor-agent run to finish, judging by its stream log.
#
# Usage:
#     await-run.sh <log.ndjson> [--pid-file <path>] [--stall-seconds N] [--poll-seconds N]
#                  [--max-tool-calls N] [--detach]
#     await-run.sh <log.ndjson> --result [--poll-seconds N]
#
# A run is over when its log carries a `result` event — not when the process
# exits. cursor-agent keeps running while it holds a foreground child it started
# (a dev server, a watcher), so waiting on process liveness can block long after
# the work is done. This waits for the event, then kills whatever is left over.
#
# --max-tool-calls N stops the run once its log holds N `tool_call` / `started`
# events, and leaves <log>.tool-limit beside the log so summarize-run.sh can tell
# the run apart from one that was cut off. The count is checked once per poll and
# only while this script is waiting, so a run overshoots N by what it starts
# between checks and while it is being stopped. Unset, there is no limit.
#
# --detach runs the same wait as a watcher in its own session and returns once the
# watcher is up, so the limit and the stall check outlive the caller (a host
# timeout, an interrupted turn, a session out of budget). The watcher leaves what a
# foreground call would print in <log>.await.out and its exit code in
# <log>.await.rc. --result waits for those and exits with that code; it only reads
# files, so it can be repeated from any turn or session. A detached watcher that
# reports a stall keeps watching while it knows the run's pid, for as long as the
# run lives: --result returns that 3 at once, and it is withdrawn if the log grows
# again and replaced when the run ends.
#
# Exit: 0 finished / 3 stalled (no log activity) / 4 process gone before its
#       result event / 5 tool-call limit reached / 64 bad usage
#       --detach: 0 a watcher is up / 6 a watcher already watches this log, or
#                 another --detach is starting one / 7 none could be started
#       --result: the watcher's exit code / 8 no watcher is running and none left
#                 a verdict
set -euo pipefail

usage() { sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }

log=""
pid_file=""
stall_seconds=600     # cursor-agent streams thinking and tool events well inside this
poll_seconds=10
max_tool_calls=""
max_tool_calls_set=0
mode="wait"           # wait / detach / result
wait_flags=0          # flags that only a wait uses, which --result rejects
while [ $# -gt 0 ]; do
  case "$1" in
    --pid-file) pid_file=${2:-}; wait_flags=1; shift 2 || usage ;;
    --stall-seconds) stall_seconds=${2:-}; wait_flags=1; shift 2 || usage ;;
    --poll-seconds) poll_seconds=${2:-}; shift 2 || usage ;;
    --max-tool-calls) max_tool_calls=${2:-}; max_tool_calls_set=1; wait_flags=1; shift 2 || usage ;;
    --detach) [ "$mode" = wait ] || usage; mode=detach; shift ;;
    --result) [ "$mode" = wait ] || usage; mode=result; shift ;;
    -h|--help) sed -n '3,35p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage ;;
    *) [ -z "$log" ] || usage; log=$1; shift ;;
  esac
done
[ -n "$log" ] || usage
[ "$mode" = result ] && [ "$wait_flags" = 1 ] && usage
# An empty value is an unset variable on the caller's side, not "no limit".
# Zero is rejected too: a zero stall window or limit ends every run on the first poll.
positive() {  # positive <value> -> prints it in base 10, or fails
  case $1 in ''|*[!0-9]*) return 1 ;; esac
  [ ${#1} -le 9 ] && [ $((10#$1)) -gt 0 ] && echo $((10#$1))
}
stall_seconds=$(positive "$stall_seconds") || usage
poll_seconds=$(positive "$poll_seconds") || usage
if [ "$max_tool_calls_set" = 1 ]; then
  max_tool_calls=$(positive "$max_tool_calls") || usage
fi

# --- detached watcher: start one, or wait on one ---------------------------------

# Physical, so a log reached through a symlink (macOS's /tmp, a linked worktree,
# or a link to the log itself) still names the same watcher.
abs_path() {  # abs_path <path> -> the same path from /, or fails if its directory is missing
  local d
  if [ -L "$1" ] && d=$(readlink -f -- "$1" 2>/dev/null) && [ -n "$d" ]; then set -- "$d"; fi
  d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "$(basename "$1")"
}
set_watch_paths() {
  watch_pid=$log.await.pid        # the watcher's pid and start token, for people to read
  watch_out=$log.await.out
  watch_rc=$log.await.rc
  watch_lock=$log.await.lock      # held by a --detach while it starts a watcher
  watch_token=$log.await.token    # names the one start a watcher may come up for
  watch_wlock=$log.await.wlock    # held for the watcher for as long as it runs
}

# Whether a watcher runs, or a --detach is starting one, is whether it holds its
# lock: the kernel drops a lock with the last process holding it, so a dead holder
# is never mistaken for a live one, whatever reuses its pid. Probing takes the lock
# for an instant; everything that waits for these locks waits long enough for that.
lock_held() { [ -e "$1" ] && ! flock -n "$1" true 2>/dev/null; }
watcher_alive() { lock_held "$watch_wlock"; }
starting() { lock_held "$watch_lock"; }

if [ "$mode" = result ]; then
  gone() {
    echo "GONE: no watcher is running for $1 and none left a final verdict — start one with --detach and the same flags; the count resumes from the log" >&2
    exit 8
  }
  given=$log
  log=$(abs_path "$log") || gone "$given"
  set_watch_paths
  # Sets $rc and $out to a pair the watcher wrote together, or fails. The watcher
  # removes the code before it touches the output, so a code that reads the same on
  # both sides of the output belongs to it.
  # $provisional is set when the watcher is still watching past that verdict.
  read_verdict() {
    local first again
    first=$(cat 2>/dev/null < "$watch_rc") || return 1
    out=$(cat 2>/dev/null < "$watch_out") || return 1
    again=$(cat 2>/dev/null < "$watch_rc") && [ "$again" = "$first" ] || return 1
    rc=$(printf '%s\n' "$first" | head -n 1 | tr -dc '0-9')
    [ -n "$rc" ] || return 1
    provisional=""
    case $first in *provisional*) provisional=1 ;; esac
  }
  show_verdict() {
    if [ "$rc" = 0 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" >&2; fi
    exit "$rc"
  }
  while :; do
    # While a --detach is starting a watcher, a verdict on disk is the last one's.
    if ! starting; then
      if read_verdict; then
        # A provisional verdict is only true while its watcher is there to keep watching.
        if [ -z "$provisional" ] || watcher_alive; then show_verdict; fi
      fi
      if ! watcher_alive && ! starting; then
        read_verdict && [ -z "$provisional" ] && show_verdict
        gone "$given"
      fi
    fi
    sleep "$poll_seconds"
  done
fi

if [ "$mode" = detach ]; then
  given=$log
  not_started() { echo "NOT_STARTED: $1 — wait in the foreground instead" >&2; exit 7; }
  log=$(abs_path "$log") || not_started "the directory of $given does not exist"
  if [ -n "$pid_file" ]; then pid_file=$(abs_path "$pid_file" || printf '%s' "$pid_file"); fi
  set_watch_paths
  command -v setsid >/dev/null || not_started "setsid is not available, so a watcher would die with this call"
  command -v flock >/dev/null || not_started "flock is not available, so two watchers could start for one log"
  [ -w "$(dirname "$log")" ] || not_started "$(dirname "$log") is not writable, so a watcher could not leave its verdict"
  # Two --detach calls racing for one log must not both start a watcher. The wait
  # covers a probe by --result, and a child of a --detach killed a moment ago that
  # still holds its copy of the lock.
  { exec 9> "$watch_lock"; } 2>/dev/null || not_started "$watch_lock cannot be opened"
  flock -w 3 9 || { echo "WATCHING: another --detach is starting a watcher for $log — wait on it with --result" >&2; exit 6; }
  if watcher_alive; then
    echo "WATCHING: a watcher (pid $(cut -d' ' -f1 2>/dev/null < "$watch_pid" || true)) already watches $log — wait on it with --result" >&2
    exit 6
  fi
  # A verdict left by an earlier watcher would answer --result before this one has looked.
  rm -f "$watch_rc" "$watch_out" "$watch_pid"
  token="$$-$(date +%s)-$RANDOM"
  { printf '%s\n' "$token" > "$watch_token.$$" && mv -f "$watch_token.$$" "$watch_token"; } 2>/dev/null ||
    not_started "the files beside $log cannot be written"
  args=("$log" --stall-seconds "$stall_seconds" --poll-seconds "$poll_seconds")
  [ -n "$pid_file" ] && args+=(--pid-file "$pid_file")
  [ -n "$max_tool_calls" ] && args+=(--max-tool-calls "$max_tool_calls")
  self=$(abs_path "${BASH_SOURCE[0]}")
  # flock holds the watcher's lock and runs the watcher as its child with the lock
  # closed (-o), so nothing the watcher starts can keep the lock past the watcher.
  # The watcher's stderr is kept: one that dies leaves only a GONE behind otherwise.
  AWAIT_RUN_WATCHER=1 AWAIT_RUN_TOKEN=$token setsid flock -o -w 5 "$watch_wlock" bash "$self" "${args[@]}" \
    </dev/null >/dev/null 2> "$log.await.err" 9>&- &
  starter=$!
  started() { [ "$(cut -d' ' -f2 2>/dev/null < "$watch_pid" || true)" = "$token" ] && watcher_alive; }
  # Called on a start that is taking too long or failed. With the token withdrawn, a
  # watcher that checks it from now on exits; holding the watcher's lock settles
  # whether one checked it before. Got, no watcher can be running past this point.
  # Not got within the wait, a watcher that passed the check holds it.
  abandon() {
    rm -f "$watch_token"
    exec 8> "$watch_wlock"
    flock -w 3 8 || return 0
    rm -f "$watch_pid"
    not_started "$1"
  }
  # setsid forks when it is started as a group leader, so its own exit says nothing
  # about the watcher — only a failing exit does. Returning before the watcher is
  # up would let a --result right after this read the run as unwatched.
  i=0
  until started || [ -f "$watch_rc" ]; do
    if [ -n "$starter" ] && ! kill -0 "$starter" 2>/dev/null; then
      # Not forked, the starter is flock, and its exit is the watcher's.
      if ! wait "$starter" && [ ! -f "$watch_rc" ]; then abandon "the watcher for $log failed to start"; break; fi
      starter=""
    fi
    i=$((i + 1))
    if [ $i -gt 100 ]; then abandon "the watcher for $log did not start within 10s"; break; fi
    sleep 0.1 9>&-
  done
  printf 'WATCHING: a detached watcher is waiting on %s — get its verdict with: await-run.sh %q --result\n' "$log" "$log" || true
  exit 0
fi

watcher=""
if [ "${AWAIT_RUN_WATCHER:-}" = 1 ]; then
  watcher=1
  set_watch_paths
  # Started by flock, which holds the lock for it: the parent going away means the
  # lock went with it, and a watcher without its lock must not go on.
  holder=$PPID
  # The --detach that started this has given up on it, or a newer one has taken over.
  [ "$(cat 2>/dev/null < "$watch_token")" = "${AWAIT_RUN_TOKEN:-}" ] || exit 0
  { printf '%s %s\n' "$$" "$AWAIT_RUN_TOKEN" > "$watch_pid.$$" && mv -f "$watch_pid.$$" "$watch_pid"; } || exit 1
fi

# Default to the pid file new-run.sh's layout puts beside the first run's log. A
# follow-up run logs to ca-followup-N.ndjson and must name its own pid file: the
# first run's pid would make a live follow-up look finished.
if [ -z "$pid_file" ] && [ "$(basename "$log")" = ca.ndjson ]; then
  pid_file="$(dirname "$log")/ca.pid"
fi

# Read again each poll until it appears: a wait started right after the run was
# launched can come before the run has written its pid.
pid=""
read_pid() { [ -n "$pid_file" ] && [ -f "$pid_file" ] && pid=$(tr -dc '0-9' < "$pid_file") || true; }
read_pid

mtime() {  # GNU coreutils and BSD/macOS spell this differently
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}
has_result() { [ -f "$log" ] && grep -q '"type":"result"' "$log"; }
alive() { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
tool_calls() {
  [ -f "$log" ] || { echo 0; return; }
  # -a: one stray NUL would otherwise make grep treat the log as binary and count 0.
  grep -a '"type":"tool_call"' "$log" | grep -ac '"subtype":"started"' || true
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
    kinds=$( { grep -a '"type":"tool_call"' "$log" | jq -R -r 'fromjson?
          | select(.type == "tool_call" and .subtype == "started")
          | .tool_call | objects | first(keys[] | select(endswith("ToolCall"))) | sub("ToolCall$"; "")' \
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

# What a foreground call would print, written for --result to read. Each file is
# written under a temporary name and moved into place, the output before the code.
publish() {  # publish <exit> <verdict line> [provisional]
  # The code goes first, so --result never pairs a code with output written after it.
  rm -f "$watch_rc"
  { echo "$2"; report; } > "$watch_out.$$"
  mv -f "$watch_out.$$" "$watch_out"
  { echo "$1"; [ -z "${3:-}" ] || echo provisional; } > "$watch_rc.$$"
  mv -f "$watch_rc.$$" "$watch_rc"
}

# The verdict line comes first and the report follows it on the same stream:
# stdout when the run finished, stderr otherwise.
finish() {  # finish <exit> <verdict line>
  if [ -n "$watcher" ]; then
    publish "$1" "$2"
    rm -f "$watch_pid"
  elif [ "$1" = 0 ]; then
    echo "$2"; report
  else
    { echo "$2"; report; } >&2
  fi
  exit "$1"
}

# Kill the run and every process it started. setsid made it a group leader, so the
# whole group goes down with one signal — that is what clears a leaked dev server.
# Signal the lone pid when it is not a leader, so an unrelated group is never hit.
# Waits on the whole group, not the leader: a child that ignores TERM outlives a
# leader that obeys it, and only KILL clears it. Sets $reaped to what was signalled.
reap() {
  local pgid
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -dc '0-9' || true)
  local target=$pid
  reaped="with its group (pid $pid)"
  if [ "$pgid" != "$pid" ]; then
    reaped="alone (pid $pid is not a group leader, so processes it started may still be running)"
  else
    target="-$pid"
  fi
  kill -TERM "$target" 2>/dev/null || true
  local i=0
  while [ $i -lt 10 ] && kill -0 -- "$target" 2>/dev/null; do sleep 1; i=$((i + 1)); done
  kill -0 -- "$target" 2>/dev/null && kill -KILL -- "$target" 2>/dev/null || true
}

# Nothing has been written yet on the first poll, so the stall clock starts here.
last_activity=$(date +%s)
[ -f "$log" ] && last_activity=$(mtime "$log")
stalled=0

while :; do
  if [ -n "$watcher" ] && ! kill -0 "$holder" 2>/dev/null; then
    echo "await-run.sh: the process holding this watcher's lock is gone; exiting so a new watcher can start" >&2
    exit 1
  fi
  [ -n "$pid" ] || read_pid
  if has_result; then
    if alive; then
      reap
      finish 0 "FINISHED: result event present; the process outlived it and was killed $reaped"
    fi
    finish 0 "FINISHED: result event present"
  fi

  # Checked before the dead-process case: a run over its limit must not be resumed,
  # even when it happened to exit on its own before this poll saw it.
  if [ -n "$max_tool_calls" ] && [ "$(tool_calls)" -ge "$max_tool_calls" ]; then
    if alive; then
      reap
      how="was killed $reaped"
      # A result written now answers the kill (or lands in the same instant); the
      # run went over its limit either way, so it does not turn this into a finish.
      has_result && how="$how; it wrote a result event while being stopped"
    elif [ -n "$pid" ]; then
      # Its last write can land after the exit was observed, as in the case below.
      sleep 1
      has_result && finish 0 "FINISHED: result event present"
      how="had already exited"
    else
      how="was NOT stopped (no pid file) — stop it before anything else"
    fi
    verdict="TOOL_LIMIT: the run started $max_tool_calls or more tool calls and $how. Do not resume it; narrow the task and delegate the rest as a new run"
    printf '%s\n' "$verdict" > "$log.tool-limit" || true
    finish 5 "$verdict"
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
    verdict="STALLED: no log activity for ${stall_seconds}s — inspect $log before killing or resuming"
    # Detached, the watcher is the only thing holding the limit, and a stalled run
    # can start moving again. With no process to watch there is nothing left to hold.
    if [ -n "$watcher" ] && [ -n "$pid" ]; then
      if [ "$stalled" = 0 ]; then
        publish 3 "$verdict. This watcher keeps watching: the verdict is withdrawn if the log grows again, and replaced when the run ends" provisional
        stalled=1
      fi
    else
      finish 3 "$verdict"
    fi
  elif [ "$stalled" = 1 ]; then
    rm -f "$watch_rc" "$watch_out"
    stalled=0
  fi

  sleep "$poll_seconds"
done
