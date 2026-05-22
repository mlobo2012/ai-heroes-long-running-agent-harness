#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Headless entry point for the evaluator subagent. Mirrors the harness's
# PASS / NEEDS_WORK gate so CI, cron, or an external orchestrator can run
# the same release gate without launching the full long-running loop.
#
# Exit codes:
#   0 - QA_REPORT.md starts with PASS
#   1 - QA_REPORT.md starts with NEEDS_WORK
#   2 - usage / invocation error
#   3 - evaluator produced no QA_REPORT.md
#   4 - interaction-evidence required by the rubric but missing

usage() {
  cat <<'USAGE'
Usage: run-evaluator.sh [--workspace <abs_path>] [--isolated] [--dry-run]

Runs the evaluator subagent against the current workspace and writes
QA_REPORT.md.

  --isolated  Run in a throwaway `git worktree add` so the evaluator
              cannot mutate the builder's working tree. The QA_REPORT.md
              is copied back to the original workspace on exit.
  --dry-run   Print the planned invocation and exit 0.
USAGE
}

WORKSPACE="$PWD"
ISOLATED=0
DRY_RUN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --isolated) ISOLATED=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "run-evaluator: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$WORKSPACE" in /*) ;; *) echo "run-evaluator: --workspace must be absolute" >&2; exit 2 ;; esac
[ -d "$WORKSPACE" ] || { echo "run-evaluator: workspace not found: $WORKSPACE" >&2; exit 2; }

cd "$WORKSPACE"

if [ "$ISOLATED" = "1" ]; then
  if ! git -C "$WORKSPACE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "run-evaluator: --isolated requires a git repository" >&2
    exit 2
  fi
  WT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/eval-isolated.XXXXXX")"
  WT_BRANCH="evaluator-isolated-$(date +%s)-$$"
  git -C "$WORKSPACE" worktree add --detach "$WT_ROOT" >/dev/null
  cleanup() {
    if [ -f "$WT_ROOT/QA_REPORT.md" ]; then
      cp "$WT_ROOT/QA_REPORT.md" "$WORKSPACE/QA_REPORT.md"
    fi
    git -C "$WORKSPACE" worktree remove --force "$WT_ROOT" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  EVAL_DIR="$WT_ROOT"
else
  EVAL_DIR="$WORKSPACE"
fi

if [ "$DRY_RUN" = "1" ]; then
  printf 'run-evaluator: would invoke `claude --agent evaluator` in %s (isolated=%s)\n' "$EVAL_DIR" "$ISOLATED"
  exit 0
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "run-evaluator: \`claude\` CLI not found on PATH" >&2
  exit 2
fi

cd "$EVAL_DIR"

PROMPT="Run the evaluator agent. Read BUILD_PLAN.md, test-results.json, the diff, and every evidence path. For UI tasks drive the running app via Playwright MCP and write the trace under playwright-mcp/round-N/. For desktop tasks drive the system via native computer-use and write the session log under computer-use/round-N/. Write QA_REPORT.md with a bare PASS or NEEDS_WORK on line 1."

claude -p --agent evaluator "$PROMPT" \
  > "$EVAL_DIR/.claude/goal-state/evaluator-stdout.log" 2>&1 || true

[ -f "$EVAL_DIR/QA_REPORT.md" ] || { echo "run-evaluator: evaluator did not write QA_REPORT.md" >&2; exit 3; }

verdict=$(sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' "$EVAL_DIR/QA_REPORT.md")
case "$verdict" in
  PASS)
    # Cross-check interaction-evidence gate when the rubric demands it.
    rubric=""
    if [ -f "$EVAL_DIR/.claude/goal-state/goal-state.json" ] && command -v python3 >/dev/null 2>&1; then
      rubric=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("rubric") or "")' "$EVAL_DIR/.claude/goal-state/goal-state.json" 2>/dev/null || true)
    fi
    case "$rubric" in
      frontend|desktop)
        # Require at least one non-empty trace.
        traces=$(find "$EVAL_DIR/playwright-mcp" -type f -name 'trace.zip' -size +0c 2>/dev/null | head -1)
        cusess=$(find "$EVAL_DIR/computer-use" -type f -name 'session.jsonl' -size +0c 2>/dev/null | head -1)
        if [ -z "$traces" ] && [ -z "$cusess" ]; then
          echo "run-evaluator: rubric=$rubric requires interaction evidence; none found under playwright-mcp/round-*/trace.zip or computer-use/round-*/session.jsonl" >&2
          exit 4
        fi
        ;;
    esac
    exit 0
    ;;
  NEEDS_WORK) exit 1 ;;
  *) echo "run-evaluator: unrecognized verdict line: $verdict" >&2; exit 3 ;;
esac
