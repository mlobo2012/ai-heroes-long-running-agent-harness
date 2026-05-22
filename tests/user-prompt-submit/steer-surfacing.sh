#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/user-prompt-submit.sh"
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKSPACE="$TMPDIR/workspace"
mkdir -p "$WORKSPACE"

run_hook() {
  set +e
  output="$(cd "$WORKSPACE" && printf '{"prompt":"hello","session_id":"prompt-test"}\n' | "$HOOK" 2>&1)"
  status=$?
  set -e
}

assert_context() {
  expected="$1"
  OUTPUT="$output" EXPECTED="$expected" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["OUTPUT"])
hook = payload["hookSpecificOutput"]
assert hook["hookEventName"] == "UserPromptSubmit"
ctx = hook["additionalContext"]
assert ctx.startswith("[STEER.md, surfaced by user-prompt-submit hook]\n\n")
assert os.environ["EXPECTED"] in ctx
PY
}

run_hook
[ "$status" -eq 0 ] || fail "missing STEER.md exit = $status, want 0"
[ -z "$output" ] || fail "missing STEER.md produced output: $output"

printf 'Please prioritize the retry path.\n' > "$WORKSPACE/STEER.md"
run_hook
[ "$status" -eq 0 ] || fail "non-empty STEER.md exit = $status, want 0"
[ -n "$output" ] || fail "non-empty STEER.md produced no output"
assert_context "Please prioritize the retry path."

head -c 9000 < /dev/zero | tr '\0' x > "$WORKSPACE/STEER.md"
run_hook
[ "$status" -eq 0 ] || fail "large STEER.md exit = $status, want 0"
OUTPUT="$output" python3 - <<'PY'
import json
import os

payload = json.loads(os.environ["OUTPUT"])
ctx = payload["hookSpecificOutput"]["additionalContext"]
assert "[Truncated by user-prompt-submit hook at 8192 bytes.]" in ctx
body = ctx.split("\n\n", 1)[1]
assert body.startswith("x" * 100)
assert len(body.encode("utf-8")) < 8400
PY

echo "PASS user-prompt-submit STEER surfacing"
