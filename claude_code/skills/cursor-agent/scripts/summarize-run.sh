#!/usr/bin/env bash
# Summarize one cursor-agent stream log: did it run, did it fail, what did it say.
#
# Usage:
#     summarize-run.sh <log.ndjson>
#
# Prints the outcome, token usage, session id (needed for --resume), the final
# message, and — in plan mode — the plan body, which never reaches the `result`
# event. Exits 1 when the log holds no `result` event, meaning the run never
# started (untrusted directory, bad flags), and 2 when it reports is_error.
set -euo pipefail

[ $# -eq 1 ] || { sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 64; }
log=$1
[ -f "$log" ] || { echo "no such log: $log" >&2; exit 64; }

if ! grep -q '"type":"result"' "$log"; then
  echo "NO_RESULT_EVENT: the run never started — check the invocation and workspace trust" >&2
  exit 1
fi

jq -r 'select(.type=="result")
       | "is_error=\(.is_error)  tokens=\(.usage.inputTokens)/\(.usage.outputTokens)  session=\(.session_id)"' "$log"

plan=$(jq -r 'select(.type=="tool_call" and .subtype=="completed" and (.tool_call.createPlanToolCall != null))
              | .tool_call.createPlanToolCall.args.plan' "$log")
if [ -n "$plan" ]; then
  printf '\n--- plan ---\n%s\n' "$plan"
fi

printf '\n--- final message ---\n'
jq -r 'select(.type=="result") | .result' "$log"

if [ "$(jq -r 'select(.type=="result") | .is_error' "$log")" = "true" ]; then
  exit 2
fi
