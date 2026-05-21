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
  for hook in heartbeat-stop.sh track-read.sh verify-gate.sh verify-gate-bash.sh kill-switch.sh steer.sh commit-on-stop.sh discord-notify.sh session-start.sh pre-compact.sh; do
    [ -x "$PLUGIN_DIR/hooks/$hook" ] || {
      echo "$hook is not executable" >&2
      return 1
    }
  done
}

check_agents_present() {
  [ -f "$PLUGIN_DIR/agents/planner.md" ] || return 1
  [ -f "$PLUGIN_DIR/agents/evaluator.md" ] || return 1
  [ -f "$PLUGIN_DIR/agents/codex-executor.md" ] || return 1
  grep -q 'QA_REPORT.md' "$PLUGIN_DIR/agents/evaluator.md" || return 1
  grep -q 'BUILD_PLAN.md' "$PLUGIN_DIR/agents/planner.md"
}

check_rubrics_present() {
  for r in frontend.md api.md library.md data-pipeline.md; do
    [ -f "$PLUGIN_DIR/agents/rubrics/$r" ] || return 1
  done
  grep -q 'agents/rubrics/' "$PLUGIN_DIR/agents/planner.md" || return 1
  grep -q 'Playwright' "$PLUGIN_DIR/agents/evaluator.md" || return 1
  grep -q 'four-axis' "$PLUGIN_DIR/agents/evaluator.md"
}

check_codex_executor_no_hardcoded_user() {
  ! grep -q '/Users/marco' "$PLUGIN_DIR/agents/codex-executor.md"
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

check_heartbeat_requires_qa_pass() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"session_id":"verify","goal":"verify","started_at":"2026-01-01T00:00:00Z"}
' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"items":[{"name":"one","passes":true}]}
' > "$workspace/test-results.json"

  set +e
  output="$(cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || return 1
  printf '%s' "$output" | grep -q 'awaiting-evaluator-pass' || return 1

  printf 'PASS\n\nEvidence checked.\n' > "$workspace/QA_REPORT.md"
  set +e
  output="$(cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 0 ] || return 1
  grep -q 'goal-met-with-evaluator-pass' "$workspace/.claude/goal-state/heartbeat-stop.log"
}

check_watchdog_requires_qa_pass() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state" "$tmp/sessions"
  printf '%s\n' "$(date +%s)" > "$workspace/.claude/goal-state/last-beat"
  printf '{"items":[{"name":"one","passes":true}]}\n' > "$workspace/test-results.json"
  cat > "$tmp/sessions/active.jsonl" <<EOF
{"session_id":"verify-qa","agent":"verify","channel":"0","goal":"verify watchdog qa","started_at":"2026-01-01T00:00:00Z","workspace":"$workspace","launcher":"/tmp/launcher"}
EOF
  "$PLUGIN_DIR/scripts/goal-watchdog.py" --active-file "$tmp/sessions/active.jsonl" --json > "$tmp/watchdog-noqa.json"
  grep -q 'healthy' "$tmp/watchdog-noqa.json" || return 1
  [ "$(wc -l < "$tmp/sessions/active.jsonl")" -eq 1 ] || return 1
  printf 'PASS\n\nEvidence checked.\n' > "$workspace/QA_REPORT.md"
  "$PLUGIN_DIR/scripts/goal-watchdog.py" --active-file "$tmp/sessions/active.jsonl" --json > "$tmp/watchdog-pass.json"
  grep -q 'complete' "$tmp/watchdog-pass.json" || return 1
  [ "$(wc -l < "$tmp/sessions/active.jsonl")" -eq 0 ]
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

check_register_creates_build_plan() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  home="$tmp/home"
  launcher="$tmp/launcher.sh"
  mkdir -p "$workspace" "$home"
  printf '#!/usr/bin/env bash\n' > "$launcher"
  chmod +x "$launcher"
  output="$(HOME="$home" "$PLUGIN_DIR/scripts/register-goal.sh" --agent verify --channel 0 --workspace "$workspace" --launcher "$launcher" "verify latest harness" 2>&1)"
  [ -f "$workspace/BUILD_PLAN.md" ] || return 1
  grep -q 'planner-generator-evaluator' "$home/.claude/goal-sessions/active.jsonl" || return 1
  printf '%s' "$output" | grep -q 'QA_REPORT.md starts with PASS'
}

check_readme_mentions_watchdog() {
  grep -q 'scripts/goal-watchdog.py' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'OpenClaw option' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'planner -> generator -> evaluator' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'QA_REPORT.md' "$PLUGIN_DIR/README.md"
}

check_session_start_hook_emits_orientation() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace"
  cat > "$workspace/BUILD_PLAN.md" <<'PLAN'
# BUILD_PLAN

## Acceptance Contract

1. C1: foo
2. C2: bar

## Evaluator Rubric

(see rubrics)
PLAN
  printf 'PASS\nEvidence checked.\n' > "$workspace/QA_REPORT.md"
  cat > "$workspace/PROGRESS.md" <<'PROG'
## Done
- nothing
PROG
  output="$(CLAUDE_PROJECT_DIR="$workspace" "$PLUGIN_DIR/hooks/session-start.sh" 2>/dev/null)"
  printf '%s' "$output" | grep -q 'Acceptance Contract' || return 1
  printf '%s' "$output" | grep -q 'Last QA verdict' || return 1
  printf '%s' "$output" | grep -q 'PROGRESS.md'
}

check_pre_compact_writes_snapshot() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace"
  cat > "$workspace/BUILD_PLAN.md" <<'PLAN'
## Acceptance Contract
1. C1
PLAN
  printf 'NEEDS_WORK\nfindings here\n' > "$workspace/QA_REPORT.md"
  output="$(CLAUDE_PROJECT_DIR="$workspace" "$PLUGIN_DIR/hooks/pre-compact.sh" 2>/dev/null)"
  printf '%s' "$output" | grep -q 'snapshot written' || return 1
  [ -f "$workspace/.claude/goal-state/post-compact-orientation.md" ] || return 1
  grep -q 'Acceptance Contract' "$workspace/.claude/goal-state/post-compact-orientation.md"
}

check_verify_gate_bash_blocks_sed() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace"
  cd "$workspace"
  echo '{"criteria":[{"id":"C1","passes":false,"evidence_paths":[]}]}' > test-results.json
  mkdir -p .claude
  : > .claude/.evidence-reads
  set +e
  output="$("$PLUGIN_DIR/hooks/verify-gate-bash.sh" <<<'{"tool_input":{"command":"sed -i s/false/true/ test-results.json"}}' 2>/dev/null)"
  set -e
  cd - >/dev/null
  printf '%s' "$output" | grep -q 'verify-gate-bash hook caught' || return 1
  printf '%s' "$output" | grep -q '"decision":"block"'
}

check_verify_gate_bash_allows_read() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace"
  cd "$workspace"
  echo '{"criteria":[]}' > test-results.json
  set +e
  output="$("$PLUGIN_DIR/hooks/verify-gate-bash.sh" <<<'{"tool_input":{"command":"cat test-results.json | head -5"}}' 2>/dev/null)"
  status=$?
  set -e
  cd - >/dev/null
  [ -z "$output" ] || ! printf '%s' "$output" | grep -q '"decision":"block"'
}

check_verify_gate_per_criterion_blocks_unproven() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude"
  cd "$workspace"
  cat > test-results.json <<'JSON'
{"criteria":[{"id":"C1","description":"x","evidence_paths":["screenshots/c1.png"],"passes":false}]}
JSON
  : > .claude/.evidence-reads
  proposed_new='{"criteria":[{"id":"C1","description":"x","evidence_paths":["screenshots/c1.png"],"passes":true}]}'
  proposed_json_payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":"test-results.json","content":sys.argv[1]}}))' "$proposed_new")
  set +e
  output="$(printf '%s' "$proposed_json_payload" | "$PLUGIN_DIR/hooks/verify-gate.sh" 2>/dev/null)"
  set -e
  cd - >/dev/null
  printf '%s' "$output" | grep -q 'Cannot flip criteria to pass' || return 1
  printf '%s' "$output" | grep -q '"decision":"block"'
}

check_verify_gate_per_criterion_allows_after_evidence() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude" "$workspace/screenshots"
  cd "$workspace"
  cat > test-results.json <<'JSON'
{"criteria":[{"id":"C1","description":"x","evidence_paths":["screenshots/c1.png"],"passes":false}]}
JSON
  touch screenshots/c1.png
  echo "screenshots/c1.png" > .claude/.evidence-reads
  proposed_new='{"criteria":[{"id":"C1","description":"x","evidence_paths":["screenshots/c1.png"],"passes":true}]}'
  proposed_json_payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":"test-results.json","content":sys.argv[1]}}))' "$proposed_new")
  set +e
  output="$(printf '%s' "$proposed_json_payload" | "$PLUGIN_DIR/hooks/verify-gate.sh" 2>/dev/null)"
  set -e
  cd - >/dev/null
  # No block expected.
  [ -z "$output" ] || ! printf '%s' "$output" | grep -q '"decision":"block"'
}

check_round_telemetry_appended() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"session_id":"verify","goal":"verify","started_at":"2026-01-01T00:00:00Z"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$workspace/test-results.json"
  printf 'PASS\n' > "$workspace/QA_REPORT.md"
  cd "$workspace"
  set +e
  "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' >/dev/null 2>&1
  set -e
  cd - >/dev/null
  [ -f "$workspace/.claude/goal-state/rounds.json" ] || return 1
  grep -q '"verdict": "PASS"' "$workspace/.claude/goal-state/rounds.json"
}

check_watchdog_kick_max_rounds() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state" "$tmp/sessions"
  printf '%s\n' "$(date +%s)" > "$workspace/.claude/goal-state/last-beat"
  printf 'NEEDS_WORK\nstale\n' > "$workspace/QA_REPORT.md"
  printf '{"items":[{"id":"C1","passes":false}]}\n' > "$workspace/test-results.json"
  # Pre-seed rounds.json at the cap
  cat > "$workspace/.claude/goal-state/rounds.json" <<'JSON'
{"rounds":[{"n":1,"verdict":"NEEDS_WORK"},{"n":2,"verdict":"NEEDS_WORK"}]}
JSON
  launcher="$tmp/launcher.sh"
  printf '#!/usr/bin/env bash\necho fired > %s/fired\n' "$tmp" > "$launcher"
  chmod +x "$launcher"
  cat > "$tmp/sessions/active.jsonl" <<EOF
{"session_id":"verify-kick","agent":"verify","channel":"0","goal":"verify kick","started_at":"2026-01-01T00:00:00Z","workspace":"$workspace","launcher":"$launcher"}
EOF
  "$PLUGIN_DIR/scripts/goal-watchdog.py" --active-file "$tmp/sessions/active.jsonl" --kick --max-rounds 2 --json > "$tmp/kick.json" 2>/dev/null
  grep -q 'max-rounds-escalated' "$tmp/kick.json" || return 1
  [ -f "$workspace/ESCALATION.md" ]
}

check_register_seeds_progress_and_init() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  home="$tmp/home"
  launcher="$tmp/launcher.sh"
  mkdir -p "$workspace" "$home"
  printf '#!/usr/bin/env bash\n' > "$launcher"
  chmod +x "$launcher"
  HOME="$home" "$PLUGIN_DIR/scripts/register-goal.sh" --agent verify --channel 0 --workspace "$workspace" --launcher "$launcher" "seed test" >/dev/null
  [ -f "$workspace/PROGRESS.md" ] || return 1
  [ -x "$workspace/init.sh" ] || return 1
  grep -q '## Done' "$workspace/PROGRESS.md"
}

check_settings_wires_new_hooks() {
  python3 - "$PLUGIN_DIR/settings.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
hooks = s.get("hooks", {})
required = ["SessionStart", "PreCompact"]
for k in required:
    if k not in hooks:
        sys.exit(1)
# verify-gate-bash wired on Bash matcher
pre = hooks.get("PreToolUse", [])
bash_block = [g for g in pre if g.get("matcher") == "Bash"]
if not bash_block:
    sys.exit(1)
cmds = []
for g in bash_block:
    for h in g.get("hooks", []):
        cmds.append(h.get("command",""))
if not any("verify-gate-bash.sh" in c for c in cmds):
    sys.exit(1)
PY
}

check "plugin dir and plugin.json" check_plugin_dir
check "settings.json valid" check_settings_json
check "hook scripts executable" check_hooks_executable
check "planner, evaluator, and codex agents present" check_agents_present
check "rubric library and planner picker present" check_rubrics_present
check "codex-executor has no hardcoded user path" check_codex_executor_no_hardcoded_user
check "standalone watchdog executable" check_watchdog_executable
check "standalone watchdog help" check_watchdog_help
check "standalone watchdog stale-session smoke" check_watchdog_smoke
check "heartbeat requires evaluator PASS" check_heartbeat_requires_qa_pass
check "watchdog requires evaluator PASS before pruning" check_watchdog_requires_qa_pass
check "codex-spawn dry-run uses gpt-5.5 xhigh" check_codex_dry_run
check "CODEX_MODEL env file valid" check_codex_env
check "forbid gpt-5.4" check_forbidden_model gpt-5.4
check "forbid gpt-5.5-codex" check_forbidden_model gpt-5.5-codex
check "goal sessions directory writable" check_goal_sessions_dir
check "register-goal usage errors" check_register_usage
check "register-goal creates BUILD_PLAN seed" check_register_creates_build_plan
check "register-goal seeds PROGRESS.md and init.sh" check_register_seeds_progress_and_init
check "README documents watchdog, OpenClaw, and v2 loop" check_readme_mentions_watchdog
check "session-start hook emits orientation" check_session_start_hook_emits_orientation
check "pre-compact hook writes snapshot" check_pre_compact_writes_snapshot
check "verify-gate-bash blocks sed without evidence" check_verify_gate_bash_blocks_sed
check "verify-gate-bash allows read-only inspection" check_verify_gate_bash_allows_read
check "verify-gate per-criterion blocks unproven pass" check_verify_gate_per_criterion_blocks_unproven
check "verify-gate per-criterion allows pass after evidence" check_verify_gate_per_criterion_allows_after_evidence
check "heartbeat appends round telemetry" check_round_telemetry_appended
check "watchdog --kick escalates at max-rounds" check_watchdog_kick_max_rounds
check "settings.json wires SessionStart, PreCompact, and Bash gate" check_settings_wires_new_hooks

exit "$failures"
