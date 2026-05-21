#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

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

line="$(python3 - "$session_id" "$AGENT" "$CHANNEL" "$GOAL" "$started_at" "$WORKSPACE" "$LAUNCHER" <<'PY'
import json
import sys

session_id, agent, channel, goal, started_at, workspace, launcher = sys.argv[1:8]
print(json.dumps({
    "session_id": session_id,
    "agent": agent,
    "channel": channel,
    "goal": goal,
    "started_at": started_at,
    "workspace": workspace,
    "launcher": launcher,
    "harness_mode": "planner-generator-evaluator",
    "requires_qa_report": True,
}, separators=(",", ":")))
PY
)"

append_active() {
  if command -v flock >/dev/null 2>&1; then
    lock="$ACTIVE_FILE.lock"
    (
      flock 9
      printf '%s\n' "$line" >> "$ACTIVE_FILE"
    ) 9>"$lock"
    return 0
  fi
  LINE="$line" ACTIVE_FILE="$ACTIVE_FILE" python3 - <<'PY'
import fcntl
import os
from pathlib import Path

active = Path(os.environ["ACTIVE_FILE"])
active.parent.mkdir(parents=True, exist_ok=True)
lock = active.with_suffix(active.suffix + ".lock")
line = os.environ["LINE"]
with lock.open("a") as lock_file:
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
    with active.open("a") as active_file:
        active_file.write(line + "\n")
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
PY
}

append_active

if [ ! -f "$WORKSPACE/PROGRESS.md" ]; then
  cat > "$WORKSPACE/PROGRESS.md" <<'PROGRESS'
# PROGRESS

## Done

(none yet)

## In progress

(none yet)

## Next

(planner will populate from BUILD_PLAN.md)

## Notes

The builder updates this file at the end of every session. The
session-start hook surfaces the latest entries automatically on the
next session.
PROGRESS
fi

if [ ! -f "$WORKSPACE/init.sh" ]; then
  cat > "$WORKSPACE/init.sh" <<'INIT'
#!/usr/bin/env bash
# init.sh — workspace orientation / dev-server starter.
# Replace this stub with the project's actual startup once known.
# Builder: keep this idempotent and safe to re-run.
set -euo pipefail
echo "init.sh stub — replace with the real startup. Returning OK."
exit 0
INIT
  chmod +x "$WORKSPACE/init.sh"
fi

if [ ! -f "$WORKSPACE/BUILD_PLAN.md" ]; then
  python3 - "$WORKSPACE/BUILD_PLAN.md" "$GOAL" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
goal = sys.argv[2]
path.write_text(f"""# BUILD_PLAN

## Goal

{goal}

## Product Spec

Planner must fill this in before implementation.

## Acceptance Contract

Planner must create numbered, observable criteria here.

## Evidence Required

Planner must list required evidence artifacts here.

## Evaluator Rubric

Planner must define the PASS bar here.

## Suggested Build Path

Planner must outline the build path here.

## Out of Scope

Planner must list non-goals here.
""", encoding="utf-8")
PY
fi

GOAL_STATE_DIR="$WORKSPACE/.claude/goal-state"
mkdir -p "$GOAL_STATE_DIR"
python3 - "$GOAL_STATE_DIR/goal-state.json" "$session_id" "$GOAL" "$started_at" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = {
    "session_id": sys.argv[2],
    "goal": sys.argv[3],
    "started_at": sys.argv[4],
    "status": "active",
}
tmp = path.with_suffix(path.suffix + ".tmp")
tmp.write_text(json.dumps(data, indent=2) + "\n")
tmp.replace(path)
PY

echo "Registered goal session. In the Claude Discord session, kick:"
printf '/goal "Plan the goal in BUILD_PLAN.md, build it, keep test-results.json green, and finish only when QA_REPORT.md starts with PASS: %s"\n' "$GOAL"
echo "Appended JSON line:"
printf '%s\n' "$line"
