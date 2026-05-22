#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Inner pulse. Fires on Stop and SubagentStop.
#
# Semantics:
#  - Always: write last-beat (epoch seconds) and a JSON snapshot so the outer
#    pulse (OpenClaw goal-supervisor) can detect stalls.
#  - On SubagentStop: that's all. A subagent finishing is a heartbeat tick,
#    not a turn boundary. Do NOT increment the block counter, do NOT decide
#    whether the goal is met. Those are the parent turn's responsibility.
#  - On Stop (or unknown event for safety): run the full Default-FAIL contract
#    — check AGENT_STOP, check test-results.json, honor STEER.md, enforce the
#    anti-runaway block cap, return decision=block when the goal is not met.
#
# Without the SubagentStop short-circuit, every subagent tool call would burn
# a block (Trap D2 in docs/parity-gap-analysis.md): a 26-tool-use evaluator
# subagent exhausts the 8-block cap in ~20 seconds and produces no verdict.

input="$(cat)"
WORKDIR="${PWD}"
STATE_DIR="$WORKDIR/.claude/goal-state"
mkdir -p "$STATE_DIR"
PREVIOUS_LAST_BEAT=""
if [ -f "$STATE_DIR/last-beat" ]; then
  PREVIOUS_LAST_BEAT="$(sed -n '1p' "$STATE_DIR/last-beat" 2>/dev/null || true)"
fi

log_status() {
  decision="$1"
  reason="$2"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$decision" "$reason" >> "$STATE_DIR/heartbeat-stop.log"
}

parse_event_name() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r '.hook_event_name // ""' 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    INPUT_JSON="$input" python3 - <<'PY' 2>/dev/null || true
import json
import os
raw = os.environ.get("INPUT_JSON", "")
try:
    data = json.loads(raw) if raw.strip() else {}
except json.JSONDecodeError:
    data = {}
print(data.get("hook_event_name", ""))
PY
    return 0
  fi
  printf ''
}

write_state_snapshot() {
  if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$input" | jq -c '{session_id, hook_event_name, background_tasks, session_crons}' > "$STATE_DIR/last-beat-state.json" 2>/dev/null; then
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
    "hook_event_name": data.get("hook_event_name"),
    "background_tasks": data.get("background_tasks"),
    "session_crons": data.get("session_crons"),
}
Path(sys.argv[1]).write_text(json.dumps(state, separators=(",", ":")) + "\n")
PY
    return 0
  fi
  printf '{"session_id":null,"hook_event_name":null,"background_tasks":null,"session_crons":null}\n' > "$STATE_DIR/last-beat-state.json"
}

EVENT_NAME="$(parse_event_name | tr -d '\r\n')"

date +%s > "$STATE_DIR/last-beat"
write_state_snapshot

# SubagentStop is a heartbeat tick, not a turn boundary. The parent Stop will
# run the goal check. If we increment the block-counter here, a subagent that
# fires 8+ SubagentStop events will exhaust the anti-runaway cap before any
# real progress is made.
if [ "$EVENT_NAME" = "SubagentStop" ]; then
  log_status "allow" "subagent-stop"
  exit 0
fi

RESULTS_FILE="$WORKDIR/test-results.json"
GOAL_STATE_FILE="$STATE_DIR/goal-state.json"
BLOCK_COUNT_FILE="$STATE_DIR/block-count"

# has_any_false / has_any_true: count "passes" booleans under any nesting,
# preferring jq for correctness (won't be fooled by future schema keys like
# "prior_passes" or "sub_passes") and falling back to an anchored regex.
# Closes Trap D7 in docs/parity-gap-analysis.md.
results_count() {
  file="$1"
  value="$2"
  [ -f "$file" ] || { printf '0\n'; return 0; }
  if command -v jq >/dev/null 2>&1; then
    count=$(jq --argjson v "$value" -r '[.. | objects | select(has("passes")) | .passes] | map(select(. == $v)) | length' "$file" 2>/dev/null) || count=""
    if [ -n "$count" ] && printf '%s' "$count" | grep -Eq '^[0-9]+$'; then
      printf '%s\n' "$count"
      return 0
    fi
  fi
  # Anchored fallback: require the literal key `"passes"` to be preceded by
  # a key-position character ({, comma, or whitespace) so substrings like
  # `"prior_passes"` cannot match.
  case "$value" in
    true) pat='[{,[:space:]]"passes"[[:space:]]*:[[:space:]]*true' ;;
    false) pat='[{,[:space:]]"passes"[[:space:]]*:[[:space:]]*false' ;;
    *) printf '0\n'; return 0 ;;
  esac
  c=$({ grep -oE "$pat" "$file" 2>/dev/null || true; } | wc -l | tr -d ' ')
  printf '%s\n' "$c"
}

append_session_ledger() {
  exit_reason="$1"
  sprints_passed="${2:-0}"

  set +e
  case "$exit_reason" in
    goal-met|operator-kill-switch|anti-runaway-cap) ;;
    *) set -e; return 0 ;;
  esac

  evidence_reads="unavailable"
  evidence_log="${VERIFY_READ_LOG:-$WORKDIR/.claude/.evidence-reads}"
  if [ -s "$evidence_log" ]; then
    evidence_reads="$(wc -l < "$evidence_log" | tr -d ' ')"
    case "$evidence_reads" in
      ''|*[!0-9]*) evidence_reads="unavailable" ;;
    esac
  fi

  commits="unavailable"
  if git -C "$WORKDIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    maybe_commits="$(git -C "$WORKDIR" rev-list main..HEAD --count 2>/dev/null || true)"
    case "$maybe_commits" in
      ''|*[!0-9]*) ;;
      *) commits="$maybe_commits" ;;
    esac
  fi

  if command -v python3 >/dev/null 2>&1; then
    SESSION_LEDGER_EXIT_REASON="$exit_reason" \
    SESSION_LEDGER_SPRINTS_PASSED="$sprints_passed" \
    SESSION_LEDGER_EVIDENCE_READS="$evidence_reads" \
    SESSION_LEDGER_COMMITS="$commits" \
    SESSION_LEDGER_PREVIOUS_LAST_BEAT="$PREVIOUS_LAST_BEAT" \
    python3 - "$STATE_DIR/sessions.jsonl" "$GOAL_STATE_FILE" "$STATE_DIR/session-ledger-id" <<'PY' >/dev/null 2>&1 || true
import datetime
import json
import os
import sys
import uuid
from pathlib import Path

ledger_path = Path(sys.argv[1])
goal_state_path = Path(sys.argv[2])
fallback_id_path = Path(sys.argv[3])


def parse_json(path):
    try:
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    return {}


def numeric_or_unavailable(value):
    if isinstance(value, int):
        return value
    text = str(value or "").strip()
    return int(text) if text.isdigit() else "unavailable"


def iso_utc(value):
    if value in (None, ""):
        return ""
    if isinstance(value, (int, float)):
        return datetime.datetime.fromtimestamp(value, datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    text = str(value).strip()
    if not text:
        return ""
    try:
        if text.isdigit():
            return datetime.datetime.fromtimestamp(int(text), datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=datetime.timezone.utc)
        return parsed.astimezone(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    except Exception:
        return text


goal_state = parse_json(goal_state_path)
session_id = str(goal_state.get("session_id") or "").strip()
if not session_id:
    try:
        session_id = fallback_id_path.read_text(encoding="utf-8").strip()
    except Exception:
        session_id = ""
if not session_id:
    session_id = str(uuid.uuid4())
    try:
        fallback_id_path.write_text(session_id + "\n", encoding="utf-8")
    except Exception:
        pass

started_at = iso_utc(goal_state.get("started_at"))
if not started_at:
    started_at = iso_utc(os.environ.get("SESSION_LEDGER_PREVIOUS_LAST_BEAT", ""))
if not started_at:
    started_at = "unavailable"

ended_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
record = {
    "session_id": session_id,
    "started_at": started_at,
    "ended_at": ended_at,
    "sprints_passed": numeric_or_unavailable(os.environ.get("SESSION_LEDGER_SPRINTS_PASSED", "0")),
    "evidence_reads": numeric_or_unavailable(os.environ.get("SESSION_LEDGER_EVIDENCE_READS", "unavailable")),
    "commits": numeric_or_unavailable(os.environ.get("SESSION_LEDGER_COMMITS", "unavailable")),
    "exit_reason": os.environ.get("SESSION_LEDGER_EXIT_REASON", "goal-met"),
}

ledger_path.parent.mkdir(parents=True, exist_ok=True)
already_recorded = False
if ledger_path.exists():
    try:
        for raw in ledger_path.read_text(encoding="utf-8").splitlines():
            if not raw.strip():
                continue
            try:
                existing = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if existing.get("session_id") == session_id:
                already_recorded = True
                break
    except Exception:
        already_recorded = False

if not already_recorded:
    with ledger_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, separators=(",", ":")) + "\n")
PY
  fi
  set -e
  return 0
}

if [ -e "${AGENT_STOP_FILE:-$WORKDIR/AGENT_STOP}" ]; then
  true_count="$(results_count "$RESULTS_FILE" true)"
  log_status "allow" "operator-kill-switch"
  append_session_ledger "operator-kill-switch" "$true_count"
  exit 0
fi

scope_policy() {
  file="$1"
  [ -f "$file" ] || { printf 'fixed_scope\n'; return 0; }
  python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); policy=data.get("scope_policy","fixed_scope"); print(policy if policy in {"fixed_scope","production_hardening","research_only"} else "fixed_scope")' "$file" 2>/dev/null || printf 'fixed_scope\n'
}

write_blocker_gate_snapshot() {
  policy="$1"
  python3 - "$policy" "$STATE_DIR/blockers.jsonl" "$STATE_DIR/blocker-gate.json" <<'PY'
import datetime
import json
import sys
from pathlib import Path

policy = sys.argv[1]
ledger_path = Path(sys.argv[2])
snapshot_path = Path(sys.argv[3])

open_count = 0
triaged_unevidenced_count = 0
decision = "skip"

if policy == "production_hardening":
    latest = {}
    if ledger_path.exists():
        for line in ledger_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            blocker_id = record.get("id")
            if isinstance(blocker_id, str) and blocker_id:
                latest[blocker_id] = record

    for record in latest.values():
        status = record.get("status")
        evidence_paths = record.get("evidence_paths")
        if not isinstance(evidence_paths, list):
            evidence_paths = []
        if status == "open":
            open_count += 1
        elif status == "triaged" and not evidence_paths:
            triaged_unevidenced_count += 1

    decision = "block" if open_count or triaged_unevidenced_count else "allow"

snapshot = {
    "policy": policy,
    "open_count": open_count,
    "triaged_unevidenced_count": triaged_unevidenced_count,
    "decision": decision,
    "timestamp": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
snapshot_path.write_text(json.dumps(snapshot, separators=(",", ":")) + "\n", encoding="utf-8")
print(f"{decision} {open_count} {triaged_unevidenced_count}")
PY
}

if [ -f "$RESULTS_FILE" ] && [ "$(results_count "$RESULTS_FILE" false)" -eq 0 ]; then
  true_count="$(results_count "$RESULTS_FILE" true)"
  policy="$(scope_policy "$RESULTS_FILE" | tr -d '\r\n')"
  gate_result="$(write_blocker_gate_snapshot "$policy" | tr -d '\r\n')"
  read -r gate_decision gate_open_count gate_triaged_unevidenced_count <<EOF
$gate_result
EOF
  if [ "$gate_decision" = "block" ]; then
    log_status "block" "blocker-gate open=$gate_open_count triaged_unevidenced=$gate_triaged_unevidenced_count"
  else
    printf '0\n' > "$BLOCK_COUNT_FILE"
    log_status "allow" "goal-met"
    append_session_ledger "goal-met" "$true_count"
    exit 0
  fi
fi

if [ ! -f "$GOAL_STATE_FILE" ]; then
  log_status "allow" "no-active-goal"
  exit 0
fi

if [ -s "$WORKDIR/STEER.md" ] || [ -e "$STATE_DIR/steered-this-turn" ]; then
  printf '0\n' > "$BLOCK_COUNT_FILE"
  rm -f "$STATE_DIR/steered-this-turn"
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
  append_session_ledger "anti-runaway-cap" "$(results_count "$RESULTS_FILE" true)"
  exit 0
fi

count=$((count + 1))
printf '%s\n' "$count" > "$BLOCK_COUNT_FILE"
log_status "block" "goal-not-met"
printf '{"decision":"block","reason":"goal not met; continue"}\n'
exit 2
