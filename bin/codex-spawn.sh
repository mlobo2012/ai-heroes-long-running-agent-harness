#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

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

exec codex exec \
  -m "$CODEX_MODEL" \
  -c model_reasoning_effort=xhigh \
  --dangerously-bypass-approvals-and-sandbox \
  -C "$WORKDIR" \
  --skip-git-repo-check \
  "$PROMPT"
