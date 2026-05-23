#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

usage() {
  cat <<'USAGE'
Usage: spawn-heartbeat.sh <target_pid> <state_dir> [--interval 30] [--command codex] [--max-runtime 7200]

Refreshes .claude/goal-state/last-beat while a spawned command is still
running, and writes spawn-active.json for dashboard consumers.
USAGE
}

if [ "$#" -lt 2 ]; then
  usage >&2
  exit 2
fi

TARGET_PID="$1"
STATE_DIR="$2"
shift 2

INTERVAL=30
COMMAND_NAME="codex"
MAX_RUNTIME=7200

while [ "$#" -gt 0 ]; do
  case "$1" in
    --interval)
      INTERVAL="${2:-}"
      shift 2
      ;;
    --command)
      COMMAND_NAME="${2:-}"
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
      echo "spawn-heartbeat: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$TARGET_PID" in
  ''|*[!0-9]*)
    echo "spawn-heartbeat: target_pid must be a positive integer" >&2
    exit 2
    ;;
esac

case "$INTERVAL" in
  ''|*[!0-9]*)
    echo "spawn-heartbeat: --interval must be a positive integer" >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -lt 1 ]; then
  echo "spawn-heartbeat: --interval must be at least 1" >&2
  exit 2
fi

case "$MAX_RUNTIME" in
  ''|*[!0-9]*)
    echo "spawn-heartbeat: --max-runtime must be a non-negative integer" >&2
    exit 2
    ;;
esac

if [ ! -d "$STATE_DIR" ]; then
  exit 0
fi

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_EPOCH="$(date +%s)"
STOP_REQUESTED=0

cleanup() {
  rm -f "$STATE_DIR/spawn-active.json" 2>/dev/null || true
}

trap 'STOP_REQUESTED=1' INT TERM
trap cleanup EXIT

write_spawn_active() {
  [ -d "$STATE_DIR" ] || return 1

  now_epoch="$(date +%s)"
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s\n' "$now_epoch" > "$STATE_DIR/last-beat"

  tmp_file="$STATE_DIR/spawn-active.json.$$"
  if command -v jq >/dev/null 2>&1 && jq -nc \
      --argjson pid "$TARGET_PID" \
      --arg started_at "$STARTED_AT" \
      --arg last_refreshed "$now_iso" \
      --arg command "$COMMAND_NAME" \
      '{pid:$pid,started_at:$started_at,last_refreshed:$last_refreshed,command:$command}' \
      > "$tmp_file" 2>/dev/null; then
    true
  elif command -v python3 >/dev/null 2>&1; then
    SPAWN_HEARTBEAT_PID="$TARGET_PID" \
    SPAWN_HEARTBEAT_STARTED_AT="$STARTED_AT" \
    SPAWN_HEARTBEAT_LAST_REFRESHED="$now_iso" \
    SPAWN_HEARTBEAT_COMMAND="$COMMAND_NAME" \
    python3 - "$tmp_file" <<'PY'
import json
import os
import sys
from pathlib import Path

record = {
    "pid": int(os.environ["SPAWN_HEARTBEAT_PID"]),
    "started_at": os.environ["SPAWN_HEARTBEAT_STARTED_AT"],
    "last_refreshed": os.environ["SPAWN_HEARTBEAT_LAST_REFRESHED"],
    "command": os.environ["SPAWN_HEARTBEAT_COMMAND"],
}
Path(sys.argv[1]).write_text(json.dumps(record, separators=(",", ":")) + "\n", encoding="utf-8")
PY
  else
    safe_command="codex"
    case "$COMMAND_NAME" in
      *[!A-Za-z0-9._/-]*) ;;
      *) safe_command="$COMMAND_NAME" ;;
    esac
    printf '{"pid":%s,"started_at":"%s","last_refreshed":"%s","command":"%s"}\n' \
      "$TARGET_PID" "$STARTED_AT" "$now_iso" "$safe_command" > "$tmp_file"
  fi

  mv "$tmp_file" "$STATE_DIR/spawn-active.json"
}

write_spawn_active || exit 0

while [ "$STOP_REQUESTED" -eq 0 ]; do
  if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    break
  fi

  now="$(date +%s)"
  if [ "$MAX_RUNTIME" -gt 0 ] && [ $((now - START_EPOCH)) -ge "$MAX_RUNTIME" ]; then
    break
  fi

  sleep "$INTERVAL" || true

  if [ "$STOP_REQUESTED" -ne 0 ]; then
    break
  fi
  if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    break
  fi

  now="$(date +%s)"
  if [ "$MAX_RUNTIME" -gt 0 ] && [ $((now - START_EPOCH)) -gt "$MAX_RUNTIME" ]; then
    break
  fi

  write_spawn_active || break
done

exit 0
