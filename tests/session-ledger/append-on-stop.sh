#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/heartbeat-stop.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/session-ledger.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

WORKSPACE="$SCRATCH_ROOT/workspace"
STATE_DIR="$WORKSPACE/.claude/goal-state"
mkdir -p "$STATE_DIR" "$WORKSPACE/.claude" "$WORKSPACE/evidence"

git -C "$WORKSPACE" init -q
git -C "$WORKSPACE" config user.email "test@example.invalid"
git -C "$WORKSPACE" config user.name "Harness Test"
git -C "$WORKSPACE" checkout -q -b main
printf 'base\n' > "$WORKSPACE/README.md"
git -C "$WORKSPACE" add README.md
git -C "$WORKSPACE" commit -q -m "init"
git -C "$WORKSPACE" checkout -q -b feature/session-ledger
printf 'work\n' > "$WORKSPACE/work.txt"
git -C "$WORKSPACE" add work.txt
git -C "$WORKSPACE" commit -q -m "work"

cat > "$STATE_DIR/goal-state.json" <<'EOF'
{"goal":"ledger test","session_id":"ledger-test","started_at":"2026-05-22T10:00:00Z","status":"active"}
EOF
cat > "$WORKSPACE/test-results.json" <<'EOF'
{"items":[{"id":"one","passes":true},{"id":"two","passes":true}]}
EOF
printf 'evidence/one-result.txt\n' > "$WORKSPACE/.claude/.evidence-reads"
printf 'evidence/two-result.txt\n' >> "$WORKSPACE/.claude/.evidence-reads"

set +e
output="$(cd "$WORKSPACE" && printf '{"hook_event_name":"Stop","session_id":"ledger-test"}\n' | "$HOOK" 2>&1)"
status=$?
set -e
[ "$status" -eq 0 ] || fail "heartbeat exit = $status, want 0; output: $output"

[ -f "$STATE_DIR/sessions.jsonl" ] || fail "sessions.jsonl missing"
python3 - "$STATE_DIR/sessions.jsonl" <<'PY'
import datetime
import json
import sys
from pathlib import Path

lines = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
assert len(lines) == 1, lines
record = lines[0]
expected_keys = {"session_id", "started_at", "ended_at", "sprints_passed", "evidence_reads", "commits", "exit_reason"}
assert expected_keys == set(record), record
assert record["session_id"] == "ledger-test", record
assert record["started_at"] == "2026-05-22T10:00:00Z", record
datetime.datetime.fromisoformat(record["ended_at"].replace("Z", "+00:00"))
assert record["sprints_passed"] == 2, record
assert record["evidence_reads"] == 2, record
assert record["commits"] == 1, record
assert record["exit_reason"] == "goal-met", record
PY

set +e
output="$(cd "$WORKSPACE" && printf '{"hook_event_name":"Stop","session_id":"ledger-test"}\n' | "$HOOK" 2>&1)"
status=$?
set -e
[ "$status" -eq 0 ] || fail "second heartbeat exit = $status, want 0; output: $output"
[ "$(wc -l < "$STATE_DIR/sessions.jsonl" | tr -d ' ')" = "1" ] || fail "sessions.jsonl is not idempotent"

echo "PASS - session ledger appends one schema-valid line on goal-complete Stop"
