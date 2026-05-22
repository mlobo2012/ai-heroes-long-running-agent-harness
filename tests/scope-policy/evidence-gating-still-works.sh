#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VERIFY_GATE="$REPO_ROOT/hooks/verify-gate.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scope-policy-evidence.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

WORKSPACE="$SCRATCH_ROOT/workspace"
STATE_DIR="$WORKSPACE/.claude"
READ_LOG="$STATE_DIR/.evidence-reads"
RESULTS="$WORKSPACE/test-results.json"
mkdir -p "$STATE_DIR" "$WORKSPACE/evidence"
printf '{"items":[{"id":"S18_evidence","passes":false}]}\n' > "$RESULTS"

hook_input() {
  python3 - "$RESULTS" <<'PY'
import json
import sys

path = sys.argv[1]
payload = {
    "tool_input": {
        "file_path": path,
        "old_string": '"passes":false',
        "new_string": '"passes":true',
    }
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

printf '/tmp/unrelated-proof.txt\n' > "$READ_LOG"
set +e
output="$(cd "$WORKSPACE" && hook_input | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "verify-gate exit = $status, want 0; output: $output"
printf '%s' "$output" | grep -q 'row-matched evidence' || fail "unmatched evidence did not trigger row-binding block: $output"

printf '%s\n' "$WORKSPACE/evidence/s18-evidence-result.txt" > "$READ_LOG"
set +e
output="$(cd "$WORKSPACE" && hook_input | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "verify-gate matched evidence exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "matched evidence should allow silently, got: $output"
[ ! -s "$READ_LOG" ] || fail "verify-gate did not consume evidence log"

echo "PASS - verify-gate row binding still works"
