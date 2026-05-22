#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# Records which evidence files the agent has opened this session.
# verify-gate.sh consults this list before allowing a test to be marked passing.
log="${VERIFY_READ_LOG:-./.claude/.evidence-reads}"
path=$(cat | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)
case "$path" in
  *screenshots/*|*-console.txt|*-result.txt|*.png|\
  .claude/goal-state/*.log|*/.claude/goal-state/*.log|\
  evidence/*.log|*/evidence/*.log|\
  evidence/*.txt|*/evidence/*.txt|\
  evidence/*.json|*/evidence/*.json|\
  *-diff.patch|\
  evidence/*.md|*/evidence/*.md)
    if [ -n "${VERIFY_READ_LOG:-}" ] || [ -f "$path" ]; then
      mkdir -p "$(dirname "$log")" 2>/dev/null || true
      echo "$path" >> "$log"
    fi
    ;;
esac
exit 0
