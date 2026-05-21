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

block_continue() {
  reason="$1"
  count="0"
  if [ -f "$BLOCK_COUNT_FILE" ]; then
    count="$(sed -n '1p' "$BLOCK_COUNT_FILE" 2>/dev/null || printf '0')"
  fi
  case "$count" in
    ''|*[!0-9]*) count="0" ;;
  esac

  if [ "$count" -ge 8 ]; then
    log_status "allow" "anti-runaway-cap:${reason}"
    exit 0
  fi

  count=$((count + 1))
  printf '%s\n' "$count" > "$BLOCK_COUNT_FILE"
  log_status "block" "$reason"
  printf '{"decision":"block","reason":"%s; continue"}\n' "$reason"
  exit 2
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

first_nonempty_line() {
  file="$1"
  if [ ! -f "$file" ]; then
    return 1
  fi
  sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' "$file" 2>/dev/null || true
}

results_have_pass_fields() {
  [ -f "$RESULTS_FILE" ] && grep -q '"passes"[[:space:]]*:' "$RESULTS_FILE"
}

results_have_failures() {
  [ -f "$RESULTS_FILE" ] && grep -q '"passes"[[:space:]]*:[[:space:]]*false' "$RESULTS_FILE"
}

qa_has_pass() {
  [ "$(first_nonempty_line "$QA_REPORT_FILE")" = "PASS" ]
}

date +%s > "$STATE_DIR/last-beat"
write_state_snapshot

RESULTS_FILE="${RESULTS_FILE:-$WORKDIR/test-results.json}"
QA_REPORT_FILE="${QA_REPORT_FILE:-$WORKDIR/QA_REPORT.md}"
GOAL_STATE_FILE="$STATE_DIR/goal-state.json"
BLOCK_COUNT_FILE="$STATE_DIR/block-count"
ROUNDS_FILE="$STATE_DIR/rounds.json"

append_round() {
  verdict="$1"
  RFILE="$ROUNDS_FILE" VERDICT="$verdict" python3 - <<'PY' 2>/dev/null || true
import json, os, time
from pathlib import Path
path = Path(os.environ["RFILE"])
verdict = os.environ["VERDICT"]
try:
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or "rounds" not in data:
        data = {"rounds": []}
except Exception:
    data = {"rounds": []}
data["rounds"].append({
    "n": len(data["rounds"]) + 1,
    "verdict": verdict,
    "at": int(time.time()),
})
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n")
tmp.replace(path)
PY
}

if [ -e "${AGENT_STOP_FILE:-$WORKDIR/AGENT_STOP}" ]; then
  log_status "allow" "operator-kill-switch"
  exit 0
fi

if [ ! -f "$GOAL_STATE_FILE" ]; then
  log_status "allow" "no-active-goal"
  exit 0
fi

if [ -s "$WORKDIR/STEER.md" ]; then
  printf '0\n' > "$BLOCK_COUNT_FILE"
fi

if ! results_have_pass_fields; then
  block_continue "missing-test-results-contract"
fi

if results_have_failures; then
  block_continue "goal-not-met"
fi

if ! qa_has_pass; then
  qa_first=$(first_nonempty_line "$QA_REPORT_FILE" || true)
  if [ "$qa_first" = "NEEDS_WORK" ]; then
    append_round "NEEDS_WORK"
  fi
  block_continue "awaiting-evaluator-pass"
fi

append_round "PASS"
printf '0\n' > "$BLOCK_COUNT_FILE"
log_status "allow" "goal-met-with-evaluator-pass"
exit 0
