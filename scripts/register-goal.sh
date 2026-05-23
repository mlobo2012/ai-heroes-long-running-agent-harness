#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Set REGISTER_GOAL_ALLOW_CWD_MISMATCH=1 to intentionally register a workspace
# from a different launching cwd without writing a mismatch warning marker.

usage() {
  cat <<'USAGE'
Usage: register-goal.sh --agent <slug> --channel <discord_id> --workspace <abs_path> --launcher <abs_path> "<goal text>"

Registers a Discord long-running goal session and prints the /goal command to kick manually.
USAGE
}

AGENT=""
CHANNEL=""
WORKSPACE=""
LAUNCHER=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      AGENT="${2:-}"
      shift 2
      ;;
    --channel)
      CHANNEL="${2:-}"
      shift 2
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --launcher)
      LAUNCHER="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 2
      ;;
    --*)
      echo "register-goal: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

GOAL="${1:-}"

if [ -z "$AGENT" ] || [ -z "$CHANNEL" ] || [ -z "$WORKSPACE" ] || [ -z "$LAUNCHER" ] || [ -z "$GOAL" ]; then
  usage >&2
  exit 2
fi
case "$WORKSPACE" in
  /*) ;;
  *)
    echo "register-goal: --workspace must be an absolute path" >&2
    exit 3
    ;;
esac
case "$LAUNCHER" in
  /*) ;;
  *)
    echo "register-goal: --launcher must be an absolute path" >&2
    exit 3
    ;;
esac
if [ ! -d "$WORKSPACE" ]; then
  echo "register-goal: workspace does not exist: $WORKSPACE" >&2
  exit 4
fi
if [ ! -f "$LAUNCHER" ]; then
  echo "register-goal: launcher does not exist: $LAUNCHER" >&2
  exit 4
fi

resolve_physical_dir() {
  cd "$1" 2>/dev/null && pwd -P
}

WORKSPACE_RESOLVED="$(resolve_physical_dir "$WORKSPACE")"
SESSION_CWD_SOURCE="${REGISTER_GOAL_CWD:-$PWD}"
if ! SESSION_CWD_RESOLVED="$(resolve_physical_dir "$SESSION_CWD_SOURCE")"; then
  SESSION_CWD_RESOLVED="$(pwd -P)"
fi
WORKSPACE="$WORKSPACE_RESOLVED"
WORKSPACE_MISMATCH=0

record_workspace_mismatch() {
  cat >&2 <<EOF
========================================
register-goal: WARNING: --workspace does not match launching cwd
  workspace:   $WORKSPACE_RESOLVED
  session cwd: $SESSION_CWD_RESOLVED
  consequence: inner-pulse hooks resolve goal-state from the session cwd; a mismatched workspace will not be driven
========================================
EOF

  recorded_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  write_mismatch_marker() {
    mismatch_dir="$1"
    mismatch_file="$mismatch_dir/workspace-mismatch.json"
    if mkdir -p "$mismatch_dir"; then
      if ! python3 - "$mismatch_file" "$WORKSPACE_RESOLVED" "$SESSION_CWD_RESOLVED" "$recorded_at" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = {
    "workspace": sys.argv[2],
    "session_cwd": sys.argv[3],
    "recorded_at": sys.argv[4],
    "source": "register-goal",
}
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n")
tmp.replace(path)
PY
      then
        echo "register-goal: WARNING: could not write workspace mismatch marker: $mismatch_file" >&2
      fi
    else
      echo "register-goal: WARNING: could not create workspace mismatch marker directory: $mismatch_dir" >&2
    fi
  }

  write_mismatch_marker "$WORKSPACE/.claude/goal-state"
  if [ "$SESSION_CWD_RESOLVED" != "$WORKSPACE" ]; then
    write_mismatch_marker "$SESSION_CWD_RESOLVED/.claude/goal-state"
  fi
}

if [ "${REGISTER_GOAL_ALLOW_CWD_MISMATCH:-0}" != "1" ] && [ "$WORKSPACE_RESOLVED" != "$SESSION_CWD_RESOLVED" ]; then
  record_workspace_mismatch
  WORKSPACE_MISMATCH=1
fi

if command -v uuidgen >/dev/null 2>&1; then
  session_id="$(uuidgen | tr 'A-Z' 'a-z')"
else
  session_id="$(python3 - <<'PY'
import uuid
print(str(uuid.uuid4()))
PY
)"
fi
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

ACTIVE_DIR="$HOME/.claude/goal-sessions"
ACTIVE_FILE="$ACTIVE_DIR/active.jsonl"
mkdir -p "$ACTIVE_DIR"
backup_ts="$(date +%s)"
ACTIVE_BACKUP="${ACTIVE_FILE}.bak.${backup_ts}.register-goal"

line="$(python3 - "$session_id" "$AGENT" "$CHANNEL" "$GOAL" "$started_at" "$WORKSPACE" "$LAUNCHER" "$SESSION_CWD_RESOLVED" "$WORKSPACE_MISMATCH" <<'PY'
import json
import sys

session_id, agent, channel, goal, started_at, workspace, launcher, session_cwd, workspace_mismatch = sys.argv[1:10]
data = {
    "session_id": session_id,
    "agent": agent,
    "channel": channel,
    "goal": goal,
    "started_at": started_at,
    "workspace": workspace,
    "launcher": launcher,
}
if workspace_mismatch == "1":
    data["registered_from_cwd"] = session_cwd
    data["workspace_mismatch"] = True
print(json.dumps(data, separators=(",", ":")))
PY
)"

append_active() {
  # AI Heroes addition (0.4.0): on re-registration for the same workspace,
  # dedupe by workspace path so the outer pulse sees one canonical session
  # per workspace, not a duplicate. Closes Trap D8 in
  # docs/parity-gap-analysis.md.
  if command -v flock >/dev/null 2>&1; then
    lock="$ACTIVE_FILE.lock"
    (
      flock 9
      LINE="$line" ACTIVE_FILE="$ACTIVE_FILE" ACTIVE_BACKUP="$ACTIVE_BACKUP" WORKSPACE="$WORKSPACE" python3 - <<'PY'
import json
import os
from pathlib import Path

active = Path(os.environ["ACTIVE_FILE"])
active.parent.mkdir(parents=True, exist_ok=True)
backup = Path(os.environ["ACTIVE_BACKUP"])
new_line = os.environ["LINE"]
new_ws = os.environ["WORKSPACE"]
if active.exists():
    backup.write_bytes(active.read_bytes())
else:
    backup.write_text("", encoding="utf-8")
kept = []
if active.exists():
    for raw in active.read_text().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            kept.append(raw)
            continue
        if data.get("workspace") == new_ws:
            continue
        kept.append(raw)
kept.append(new_line)
tmp = active.with_suffix(active.suffix + ".tmp")
tmp.write_text("\n".join(kept) + "\n")
tmp.replace(active)
PY
    ) 9>"$lock"
    return 0
  fi
  LINE="$line" ACTIVE_FILE="$ACTIVE_FILE" ACTIVE_BACKUP="$ACTIVE_BACKUP" WORKSPACE="$WORKSPACE" python3 - <<'PY'
import fcntl
import json
import os
from pathlib import Path

active = Path(os.environ["ACTIVE_FILE"])
active.parent.mkdir(parents=True, exist_ok=True)
backup = Path(os.environ["ACTIVE_BACKUP"])
lock = active.with_suffix(active.suffix + ".lock")
new_line = os.environ["LINE"]
new_ws = os.environ["WORKSPACE"]
with lock.open("a") as lock_file:
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
    if active.exists():
        backup.write_bytes(active.read_bytes())
    else:
        backup.write_text("", encoding="utf-8")
    kept = []
    if active.exists():
        for raw in active.read_text().splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                data = json.loads(raw)
            except json.JSONDecodeError:
                kept.append(raw)
                continue
            if data.get("workspace") == new_ws:
                continue
            kept.append(raw)
    kept.append(new_line)
    tmp = active.with_suffix(active.suffix + ".tmp")
    tmp.write_text("\n".join(kept) + "\n")
    tmp.replace(active)
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
PY
}

append_active

GOAL_STATE_DIR="$WORKSPACE/.claude/goal-state"
GOAL_STATE_FILE="$GOAL_STATE_DIR/goal-state.json"
GOAL_STATE_BACKUP="${GOAL_STATE_FILE}.bak.${backup_ts}.register-goal"
mkdir -p "$GOAL_STATE_DIR"
GOAL_STATE_BACKUP="$GOAL_STATE_BACKUP" python3 - "$GOAL_STATE_FILE" "$session_id" "$GOAL" "$started_at" "$WORKSPACE" "$SESSION_CWD_RESOLVED" "$WORKSPACE_MISMATCH" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
backup = Path(os.environ["GOAL_STATE_BACKUP"])
if path.exists():
    backup.write_bytes(path.read_bytes())
else:
    backup.write_text("", encoding="utf-8")
data = {
    "session_id": sys.argv[2],
    "goal": sys.argv[3],
    "started_at": sys.argv[4],
    "status": "active",
    "workspace": sys.argv[5],
}
if sys.argv[7] == "1":
    data["registered_from_cwd"] = sys.argv[6]
    data["workspace_mismatch"] = {
        "workspace": sys.argv[5],
        "session_cwd": sys.argv[6],
        "source": "register-goal",
    }
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n")
tmp.replace(path)
PY

echo "Registered goal session. In the Claude Discord session, kick:"
printf '/goal "%s"\n' "$GOAL"
echo "Active ledger backup: $ACTIVE_BACKUP"
echo "Goal state backup: $GOAL_STATE_BACKUP"
echo "Appended JSON line:"
printf '%s\n' "$line"
