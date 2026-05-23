#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VERIFY_GATE="$REPO_ROOT/hooks/verify-gate.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-gate-unmatched.XXXXXX")"

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
mkdir -p "$STATE_DIR"
printf '{"items":[{"id":"S99_demo","passes":false}]}\n' > "$RESULTS"
printf '/tmp/unrelated-proof.txt\n' > "$READ_LOG"

hook_input_content() {
  python3 - "$RESULTS" "$1" <<'PY'
import json
import sys

path, content = sys.argv[1:3]
payload = {
    "tool_input": {
        "file_path": path,
        "content": content,
    }
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

new_content='{"items":[{"id":"S99_demo","passes":true}]}'

set +e
output="$(cd "$WORKSPACE" && hook_input_content "$new_content" | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "unmatched flip exit = $status, want 0; output: $output"
printf '%s' "$output" | grep -q 'row-matched evidence' || fail "unmatched flip did not block for row-matched evidence: $output"
grep -q '/tmp/unrelated-proof.txt' "$READ_LOG" || fail "unmatched evidence line was consumed on block"

echo "PASS - verify-gate blocks false-to-true flips without row-matched evidence"
