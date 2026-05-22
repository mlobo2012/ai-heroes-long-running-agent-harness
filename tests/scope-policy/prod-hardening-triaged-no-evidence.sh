#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/heartbeat-stop.sh"
RECORD="$REPO_ROOT/scripts/blocker-record.sh"
UPDATE="$REPO_ROOT/scripts/blocker-update.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scope-policy-prod-triaged.XXXXXX")"

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
printf '{"goal":"production hardening triaged blocker","session_id":"scope-prod-triaged"}\n' > "$STATE_DIR/goal-state.json"
printf '{"scope_policy":"production_hardening","items":[{"id":"prod-triaged","passes":true}]}\n' > "$WORKSPACE/test-results.json"

blocker_id="$(cd "$WORKSPACE" && "$RECORD" --title "auth callback loses state" --severity critical)"
(cd "$WORKSPACE" && "$UPDATE" --id "$blocker_id" --status triaged >/dev/null)

set +e
output="$(cd "$WORKSPACE" && printf '{"hook_event_name":"Stop","session_id":"scope-prod-triaged"}\n' | "$HOOK" 2>&1)"
status=$?
set -e

[ "$status" -eq 2 ] || fail "heartbeat exit = $status, want 2; output: $output"
grep -q 'block blocker-gate open=0 triaged_unevidenced=1' "$STATE_DIR/heartbeat-stop.log" || fail "triaged blocker gate note missing"
python3 - "$STATE_DIR/blocker-gate.json" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert snapshot["open_count"] == 0, snapshot
assert snapshot["triaged_unevidenced_count"] == 1, snapshot
assert snapshot["decision"] == "block", snapshot
PY

echo "PASS - production_hardening blocks on triaged blockers without evidence"
