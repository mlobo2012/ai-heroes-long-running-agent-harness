#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
#
# Records which evidence files the agent has opened this session.
# verify-gate.sh consults this list before allowing a criterion to be
# marked passing.
#
# Pattern coverage: upstream's original shape (screenshots/, -console.txt,
# -result.txt, .png) plus the round-N evidence shapes the v0.4 planner
# declares (evidence/round-N/*, playwright-mcp/round-N/*, computer-use/
# round-N/*) plus the trace/session-log file extensions used by the
# interaction-evidence gate (.zip, .jsonl, .log, .txt, .jpg, .jpeg, .gif,
# .webp, .svg, .pdf, .json).
#
# The verify-gate's per-criterion mode also accepts an absolute path if
# the criterion's evidence_paths list contains a relative path that
# resolves to a Read-tracked file, so we log both the literal path the
# agent opened and its absolute path. This means a planner declaring
# `evidence/round-1/c1-curl.txt` and a builder Reading it via that exact
# string will match without needing CWD acrobatics.
log="${VERIFY_READ_LOG:-./.claude/.evidence-reads}"
path=$(cat | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)
[ -z "$path" ] && exit 0
[ -f "$path" ] || exit 0

matched=0
case "$path" in
  # Upstream shape (kept verbatim for parity).
  *screenshots/*|*-console.txt|*-result.txt|*.png) matched=1 ;;
  # v0.4 round-N evidence shapes.
  *evidence/round-*|*evidence/round-*/*) matched=1 ;;
  *playwright-mcp/round-*|*playwright-mcp/round-*/*) matched=1 ;;
  *computer-use/round-*|*computer-use/round-*/*) matched=1 ;;
  # Common evidence file extensions the planner/evaluator emit.
  *.zip|*.jsonl|*.log|*.txt|*.jpg|*.jpeg|*.gif|*.webp|*.svg|*.pdf|*.json|*.html) matched=1 ;;
esac

if [ "$matched" = "1" ]; then
  echo "$path" >> "$log"
  # Also log absolute path so per-criterion gate can match either shape.
  if command -v python3 >/dev/null 2>&1; then
    abs=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$path" 2>/dev/null || true)
    if [ -n "$abs" ] && [ "$abs" != "$path" ]; then
      echo "$abs" >> "$log"
    fi
  fi
fi
exit 0
