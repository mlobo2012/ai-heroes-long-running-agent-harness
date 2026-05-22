#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/heartbeat-stop.sh"
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
STATE_DIR="$WORKSPACE/.claude/goal-state"
mkdir -p "$STATE_DIR"
printf '{"goal":"cap test","session_id":"cap-test"}\n' > "$STATE_DIR/goal-state.json"
printf '{"items":[{"id":"cap","passes":false}]}\n' > "$WORKSPACE/test-results.json"

run_hook() {
  event="$1"
  set +e
  output="$(cd "$WORKSPACE" && printf '{"hook_event_name":"%s","session_id":"cap-test"}\n' "$event" | "$HOOK" 2>&1)"
  status=$?
  set -e
}

read_count() {
  if [ -f "$STATE_DIR/block-count" ]; then
    sed -n '1p' "$STATE_DIR/block-count"
  else
    printf '0\n'
  fi
}

run_hook "SubagentStop"
[ "$status" -eq 0 ] || fail "SubagentStop exit = $status, want 0; output: $output"
[ "$(read_count)" = "0" ] || fail "SubagentStop incremented block-count to $(read_count)"
grep -q 'allow subagent-stop' "$STATE_DIR/heartbeat-stop.log" || fail "SubagentStop allow not logged"

i=1
while [ "$i" -le 8 ]; do
  run_hook "Stop"
  [ "$status" -eq 2 ] || fail "Stop $i exit = $status, want 2; output: $output"
  [ "$(read_count)" = "$i" ] || fail "Stop $i block-count = $(read_count), want $i"
  i=$((i + 1))
done

run_hook "Stop"
[ "$status" -eq 0 ] || fail "9th Stop exit = $status, want 0; output: $output"
[ "$(read_count)" = "8" ] || fail "9th Stop changed block-count to $(read_count), want 8"
grep -q 'allow anti-runaway-cap' "$STATE_DIR/heartbeat-stop.log" || fail "anti-runaway-cap allow not logged"

echo "PASS eight-block anti-runaway cap"
