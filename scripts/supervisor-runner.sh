#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: supervisor-runner.sh [--help]

Runs the OpenClaw goal-supervisor heartbeat protocol against the active
goal-session ledger.

Environment overrides:
  SUPERVISOR_ACTIVE_LEDGER     Default: ~/.claude/goal-sessions/active.jsonl
  SUPERVISOR_STALL_THRESHOLD   Default: 1200
  SUPERVISOR_RECOVERY_LOG      Default: ~/.claude/goal-sessions/recovery.log
  SUPERVISOR_COMPLETION_LOG    Default: ~/.claude/goal-sessions/completion.log
  SUPERVISOR_DISCORD_WEBHOOK   Optional Discord webhook for stall alerts

Webhook retry controls match hooks/discord-notify.sh:
  DISCORD_NOTIFY_MAX_ATTEMPTS  Default: 3
  DISCORD_NOTIFY_TIMEOUT       Default: 10
USAGE
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "supervisor-runner: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "supervisor-runner: python3 is required" >&2
  exit 127
fi

ACTIVE_LEDGER="${SUPERVISOR_ACTIVE_LEDGER:-$HOME/.claude/goal-sessions/active.jsonl}"
STALL_THRESHOLD="${SUPERVISOR_STALL_THRESHOLD:-1200}"
RECOVERY_LOG="${SUPERVISOR_RECOVERY_LOG:-$HOME/.claude/goal-sessions/recovery.log}"
COMPLETION_LOG="${SUPERVISOR_COMPLETION_LOG:-$HOME/.claude/goal-sessions/completion.log}"

case "$STALL_THRESHOLD" in
  ''|*[!0-9]*)
    echo "supervisor-runner: SUPERVISOR_STALL_THRESHOLD must be a non-negative integer" >&2
    exit 2
    ;;
esac

# Log parent directories are created only when a JSONL entry is written.

TMPDIR_BASE="${TMPDIR:-/tmp}"
POST_QUEUE="$(mktemp "$TMPDIR_BASE/supervisor-runner-posts.XXXXXX")"
SUMMARY_FILE="$(mktemp "$TMPDIR_BASE/supervisor-runner-summary.XXXXXX")"
SUPERVISOR_BACKUP_TS="${SUPERVISOR_BACKUP_TS:-$(date +%s)}"
cleanup() {
  rm -f "$POST_QUEUE" "$SUMMARY_FILE"
}
trap cleanup EXIT

SUPERVISOR_POST_QUEUE="$POST_QUEUE" \
SUPERVISOR_SUMMARY_FILE="$SUMMARY_FILE" \
SUPERVISOR_BACKUP_TS="$SUPERVISOR_BACKUP_TS" \
python3 - "$ACTIVE_LEDGER" "$RECOVERY_LOG" "$COMPLETION_LOG" "$STALL_THRESHOLD" <<'PY'
import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

active_ledger = Path(sys.argv[1]).expanduser()
recovery_log = Path(sys.argv[2]).expanduser()
completion_log = Path(sys.argv[3]).expanduser()
stall_threshold = int(sys.argv[4])
post_queue = Path(os.environ["SUPERVISOR_POST_QUEUE"])
summary_file = Path(os.environ["SUPERVISOR_SUMMARY_FILE"])
webhook_enabled = bool(os.environ.get("SUPERVISOR_DISCORD_WEBHOOK"))
backup_ts = os.environ["SUPERVISOR_BACKUP_TS"]
backed_up = set()

now = int(time.time())
now_iso = datetime.fromtimestamp(now, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def append_jsonl(path, entry):
    path.parent.mkdir(parents=True, exist_ok=True)
    backup_before_write(path)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True, separators=(",", ":")) + "\n")


def backup_before_write(path):
    key = str(path)
    if key in backed_up:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    backup = path.with_name(f"{path.name}.bak.{backup_ts}.supervisor-runner")
    if path.exists():
        backup.write_bytes(path.read_bytes())
    else:
        backup.write_text("", encoding="utf-8")
    backed_up.add(key)


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8")), None
    except FileNotFoundError:
        return None, str(path)
    except Exception:
        return None, str(path)


def read_last_beat(path):
    try:
        raw = path.read_text(encoding="utf-8").strip()
        return int(raw), None
    except FileNotFoundError:
        return None, str(path)
    except Exception:
        return None, str(path)


def parse_started_at(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        stripped = value.strip()
        if stripped.isdigit():
            return int(stripped)
        try:
            return int(datetime.fromisoformat(stripped.replace("Z", "+00:00")).timestamp())
        except Exception:
            return None
    return None


def session_message(session, age_seconds, last_beat_path):
    minutes = max(0, age_seconds // 60) if isinstance(age_seconds, int) else "unknown"
    goal = session.get("goal") or "goal"
    agent = session.get("agent") or "agent"
    return (
        f"Goal '{goal}' for {agent} has been silent for {minutes} minutes. "
        f"Last beat file: {last_beat_path}. Recovery note written to {recovery_log}."
    )


raw_lines = []
if active_ledger.exists():
    raw_lines = active_ledger.read_text(encoding="utf-8").splitlines()

remaining_lines = []
sessions_seen = 0
sessions_stalled = 0
sessions_completed = 0
sessions_ok = 0

for raw_line in raw_lines:
    if not raw_line.strip():
        continue

    sessions_seen += 1
    try:
        session = json.loads(raw_line)
    except Exception:
        entry = {
            "event": "stalled",
            "detected_at": now_iso,
            "session_id": "invalid-active-ledger-line",
            "workspace": None,
            "last_beat_age_seconds": None,
            "missing_paths": [str(active_ledger)],
            "reason": "invalid active ledger JSON",
        }
        append_jsonl(recovery_log, entry)
        sessions_stalled += 1
        remaining_lines.append(raw_line)
        continue

    session_id = str(session.get("session_id") or "")
    workspace = session.get("workspace")
    missing_paths = []
    last_beat_age = None
    stalled = False
    completed = False

    if not workspace:
        missing_paths.append("workspace")
        stalled = True
        goal_state = None
        last_beat_path = "workspace/.claude/goal-state/last-beat"
    else:
        workspace_path = Path(str(workspace)).expanduser()
        goal_state_path = workspace_path / ".claude" / "goal-state" / "goal-state.json"
        last_beat_path = str(workspace_path / ".claude" / "goal-state" / "last-beat")
        goal_state, goal_state_error = read_json(goal_state_path)
        if goal_state_error:
            missing_paths.append(goal_state_error)
            stalled = True
        elif goal_state.get("status") == "complete":
            completed = True

        if not completed:
            last_beat, last_beat_error = read_last_beat(Path(last_beat_path))
            if last_beat_error:
                missing_paths.append(last_beat_error)
                stalled = True
            else:
                last_beat_age = max(0, now - last_beat)
                if last_beat_age > stall_threshold:
                    stalled = True

    if completed:
        started_at = parse_started_at(session.get("started_at"))
        duration_seconds = None if started_at is None else max(0, now - started_at)
        append_jsonl(
            completion_log,
            {
                "event": "completed",
                "completed_at": now_iso,
                "session_id": session_id,
                "workspace": workspace,
                "duration_seconds": duration_seconds,
            },
        )
        sessions_completed += 1
        continue

    if stalled:
        entry = {
            "event": "stalled",
            "detected_at": now_iso,
            "session_id": session_id,
            "workspace": workspace,
            "last_beat_age_seconds": last_beat_age,
            "missing_paths": missing_paths,
        }
        append_jsonl(recovery_log, entry)
        sessions_stalled += 1
        remaining_lines.append(raw_line)
        if webhook_enabled:
            age_for_message = last_beat_age if last_beat_age is not None else 0
            payload = {"content": session_message(session, age_for_message, last_beat_path)}
            with post_queue.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(payload, separators=(",", ":")) + "\n")
        continue

    sessions_ok += 1
    remaining_lines.append(raw_line)

if sessions_completed > 0:
    active_ledger.parent.mkdir(parents=True, exist_ok=True)
    backup_before_write(active_ledger)
    fd, temp_name = tempfile.mkstemp(
        prefix=f".{active_ledger.name}.",
        suffix=".tmp",
        dir=str(active_ledger.parent),
        text=True,
    )
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        if remaining_lines:
            handle.write("\n".join(remaining_lines) + "\n")
    os.replace(temp_name, active_ledger)

summary_file.write_text(
    f"{sessions_seen} {sessions_stalled} {sessions_completed} {sessions_ok}\n",
    encoding="utf-8",
)
PY

post_discord() {
  payload="$1"
  max_attempts="${DISCORD_NOTIFY_MAX_ATTEMPTS:-3}"
  case "$max_attempts" in
    ''|*[!0-9]*) max_attempts="3" ;;
  esac
  if [ "$max_attempts" -lt 1 ]; then
    max_attempts="1"
  fi

  timeout="${DISCORD_NOTIFY_TIMEOUT:-10}"
  case "$timeout" in
    ''|*[!0-9]*) timeout="10" ;;
  esac

  attempts=0
  while [ "$attempts" -lt "$max_attempts" ]; do
    attempts=$((attempts + 1))
    if curl -fsS -X POST -H 'Content-Type: application/json' \
      --max-time "$timeout" \
      -d "$payload" "$SUPERVISOR_DISCORD_WEBHOOK" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$attempts" -lt "$max_attempts" ]; then
      sleep_for=$((2 ** (attempts - 1)))
      sleep "$sleep_for"
    fi
  done
  return 1
}

webhook_posts=0
webhook_failures=0
if [ -n "${SUPERVISOR_DISCORD_WEBHOOK:-}" ]; then
  while IFS= read -r payload; do
    [ -n "$payload" ] || continue
    if post_discord "$payload"; then
      webhook_posts=$((webhook_posts + 1))
    else
      webhook_failures=$((webhook_failures + 1))
    fi
  done < "$POST_QUEUE"
fi

read -r sessions_seen sessions_stalled sessions_completed sessions_ok < "$SUMMARY_FILE"
printf 'supervisor-runner: sessions_seen=%s sessions_stalled=%s sessions_completed=%s sessions_ok=%s webhook_posts=%s webhook_failures=%s\n' \
  "$sessions_seen" "$sessions_stalled" "$sessions_completed" "$sessions_ok" "$webhook_posts" "$webhook_failures"
