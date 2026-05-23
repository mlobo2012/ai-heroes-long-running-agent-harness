#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REGISTER="$REPO_ROOT/scripts/register-goal.sh"
SESSION_START="$REPO_ROOT/hooks/session-start.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/register-goal-mismatch.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

WORKSPACE_DIR="$SCRATCH_ROOT/workspace-target"
WORKSPACE_DIR_2="$SCRATCH_ROOT/workspace-normal"
SESSION_CWD="$SCRATCH_ROOT/session-cwd"
HOME_DIR="$SCRATCH_ROOT/home"
LAUNCHER="$SCRATCH_ROOT/start-test.sh"
ERR1="$SCRATCH_ROOT/err1.txt"
ERR2="$SCRATCH_ROOT/err2.txt"
ERR3="$SCRATCH_ROOT/err3.txt"
ERR4="$SCRATCH_ROOT/err4.txt"
mkdir -p "$WORKSPACE_DIR" "$WORKSPACE_DIR_2" "$SESSION_CWD" "$HOME_DIR"
printf '#!/usr/bin/env bash\n' > "$LAUNCHER"
chmod +x "$LAUNCHER"
export HOME="$HOME_DIR"

resolved_dir() {
  cd "$1" && pwd -P
}

WORKSPACE_RESOLVED="$(resolved_dir "$WORKSPACE_DIR")"
SESSION_CWD_RESOLVED="$(resolved_dir "$SESSION_CWD")"
MARKER="$WORKSPACE_DIR/.claude/goal-state/workspace-mismatch.json"

set +e
(cd "$SESSION_CWD" && "$REGISTER" --agent test --channel 123 --workspace "$WORKSPACE_DIR" --launcher "$LAUNCHER" "do the thing" 2>"$ERR1" >/dev/null)
status=$?
set -e

[ "$status" -eq 0 ] || fail "register-goal mismatch exit = $status; stderr: $(cat "$ERR1")"
grep -q 'does not match launching cwd' "$ERR1" || fail "register-goal mismatch warning missing: $(cat "$ERR1")"
[ -f "$MARKER" ] || fail "workspace mismatch marker missing: $MARKER"

python3 - "$MARKER" "$WORKSPACE_RESOLVED" "$SESSION_CWD_RESOLVED" <<'PY' || fail "workspace mismatch marker JSON did not match expected fields"
import json
import sys

path, workspace, session_cwd = sys.argv[1:4]
data = json.load(open(path, encoding="utf-8"))
assert data["workspace"] == workspace
assert data["session_cwd"] == session_cwd
assert data["source"] == "register-goal"
assert data.get("recorded_at")
PY

rm -f "$MARKER"
set +e
(cd "$WORKSPACE_DIR" && "$REGISTER" --agent test --channel 123 --workspace "$WORKSPACE_DIR" --launcher "$LAUNCHER" "do the thing" 2>"$ERR2" >/dev/null)
status=$?
set -e

[ "$status" -eq 0 ] || fail "register-goal matching exit = $status; stderr: $(cat "$ERR2")"
! grep -q 'does not match launching cwd' "$ERR2" || fail "register-goal matching cwd emitted mismatch warning: $(cat "$ERR2")"
[ ! -f "$MARKER" ] || fail "register-goal matching cwd wrote mismatch marker"

mkdir -p "$HOME/.claude/goal-sessions"
python3 - "$HOME/.claude/goal-sessions/active.jsonl" "$WORKSPACE_RESOLVED" <<'PY'
import json
import sys

path, workspace = sys.argv[1:3]
record = {
    "session_id": "sess-xyz",
    "agent": "test",
    "channel": "123",
    "goal": "do the thing",
    "started_at": "2026-01-01T00:00:00Z",
    "workspace": workspace,
    "launcher": "test",
}
with open(path, "w", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":")) + "\n")
PY

set +e
(cd "$SESSION_CWD" && printf '{"hook_event_name":"SessionStart","session_id":"sess-xyz"}' | "$SESSION_START" 2>"$ERR3" >/dev/null)
status=$?
set -e

[ "$status" -eq 0 ] || fail "session-start mismatch exit = $status; stderr: $(cat "$ERR3")"
grep -q 'registered goal workspace does not match current session cwd' "$ERR3" || fail "session-start mismatch warning missing: $(cat "$ERR3")"
grep -Fq "$WORKSPACE_RESOLVED" "$ERR3" || fail "session-start warning did not name registered workspace: $(cat "$ERR3")"
grep -Fq "$SESSION_CWD_RESOLVED" "$ERR3" || fail "session-start warning did not name current cwd: $(cat "$ERR3")"

set +e
(cd "$WORKSPACE_DIR_2" && printf '{"hook_event_name":"SessionStart","session_id":"sess-none"}' | "$SESSION_START" 2>"$ERR4" >/dev/null)
status=$?
set -e

[ "$status" -eq 0 ] || fail "session-start normal exit = $status; stderr: $(cat "$ERR4")"
! grep -q 'registered goal workspace does not match current session cwd' "$ERR4" || fail "session-start normal path emitted mismatch warning: $(cat "$ERR4")"

echo "PASS - register-goal and session-start warn on workspace/cwd mismatch"
