#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Ralph loop: the unattended build -> evaluate -> rebuild cycle the
# March 2026 article describes under "Why naive implementations fall short"
# and "Removing the sprint construct". Runs headless using `claude -p`,
# honors the shared round-budget file the heartbeat hook and watchdog
# also read, writes NEXT_FINDINGS.md after every NEEDS_WORK so the next
# build round opens with the operator-relevant findings already
# surfaced.
#
# This is the in-repo equivalent of the upstream README wrapper:
#
#   while grep -q '"passes": false' test-results.json; do
#     claude -p "Read PROGRESS.md and build the next unfinished feature."
#     VERDICT=$(claude --agent evaluator -p "Review the most recent commit.")
#     [ "$(echo "$VERDICT" | head -1)" = "PASS" ] || echo "$VERDICT" > NEXT_FINDINGS.md
#   done
#
# Differences from the upstream snippet:
#   * Honors `.claude/goal-state/round-budget` as the shared cap.
#   * Reads goal-state.json for rubric / model / round-budget.
#   * Surfaces NEXT_FINDINGS.md before the next build call so the next
#     turn opens with the previous evaluator's findings.
#   * Touches `AGENT_STOP` semantics: respects an existing file as
#     "stop after current round".
#   * Calls `run-evaluator.sh` (with --isolated when requested) so the
#     evaluator runs in a worktree and cannot mutate the builder tree.
#   * Records ralph-loop progress under `.claude/goal-state/ralph-loop.jsonl`.
#
# Exit codes:
#   0 - PASS achieved within the round budget
#   1 - max rounds exhausted (writes ESCALATION.md if not already there)
#   2 - usage / invocation error
#   3 - no test-results.json contract present (planner not run yet)
#   4 - operator AGENT_STOP encountered before any round completed
#   5 - `claude` CLI missing

usage() {
  cat <<'USAGE'
Usage: ralph-loop.sh [--workspace <abs_path>] [--max-rounds N]
                     [--isolated-evaluator] [--build-prompt "<text>"]
                     [--dry-run] [--no-evaluator]

Runs the build -> evaluate -> rebuild cycle headless until the
heartbeat hook would accept goal-completion or the round budget is hit.

  --workspace          Workspace root (default: $PWD).
  --max-rounds         Override the round budget cap. By default reads
                       .claude/goal-state/round-budget (or 8).
  --isolated-evaluator Run the evaluator inside `git worktree add`.
  --build-prompt       Custom builder prompt (default: orient + build).
  --no-evaluator       Skip the evaluator call (useful for measuring
                       baseline builder behavior in benches).
  --dry-run            Print what would be invoked and exit 0.

Reads:
  BUILD_PLAN.md, test-results.json, QA_REPORT.md, NEXT_FINDINGS.md,
  .claude/goal-state/{goal-state.json,round-budget,rounds.json}

Writes:
  NEXT_FINDINGS.md (each NEEDS_WORK round),
  .claude/goal-state/ralph-loop.jsonl (one line per round attempted),
  .claude/goal-state/ralph-loop-build-N.log,
  .claude/goal-state/ralph-loop-eval-N.log
USAGE
}

WORKSPACE="$PWD"
MAX_ROUNDS=""
ISOLATED=0
BUILD_PROMPT=""
DRY_RUN=0
SKIP_EVAL=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --max-rounds) MAX_ROUNDS="${2:-}"; shift 2 ;;
    --isolated-evaluator) ISOLATED=1; shift ;;
    --build-prompt) BUILD_PROMPT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-evaluator) SKIP_EVAL=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ralph-loop: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$WORKSPACE" in /*) ;; *) echo "ralph-loop: --workspace must be absolute" >&2; exit 2 ;; esac
[ -d "$WORKSPACE" ] || { echo "ralph-loop: workspace not found: $WORKSPACE" >&2; exit 2; }
case "$MAX_ROUNDS" in
  ""|*[!0-9]*) ;;
  *) [ "$MAX_ROUNDS" -gt 0 ] || { echo "ralph-loop: --max-rounds must be > 0" >&2; exit 2; } ;;
esac

cd "$WORKSPACE"

STATE_DIR="$WORKSPACE/.claude/goal-state"
mkdir -p "$STATE_DIR"
LOOP_LOG="$STATE_DIR/ralph-loop.jsonl"

# Resolve effective round budget. CLI --max-rounds beats round-budget
# file beats goal-state.json beats default 8.
effective_budget=8
if [ -f "$STATE_DIR/round-budget" ]; then
  rb=$(sed -n '1p' "$STATE_DIR/round-budget" 2>/dev/null || true)
  case "$rb" in ''|*[!0-9]*) ;; *) effective_budget="$rb" ;; esac
fi
if [ -f "$STATE_DIR/goal-state.json" ] && command -v python3 >/dev/null 2>&1; then
  gb=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("round_budget") or "")
except Exception:
    print("")
' "$STATE_DIR/goal-state.json")
  case "$gb" in ''|*[!0-9]*) ;; *) effective_budget="$gb" ;; esac
fi
[ -n "$MAX_ROUNDS" ] && effective_budget="$MAX_ROUNDS"

# Resolve rubric for evaluator gate context.
rubric=""
if [ -f "$STATE_DIR/goal-state.json" ] && command -v python3 >/dev/null 2>&1; then
  rubric=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get("rubric") or "")
except Exception:
    print("")
' "$STATE_DIR/goal-state.json")
fi

# Compose the default builder prompt. The harness re-orients on every
# session via session-start.sh, so this prompt only needs to set the
# direction.
if [ -z "$BUILD_PROMPT" ]; then
  BUILD_PROMPT="Read BUILD_PLAN.md and PROGRESS.md. If NEXT_FINDINGS.md exists, treat its bullets as the top of the queue. Build the next unfinished criterion from test-results.json. Produce the declared round-N evidence at the declared paths and Read each before flipping a criterion to passing. Update PROGRESS.md when you complete a coherent unit."
fi

# Pre-flight: planner must have written the contract.
if [ ! -f "$WORKSPACE/test-results.json" ]; then
  echo "ralph-loop: test-results.json missing — invoke the planner agent first" >&2
  exit 3
fi
if ! grep -q '"passes"' "$WORKSPACE/test-results.json" 2>/dev/null; then
  echo "ralph-loop: test-results.json has no passes:* entries — planner contract incomplete" >&2
  exit 3
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "ralph-loop: workspace=$WORKSPACE"
  echo "ralph-loop: effective_budget=$effective_budget"
  echo "ralph-loop: rubric=${rubric:-(none)}"
  echo "ralph-loop: isolated_evaluator=$ISOLATED"
  echo "ralph-loop: would invoke for each round:"
  echo "  builder: claude -p \"$BUILD_PROMPT\""
  if [ "$SKIP_EVAL" = "0" ]; then
    if [ "$ISOLATED" = "1" ]; then
      echo "  evaluator: scripts/run-evaluator.sh --workspace $WORKSPACE --isolated"
    else
      echo "  evaluator: scripts/run-evaluator.sh --workspace $WORKSPACE"
    fi
  else
    echo "  (evaluator skipped: --no-evaluator)"
  fi
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "ralph-loop: \`claude\` CLI not found on PATH" >&2
  exit 5
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

count_rounds() {
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    r = d.get("rounds") if isinstance(d, dict) else None
    print(len(r) if isinstance(r, list) else 0)
except Exception:
    print(0)
' "$STATE_DIR/rounds.json" 2>/dev/null || echo 0
}

verdict_of_qa() {
  if [ ! -f "$WORKSPACE/QA_REPORT.md" ]; then echo "MISSING"; return; fi
  sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' "$WORKSPACE/QA_REPORT.md"
}

contract_green() {
  grep -q '"passes"[[:space:]]*:' "$WORKSPACE/test-results.json" && \
    ! grep -q '"passes"[[:space:]]*:[[:space:]]*false' "$WORKSPACE/test-results.json"
}

write_next_findings() {
  # Capture the most recent evaluator findings into NEXT_FINDINGS.md so
  # the next build round opens with them.
  python3 - "$WORKSPACE/QA_REPORT.md" "$WORKSPACE/NEXT_FINDINGS.md" <<'PY'
import sys
from pathlib import Path
qa, nf = sys.argv[1:3]
src = Path(qa)
dst = Path(nf)
if not src.is_file():
    sys.exit(0)
text = src.read_text(encoding="utf-8", errors="ignore")
# Trim to the actionable bullets if the report has the standard layout.
lo = text.find("Specific findings")
if lo == -1:
    body = text
else:
    body = text[lo:]
header = (
    "# NEXT_FINDINGS\n\n"
    "Captured from the most recent QA_REPORT.md after a NEEDS_WORK\n"
    "verdict. The next builder turn must address these before opening\n"
    "new ground. ralph-loop refreshes this file on every NEEDS_WORK\n"
    "round.\n\n"
)
dst.write_text(header + body, encoding="utf-8")
PY
}

append_loop_event() {
  verdict="$1"
  round_n="$2"
  reason="$3"
  ROUND="$round_n" VERDICT="$verdict" REASON="$reason" LOG="$LOOP_LOG" python3 - <<'PY'
import json, os, time
entry = {
    "at": int(time.time()),
    "round": int(os.environ.get("ROUND") or 0),
    "verdict": os.environ.get("VERDICT") or "",
    "reason": os.environ.get("REASON") or "",
}
with open(os.environ["LOG"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(entry, separators=(",", ":")) + "\n")
PY
}

# Main loop.
for attempt in $(seq 1 "$effective_budget"); do
  if [ -e "$WORKSPACE/AGENT_STOP" ]; then
    echo "ralph-loop: AGENT_STOP present; stopping before round $attempt"
    append_loop_event "halted" "$attempt" "agent-stop"
    [ "$attempt" -eq 1 ] && exit 4
    exit 0
  fi

  echo "ralph-loop: round $attempt/$effective_budget (rubric=${rubric:-?})"

  # If the contract is already green and QA already passes, we're done
  # before we even start. This is the no-op happy path on resume.
  if contract_green && [ "$(verdict_of_qa)" = "PASS" ]; then
    echo "ralph-loop: contract green + QA PASS on entry; nothing to do."
    append_loop_event "PASS" "$attempt" "already-green-on-entry"
    exit 0
  fi

  build_log="$STATE_DIR/ralph-loop-build-${attempt}.log"
  echo "ralph-loop: builder -> $build_log"
  set +e
  claude -p "$BUILD_PROMPT" > "$build_log" 2>&1
  build_status=$?
  set -e
  if [ "$build_status" -ne 0 ]; then
    echo "ralph-loop: builder exited $build_status (continuing — evaluator will adjudicate)"
  fi

  if [ "$SKIP_EVAL" = "1" ]; then
    append_loop_event "no-eval" "$attempt" "skip-evaluator-flag"
    if contract_green; then
      echo "ralph-loop: contract green (no evaluator requested); exiting 0"
      exit 0
    fi
    continue
  fi

  eval_log="$STATE_DIR/ralph-loop-eval-${attempt}.log"
  echo "ralph-loop: evaluator -> $eval_log"
  set +e
  if [ "$ISOLATED" = "1" ]; then
    "$SCRIPT_DIR/run-evaluator.sh" --workspace "$WORKSPACE" --isolated > "$eval_log" 2>&1
  else
    "$SCRIPT_DIR/run-evaluator.sh" --workspace "$WORKSPACE" > "$eval_log" 2>&1
  fi
  eval_status=$?
  set -e

  verdict=$(verdict_of_qa)
  case "$verdict" in
    PASS)
      if contract_green; then
        append_loop_event "PASS" "$attempt" "ok"
        echo "ralph-loop: PASS achieved at round $attempt"
        exit 0
      fi
      # Evaluator said PASS but contract still has failing rows. Re-mark
      # as NEEDS_WORK so the next builder turn closes the gap.
      append_loop_event "PASS-but-contract-not-green" "$attempt" "rolled-back-to-NEEDS_WORK"
      write_next_findings
      ;;
    NEEDS_WORK)
      append_loop_event "NEEDS_WORK" "$attempt" "evaluator-rejected:run-evaluator-exit=$eval_status"
      write_next_findings
      ;;
    *)
      append_loop_event "unknown" "$attempt" "verdict=${verdict:-empty}:run-evaluator-exit=$eval_status"
      ;;
  esac
done

# If we get here, we burned the budget without PASS.
ESCALATION="$WORKSPACE/ESCALATION.md"
if [ ! -f "$ESCALATION" ]; then
  cat > "$ESCALATION" <<EOF
# Escalation — ralph-loop max rounds exhausted

At: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Workspace: $WORKSPACE
Round budget: $effective_budget
Last verdict: $(verdict_of_qa)
Rubric: ${rubric:-(unset)}

ralph-loop ran $effective_budget rounds without achieving PASS with a
green test-results.json. Operator review required.

Inspect:
- .claude/goal-state/ralph-loop.jsonl (one line per round)
- .claude/goal-state/ralph-loop-build-*.log (builder transcripts)
- .claude/goal-state/ralph-loop-eval-*.log (evaluator transcripts)
- NEXT_FINDINGS.md (latest evaluator findings)
- QA_REPORT.md (most recent verdict)
- .claude/goal-state/heartbeat-stop.log
EOF
fi
echo "ralph-loop: max rounds exhausted ($effective_budget); see ESCALATION.md" >&2
exit 1
