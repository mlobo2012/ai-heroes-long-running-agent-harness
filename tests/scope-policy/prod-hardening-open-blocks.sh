#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/heartbeat-stop.sh"
RECORD="$REPO_ROOT/scripts/blocker-record.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scope-policy-prod-open.XXXXXX")"

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
printf '{"goal":"production hardening open blocker","session_id":"scope-prod-open"}\n' > "$STATE_DIR/goal-state.json"
printf '{"scope_policy":"production_hardening","items":[{"id":"prod-open","passes":true}]}\n' > "$WORKSPACE/test-results.json"

(cd "$WORKSPACE" && "$RECORD" --title "delivery retries fail" --severity high >/dev/null)

set +e
output="$(cd "$WORKSPACE" && printf '{"hook_event_name":"Stop","session_id":"scope-prod-open"}\n' | "$HOOK" 2>&1)"
status=$?
set -e

[ "$status" -eq 2 ] || fail "heartbeat exit = $status, want 2; output: $output"
printf '%s' "$output" | grep -q '"decision":"block"' || fail "block JSON not emitted: $output"
grep -q 'block blocker-gate open=1 triaged_unevidenced=0' "$STATE_DIR/heartbeat-stop.log" || fail "blocker-gate note missing"
grep -q 'block goal-not-met' "$STATE_DIR/heartbeat-stop.log" || fail "regular block path was not reached"
python3 - "$STATE_DIR/blocker-gate.json" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert snapshot["policy"] == "production_hardening", snapshot
assert snapshot["open_count"] == 1, snapshot
assert snapshot["triaged_unevidenced_count"] == 0, snapshot
assert snapshot["decision"] == "block", snapshot
PY

echo "PASS - production_hardening blocks on open blockers"
