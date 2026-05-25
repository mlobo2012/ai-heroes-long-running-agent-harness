#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TRACK_READ="$REPO_ROOT/hooks/track-read.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/track-read-project-dir.XXXXXX")"

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
EVIDENCE="$WORKSPACE/_evidence/A8-focused.md"
DRIFTED_CWD="$SCRATCH_ROOT/drifted-cwd"
mkdir -p "$STATE_DIR" "$(dirname "$EVIDENCE")" "$DRIFTED_CWD"
printf 'focused proof\n' > "$EVIDENCE"

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
output="$(cd "$DRIFTED_CWD" && hook_input_read "$EVIDENCE" | env -u VERIFY_READ_LOG CLAUDE_PROJECT_DIR="$WORKSPACE" "$TRACK_READ" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "project-dir log target exit = $status, want 0; output: $output"
[ -z "$output" ] || fail "project-dir log target should be silent, got: $output"
grep -Fxq "$EVIDENCE" "$READ_LOG" || fail "track-read did not write to CLAUDE_PROJECT_DIR/.claude/.evidence-reads"
[ ! -e "$DRIFTED_CWD/.claude/.evidence-reads" ] || fail "track-read wrote a cwd-relative read log"

echo "PASS - track-read writes CLAUDE_PROJECT_DIR read log when cwd differs"
