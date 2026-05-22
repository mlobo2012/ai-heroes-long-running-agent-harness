#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/heartbeat-stop.sh"
RECORD="$REPO_ROOT/scripts/blocker-record.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scope-policy-research.XXXXXX")"

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
mkdir -p "$STATE_DIR"
printf '{"goal":"research only blockers","session_id":"scope-research"}\n' > "$STATE_DIR/goal-state.json"
printf '{"scope_policy":"research_only","items":[{"id":"research","passes":true}]}\n' > "$WORKSPACE/test-results.json"

(cd "$WORKSPACE" && "$RECORD" --title "auth finding for later" --severity high >/dev/null)
(cd "$WORKSPACE" && "$RECORD" --title "delivery finding for later" --severity medium >/dev/null)

set +e
output="$(cd "$WORKSPACE" && printf '{"hook_event_name":"Stop","session_id":"scope-research"}\n' | "$HOOK" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "heartbeat exit = $status, want 0; output: $output"
grep -q 'allow goal-met' "$STATE_DIR/heartbeat-stop.log" || fail "goal-met was not logged"
python3 - "$STATE_DIR/blocker-gate.json" "$STATE_DIR/blockers.jsonl" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
records = [json.loads(line) for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()]
assert snapshot["policy"] == "research_only", snapshot
assert snapshot["decision"] == "skip", snapshot
assert len(records) == 2, records
assert all(record["status"] == "open" for record in records), records
PY

echo "PASS - research_only records blockers but does not block completion"
