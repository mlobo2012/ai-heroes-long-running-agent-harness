#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

failures=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${DISCORD_LONG_RUNNING_HARNESS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

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

check_settings_json() {
  python3 -c "import json; json.load(open('$PLUGIN_DIR/settings.json'))" >/dev/null 2>&1
}

check_hooks_executable() {
  for hook in heartbeat-stop.sh track-read.sh verify-gate.sh kill-switch.sh steer.sh commit-on-stop.sh discord-notify.sh; do
    [ -x "$PLUGIN_DIR/hooks/$hook" ] || {
      echo "$hook is not executable" >&2
      return 1
    }
  done
}

check_watchdog_executable() {
  [ -x "$PLUGIN_DIR/scripts/goal-watchdog.py" ] || return 1
  python3 -m py_compile "$PLUGIN_DIR/scripts/goal-watchdog.py"
}

check_watchdog_help() {
  output="$($PLUGIN_DIR/scripts/goal-watchdog.py --help 2>&1)"
  printf '%s' "$output" | grep -q 'Clock-driven watchdog'
}

check_watchdog_smoke() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state" "$tmp/sessions"
  old="$(( $(date +%s) - 3600 ))"
  printf '%s\n' "$old" > "$workspace/.claude/goal-state/last-beat"
  cat > "$tmp/sessions/active.jsonl" <<EOF
{"session_id":"verify-stale","agent":"verify","channel":"0","goal":"verify watchdog","started_at":"2026-01-01T00:00:00Z","workspace":"$workspace","launcher":"/tmp/launcher"}
EOF
  "$PLUGIN_DIR/scripts/goal-watchdog.py" --active-file "$tmp/sessions/active.jsonl" --stale-after 1200 --json >/tmp/discord-harness-watchdog-smoke.json
  grep -q 'stale-alert' /tmp/discord-harness-watchdog-smoke.json || return 1
  grep -q 'Watchdog recovery' "$workspace/STEER.md" || return 1
}

check_codex_dry_run() {
  output="$($PLUGIN_DIR/bin/codex-spawn.sh --dry-run "test prompt" 2>/dev/null)"
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

check_goal_sessions_dir() {
  dir="$HOME/.claude/goal-sessions"
  mkdir -p "$dir"
  [ -w "$dir" ] || return 1
}

check_register_usage() {
  set +e
  output="$($PLUGIN_DIR/scripts/register-goal.sh --help 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || return 1
  printf '%s' "$output" | grep -q 'Usage: register-goal.sh'
}

check_readme_mentions_watchdog() {
  grep -q 'scripts/goal-watchdog.py' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'OpenClaw option' "$PLUGIN_DIR/README.md"
}

check "plugin dir and plugin.json" check_plugin_dir
check "settings.json valid" check_settings_json
check "hook scripts executable" check_hooks_executable
check "standalone watchdog executable" check_watchdog_executable
check "standalone watchdog help" check_watchdog_help
check "standalone watchdog stale-session smoke" check_watchdog_smoke
check "codex-spawn dry-run uses gpt-5.5 xhigh" check_codex_dry_run
check "CODEX_MODEL env file valid" check_codex_env
check "forbid gpt-5.4" check_forbidden_model gpt-5.4
check "forbid gpt-5.5-codex" check_forbidden_model gpt-5.5-codex
check "goal sessions directory writable" check_goal_sessions_dir
check "register-goal usage errors" check_register_usage
check "README documents watchdog and OpenClaw options" check_readme_mentions_watchdog

exit "$failures"
