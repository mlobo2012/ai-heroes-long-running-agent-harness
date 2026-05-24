#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

usage() {
  cat <<'USAGE'
Usage: liveness-keepalive.sh <session_pid> <workspace_abs_path> [--interval 30] [--session-id <id>] [--max-runtime 86400]

Refreshes .claude/goal-state/last-beat and the active session ledger while
the owning session process is alive and the goal is still active.
USAGE
}

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 0
fi

SESSION_PID="$1"
WORKSPACE="$2"
shift 2

INTERVAL=30
SESSION_ID=""
MAX_RUNTIME=86400

while [ "$#" -gt 0 ]; do
  case "$1" in
    --interval)
      INTERVAL="${2:-}"
      shift 2
      ;;
    --session-id)
      SESSION_ID="${2:-}"
      shift 2
      ;;
    --max-runtime)
      MAX_RUNTIME="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "liveness-keepalive: unknown argument: $1" >&2
      usage >&2
      exit 0
      ;;
  esac
done

case "$SESSION_PID" in
  ''|*[!0-9]*)
    echo "liveness-keepalive: session_pid must be a positive integer" >&2
    exit 0
    ;;
esac
if [ "$SESSION_PID" -lt 1 ]; then
  echo "liveness-keepalive: session_pid must be a positive integer" >&2
  exit 0
fi

case "$INTERVAL" in
  ''|*[!0-9]*)
    echo "liveness-keepalive: --interval must be a positive integer" >&2
    exit 0
    ;;
esac
if [ "$INTERVAL" -lt 1 ]; then
  echo "liveness-keepalive: --interval must be at least 1" >&2
  exit 0
fi

case "$MAX_RUNTIME" in
  ''|*[!0-9]*)
    echo "liveness-keepalive: --max-runtime must be a non-negative integer" >&2
    exit 0
    ;;
esac

[ -d "$WORKSPACE" ] || exit 0
WORKSPACE_PHYSICAL="$(cd "$WORKSPACE" 2>/dev/null && pwd -P)" || exit 0
STATE_DIR="$WORKSPACE/.claude/goal-state"
[ -d "$STATE_DIR" ] || exit 0

PID_FILE="$STATE_DIR/liveness-keepalive.pid"
PID_TMP="$STATE_DIR/liveness-keepalive.pid.$$"
LAST_BEAT_TMP="$STATE_DIR/last-beat.$$"
START_EPOCH="$(date +%s 2>/dev/null || printf '0')"
STOP_REQUESTED=0

cleanup() {
  set +e
  if [ -f "$PID_FILE" ]; then
    current_pid="$(sed -n '1p' "$PID_FILE" 2>/dev/null || true)"
    if [ "$current_pid" = "$$" ]; then
      rm -f "$PID_FILE" 2>/dev/null || true
    fi
  fi
  rm -f "$PID_TMP" "$LAST_BEAT_TMP" 2>/dev/null || true
}

trap 'STOP_REQUESTED=1' INT TERM
trap cleanup EXIT

existing_pid=""
if [ -f "$PID_FILE" ]; then
  existing_pid="$(sed -n '1p' "$PID_FILE" 2>/dev/null || true)"
fi
case "$existing_pid" in
  ''|*[!0-9]*) ;;
  *)
    if [ "$existing_pid" != "$$" ] && kill -0 "$existing_pid" 2>/dev/null; then
      exit 0
    fi
    ;;
esac

if ! printf '%s\n' "$$" > "$PID_TMP" 2>/dev/null || ! mv "$PID_TMP" "$PID_FILE" 2>/dev/null; then
  exit 0
fi

is_session_alive() {
  kill -0 "$SESSION_PID" 2>/dev/null
}

goal_state_complete() {
  file="$STATE_DIR/goal-state.json"
  [ -f "$file" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    jq -e '.status == "complete"' "$file" >/dev/null 2>&1
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY' >/dev/null 2>&1
import json
import sys
from pathlib import Path

try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if isinstance(data, dict) and data.get("status") == "complete" else 1)
PY
    return $?
  fi

  return 1
}

test_results_all_green() {
  file="$WORKSPACE/test-results.json"
  [ -f "$file" ] || return 1

  if command -v jq >/dev/null 2>&1; then
    counts="$(jq -r '[.. | objects | select(has("passes")) | .passes] | [(map(select(. == false)) | length), (map(select(. == true)) | length)] | @tsv' "$file" 2>/dev/null)" || return 1
    false_count="${counts%%	*}"
    true_count="${counts#*	}"
    case "$false_count:$true_count" in
      *[!0-9:]*|:*|*:) return 1 ;;
    esac
    [ "$false_count" -eq 0 ] && [ "$true_count" -ge 1 ]
    return $?
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY' >/dev/null 2>&1
import json
import sys
from pathlib import Path

try:
    data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

values = []

def walk(value):
    if isinstance(value, dict):
        if isinstance(value.get("passes"), bool):
            values.append(value["passes"])
        for child in value.values():
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

walk(data)
raise SystemExit(0 if values and not any(v is False for v in values) and any(v is True for v in values) else 1)
PY
    return $?
  fi

  false_count="$({ grep -oE '[{,[:space:]]"passes"[[:space:]]*:[[:space:]]*false' "$file" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  true_count="$({ grep -oE '[{,[:space:]]"passes"[[:space:]]*:[[:space:]]*true' "$file" 2>/dev/null || true; } | wc -l | tr -d ' ')"
  case "$false_count:$true_count" in
    *[!0-9:]*|:*|*:) return 1 ;;
  esac
  [ "$false_count" -eq 0 ] && [ "$true_count" -ge 1 ]
}

goal_is_terminal() {
  goal_state_complete || test_results_all_green
}

write_last_beat() {
  [ -d "$STATE_DIR" ] || return 1
  now_epoch="$(date +%s 2>/dev/null || printf '0')"
  if printf '%s\n' "$now_epoch" > "$LAST_BEAT_TMP" 2>/dev/null && mv "$LAST_BEAT_TMP" "$STATE_DIR/last-beat" 2>/dev/null; then
    return 0
  fi
  rm -f "$LAST_BEAT_TMP" 2>/dev/null || true
  return 1
}

update_active_session_last_beat() {
  set +e
  active_home="${HOME:-}"
  [ -n "$active_home" ] || { set -e; return 0; }
  active_file="$active_home/.claude/goal-sessions/active.jsonl"
  [ -f "$active_file" ] || { set -e; return 0; }
  command -v python3 >/dev/null 2>&1 || { set -e; return 0; }

  last_beat="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  [ -n "$last_beat" ] || { set -e; return 0; }

  run_active_update_python() {
    ACTIVE_FILE="$active_file" \
    ACTIVE_SESSION_ID="$SESSION_ID" \
    WORKDIR_PHYSICAL="$WORKSPACE_PHYSICAL" \
    ACTIVE_LAST_BEAT="$last_beat" \
    ACTIVE_UPDATE_LOCK_WITH_FCNTL="${1:-0}" \
    python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

active = Path(os.environ["ACTIVE_FILE"])
if not active.exists():
    raise SystemExit(0)

session_id = str(os.environ.get("ACTIVE_SESSION_ID") or "").strip()
workspace = os.environ.get("WORKDIR_PHYSICAL", "").strip()
last_beat = os.environ["ACTIVE_LAST_BEAT"]


def update_file():
    if not active.exists():
        return

    text = active.read_text(encoding="utf-8")
    chunks = text.splitlines(keepends=True)
    updated = []
    changed = False

    for chunk in chunks:
        line = chunk.rstrip("\r\n")
        newline = chunk[len(line):]
        if not line.strip():
            updated.append(chunk)
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            updated.append(chunk)
            continue
        if not isinstance(record, dict):
            updated.append(chunk)
            continue

        record_session_id = str(record.get("session_id") or "").strip()
        record_workspace = str(record.get("workspace") or "").strip()
        if (session_id and record_session_id == session_id) or (workspace and record_workspace == workspace):
            record["last_beat"] = last_beat
            updated.append(json.dumps(record, separators=(",", ":")) + newline)
            changed = True
        else:
            updated.append(chunk)

    if not changed:
        return

    fd, temp_name = tempfile.mkstemp(
        prefix=f".{active.name}.",
        suffix=".tmp",
        dir=str(active.parent),
        text=True,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("".join(updated))
        os.replace(temp_name, active)
    except Exception:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


if os.environ.get("ACTIVE_UPDATE_LOCK_WITH_FCNTL") == "1":
    import fcntl

    lock = active.with_suffix(active.suffix + ".lock")
    with lock.open("a", encoding="utf-8") as lock_file:
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
        update_file()
else:
    update_file()
PY
  }

  lock="$active_file.lock"
  if command -v flock >/dev/null 2>&1; then
    ( flock 9 && run_active_update_python 0 ) 9>"$lock" >/dev/null 2>&1 || true
  else
    run_active_update_python 1 >/dev/null 2>&1 || true
  fi

  set -e
  return 0
}

refresh_liveness() {
  write_last_beat || true
  update_active_session_last_beat || true
}

should_stop() {
  if ! is_session_alive; then
    return 0
  fi

  now="$(date +%s 2>/dev/null || printf '0')"
  if [ "$MAX_RUNTIME" -gt 0 ] && [ "$now" -gt 0 ] && [ $((now - START_EPOCH)) -ge "$MAX_RUNTIME" ]; then
    return 0
  fi

  if goal_is_terminal; then
    return 0
  fi

  return 1
}

if should_stop; then
  exit 0
fi
refresh_liveness

while [ "$STOP_REQUESTED" -eq 0 ]; do
  sleep "$INTERVAL" || true

  if [ "$STOP_REQUESTED" -ne 0 ]; then
    break
  fi

  if should_stop; then
    break
  fi

  refresh_liveness
done

exit 0
