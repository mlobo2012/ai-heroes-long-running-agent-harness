#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# SessionStart hook. Idempotent bootstrap for a long-running goal workspace:
#   - PROGRESS.md (4 sections) if missing
#   - test-results.json (empty items array) if missing
#   - .claude/goal-state/ directory + an empty block-count file if missing
#
# Blocks session start with exit 2 if bootstrap cannot create readable,
# non-empty harness artefacts. The Default-FAIL contract (via heartbeat-stop's
# Stop hook) still enforces goal-not-met after the session starts. Closes
# matrix gap row 35 (SessionStart hook not used by upstream cwc) and the Nov
# article's Initializer Agent pattern.

WORKDIR="${PWD}"
PROGRESS="$WORKDIR/PROGRESS.md"
RESULTS="$WORKDIR/test-results.json"
STATE_DIR="$WORKDIR/.claude/goal-state"
input="$(cat 2>/dev/null || true)"

fail_bootstrap() {
  echo "session-start: $1" >&2
  exit 2
}

require_readable_nonempty_file() {
  file="$1"
  label="$2"
  [ -f "$file" ] || fail_bootstrap "$label was not created: $file"
  [ -r "$file" ] || fail_bootstrap "$label is not readable: $file"
  [ -s "$file" ] || fail_bootstrap "$label is empty: $file"
}

require_readable_nonempty_dir() {
  dir="$1"
  label="$2"
  [ -d "$dir" ] || fail_bootstrap "$label directory was not created: $dir"
  [ -r "$dir" ] || fail_bootstrap "$label directory is not readable: $dir"
  [ -s "$dir" ] || fail_bootstrap "$label directory is empty: $dir"
}

parse_session_id() {
  set +e
  parsed_session_id=""
  if command -v jq >/dev/null 2>&1; then
    parsed_session_id="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)"
  elif command -v python3 >/dev/null 2>&1; then
    parsed_session_id="$(INPUT_JSON="$input" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    data = json.loads(os.environ.get("INPUT_JSON", "") or "{}")
except json.JSONDecodeError:
    data = {}
print(data.get("session_id") or "")
PY
)"
  fi
  parsed_session_id="$(printf '%s' "$parsed_session_id" | tr -d '\r\n')"
  printf '%s' "$parsed_session_id"
  set -e
}

SESSION_ID="$(parse_session_id || true)"

write_harness_loaded_beacon() {
  set +e
  printf '%s %s\n' "$(date +%s)" "$SESSION_ID" > "$STATE_DIR/harness-loaded" 2>/dev/null || true
  set -e
}

warn_workspace_cwd_mismatch() {
  set +e
  active_file="$HOME/.claude/goal-sessions/active.jsonl"
  marker_file="$STATE_DIR/workspace-mismatch.json"
  goal_state_file="$STATE_DIR/goal-state.json"
  if ! command -v python3 >/dev/null 2>&1; then
    set -e
    return 0
  fi
  SESSION_START_INPUT="$input" SESSION_START_SESSION_ID="$SESSION_ID" ACTIVE_FILE="$active_file" SESSION_WORKDIR="$WORKDIR" MARKER_FILE="$marker_file" GOAL_STATE_FILE="$goal_state_file" python3 - <<'PY' || true
import json
import os
import sys
from pathlib import Path


def physical(path):
    return os.path.realpath(os.path.abspath(os.path.expanduser(str(path))))


def read_json(path):
    try:
        p = Path(path)
        if not p.is_file():
            return None
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


try:
    hook_input = json.loads(os.environ.get("SESSION_START_INPUT", "") or "{}")
except json.JSONDecodeError:
    hook_input = {}

session_id = str(os.environ.get("SESSION_START_SESSION_ID") or "").strip()
if not session_id:
    session_id = str(hook_input.get("session_id") or "").strip()

workdir = physical(os.environ.get("SESSION_WORKDIR", os.getcwd()))
marker_path = Path(os.environ.get("MARKER_FILE", ""))
goal_state_path = Path(os.environ.get("GOAL_STATE_FILE", ""))
warnings = []


def add_warning(source, workspace, extra=None):
    if not workspace:
        return
    workspace = physical(workspace)
    if workspace == workdir:
        return
    warning = {
        "source": source,
        "workspace": workspace,
        "session_cwd": workdir,
    }
    if extra:
        warning.update(extra)
    if warning not in warnings:
        warnings.append(warning)


marker = read_json(marker_path)
if isinstance(marker, dict):
    add_warning(marker.get("source") or "workspace-mismatch marker", marker.get("workspace"), {"marker": str(marker_path)})

goal_state = read_json(goal_state_path)
if isinstance(goal_state, dict):
    add_warning("goal-state", goal_state.get("workspace"), {"goal_state": str(goal_state_path)})

active_file = os.environ.get("ACTIVE_FILE", "")
if session_id and active_file:
    try:
        lines = open(active_file, encoding="utf-8").read().splitlines()
    except OSError:
        lines = []
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            record = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if str(record.get("session_id") or "").strip() != session_id:
            continue
        add_warning("active goal ledger", record.get("workspace"), {"session_id": session_id})
        break

if warnings:
    marker_data = {
        "workspace": warnings[0]["workspace"],
        "session_cwd": workdir,
        "source": "session-start",
        "detected_from": warnings[0]["source"],
    }
    try:
        marker_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = marker_path.with_suffix(marker_path.suffix + ".tmp")
        tmp.write_text(json.dumps(marker_data, indent=2) + "\n", encoding="utf-8")
        tmp.replace(marker_path)
    except Exception:
        pass
    print("========================================", file=sys.stderr)
    print("session-start: WARNING: registered goal workspace does not match current session cwd", file=sys.stderr)
    for warning in warnings:
        if warning.get("session_id"):
            print(f"  session id: {warning['session_id']}", file=sys.stderr)
        print(f"  source:               {warning['source']}", file=sys.stderr)
        print(f"  registered workspace: {warning['workspace']}", file=sys.stderr)
        print(f"  current cwd:          {warning['session_cwd']}", file=sys.stderr)
    print("  consequence: inner-pulse hooks resolve goal-state from the session cwd; this registered goal will not be driven", file=sys.stderr)
    print(f"  marker: {marker_path}", file=sys.stderr)
    print("========================================", file=sys.stderr)
PY
  set -e
}

launch_liveness_keepalive() {
  set +e
  # HARNESS_LIVENESS_KEEPALIVE=0 disables the session-lifetime liveness watcher.
  if [ "${HARNESS_LIVENESS_KEEPALIVE:-1}" = "0" ]; then
    set -e
    return 0
  fi

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
  keepalive="$script_dir/../scripts/liveness-keepalive.sh"
  [ -x "$keepalive" ] || { set -e; return 0; }
  [ -d "$STATE_DIR" ] || { set -e; return 0; }

  interval="${HARNESS_LIVENESS_INTERVAL:-30}"
  log_file="$STATE_DIR/liveness-keepalive.log"
  # SessionStart runs as a child of the Claude session process, so PPID is the
  # long-lived process whose liveness should keep the goal heartbeat fresh.
  args=("$keepalive" "$PPID" "$WORKDIR" "--interval" "$interval")
  if [ -n "$SESSION_ID" ]; then
    args+=("--session-id" "$SESSION_ID")
  fi

  if command -v setsid >/dev/null 2>&1; then
    setsid "${args[@]}" >> "$log_file" 2>&1 < /dev/null &
  else
    nohup "${args[@]}" >> "$log_file" 2>&1 < /dev/null &
  fi
  disown "$!" 2>/dev/null || true

  set -e
  return 0
}

mkdir -p "$STATE_DIR" || fail_bootstrap "could not create goal-state directory: $STATE_DIR"
# This beacon's presence proves the plugin loaded for the session; its absence for a registered goal proves it did not (the silent-load detector).
write_harness_loaded_beacon || true
warn_workspace_cwd_mismatch || true
launch_liveness_keepalive || true
require_readable_nonempty_dir "$STATE_DIR" ".claude/goal-state"

if [ ! -f "$PROGRESS" ]; then
  if ! cat > "$PROGRESS" <<'EOF'
<!-- Auto-bootstrapped by hooks/session-start.sh. Edit freely. -->

# PROGRESS

## Done

_Nothing yet._

## In progress

_Nothing yet._

## Next

_Nothing yet._

## Notes

Set the goal with `scripts/register-goal.sh` (see README §"Register and run a goal").
EOF
  then
    fail_bootstrap "could not write PROGRESS.md: $PROGRESS"
  fi
fi
require_readable_nonempty_file "$PROGRESS" "PROGRESS.md"

if [ ! -f "$RESULTS" ]; then
  if ! cat > "$RESULTS" <<'EOF'
{
  "_note": "Auto-bootstrapped by hooks/session-start.sh. Edit before registering a goal.",
  "goal": "Set me — the inner pulse blocks turn-end until every items[].passes is true.",
  "items": []
}
EOF
  then
    fail_bootstrap "could not write test-results.json: $RESULTS"
  fi
fi
require_readable_nonempty_file "$RESULTS" "test-results.json"

if [ ! -f "$STATE_DIR/block-count" ]; then
  printf '0\n' > "$STATE_DIR/block-count" || fail_bootstrap "could not write block-count: $STATE_DIR/block-count"
fi
require_readable_nonempty_file "$STATE_DIR/block-count" "block-count"
require_readable_nonempty_dir "$STATE_DIR" ".claude/goal-state"

exit 0
