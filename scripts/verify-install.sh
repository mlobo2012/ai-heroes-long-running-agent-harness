#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Usage: verify-install.sh [--scope core|setup|all]
#
#   --scope core    Universal harness checks only. Should pass on any machine
#                   with the plugin properly installed and the codex env file
#                   pinned, even without OpenClaw or Marco-specific Discord
#                   launchers. 28 checks.
#   --scope setup   The Marco-specific outer-pulse + Discord-router launcher
#                   checks. Verifies the OpenClaw goal-supervisor is wired and
#                   that no launcher uses the obsolete --plugin flag. 6 checks.
#                   FAILS on a community install — that's expected.
#   --scope all     core + setup. Default. 34 checks total.
#
# A community user reading the README should expect `--scope core` to exit 0
# after they follow the install + codex-pin steps. `--scope all` is for
# AI Heroes machines that also run the OpenClaw outer pulse.

SCOPE="all"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --scope)
      SCOPE="${2:-}"
      shift 2
      ;;
    --help|-h)
      cat <<'USAGE'
Usage: verify-install.sh [--scope core|setup|all]
  --scope core    Universal harness checks (default-runnable on any install).
  --scope setup   OpenClaw outer pulse + Discord launcher integration.
  --scope all     Both groups (default).
USAGE
      exit 2
      ;;
    *)
      echo "verify-install: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done
case "$SCOPE" in
  core|setup|all) ;;
  *)
    echo "verify-install: invalid scope: $SCOPE (expected core|setup|all)" >&2
    exit 2
    ;;
esac

failures=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"

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

check_plugin_manifest_schema() {
  claude plugin validate "$PLUGIN_DIR" >/tmp/discord-harness-plugin-validate.out 2>/tmp/discord-harness-plugin-validate.err
}

check_plugin_hooks_config() {
  python3 - "$PLUGIN_DIR/hooks/hooks.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text())
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit("hooks/hooks.json must wrap events in a top-level hooks object")
for event in ("SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "SubagentStop"):
    if event not in hooks:
        raise SystemExit(f"missing hook event: {event}")
commands = []
for entries in hooks.values():
    for entry in entries:
        for hook in entry.get("hooks", []):
            command = hook.get("command", "")
            if isinstance(command, str):
                commands.append(command)
required = [
    "session-start.sh",
    "user-prompt-submit.sh",
    "heartbeat-stop.sh",
    "commit-on-stop.sh",
    "discord-notify.sh",
    "kill-switch.sh",
    "steer.sh",
    "track-read.sh",
    "verify-gate.sh",
]
missing = [name for name in required if not any(name in command for command in commands)]
if missing:
    raise SystemExit("missing hook commands: " + ", ".join(missing))
if not all("${CLAUDE_PLUGIN_ROOT}" in command for command in commands):
    raise SystemExit("hook commands must use ${CLAUDE_PLUGIN_ROOT}")
PY
}

check_hooks_executable() {
  for hook in session-start.sh user-prompt-submit.sh heartbeat-stop.sh track-read.sh verify-gate.sh kill-switch.sh steer.sh commit-on-stop.sh discord-notify.sh; do
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

check_claude_supports_plugin_dir() {
  claude --help 2>&1 | grep -q -- '--plugin-dir <path>'
}

check_enable_dry_run() {
  launcher="$HOME/.claude/channels/discord/start-klaus.sh"
  before="$(stat -f '%m:%z' "$launcher")"
  output="$("$PLUGIN_DIR/bin/enable-for-launcher.sh" --slug klaus 2>&1)"
  after="$(stat -f '%m:%z' "$launcher")"
  [ "$before" = "$after" ] || return 1
  if grep -Eq -- '--plugin-dir[[:space:]]+[^[:space:]]*discord-long-running-harness' "$launcher"; then
    return 0
  fi
  printf '%s' "$output" | grep -Eq -- '--plugin-dir[[:space:]]+[^[:space:]]*discord-long-running-harness'
}

check_no_legacy_launcher_flags() {
  for slug in klaus richard ted-mosby; do
    launcher="$HOME/.claude/channels/discord/start-${slug}.sh"
    [ -f "$launcher" ] || return 1
    if grep -q -- '--plugin[[:space:]]\+discord-long-running-harness' "$launcher"; then
      echo "$launcher uses obsolete --plugin instead of --plugin-dir" >&2
      return 1
    fi
  done
}

check_router_workers_get_plugin_dir() {
  launcher="$HOME/.claude/channels/discord/start-klaus.sh"
  [ -f "$launcher" ] || return 1
  grep -q -- 'plugin:discord-router@claude-discord-threads' "$launcher" || return 0
  grep -Eq -- 'DISCORD_WORKER_PLUGIN_DIRS=[^[:space:]]*discord-long-running-harness' "$launcher"
}

check_supervisor_runner_executable() {
  [ -x "$PLUGIN_DIR/scripts/supervisor-runner.sh" ]
}

check_outer_pulse_tests_present() {
  [ -f "$PLUGIN_DIR/tests/outer-pulse/stall-detection.sh" ] || return 1
  [ -f "$PLUGIN_DIR/tests/outer-pulse/completion-trim.sh" ]
}

check_rubric_files_present() {
  [ -f "$PLUGIN_DIR/agents/rubrics/_template.md" ] || return 1
  [ -f "$PLUGIN_DIR/agents/rubrics/geo-article.md" ] || return 1
  grep -q 'rubric path' "$PLUGIN_DIR/agents/evaluator-strict.md"
}

check_reversibility_docs_present() {
  grep -q 'Reversibility' "$PLUGIN_DIR/README.md" || return 1
  grep -Eq 'rollback|restore|revert' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'enable-for-launcher.sh' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'register-goal.sh' "$PLUGIN_DIR/README.md"
}

check_soak_test_present() {
  [ -x "$PLUGIN_DIR/tests/soak/soak.sh" ] || return 1
  bash -n "$PLUGIN_DIR/tests/soak/soak.sh"
}

check_scope_policy_optional_enum() {
  python3 - "$PLUGIN_DIR/test-results.json" <<'PY'
import json
import sys
from pathlib import Path

allowed = {"fixed_scope", "production_hardening", "research_only"}

def validate(data):
    if not isinstance(data, dict):
        raise SystemExit("test-results.json must be a JSON object")
    policy = data.get("scope_policy", "fixed_scope")
    if policy not in allowed:
        raise SystemExit("invalid scope_policy: " + str(policy))

for sample in (
    {},
    {"scope_policy": "fixed_scope"},
    {"scope_policy": "production_hardening"},
    {"scope_policy": "research_only"},
):
    validate(sample)

try:
    validate({"scope_policy": "invalid"})
except SystemExit:
    pass
else:
    raise SystemExit("invalid scope_policy sample was accepted")

path = Path(sys.argv[1])
if path.exists():
    validate(json.loads(path.read_text(encoding="utf-8")))
PY
}

check_blocker_scripts_executable() {
  [ -x "$PLUGIN_DIR/scripts/blocker-record.sh" ] || return 1
  [ -x "$PLUGIN_DIR/scripts/blocker-update.sh" ]
}

check_scope_policy_tests_present() {
  for test_name in \
    fixed-scope-unchanged.sh \
    prod-hardening-open-blocks.sh \
    prod-hardening-triaged-no-evidence.sh \
    prod-hardening-completes-when-clean.sh \
    research-only-records-but-allows.sh \
    evidence-gating-still-works.sh
  do
    [ -x "$PLUGIN_DIR/tests/scope-policy/$test_name" ] || {
      echo "$test_name is missing or not executable" >&2
      return 1
    }
  done
}

check_scope_policy_docs_present() {
  [ -f "$PLUGIN_DIR/docs/scope-policies.md" ] || return 1
  [ -f "$PLUGIN_DIR/docs/examples/production-hardening-prompt.md" ]
}

check_benchmark_docs_present() {
  [ -f "$PLUGIN_DIR/docs/benchmarks.md" ] || return 1
  grep -q 'Stall detection latency' "$PLUGIN_DIR/docs/benchmarks.md" || return 1
  grep -q 'Sprint throughput' "$PLUGIN_DIR/docs/benchmarks.md" || return 1
  grep -q 'Evidence-gate enforcement' "$PLUGIN_DIR/docs/benchmarks.md"
}

check_benchmark_collector_executable() {
  [ -x "$PLUGIN_DIR/scripts/benchmark-collect.sh" ]
}

check_init_workspace_script() {
  [ -x "$PLUGIN_DIR/scripts/init-workspace.sh" ] || return 1
  bash -n "$PLUGIN_DIR/scripts/init-workspace.sh"
}

check_planner_agent_present() {
  [ -f "$PLUGIN_DIR/agents/planner.md" ] || return 1
  grep -q '^name: planner$' "$PLUGIN_DIR/agents/planner.md" || return 1
  grep -q '^tools: Read, Glob, Grep, Write$' "$PLUGIN_DIR/agents/planner.md"
}

check_session_ledger_write_path() {
  bash -n "$PLUGIN_DIR/hooks/heartbeat-stop.sh" || return 1
  grep -q 'append_session_ledger' "$PLUGIN_DIR/hooks/heartbeat-stop.sh" || return 1
  grep -q 'sessions.jsonl' "$PLUGIN_DIR/hooks/heartbeat-stop.sh"
}

check_parity_decisions_present() {
  [ -f "$PLUGIN_DIR/docs/parity-decisions.md" ] || return 1
  grep -q 'Primitive Matrix Rows' "$PLUGIN_DIR/docs/parity-decisions.md" || return 1
  grep -q 'B10' "$PLUGIN_DIR/docs/parity-decisions.md" || return 1
  grep -q 'D14' "$PLUGIN_DIR/docs/parity-decisions.md" || return 1
  grep -q '| 37 |' "$PLUGIN_DIR/docs/parity-decisions.md"
}

check_sync_to_install_script() {
  [ -x "$PLUGIN_DIR/scripts/sync-to-install.sh" ] || return 1
  bash -n "$PLUGIN_DIR/scripts/sync-to-install.sh"
}

check_readme_capability_map() {
  grep -q 'Capabilities and where they are tested' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'scripts/sync-to-install.sh' "$PLUGIN_DIR/README.md" || return 1
  if [ -f "$PLUGIN_DIR/scripts/audit-readme.sh" ]; then
    bash -n "$PLUGIN_DIR/scripts/audit-readme.sh" || return 1
  fi
}

if [ "$SCOPE" = "core" ] || [ "$SCOPE" = "all" ]; then
  echo "== core checks =="
  check "plugin dir and plugin.json" check_plugin_dir
  check "Claude plugin manifest validates" check_plugin_manifest_schema
  check "plugin hooks config is discoverable" check_plugin_hooks_config
  check "hook scripts executable" check_hooks_executable
  check "codex-spawn dry-run uses gpt-5.5 xhigh" check_codex_dry_run
  check "CODEX_MODEL env file valid" check_codex_env
  check "forbid gpt-5.4" check_forbidden_model gpt-5.4
  check "forbid gpt-5.5-codex" check_forbidden_model gpt-5.5-codex
  check "goal sessions active.jsonl exists" check_active_jsonl
  check "register-goal usage errors" check_register_usage
  check "Claude CLI supports --plugin-dir" check_claude_supports_plugin_dir
  check "supervisor runner executable" check_supervisor_runner_executable
  check "outer-pulse fixture tests present" check_outer_pulse_tests_present
  check "rubric template and GEO example present" check_rubric_files_present
  check "reversibility docs present" check_reversibility_docs_present
  check "synthetic soak test present" check_soak_test_present
  check "scope_policy field is optional and enumerated" check_scope_policy_optional_enum
  check "blocker ledger scripts executable" check_blocker_scripts_executable
  check "scope-policy lifecycle tests present" check_scope_policy_tests_present
  check "scope-policy docs present" check_scope_policy_docs_present
  check "benchmark docs present" check_benchmark_docs_present
  check "benchmark collector executable" check_benchmark_collector_executable
  check "init-workspace script executable and syntactically valid" check_init_workspace_script
  check "optional planner agent present" check_planner_agent_present
  check "session ledger write path present" check_session_ledger_write_path
  check "parity decisions rollup present" check_parity_decisions_present
  check "sync-to-install script executable and syntactically valid" check_sync_to_install_script
  check "README capability map present" check_readme_capability_map
fi

if [ "$SCOPE" = "setup" ] || [ "$SCOPE" = "all" ]; then
  echo "== setup checks =="
  check "goal-supervisor HEARTBEAT.md exists" check_supervisor_heartbeat
  check "openclaw.json contains goal-supervisor" check_openclaw_agent
  check "openclaw.json backup exists" check_backup_exists
  check "enable-for-launcher dry-run does not edit" check_enable_dry_run
  check "launchers do not use obsolete --plugin flag" check_no_legacy_launcher_flags
  check "router workers inherit harness plugin dir" check_router_workers_get_plugin_dir
fi

exit "$failures"
