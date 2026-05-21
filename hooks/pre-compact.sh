#!/usr/bin/env bash
# AI Heroes / Marco - discord-long-running-harness
#
# PreCompact hook. Snapshots the contract state into a markdown block that
# survives compaction so the agent's post-compact context still knows the
# acceptance contract and open NEEDS_WORK items. Mitigates context anxiety
# called out in Anthropic's March 2026 harness-design article.
#
# Writes a snapshot file the agent can Read after compaction, and emits a
# short additionalContext block via stdout so Claude Code carries the
# pointer into the new (smaller) context.

set -u
WORKDIR="${CLAUDE_PROJECT_DIR:-$PWD}"
STATE_DIR="$WORKDIR/.claude/goal-state"
mkdir -p "$STATE_DIR"
SNAPSHOT="$STATE_DIR/post-compact-orientation.md"

{
  printf '# Post-compact orientation snapshot (taken %s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -f "$WORKDIR/BUILD_PLAN.md" ]; then
    printf '## BUILD_PLAN.md (Acceptance Contract section)\n\n'
    awk '
      /^## Acceptance Contract/ { in_block=1; print; next }
      /^## / && in_block { in_block=0 }
      in_block { print }
    ' "$WORKDIR/BUILD_PLAN.md"
    printf '\n'
  fi
  if [ -f "$WORKDIR/QA_REPORT.md" ]; then
    printf '## Last QA_REPORT.md\n\n'
    head -120 "$WORKDIR/QA_REPORT.md"
    printf '\n'
  fi
  if [ -f "$WORKDIR/test-results.json" ]; then
    printf '## test-results.json (raw)\n\n```json\n'
    cat "$WORKDIR/test-results.json"
    printf '\n```\n\n'
  fi
} > "$SNAPSHOT"

printf '## Pre-compact snapshot written\n\n'
printf 'Contract state was snapshotted to `%s` before compaction. After compaction completes, Read that file to recover the acceptance contract and last QA verdict.\n' "$SNAPSHOT"

exit 0
