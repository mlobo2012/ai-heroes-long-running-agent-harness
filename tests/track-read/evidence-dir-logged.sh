#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TRACK_READ="$REPO_ROOT/hooks/track-read.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/track-read-evidence-dir.XXXXXX")"

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
EVIDENCE="$WORKSPACE/evidence/C11-plain.txt"
mkdir -p "$STATE_DIR" "$(dirname "$EVIDENCE")"
printf 'plain proof\n' > "$EVIDENCE"

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

rm -f "$READ_LOG"
set +e
output="$(hook_input_read "$EVIDENCE" | VERIFY_READ_LOG="$READ_LOG" "$TRACK_READ" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "plain evidence Read exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "plain evidence Read should log silently, got: $output"
grep -Fxq "$EVIDENCE" "$READ_LOG" || fail "plain evidence path was not logged"

echo "PASS - track-read still logs plain evidence directory files"
