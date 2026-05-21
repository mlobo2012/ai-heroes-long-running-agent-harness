#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

input="$(cat)"
WORKDIR="${PWD}"
STATE_DIR="$WORKDIR/.claude/goal-state"
mkdir -p "$STATE_DIR"

log_status() {
  decision="$1"
  reason="$2"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$decision" "$reason" >> "$STATE_DIR/heartbeat-stop.log"
}

write_state_snapshot() {
  if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$input" | jq -c '{session_id, background_tasks, session_crons}' > "$STATE_DIR/last-beat-state.json" 2>/dev/null; then
      return 0
    fi
  fi
  if command -v python3 >/dev/null 2>&1; then
    INPUT_JSON="$input" python3 - "$STATE_DIR/last-beat-state.json" <<'PY'
import json
import os
import sys
from pathlib import Path

raw = os.environ.get("INPUT_JSON", "")
try:
    data = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    data = {}
state = {
    "session_id": data.get("session_id"),
    "background_tasks": data.get("background_tasks"),
    "session_crons": data.get("session_crons"),
}
Path(sys.argv[1]).write_text(json.dumps(state, separators=(",", ":")) + "\n")
PY
    return 0
  fi
  printf '{"session_id":null,"background_tasks":null,"session_crons":null}\n' > "$STATE_DIR/last-beat-state.json"
}

date +%s > "$STATE_DIR/last-beat"
write_state_snapshot

if [ -e "${AGENT_STOP_FILE:-$WORKDIR/AGENT_STOP}" ]; then
  log_status "allow" "operator-kill-switch"
  exit 0
fi

RESULTS_FILE="$WORKDIR/test-results.json"
GOAL_STATE_FILE="$STATE_DIR/goal-state.json"
BLOCK_COUNT_FILE="$STATE_DIR/block-count"

if [ -f "$RESULTS_FILE" ] && ! grep -q '"passes"[[:space:]]*:[[:space:]]*false' "$RESULTS_FILE"; then
  printf '0\n' > "$BLOCK_COUNT_FILE"
  log_status "allow" "goal-met"
  exit 0
fi

if [ ! -f "$GOAL_STATE_FILE" ]; then
  log_status "allow" "no-active-goal"
  exit 0
fi

if [ -s "$WORKDIR/STEER.md" ]; then
  printf '0\n' > "$BLOCK_COUNT_FILE"
fi

count="0"
if [ -f "$BLOCK_COUNT_FILE" ]; then
  count="$(sed -n '1p' "$BLOCK_COUNT_FILE" 2>/dev/null || printf '0')"
fi
case "$count" in
  ''|*[!0-9]*) count="0" ;;
esac

if [ "$count" -ge 8 ]; then
  log_status "allow" "anti-runaway-cap"
  exit 0
fi

count=$((count + 1))
printf '%s\n' "$count" > "$BLOCK_COUNT_FILE"
log_status "block" "goal-not-met"
printf '{"decision":"block","reason":"goal not met; continue"}\n'
exit 2
