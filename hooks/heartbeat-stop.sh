#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

input="$(cat)"
WORKDIR="${PWD}"
STATE_DIR="$WORKDIR/.claude/goal-state"
mkdir -p "$STATE_DIR"

RESULTS_FILE="${RESULTS_FILE:-$WORKDIR/test-results.json}"
QA_REPORT_FILE="${QA_REPORT_FILE:-$WORKDIR/QA_REPORT.md}"
GOAL_STATE_FILE="$STATE_DIR/goal-state.json"
BLOCK_COUNT_FILE="$STATE_DIR/block-count"
ROUNDS_FILE="$STATE_DIR/rounds.json"
ESCALATION_FILE="$WORKDIR/ESCALATION.md"
NOTIFIED_FILE="$STATE_DIR/escalation-notified"

# Round budget: the inner block-count and the outer --max-rounds share one
# value. The watchdog reads .claude/goal-state/round-budget when present.
ROUND_BUDGET=8
if [ -f "$STATE_DIR/round-budget" ]; then
  rb=$(sed -n '1p' "$STATE_DIR/round-budget" 2>/dev/null || true)
  case "$rb" in
    ''|*[!0-9]*) ;;
    *) ROUND_BUDGET="$rb" ;;
  esac
fi

log_status() {
  decision="$1"
  reason="$2"
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$decision" "$reason" >> "$STATE_DIR/heartbeat-stop.log"
}

read_goal_field() {
  field="$1"
  [ -f "$GOAL_STATE_FILE" ] || { printf ''; return 0; }
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2]) or "")' "$GOAL_STATE_FILE" "$field" 2>/dev/null || printf ''
}

notify_webhook() {
  msg="$1"
  url="${DISCORD_NOTIFY_WEBHOOK:-}"
  [ -n "$url" ] || return 0
  if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    payload=$(MESSAGE="$msg" python3 -c 'import json,os; print(json.dumps({"content": os.environ.get("MESSAGE","")}))')
    curl -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null 2>&1 || true
  fi
}

write_escalation() {
  tag="$1"
  reason="$2"
  # Only write once per stuck session, but always update timestamp.
  if [ ! -f "$ESCALATION_FILE" ]; then
    {
      printf '# Escalation — %s\n\n' "$tag"
      printf 'At: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'Reason: %s\n\n' "$reason"
      printf 'Round budget: %s\n' "$ROUND_BUDGET"
      session_id=$(read_goal_field session_id)
      goal=$(read_goal_field goal)
      rubric=$(read_goal_field rubric)
      [ -n "$session_id" ] && printf 'Session: %s\n' "$session_id"
      [ -n "$rubric" ] && printf 'Rubric: %s\n' "$rubric"
      [ -n "$goal" ] && printf 'Goal: %s\n' "$goal"
      printf '\nThis session hit the runaway cap inside the heartbeat hook. The\n'
      printf 'inner pulse stopped blocking so the worker can exit; the operator\n'
      printf 'must inspect .claude/goal-state/heartbeat-stop.log and decide\n'
      printf 'whether to fix the contract, the evidence, or the evaluator.\n'
    } > "$ESCALATION_FILE"
  fi
  if [ ! -f "$NOTIFIED_FILE" ]; then
    notify_webhook "ESCALATION ($tag): $reason"
    date -u +%Y-%m-%dT%H:%M:%SZ > "$NOTIFIED_FILE"
  fi
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

  if [ "$count" -ge "$ROUND_BUDGET" ]; then
    # No more silent-allow. Escalate explicitly and let the session exit.
    write_escalation "anti-runaway-cap" "$reason"
    log_status "escalated" "anti-runaway-cap:${reason}:budget=${ROUND_BUDGET}"
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

# Interaction-evidence gate. The frontend and desktop rubrics demand that
# the evaluator drove the live surface. Same enforcement floor for both:
# at least one non-empty artifact under the round-namespaced path. The
# strict-named contract (trace.zip / session.jsonl) is the preferred
# shape and what the planner declares, but Playwright MCP server versions
# vary in trace filename and computer-use servers sometimes emit
# `actions.jsonl` or `events.log`. Accept any non-empty regular file under
# `playwright-mcp/round-*/` or `computer-use/round-*/` so a contract
# satisfied in spirit is not blocked by a filename mismatch. Strict path
# remains documented in the rubric for evaluator discipline.
has_interaction_evidence() {
  if command -v find >/dev/null 2>&1; then
    # Strict-named preferred shapes first (cheaper for the common case).
    if find "$WORKDIR/playwright-mcp" -type f -name 'trace.zip' -size +0c 2>/dev/null | grep -q .; then
      return 0
    fi
    if find "$WORKDIR/computer-use" -type f -name 'session.jsonl' -size +0c 2>/dev/null | grep -q .; then
      return 0
    fi
    # Fallback: any non-empty file under the round-namespaced dirs.
    if find "$WORKDIR/playwright-mcp" -type d -name 'round-*' 2>/dev/null | while read -r d; do
        find "$d" -type f -size +0c | head -1
      done | grep -q .; then
      return 0
    fi
    if find "$WORKDIR/computer-use" -type d -name 'round-*' 2>/dev/null | while read -r d; do
        find "$d" -type f -size +0c | head -1
      done | grep -q .; then
      return 0
    fi
  fi
  return 1
}

append_round() {
  verdict="$1"
  rubric=$(read_goal_field rubric)
  model=$(read_goal_field model)
  codex_model=$(read_goal_field codex_model)
  RFILE="$ROUNDS_FILE" VERDICT="$verdict" RUBRIC="$rubric" MODEL="$model" CODEX_MODEL="$codex_model" RESULTS="$RESULTS_FILE" QA="$QA_REPORT_FILE" python3 - <<'PY' 2>/dev/null || true
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

# Count evidence files referenced this round (rough proxy for "did the
# evaluator look at anything").
results_path = Path(os.environ.get("RESULTS", ""))
evidence_count = 0
try:
    if results_path.is_file():
        d = json.loads(results_path.read_text())
        items = d.get("criteria") if isinstance(d, dict) and isinstance(d.get("criteria"), list) else None
        if items:
            for c in items:
                if isinstance(c, dict):
                    evidence_count += len(c.get("evidence_paths") or [])
except Exception:
    pass

axis_scores = []
try:
    qa = Path(os.environ.get("QA", ""))
    if qa.is_file():
        text = qa.read_text(errors="ignore")
        # Best-effort axis-score scrape: lines that look like "Axis: N/5" or "Design Quality: 4"
        import re
        for m in re.finditer(r"([A-Z][A-Za-z ]+?)[:\-]\s*([0-5])\s*(?:/\s*5)?", text):
            label = m.group(1).strip()
            if any(k in label.lower() for k in ("design", "originality", "craft", "functionality", "contract", "reliability", "operational", "surface", "correctness", "consumer", "output", "robustness", "behavior", "integration")):
                axis_scores.append({"label": label, "score": int(m.group(2))})
            if len(axis_scores) >= 4:
                break
except Exception:
    pass

data["rounds"].append({
    "n": len(data["rounds"]) + 1,
    "verdict": verdict,
    "at": int(time.time()),
    "rubric": os.environ.get("RUBRIC") or None,
    "model": os.environ.get("MODEL") or None,
    "codex_model": os.environ.get("CODEX_MODEL") or None,
    "evidence_count": evidence_count,
    "axis_scores": axis_scores or None,
})
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n")
tmp.replace(path)
PY
}

date +%s > "$STATE_DIR/last-beat"
write_state_snapshot

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

# re-simplify override: operator can disable the evaluator gate entirely
# to bench whether the gate is still load-bearing on the current model.
# RISKY by design — the heartbeat will allow goal-completion based on
# test-results.json alone. Documented as the highest-risk override.
evaluator_override_set=0
if [ -f "$STATE_DIR/re-simplify-overrides.json" ] && command -v python3 >/dev/null 2>&1; then
  if python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if isinstance(d, dict) and "evaluator" in d else 1)
except Exception:
    sys.exit(1)
' "$STATE_DIR/re-simplify-overrides.json" 2>/dev/null; then
    evaluator_override_set=1
    log_status "re-simplify" "evaluator gate disabled by override (risky)"
  fi
fi

if [ "$evaluator_override_set" != "1" ] && ! qa_has_pass; then
  qa_first=$(first_nonempty_line "$QA_REPORT_FILE" || true)
  if [ "$qa_first" = "NEEDS_WORK" ]; then
    append_round "NEEDS_WORK"
  fi
  block_continue "awaiting-evaluator-pass"
fi

# Re-simplify override: the operator may disable the interaction-
# evidence gate to bench whether the gate is still load-bearing on the
# current model. The override is read every beat so it can be toggled
# without restarting the worker.
trace_override_set=0
if [ -f "$STATE_DIR/re-simplify-overrides.json" ] && command -v python3 >/dev/null 2>&1; then
  if python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if isinstance(d, dict) and "playwright-trace" in d else 1)
except Exception:
    sys.exit(1)
' "$STATE_DIR/re-simplify-overrides.json" 2>/dev/null; then
    trace_override_set=1
    log_status "re-simplify" "playwright-trace gate disabled by override"
  fi
fi

# QA says PASS. Apply the interaction-evidence gate for rubrics that demand it.
rubric_check=$(read_goal_field rubric)
if [ "$trace_override_set" != "1" ]; then
  case "$rubric_check" in
    frontend|desktop)
      if ! has_interaction_evidence; then
        # Roll the verdict back: the evaluator claimed PASS but did not drive
        # the live surface. The agent must produce a Playwright trace under
        # playwright-mcp/round-N/trace.zip OR a computer-use session log
        # under computer-use/round-N/session.jsonl before PASS sticks.
        block_continue "missing-interaction-evidence:${rubric_check}"
      fi
      ;;
  esac
fi

append_round "PASS"
printf '0\n' > "$BLOCK_COUNT_FILE"
log_status "allow" "goal-met-with-evaluator-pass"
exit 0
