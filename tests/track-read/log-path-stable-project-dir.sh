#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TRACK_READ="$REPO_ROOT/hooks/track-read.sh"
VERIFY_GATE="$REPO_ROOT/hooks/verify-gate.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/track-read-stable-log.XXXXXX")"

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
EVIDENCE="$WORKSPACE/_evidence/A8_stable-result.md"
TRACK_CWD="$SCRATCH_ROOT/track-cwd"
VERIFY_CWD="$SCRATCH_ROOT/verify-cwd"
mkdir -p "$STATE_DIR" "$(dirname "$EVIDENCE")" "$TRACK_CWD" "$VERIFY_CWD"
printf 'stable proof\n' > "$EVIDENCE"
printf '{"items":[{"id":"A8_stable","passes":false}]}\n' > "$RESULTS"

hook_input_read() {
  python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
payload = {
    "tool_input": {
        "file_path": path,
    }
}
print(json.dumps(payload, separators=(",", ":")))
PY
}

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

rm -f "$READ_LOG"
set +e
output="$(cd "$TRACK_CWD" && hook_input_read "$EVIDENCE" | env -u VERIFY_READ_LOG CLAUDE_PROJECT_DIR="$WORKSPACE" "$TRACK_READ" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "track-read from drifted cwd exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "track-read from drifted cwd should log silently, got: $output"
grep -Fxq "$EVIDENCE" "$READ_LOG" || fail "track-read did not write to CLAUDE_PROJECT_DIR read log"

new_content='{"items":[{"id":"A8_stable","passes":true}]}'
set +e
output="$(cd "$VERIFY_CWD" && hook_input_content "$new_content" | env -u VERIFY_READ_LOG CLAUDE_PROJECT_DIR="$WORKSPACE" RESULTS_FILE="$RESULTS" "$VERIFY_GATE" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "verify-gate from different cwd exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "verify-gate should allow silently using shared read log, got: $output"
! grep -q 'A8_stable-result.md' "$READ_LOG" || fail "verify-gate did not consume the shared read-log evidence"

echo "PASS - track-read and verify-gate share CLAUDE_PROJECT_DIR read log across cwd changes"
