#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNNER="$PLUGIN_DIR/scripts/supervisor-runner.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/outer-pulse-completion.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

assert_line_count() {
  file="$1"
  expected="$2"
  [ -f "$file" ] || fail "$file does not exist"
  actual="$(wc -l < "$file" | tr -d ' ')"
  [ "$actual" = "$expected" ] || fail "$file has $actual lines, expected $expected"
}

workspace_a="$SCRATCH_ROOT/workspace-a"
workspace_b="$SCRATCH_ROOT/workspace-b"
state_a="$workspace_a/.claude/goal-state"
state_b="$workspace_b/.claude/goal-state"
ledger="$SCRATCH_ROOT/active.jsonl"
completion_log="$SCRATCH_ROOT/completion.log"
mkdir -p "$state_a" "$state_b"

now="$(date +%s)"
printf '%s\n' '{"status":"complete","session_id":"session-a","goal":"completed goal"}' > "$state_a/goal-state.json"
printf '%s\n' "$now" > "$state_b/last-beat"
printf '%s\n' '{"status":"running","session_id":"session-b","goal":"running goal"}' > "$state_b/goal-state.json"

{
  printf '{"session_id":"session-a","agent":"klaus","channel":"test-channel","goal":"completed goal","started_at":%s,"workspace":"%s","launcher":"test"}\n' \
    "$((now - 300))" "$workspace_a"
  printf '{"session_id":"session-b","agent":"klaus","channel":"test-channel","goal":"running goal","started_at":%s,"workspace":"%s","launcher":"test"}\n' \
    "$now" "$workspace_b"
} > "$ledger"

SUPERVISOR_ACTIVE_LEDGER="$ledger" \
SUPERVISOR_COMPLETION_LOG="$completion_log" \
"$RUNNER" > "$SCRATCH_ROOT/output.txt"

assert_line_count "$ledger" 1
assert_line_count "$completion_log" 1
python3 - "$ledger" "$completion_log" <<'PY'
import json
import sys
from pathlib import Path

remaining = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
completion = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
assert len(remaining) == 1, remaining
assert remaining[0]["session_id"] == "session-b", remaining
assert completion["event"] == "completed", completion
assert completion["session_id"] == "session-a", completion
PY

echo "PASS - outer pulse completion trim"
