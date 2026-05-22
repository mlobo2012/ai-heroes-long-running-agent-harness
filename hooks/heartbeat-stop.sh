#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

input="$(cat)"
WORKDIR="${PWD}"
STATE_DIR="$WORKDIR/.claude/goal-state"
mkdir -p "$STATE_DIR"
PREVIOUS_LAST_BEAT=""
if [ -f "$STATE_DIR/last-beat" ]; then
  PREVIOUS_LAST_BEAT="$(sed -n '1p' "$STATE_DIR/last-beat" 2>/dev/null || true)"
fi

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
    log_status "allow" "anti-runaway-cap"
    append_session_ledger "anti-runaway-cap" "$(results_count "$RESULTS_FILE" true)"
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

record = {
    "session_id": session_id,
    "started_at": started_at,
    "ended_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
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

EVENT_NAME="$(parse_event_name | tr -d '\r\n')"

date +%s > "$STATE_DIR/last-beat"
write_state_snapshot

if [ "$EVENT_NAME" = "SubagentStop" ]; then
  log_status "allow" "subagent-stop"
  exit 0
fi

if [ -e "${AGENT_STOP_FILE:-$WORKDIR/AGENT_STOP}" ]; then
  true_count="$(results_count "$RESULTS_FILE" true)"
  log_status "allow" "operator-kill-switch"
  append_session_ledger "operator-kill-switch" "$true_count"
  exit 0
fi

if [ ! -f "$GOAL_STATE_FILE" ]; then
  log_status "allow" "no-active-goal"
  exit 0
fi

if [ -f "$RESULTS_FILE" ] && [ "$(results_count "$RESULTS_FILE" false)" -eq 0 ]; then
  true_count="$(results_count "$RESULTS_FILE" true)"
  policy="$(scope_policy "$RESULTS_FILE" | tr -d '\r\n')"
  gate_result="$(write_blocker_gate_snapshot "$policy" | tr -d '\r\n')"
  read -r gate_decision gate_open_count gate_triaged_unevidenced_count <<EOF
$gate_result
EOF
  if [ "$gate_decision" = "block" ]; then
    log_status "block" "blocker-gate open=$gate_open_count triaged_unevidenced=$gate_triaged_unevidenced_count"
    block_continue "goal-not-met"
  fi

  terminal_without_qa=0
  if [ "$policy" != "fixed_scope" ] || [ -f "$STATE_DIR/blockers.jsonl" ] || [ -s "${VERIFY_READ_LOG:-$WORKDIR/.claude/.evidence-reads}" ]; then
    terminal_without_qa=1
  fi
  if [ "$terminal_without_qa" = "1" ]; then
    printf '0\n' > "$BLOCK_COUNT_FILE"
    log_status "allow" "goal-met"
    append_session_ledger "goal-met" "$true_count"
    exit 0
  fi
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
