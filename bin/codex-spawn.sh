#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
HEARTBEAT_HELPER="$PLUGIN_DIR/scripts/spawn-heartbeat.sh"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

# Source the pinned model. Preserve an explicit environment override for
# verification and emergency operator tests.
ENV_CODEX_MODEL="${CODEX_MODEL:-}"
ENV_FILE="${CODEX_MODEL_ENV_FILE:-$HOME/.claude/codex-current-model.env}"
if [ ! -r "$ENV_FILE" ]; then
  echo "codex-spawn: missing $ENV_FILE" >&2
  exit 2
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
if [ -n "$ENV_CODEX_MODEL" ]; then
  CODEX_MODEL="$ENV_CODEX_MODEL"
fi

case "${CODEX_MODEL:-}" in
  gpt-5.5-codex|gpt-5.4)
    echo "codex-spawn: forbidden CODEX_MODEL=$CODEX_MODEL" >&2
    exit 3
    ;;
  "")
    echo "codex-spawn: CODEX_MODEL not set in $ENV_FILE" >&2
    exit 4
    ;;
esac

WORKDIR="${CODEX_SPAWN_WORKDIR:-$PWD}"
PROMPT="${1:-}"
if [ "$PROMPT" = "-" ]; then
  PROMPT="$(cat)"
fi
if [ -z "$PROMPT" ]; then
  echo "codex-spawn: empty prompt" >&2
  exit 5
fi

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'codex exec -m %s -c model_reasoning_effort=xhigh --dangerously-bypass-approvals-and-sandbox -C %s --skip-git-repo-check %s\n' "$CODEX_MODEL" "$WORKDIR" "$PROMPT"
  exit 0
fi

codex_pid=""
heartbeat_pid=""

cleanup_heartbeat() {
  set +e
  if [ -n "$heartbeat_pid" ] && kill -0 "$heartbeat_pid" 2>/dev/null; then
    kill "$heartbeat_pid" 2>/dev/null || true
    wait "$heartbeat_pid" 2>/dev/null || true
  fi
}

forward_signal() {
  signal="$1"
  trap - EXIT INT TERM
  set +e
  if [ -n "$codex_pid" ] && kill -0 "$codex_pid" 2>/dev/null; then
    kill "-$signal" "$codex_pid" 2>/dev/null || true
  fi
  cleanup_heartbeat
  if [ "$signal" = "INT" ]; then
    exit 130
  fi
  exit 143
}

trap cleanup_heartbeat EXIT
trap 'forward_signal INT' INT
trap 'forward_signal TERM' TERM

codex exec \
  -m "$CODEX_MODEL" \
  -c model_reasoning_effort=xhigh \
  --dangerously-bypass-approvals-and-sandbox \
  -C "$WORKDIR" \
  --skip-git-repo-check \
  "$PROMPT" &
codex_pid="$!"

STATE_DIR="$WORKDIR/.claude/goal-state"
if [ -d "$STATE_DIR" ] && [ -x "$HEARTBEAT_HELPER" ]; then
  heartbeat_args=("$codex_pid" "$STATE_DIR" --command codex)
  if [ -n "${CODEX_SPAWN_HEARTBEAT_INTERVAL:-}" ]; then
    heartbeat_args+=(--interval "$CODEX_SPAWN_HEARTBEAT_INTERVAL")
  fi
  if [ -n "${CODEX_SPAWN_HEARTBEAT_MAX_RUNTIME:-}" ]; then
    heartbeat_args+=(--max-runtime "$CODEX_SPAWN_HEARTBEAT_MAX_RUNTIME")
  fi
  "$HEARTBEAT_HELPER" "${heartbeat_args[@]}" &
  heartbeat_pid="$!"
fi

set +e
wait "$codex_pid"
codex_status="$?"
set -e

cleanup_heartbeat
trap - EXIT INT TERM
exit "$codex_status"
