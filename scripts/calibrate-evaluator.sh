#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Operator override capture for evaluator calibration. The March 2026
# harness-design article calls out that evaluators drift -- they "identify
# legitimate issues then talk themselves into approving the work." The fix
# is to capture operator disagreements as a calibration corpus the
# evaluator agent reads on every invocation.
#
# Records one JSON line to .claude/goal-state/evaluator-calibration.jsonl:
#   {at, round, evaluator_verdict, operator_verdict, axes_in_dispute, reason, goal_id}
#
# The evaluator agent reads the tail of this file before grading.

usage() {
  cat <<'USAGE'
Usage: calibrate-evaluator.sh \
    --workspace <abs_path> \
    --operator-verdict PASS|NEEDS_WORK \
    --reason "<one-line operator note>" \
    [--axes "axis1,axis2"] \
    [--round N]

Captures an operator override against the most recent QA_REPORT.md.

The evaluator verdict and round are read from QA_REPORT.md and rounds.json
when not provided. The reason is required: a calibration entry without a
reason teaches nothing.
USAGE
}

WORKSPACE="$PWD"
OPERATOR_VERDICT=""
REASON=""
AXES=""
ROUND=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --operator-verdict) OPERATOR_VERDICT="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --axes) AXES="${2:-}"; shift 2 ;;
    --round) ROUND="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "calibrate-evaluator: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$WORKSPACE" in /*) ;; *) echo "calibrate-evaluator: --workspace must be absolute" >&2; exit 2 ;; esac
case "$OPERATOR_VERDICT" in PASS|NEEDS_WORK) ;; *) echo "calibrate-evaluator: --operator-verdict must be PASS or NEEDS_WORK" >&2; exit 2 ;; esac
[ -n "$REASON" ] || { echo "calibrate-evaluator: --reason is required" >&2; exit 2; }
[ -d "$WORKSPACE" ] || { echo "calibrate-evaluator: workspace not found: $WORKSPACE" >&2; exit 2; }

QA="$WORKSPACE/QA_REPORT.md"
STATE_DIR="$WORKSPACE/.claude/goal-state"
mkdir -p "$STATE_DIR"
CAL="$STATE_DIR/evaluator-calibration.jsonl"

evaluator_verdict=""
if [ -f "$QA" ]; then
  evaluator_verdict=$(sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' "$QA")
fi
case "$evaluator_verdict" in PASS|NEEDS_WORK) ;; *) evaluator_verdict="unknown" ;; esac

if [ "$evaluator_verdict" = "$OPERATOR_VERDICT" ]; then
  echo "calibrate-evaluator: operator verdict matches evaluator verdict (both $OPERATOR_VERDICT); nothing to calibrate." >&2
  exit 0
fi

if [ -z "$ROUND" ]; then
  ROUND=$(python3 - "$STATE_DIR/rounds.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    rounds = d.get("rounds") if isinstance(d, dict) else None
    print(len(rounds) if isinstance(rounds, list) else 0)
except Exception:
    print(0)
PY
)
fi

goal_id=""
if [ -f "$STATE_DIR/goal-state.json" ]; then
  goal_id=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("session_id") or "")' "$STATE_DIR/goal-state.json" 2>/dev/null || true)
fi

ROUND="$ROUND" EVERDICT="$evaluator_verdict" OVERDICT="$OPERATOR_VERDICT" REASON="$REASON" AXES="$AXES" GOAL="$goal_id" CAL="$CAL" python3 - <<'PY'
import json, os, time
entry = {
    "at": int(time.time()),
    "round": int(os.environ.get("ROUND") or 0),
    "evaluator_verdict": os.environ.get("EVERDICT") or "unknown",
    "operator_verdict": os.environ.get("OVERDICT") or "unknown",
    "axes_in_dispute": [a.strip() for a in os.environ.get("AXES","").split(",") if a.strip()],
    "reason": os.environ.get("REASON") or "",
    "goal_id": os.environ.get("GOAL") or "",
}
with open(os.environ["CAL"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, separators=(",", ":")) + "\n")
PY

echo "calibrate-evaluator: recorded override in $CAL"
