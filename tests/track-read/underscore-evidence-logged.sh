#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TRACK_READ="$REPO_ROOT/hooks/track-read.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/track-read-underscore.XXXXXX")"

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
EVIDENCE="$WORKSPACE/_evidence/C10-foo.md"
NON_EVIDENCE="$SCRATCH_ROOT/random.md"
mkdir -p "$STATE_DIR" "$(dirname "$EVIDENCE")"
printf 'proof\n' > "$EVIDENCE"
printf 'not evidence\n' > "$NON_EVIDENCE"

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

[ "$status" -eq 0 ] || fail "underscore evidence Read exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "underscore evidence Read should log silently, got: $output"
grep -Fxq "$EVIDENCE" "$READ_LOG" || fail "underscore evidence path was not logged"

rm -f "$READ_LOG"
set +e
output="$(hook_input_read "$NON_EVIDENCE" | VERIFY_READ_LOG="$READ_LOG" "$TRACK_READ" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "non-evidence Read exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "non-evidence Read should be silent, got: $output"
[ ! -e "$READ_LOG" ] || [ ! -s "$READ_LOG" ] || fail "non-evidence markdown path was logged"

echo "PASS - track-read logs underscore evidence markdown and ignores non-evidence markdown"
