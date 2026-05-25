#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REGISTER="$REPO_ROOT/scripts/register-goal.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/register-goal-channel-dedup.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

resolved_dir() {
  cd "$1" && pwd -P
}

HOME_DIR="$SCRATCH_ROOT/home"
LAUNCHER="$SCRATCH_ROOT/start-test.sh"
mkdir -p "$HOME_DIR"
printf '#!/usr/bin/env bash\n' > "$LAUNCHER"
chmod +x "$LAUNCHER"
export HOME="$HOME_DIR"

make_workspace() {
  dir="$SCRATCH_ROOT/$1"
  mkdir -p "$dir"
  resolved_dir "$dir"
}

register_goal() {
  workspace="$1"
  channel="$2"
  goal="$3"
  set +e
  output="$(cd "$workspace" && "$REGISTER" --agent test --channel "$channel" --workspace "$workspace" --launcher "$LAUNCHER" "$goal" 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "register-goal exit = $status for goal '$goal'; output: $output"
}

WORKSPACE_A="$(make_workspace workspace-a)"
WORKSPACE_B="$(make_workspace workspace-b)"
WORKSPACE_EMPTY_1="$(make_workspace workspace-empty-1)"
WORKSPACE_EMPTY_2="$(make_workspace workspace-empty-2)"
WORKSPACE_REUSED="$(make_workspace workspace-reused)"
LEDGER="$HOME/.claude/goal-sessions/active.jsonl"

register_goal "$WORKSPACE_A" "discord-channel-1" "goal A"
register_goal "$WORKSPACE_B" "discord-channel-1" "goal B"
register_goal "$WORKSPACE_EMPTY_1" "" "empty channel one"
register_goal "$WORKSPACE_EMPTY_2" "" "empty channel two"
register_goal "$WORKSPACE_REUSED" "discord-channel-workspace-old" "workspace original"
register_goal "$WORKSPACE_REUSED" "discord-channel-workspace-new" "workspace updated"

[ -f "$LEDGER" ] || fail "active ledger missing: $LEDGER"

python3 - "$LEDGER" "$WORKSPACE_A" "$WORKSPACE_B" "$WORKSPACE_EMPTY_1" "$WORKSPACE_EMPTY_2" "$WORKSPACE_REUSED" <<'PY' || fail "active ledger did not match channel/workspace dedup expectations"
import json
import sys
from pathlib import Path

ledger, ws_a, ws_b, ws_empty_1, ws_empty_2, ws_reused = sys.argv[1:7]
records = [
    json.loads(raw)
    for raw in Path(ledger).read_text(encoding="utf-8").splitlines()
    if raw.strip()
]

same_channel = [record for record in records if record.get("channel") == "discord-channel-1"]
assert len(same_channel) == 1, same_channel
assert same_channel[0]["workspace"] == ws_b, same_channel
assert same_channel[0]["goal"] == "goal B", same_channel
assert not [record for record in records if record.get("workspace") == ws_a], records

empty_channel = [record for record in records if record.get("channel") == ""]
assert len(empty_channel) == 2, empty_channel
assert {record["workspace"] for record in empty_channel} == {ws_empty_1, ws_empty_2}, empty_channel

same_workspace = [record for record in records if record.get("workspace") == ws_reused]
assert len(same_workspace) == 1, same_workspace
assert same_workspace[0]["channel"] == "discord-channel-workspace-new", same_workspace
assert same_workspace[0]["goal"] == "workspace updated", same_workspace

assert len(records) == 4, records
PY

echo "PASS - register-goal dedupes non-empty channels without collapsing empty-channel goals"
