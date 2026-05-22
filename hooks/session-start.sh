#!/usr/bin/env bash
# AI Heroes / Marco - discord-long-running-harness
#
# SessionStart hook. Re-seeds the agent with the durable contract state
# every time a new session begins, so orientation doesn't depend on the
# CLAUDE.md prose alone. Mitigates context anxiety and silent handoffs.
#
# Prints the seed text to stdout — Claude Code surfaces SessionStart
# stdout to the model as additional context.

set -u
WORKDIR="${CLAUDE_PROJECT_DIR:-$PWD}"
cd "$WORKDIR" || exit 0

emit() { printf '%s\n' "$1"; }

emit "## Session orientation (auto-seeded by session-start hook)"
emit ""

# Pinned rubric, model, and current round — read once and surface up top.
if [ -f "$WORKDIR/.claude/goal-state/goal-state.json" ]; then
  python3 - "$WORKDIR/.claude/goal-state/goal-state.json" "$WORKDIR/.claude/goal-state/rounds.json" <<'PY' 2>/dev/null || true
import json, sys
from pathlib import Path
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
rubric = d.get("rubric") or "(none pinned)"
model = d.get("model") or "(unset)"
budget = d.get("round_budget") or "(default)"
n = 0
try:
    r = json.load(open(sys.argv[2]))
    rounds = r.get("rounds") if isinstance(r, dict) else None
    n = len(rounds) if isinstance(rounds, list) else 0
except Exception:
    pass
print(f"### Goal state")
print()
print(f"- Rubric: {rubric}")
print(f"- Model: {model}")
print(f"- Round budget: {budget}")
print(f"- Rounds completed: {n} (next round is {n + 1})")
print()
PY
fi

# Calibration tail — operator overrides on prior evaluator verdicts.
# Surface up to the last 5 entries so the agent's next round bakes them in.
if [ -f "$WORKDIR/.claude/goal-state/evaluator-calibration.jsonl" ]; then
  emit "### Evaluator calibration — recent operator overrides"
  emit ""
  emit '```'
  tail -5 "$WORKDIR/.claude/goal-state/evaluator-calibration.jsonl"
  emit '```'
  emit ""
fi

if [ -f "$WORKDIR/BUILD_PLAN.md" ]; then
  emit "### BUILD_PLAN.md — Acceptance Contract"
  emit ""
  awk '
    /^## Acceptance Contract/ { in_block=1; print; next }
    /^## / && in_block { in_block=0 }
    in_block { print }
  ' "$WORKDIR/BUILD_PLAN.md" | head -80
  emit ""
else
  emit "(no BUILD_PLAN.md yet — invoke the planner agent before implementing)"
  emit ""
fi

if [ -f "$WORKDIR/QA_REPORT.md" ]; then
  verdict=$(sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' "$WORKDIR/QA_REPORT.md" 2>/dev/null || true)
  emit "### Last QA verdict: ${verdict:-unknown}"
  if [ "$verdict" = "NEEDS_WORK" ]; then
    emit ""
    emit "Open findings from last evaluator pass:"
    emit ""
    sed -n '/Specific findings/,/Regression risk/p' "$WORKDIR/QA_REPORT.md" 2>/dev/null | head -60
  fi
  emit ""
fi

# NEXT_FINDINGS.md carry-forward — written by the evaluator wrapper /
# ralph-loop after a NEEDS_WORK round. Surface it at the top of the new
# session so the builder doesn't redo the previous turn's work.
if [ -s "$WORKDIR/NEXT_FINDINGS.md" ]; then
  emit "### NEXT_FINDINGS.md — open items from the prior evaluator round"
  emit ""
  emit "These bullets are the top of the queue for this session. Address them"
  emit "before opening new ground. The file is rewritten on every NEEDS_WORK"
  emit "round, so don't mark anything done by 'fixing the file' — fix the"
  emit "underlying issue and let the next evaluator round overwrite it."
  emit ""
  emit '```markdown'
  head -120 "$WORKDIR/NEXT_FINDINGS.md"
  emit '```'
  emit ""
fi

if [ -f "$WORKDIR/PROGRESS.md" ]; then
  emit "### PROGRESS.md (last 40 lines)"
  emit ""
  tail -40 "$WORKDIR/PROGRESS.md"
  emit ""
fi

if [ -f "$WORKDIR/test-results.json" ]; then
  emit "### test-results.json — open criteria"
  emit ""
  python3 - "$WORKDIR/test-results.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
items = d.get("criteria") if isinstance(d, dict) and isinstance(d.get("criteria"), list) else None
if items is None and isinstance(d, dict):
    items = [{"id": k, **(v if isinstance(v, dict) else {})} for k, v in d.items()]
for c in items or []:
    if not isinstance(c, dict): continue
    if c.get("passes") is not True:
        print(f"- {c.get('id','?')}: {c.get('description', c.get('desc',''))[:120]}")
PY
  emit ""
fi

if git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1; then
  emit "### Recent commits"
  emit ""
  git -C "$WORKDIR" log --oneline -10 2>/dev/null | head -10
  emit ""
fi

if [ -x "$WORKDIR/init.sh" ]; then
  emit "### init.sh present — run it before editing to confirm the app starts."
elif [ -f "$WORKDIR/init.sh" ]; then
  emit "### init.sh present but not executable — \`chmod +x init.sh\` then run it."
else
  emit "### init.sh missing — create one that starts the dev server / runs the smoke test, then commit it."
fi

exit 0
