#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Headless wrapper around the contract-reviewer agent. Run after the
# planner produces BUILD_PLAN.md, before the generator starts.
#
# Returns:
#   0 - CONTRACT_OK
#   1 - CONTRACT_REWRITE  (caller should re-run the planner with findings)
#   2 - usage / invocation error
#   3 - max rounds exhausted (CONTRACT_OK was written with a Concessions
#       section; caller should treat as a soft pass and surface it)
#
# Reads:
#   BUILD_PLAN.md, test-results.json, .claude/goal-state/goal-state.json
# Writes:
#   CONTRACT_REVIEW.md at the workspace root.

usage() {
  cat <<'USAGE'
Usage: run-contract-review.sh [--workspace <abs_path>] [--max-rounds N] [--dry-run]

Runs the contract-reviewer subagent on the workspace BUILD_PLAN.md and
writes CONTRACT_REVIEW.md. Exits 0 on CONTRACT_OK, 1 on CONTRACT_REWRITE,
3 if --max-rounds exhausted.

The script does not itself loop. Round counting is the caller's job;
this script enforces only that --max-rounds is a positive integer and
records the round in .claude/goal-state/contract-rounds.json.
USAGE
}

WORKSPACE="$PWD"
MAX_ROUNDS=3
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --max-rounds) MAX_ROUNDS="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "run-contract-review: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$WORKSPACE" in /*) ;; *) echo "run-contract-review: --workspace must be absolute" >&2; exit 2 ;; esac
case "$MAX_ROUNDS" in ''|*[!0-9]*) echo "run-contract-review: --max-rounds must be a positive integer" >&2; exit 2 ;; esac
[ "$MAX_ROUNDS" -gt 0 ] || { echo "run-contract-review: --max-rounds must be > 0" >&2; exit 2; }

cd "$WORKSPACE"

if [ ! -f BUILD_PLAN.md ]; then
  cat > CONTRACT_REVIEW.md <<'REVIEW'
CONTRACT_REWRITE

Reviewed: (nothing — BUILD_PLAN.md is missing)

Rubric fit: cannot judge; no plan present.

Per-criterion verdicts: n/a

Missing criteria: Planner did not produce a plan. Invoke the planner
subagent before re-running this script.

Interaction-evidence path: n/a
REVIEW
  exit 1
fi

STATE_DIR="$WORKSPACE/.claude/goal-state"
mkdir -p "$STATE_DIR"
ROUNDS_FILE="$STATE_DIR/contract-rounds.json"

# Track contract-review rounds.
CURRENT_ROUND=$(python3 - "$ROUNDS_FILE" <<'PY'
import json, os, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
    rounds = d.get("rounds") if isinstance(d, dict) else None
    n = len(rounds) if isinstance(rounds, list) else 0
except Exception:
    n = 0
print(n + 1)
PY
)

if [ "$CURRENT_ROUND" -gt "$MAX_ROUNDS" ]; then
  cat > CONTRACT_REVIEW.md <<REVIEW
CONTRACT_OK

(soft pass — max contract-review rounds reached: $((CURRENT_ROUND - 1))/$MAX_ROUNDS)

Concessions:
- Operator must verify the acceptance contract is testable. The
  contract-reviewer did not converge on CONTRACT_OK within $MAX_ROUNDS
  rounds. Proceed with the generator only if the remaining criteria
  are observable enough to defend.
REVIEW
  exit 3
fi

if [ "$DRY_RUN" = "1" ]; then
  printf 'run-contract-review: would invoke `claude --agent contract-reviewer` in %s\n' "$WORKSPACE"
  printf 'run-contract-review: round=%s max=%s\n' "$CURRENT_ROUND" "$MAX_ROUNDS"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "run-contract-review: \`claude\` CLI not found on PATH" >&2
  exit 2
fi

PROMPT="Review the acceptance contract in BUILD_PLAN.md. Follow the contract-reviewer agent definition. Write CONTRACT_REVIEW.md. Do not write any other file."

# Invoke the agent. Print mode (-p) is non-interactive.
claude -p --agent contract-reviewer "$PROMPT" \
  > "$STATE_DIR/contract-review-stdout-${CURRENT_ROUND}.log" \
  2> "$STATE_DIR/contract-review-stderr-${CURRENT_ROUND}.log" || true

# Record the round.
python3 - "$ROUNDS_FILE" "$CURRENT_ROUND" <<'PY'
import json, os, sys, time
from pathlib import Path
path = Path(sys.argv[1])
n = int(sys.argv[2])
try:
    d = json.loads(path.read_text())
    if not isinstance(d, dict) or "rounds" not in d:
        d = {"rounds": []}
except Exception:
    d = {"rounds": []}
d["rounds"].append({"n": n, "at": int(time.time())})
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(d, indent=2) + "\n")
tmp.replace(path)
PY

if [ ! -f CONTRACT_REVIEW.md ]; then
  echo "run-contract-review: agent did not write CONTRACT_REVIEW.md" >&2
  exit 2
fi

first_line=$(sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' CONTRACT_REVIEW.md)
case "$first_line" in
  CONTRACT_OK) exit 0 ;;
  CONTRACT_REWRITE) exit 1 ;;
  *) echo "run-contract-review: unrecognized verdict line: $first_line" >&2; exit 2 ;;
esac
