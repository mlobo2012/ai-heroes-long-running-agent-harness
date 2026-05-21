#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# TODO: real Discord POST
# When a webhook is available, this script posts with:
#   curl -fsS -X POST \
#     -H 'Content-Type: application/json' \
#     -d '{"content":"<message>"}' \
#     "$DISCORD_NOTIFY_WEBHOOK"
# Env vars:
#   DISCORD_NOTIFY_WEBHOOK     Discord webhook URL for the bound channel.
#   DISCORD_NOTIFY_CHANNEL_ID  Optional channel id for log context.

WORKDIR="${PWD}"
STATE_DIR="$WORKDIR/.claude/goal-state"
mkdir -p "$STATE_DIR"

RESULTS_FILE="$WORKDIR/test-results.json"
QA_REPORT_FILE="$WORKDIR/QA_REPORT.md"
LAST_STATUS_FILE="$STATE_DIR/last-status"
LAST_PASS_COUNT_FILE="$STATE_DIR/last-pass-count"
LOG_FILE="$STATE_DIR/discord-notify.log"

count_matches() {
  pattern="$1"
  file="$2"
  if [ ! -f "$file" ]; then
    printf '0\n'
    return 0
  fi
  { grep -o "$pattern" "$file" 2>/dev/null || true; } | wc -l | tr -d ' '
}

true_count="$(count_matches '"passes"[[:space:]]*:[[:space:]]*true' "$RESULTS_FILE")"
false_count="$(count_matches '"passes"[[:space:]]*:[[:space:]]*false' "$RESULTS_FILE")"
qa_verdict=""
if [ -f "$QA_REPORT_FILE" ]; then
  qa_verdict="$(sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' "$QA_REPORT_FILE" 2>/dev/null || true)"
fi

status="running"
if [ -f "$RESULTS_FILE" ] && [ "$true_count" -gt 0 ] && [ "$false_count" -eq 0 ] && [ "$qa_verdict" = "PASS" ]; then
  status="goal-complete"
elif [ -f "$RESULTS_FILE" ] && [ "$true_count" -gt 0 ] && [ "$false_count" -eq 0 ]; then
  status="awaiting-evaluator-pass"
else
  last_pass_count="0"
  if [ -f "$LAST_PASS_COUNT_FILE" ]; then
    last_pass_count="$(sed -n '1p' "$LAST_PASS_COUNT_FILE" 2>/dev/null || printf '0')"
  fi
  case "$last_pass_count" in
    ''|*[!0-9]*) last_pass_count="0" ;;
  esac
  if [ "$true_count" -gt "$last_pass_count" ]; then
    status="builder-pass"
  fi
fi

last_status=""
if [ -f "$LAST_STATUS_FILE" ]; then
  last_status="$(sed -n '1p' "$LAST_STATUS_FILE" 2>/dev/null || true)"
fi

should_post="false"
if [ "$status" != "running" ] && [ "$status" != "awaiting-evaluator-pass" ] && [ "$status" != "$last_status" ]; then
  should_post="true"
elif [ "$status" = "builder-pass" ]; then
  last_pass_count="0"
  if [ -f "$LAST_PASS_COUNT_FILE" ]; then
    last_pass_count="$(sed -n '1p' "$LAST_PASS_COUNT_FILE" 2>/dev/null || printf '0')"
  fi
  case "$last_pass_count" in
    ''|*[!0-9]*) last_pass_count="0" ;;
  esac
  if [ "$true_count" -gt "$last_pass_count" ]; then
    should_post="true"
  fi
fi

goal="goal"
session_id=""
if [ -f "$STATE_DIR/goal-state.json" ] && command -v python3 >/dev/null 2>&1; then
  goal="$(python3 - "$STATE_DIR/goal-state.json" <<'PY' 2>/dev/null || printf 'goal'
import json
import sys
data = json.load(open(sys.argv[1]))
print(data.get("goal") or "goal")
PY
)"
  session_id="$(python3 - "$STATE_DIR/goal-state.json" <<'PY' 2>/dev/null || true
import json
import sys
data = json.load(open(sys.argv[1]))
print(data.get("session_id") or "")
PY
)"
fi

message=""
case "$status" in
  goal-complete)
    message="Goal complete: ${goal}"
    ;;
  builder-pass)
    message="Builder criterion PASS for goal: ${goal}"
    ;;
esac

printf '%s\n' "$status" > "$LAST_STATUS_FILE"
printf '%s\n' "$true_count" > "$LAST_PASS_COUNT_FILE"

if [ "$should_post" != "true" ] || [ -z "$message" ]; then
  exit 0
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
channel="${DISCORD_NOTIFY_CHANNEL_ID:-unknown-channel}"
printf '%s channel=%s session=%s status=%s message=%s\n' "$timestamp" "$channel" "$session_id" "$status" "$message" >> "$LOG_FILE"

if [ -n "${DISCORD_NOTIFY_WEBHOOK:-}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    payload="$(MESSAGE="$message" python3 - <<'PY'
import json
import os
print(json.dumps({"content": os.environ.get("MESSAGE", "")}))
PY
)"
    curl -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$DISCORD_NOTIFY_WEBHOOK" >/dev/null 2>&1 || {
      printf '%s channel=%s status=%s webhook-error\n' "$timestamp" "$channel" "$status" >> "$LOG_FILE"
    }
  fi
fi

exit 0
