#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/heartbeat-stop.sh"
RECORD="$REPO_ROOT/scripts/blocker-record.sh"
UPDATE="$REPO_ROOT/scripts/blocker-update.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scope-policy-prod-clean.XXXXXX")"

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
mkdir -p "$STATE_DIR" "$WORKSPACE/evidence"
printf '{"goal":"production hardening clean blocker","session_id":"scope-prod-clean"}\n' > "$STATE_DIR/goal-state.json"
printf '{"scope_policy":"production_hardening","items":[{"id":"prod-clean","passes":true}]}\n' > "$WORKSPACE/test-results.json"
printf 'fixed\n' > "$WORKSPACE/evidence/prod-clean-blocker.txt"

blocker_id="$(cd "$WORKSPACE" && "$RECORD" --title "recovery worker drops jobs" --severity high)"
(cd "$WORKSPACE" && "$UPDATE" --id "$blocker_id" --status resolved --evidence "evidence/prod-clean-blocker.txt" --resolution "fixed and verified" >/dev/null)

set +e
output="$(cd "$WORKSPACE" && printf '{"hook_event_name":"Stop","session_id":"scope-prod-clean"}\n' | "$HOOK" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "heartbeat exit = $status, want 0; output: $output"
grep -q 'allow goal-met' "$STATE_DIR/heartbeat-stop.log" || fail "goal-met was not logged"
python3 - "$STATE_DIR/blocker-gate.json" <<'PY'
import json
import sys
from pathlib import Path

snapshot = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert snapshot["policy"] == "production_hardening", snapshot
assert snapshot["open_count"] == 0, snapshot
assert snapshot["triaged_unevidenced_count"] == 0, snapshot
assert snapshot["decision"] == "allow", snapshot
PY

echo "PASS - production_hardening completes when blockers are resolved with evidence"
