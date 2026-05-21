#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

failures=0
PLUGIN_DIR="$HOME/.claude/plugins/discord-long-running-harness"

pass() {
  echo "PASS - $1"
}

fail() {
  echo "FAIL - $1: $2"
  failures=$((failures + 1))
}

check() {
  name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name" "check failed"
  fi
}

check_plugin_dir() {
  [ -d "$PLUGIN_DIR" ] || return 1
  python3 -c "import json; json.load(open('$PLUGIN_DIR/.claude-plugin/plugin.json'))" >/dev/null 2>&1
}

check_hooks_executable() {
  for hook in heartbeat-stop.sh track-read.sh verify-gate.sh kill-switch.sh steer.sh commit-on-stop.sh discord-notify.sh; do
    [ -x "$PLUGIN_DIR/hooks/$hook" ] || {
      echo "$hook is not executable" >&2
      return 1
    }
  done
}

check_codex_dry_run() {
  output="$("$PLUGIN_DIR/bin/codex-spawn.sh" --dry-run "test prompt" 2>/dev/null)"
  printf '%s' "$output" | grep -q -- '-m gpt-5.5' || return 1
  printf '%s' "$output" | grep -q -- 'model_reasoning_effort=xhigh'
}

check_codex_env() {
  env_file="$HOME/.claude/codex-current-model.env"
  [ -r "$env_file" ] || return 1
  # shellcheck disable=SC1090
  . "$env_file"
  [ -n "${CODEX_MODEL:-}" ] || return 1
  case "$CODEX_MODEL" in
    gpt-5.4|gpt-5.5-codex) return 1 ;;
  esac
}

check_forbidden_model() {
  model="$1"
  set +e
  CODEX_MODEL="$model" "$PLUGIN_DIR/bin/codex-spawn.sh" --dry-run "test prompt" >/tmp/discord-harness-codex-forbidden.out 2>/tmp/discord-harness-codex-forbidden.err
  status=$?
  set -e
  [ "$status" -eq 3 ]
}

check_active_jsonl() {
  [ -f "$HOME/.claude/goal-sessions/active.jsonl" ]
}

check_supervisor_heartbeat() {
  [ -f "$HOME/.openclaw/workspace-goal-supervisor/HEARTBEAT.md" ]
}

check_openclaw_agent() {
  python3 - <<'PY'
import json
import os
path = os.path.expanduser("~/.openclaw/openclaw.json")
data = json.load(open(path))
raise SystemExit(0 if any(a.get("id") == "goal-supervisor" for a in data["agents"]["list"]) else 1)
PY
}

check_backup_exists() {
  ls "$HOME"/.openclaw/openclaw.json.bak.pre-goal-supervisor.* >/dev/null 2>&1
}

check_register_usage() {
  set +e
  output="$("$PLUGIN_DIR/scripts/register-goal.sh" --help 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || return 1
  printf '%s' "$output" | grep -q 'Usage: register-goal.sh'
}

check_enable_dry_run() {
  launcher="$HOME/.claude/channels/discord/start-klaus.sh"
  before="$(stat -f '%m:%z' "$launcher")"
  output="$("$PLUGIN_DIR/bin/enable-for-launcher.sh" --slug klaus 2>&1)"
  after="$(stat -f '%m:%z' "$launcher")"
  [ "$before" = "$after" ] || return 1
  printf '%s' "$output" | grep -q -- '--plugin discord-long-running-harness'
}

check_launchers_unchanged() {
  for slug in klaus richard; do
    launcher="$HOME/.claude/channels/discord/start-${slug}.sh"
    [ -f "$launcher" ] || return 1
    if grep -q -- '--plugin[[:space:]]\+discord-long-running-harness' "$launcher"; then
      echo "$launcher already opted into harness" >&2
      return 1
    fi
  done
}

check "plugin dir and plugin.json" check_plugin_dir
check "hook scripts executable" check_hooks_executable
check "codex-spawn dry-run uses gpt-5.5 xhigh" check_codex_dry_run
check "CODEX_MODEL env file valid" check_codex_env
check "forbid gpt-5.4" check_forbidden_model gpt-5.4
check "forbid gpt-5.5-codex" check_forbidden_model gpt-5.5-codex
check "goal sessions active.jsonl exists" check_active_jsonl
check "goal-supervisor HEARTBEAT.md exists" check_supervisor_heartbeat
check "openclaw.json contains goal-supervisor" check_openclaw_agent
check "openclaw.json backup exists" check_backup_exists
check "register-goal usage errors" check_register_usage
check "enable-for-launcher dry-run does not edit" check_enable_dry_run
check "Klaus and Richard launchers not opted in" check_launchers_unchanged

exit "$failures"
