#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Compare two rounds' evidence and verdicts side by side. The March 2026
# article describes the planner/generator/evaluator loop as a convergence
# loop, but rounds.json only stores the verdict label. This script
# surfaces what actually changed between two rounds so an operator (or
# the agent on session-start) can see "round 2 fixed contrast but broke
# spacing."
#
# Compares:
#   - QA_REPORT.md verdict and axis scores
#   - test-results.json passes/fails by criterion id
#   - artifact paths under screenshots/round-A vs round-B,
#     playwright-mcp/round-A vs round-B, computer-use/round-A vs round-B
#   - per-round git commit ranges (read from rounds.json if present)

usage() {
  cat <<'USAGE'
Usage: diff-rounds.sh <round_a> <round_b> [--workspace <abs_path>]

Reads round artifacts under .claude/goal-state/round-archives/round-N/ if
present, otherwise tries the live artifact directories. Prints a
markdown diff to stdout suitable for an operator review.
USAGE
}

WORKSPACE="$PWD"
A=""
B=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *)
      if [ -z "$A" ]; then A="$1"; shift
      elif [ -z "$B" ]; then B="$1"; shift
      else echo "diff-rounds: extra positional arg: $1" >&2; exit 2
      fi
      ;;
  esac
done

[ -n "$A" ] && [ -n "$B" ] || { usage >&2; exit 2; }
case "$A" in ''|*[!0-9]*) echo "diff-rounds: round_a must be a positive integer" >&2; exit 2 ;; esac
case "$B" in ''|*[!0-9]*) echo "diff-rounds: round_b must be a positive integer" >&2; exit 2 ;; esac
[ -d "$WORKSPACE" ] || { echo "diff-rounds: workspace not found: $WORKSPACE" >&2; exit 2; }

cd "$WORKSPACE"

ROUND_DIR_A=".claude/goal-state/round-archives/round-${A}"
ROUND_DIR_B=".claude/goal-state/round-archives/round-${B}"

# QA verdict + axis scores for each round.
verdict_of() {
  local n="$1"
  local rd=".claude/goal-state/round-archives/round-${n}"
  local qa
  if [ -f "$rd/QA_REPORT.md" ]; then qa="$rd/QA_REPORT.md"
  elif [ -f QA_REPORT.md ]; then qa="QA_REPORT.md"
  else echo "(no QA_REPORT.md)"; return; fi
  sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' "$qa"
}

axes_of() {
  local n="$1"
  local rd=".claude/goal-state/round-archives/round-${n}"
  local qa
  if [ -f "$rd/QA_REPORT.md" ]; then qa="$rd/QA_REPORT.md"
  elif [ -f QA_REPORT.md ]; then qa="QA_REPORT.md"
  else echo "(no QA_REPORT.md)"; return; fi
  awk '/Axis scores/,/Acceptance criteria/' "$qa" | head -20
}

results_of() {
  local n="$1"
  local rd=".claude/goal-state/round-archives/round-${n}"
  local rf
  if [ -f "$rd/test-results.json" ]; then rf="$rd/test-results.json"
  elif [ -f test-results.json ]; then rf="test-results.json"
  else echo "(no test-results.json)"; return; fi
  python3 - "$rf" <<'PY' 2>/dev/null || echo "(unreadable)"
import json, sys
d = json.load(open(sys.argv[1]))
items = d.get("criteria") if isinstance(d, dict) and isinstance(d.get("criteria"), list) else None
if items is None and isinstance(d, dict):
    items = [{"id": k, **(v if isinstance(v, dict) else {})} for k, v in d.items()]
for c in items or []:
    if not isinstance(c, dict): continue
    status = "PASS" if c.get("passes") is True else "FAIL"
    print(f"  {c.get('id','?'):>4}  {status}  {(c.get('description', c.get('desc','')) or '')[:80]}")
PY
}

artifacts_of() {
  local n="$1"
  printf '  screenshots/round-%s: ' "$n"
  if [ -d "screenshots/round-${n}" ]; then
    find "screenshots/round-${n}" -type f 2>/dev/null | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
  printf '  playwright-mcp/round-%s: ' "$n"
  if [ -d "playwright-mcp/round-${n}" ]; then
    find "playwright-mcp/round-${n}" -type f 2>/dev/null | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
  printf '  computer-use/round-%s: ' "$n"
  if [ -d "computer-use/round-${n}" ]; then
    find "computer-use/round-${n}" -type f 2>/dev/null | wc -l | tr -d ' '
  else
    printf '0\n'
  fi
}

cat <<HEADER
# Round diff — round ${A} vs round ${B}

Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Workspace: $WORKSPACE

## Verdicts

- round ${A}: $(verdict_of "$A")
- round ${B}: $(verdict_of "$B")

## Axis scores (round ${A})
\`\`\`
$(axes_of "$A")
\`\`\`

## Axis scores (round ${B})
\`\`\`
$(axes_of "$B")
\`\`\`

## Criterion results (round ${A})
\`\`\`
$(results_of "$A")
\`\`\`

## Criterion results (round ${B})
\`\`\`
$(results_of "$B")
\`\`\`

## Artifact counts
\`\`\`
round ${A}:
$(artifacts_of "$A")
round ${B}:
$(artifacts_of "$B")
\`\`\`
HEADER

# Git diff between rounds, if both rounds left a commit-sha marker.
sha_a=$(python3 - "$ROUND_DIR_A/round-meta.json" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get("commit_sha", ""))
PY
)
sha_b=$(python3 - "$ROUND_DIR_B/round-meta.json" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get("commit_sha", ""))
PY
)
if [ -n "$sha_a" ] && [ -n "$sha_b" ]; then
  echo ""
  echo "## Code changes ${sha_a:0:10}..${sha_b:0:10}"
  echo '```'
  git diff --stat "${sha_a}" "${sha_b}" 2>/dev/null || echo "(git diff failed)"
  echo '```'
fi
