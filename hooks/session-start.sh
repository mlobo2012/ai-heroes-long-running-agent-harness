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
