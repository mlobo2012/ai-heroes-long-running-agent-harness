#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VERIFY_GATE="$REPO_ROOT/hooks/verify-gate.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-gate-no-flip.XXXXXX")"

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

printf '{"items":[{"id":"X1","passes":false,"description":"old"}]}\n' > "$RESULTS"
rm -f "$READ_LOG"
new_content='{"items":[{"id":"X1","passes":false,"description":"new"}]}'

set +e
output="$(cd "$WORKSPACE" && hook_input_content "$new_content" | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "metadata-only edit exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "metadata-only edit should allow silently, got: $output"
[ ! -s "$READ_LOG" ] || fail "metadata-only edit should not write evidence log"

printf '{"items":[{"id":"X1","passes":true,"description":"old"}]}\n' > "$RESULTS"
rm -f "$READ_LOG"
new_content='{"items":[{"id":"X1","passes":false,"description":"old"}]}'

set +e
output="$(cd "$WORKSPACE" && hook_input_content "$new_content" | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "true-to-false edit exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "true-to-false edit should allow silently, got: $output"
[ ! -s "$READ_LOG" ] || fail "true-to-false edit should not write evidence log"

echo "PASS - verify-gate allows no-flip metadata and true-to-false edits"
