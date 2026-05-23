#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
VERIFY_GATE="$REPO_ROOT/hooks/verify-gate.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-gate-batch.XXXXXX")"

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

printf '{"items":[{"id":"A_one","passes":false},{"id":"B_two","passes":false}]}\n' > "$RESULTS"
{
  printf '%s\n' "$WORKSPACE/evidence/a_one-result.txt"
  printf '%s\n' "$WORKSPACE/evidence/b_two-result.txt"
} > "$READ_LOG"
first_content='{"items":[{"id":"A_one","passes":true},{"id":"B_two","passes":false}]}'

set +e
output="$(cd "$WORKSPACE" && hook_input_content "$first_content" | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "first sequential flip exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "first sequential flip should allow silently, got: $output"
! grep -q 'a_one-result.txt' "$READ_LOG" || fail "first sequential flip did not consume its matched evidence"
grep -q 'b_two-result.txt' "$READ_LOG" || fail "first sequential flip consumed unrelated evidence"

printf '%s\n' "$first_content" > "$RESULTS"
second_content='{"items":[{"id":"A_one","passes":true},{"id":"B_two","passes":true}]}'

set +e
output="$(cd "$WORKSPACE" && hook_input_content "$second_content" | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "second sequential flip exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "second sequential flip should allow silently, got: $output"
[ ! -s "$READ_LOG" ] || fail "second sequential flip did not consume remaining evidence"

printf '{"items":[{"id":"A_one","passes":false},{"id":"B_two","passes":false}]}\n' > "$RESULTS"
{
  printf '%s\n' "$WORKSPACE/evidence/a_one-result.txt"
  printf '%s\n' "$WORKSPACE/evidence/b_two-result.txt"
} > "$READ_LOG"
batch_content='{"items":[{"id":"A_one","passes":true},{"id":"B_two","passes":true}]}'

set +e
output="$(cd "$WORKSPACE" && hook_input_content "$batch_content" | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "batch flip exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "batch flip should allow silently, got: $output"
[ ! -s "$READ_LOG" ] || fail "batch flip did not consume both matched evidence lines"

printf '{"items":[{"id":"A_one","passes":false},{"id":"C_three","passes":false}]}\n' > "$RESULTS"
printf '%s\n' "$WORKSPACE/evidence/a_one-result.txt" > "$READ_LOG"
new_content='{"items":[{"id":"A_one","passes":true},{"id":"C_three","passes":true}]}'

set +e
output="$(cd "$WORKSPACE" && hook_input_content "$new_content" | VERIFY_READ_LOG="$READ_LOG" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "partial batch exit = $status, want 0; output: $output"
printf '%s' "$output" | grep -q 'row-matched evidence' || fail "partial batch did not block for row-matched evidence: $output"
printf '%s' "$output" | grep -q 'C_three' || fail "partial batch block did not name C_three: $output"
grep -q 'a_one-result.txt' "$READ_LOG" || fail "partial batch block consumed evidence unexpectedly"

echo "PASS - verify-gate allows batch flips with per-row evidence and blocks partial evidence"
