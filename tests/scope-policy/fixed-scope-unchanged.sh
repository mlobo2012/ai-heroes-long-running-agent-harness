#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/heartbeat-stop.sh"
RECORD="$REPO_ROOT/scripts/blocker-record.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scope-policy-fixed.XXXXXX")"

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
printf '{"goal":"fixed scope test","session_id":"scope-fixed"}\n' > "$STATE_DIR/goal-state.json"
printf '{"items":[{"id":"fixed-scope","passes":true}]}\n' > "$WORKSPACE/test-results.json"

(cd "$WORKSPACE" && "$RECORD" --title "ignored fixed-scope blocker" --severity high >/dev/null)

set +e
output="$(cd "$WORKSPACE" && printf '{"hook_event_name":"Stop","session_id":"scope-fixed"}\n' | "$HOOK" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "heartbeat exit = $status, want 0; output: $output"
grep -q 'allow goal-met' "$STATE_DIR/heartbeat-stop.log" || fail "goal-met was not logged"
python3 - "$STATE_DIR/blocker-gate.json" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert snapshot["policy"] == "fixed_scope", snapshot
assert snapshot["decision"] == "skip", snapshot
PY

echo "PASS - fixed_scope missing field preserves existing completion behavior"
