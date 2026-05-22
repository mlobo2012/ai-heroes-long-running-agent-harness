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

check_new_scripts_executable() {
  for s in run-contract-review.sh run-evaluator.sh calibrate-evaluator.sh diff-rounds.sh bench-harness.sh bench-score.py; do
    [ -x "$PLUGIN_DIR/scripts/$s" ] || { echo "$s is not executable" >&2; return 1; }
  done
}

check_mcp_json_valid() {
  [ -f "$PLUGIN_DIR/.mcp.json" ] || return 1
  python3 -c "import json; d=json.load(open('$PLUGIN_DIR/.mcp.json')); assert 'playwright' in d['mcpServers']" >/dev/null 2>&1
}

check_contract_reviewer_agent() {
  [ -f "$PLUGIN_DIR/agents/contract-reviewer.md" ] || return 1
  grep -q 'CONTRACT_OK' "$PLUGIN_DIR/agents/contract-reviewer.md" || return 1
  grep -q 'CONTRACT_REWRITE' "$PLUGIN_DIR/agents/contract-reviewer.md"
}

check_desktop_rubric_present() {
  [ -f "$PLUGIN_DIR/agents/rubrics/desktop.md" ] || return 1
  grep -q 'computer-use/round-' "$PLUGIN_DIR/agents/rubrics/desktop.md" || return 1
  grep -q 'session.jsonl' "$PLUGIN_DIR/agents/rubrics/desktop.md"
}

check_evaluator_reads_calibration() {
  grep -q 'evaluator-calibration.jsonl' "$PLUGIN_DIR/agents/evaluator.md" || return 1
  grep -q 'playwright-mcp/round-' "$PLUGIN_DIR/agents/evaluator.md" || return 1
  grep -q 'computer-use/round-' "$PLUGIN_DIR/agents/evaluator.md"
}

check_planner_honors_pinned_rubric() {
  grep -q 'pinned in goal-state.json' "$PLUGIN_DIR/agents/planner.md" || return 1
  grep -q 'rubrics/desktop.md' "$PLUGIN_DIR/agents/planner.md" || return 1
  grep -q 'contract-reviewer' "$PLUGIN_DIR/agents/planner.md"
}

check_heartbeat_blocks_missing_interaction_evidence() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"session_id":"iev","goal":"iev","started_at":"2026-01-01T00:00:00Z","rubric":"frontend"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$workspace/test-results.json"
  printf 'PASS\nEvidence checked.\n' > "$workspace/QA_REPORT.md"
  set +e
  output="$(cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || return 1
  printf '%s' "$output" | grep -q 'missing-interaction-evidence:frontend'
}

check_heartbeat_accepts_playwright_trace() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state" "$workspace/playwright-mcp/round-1"
  printf '{"session_id":"iev","goal":"iev","started_at":"2026-01-01T00:00:00Z","rubric":"frontend"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$workspace/test-results.json"
  printf 'PASS\nEvidence checked.\n' > "$workspace/QA_REPORT.md"
  echo "fake trace bytes" > "$workspace/playwright-mcp/round-1/trace.zip"
  set +e
  output="$(cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 0 ] || return 1
  grep -q 'goal-met-with-evaluator-pass' "$workspace/.claude/goal-state/heartbeat-stop.log"
}

check_heartbeat_accepts_computer_use_session() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state" "$workspace/computer-use/round-1"
  printf '{"session_id":"iev","goal":"iev","started_at":"2026-01-01T00:00:00Z","rubric":"desktop"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$workspace/test-results.json"
  printf 'PASS\nEvidence checked.\n' > "$workspace/QA_REPORT.md"
  printf '{"at":"now","action":"click"}\n' > "$workspace/computer-use/round-1/session.jsonl"
  set +e
  status_out="$(cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' 2>/dev/null; echo "rc=$?")"
  set -e
  printf '%s' "$status_out" | grep -q 'rc=0'
}

check_heartbeat_always_escalates() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"session_id":"runaway","goal":"runaway","started_at":"2026-01-01T00:00:00Z","rubric":"api"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"items":[{"name":"x","passes":false}]}\n' > "$workspace/test-results.json"
  cd "$workspace"
  # Run heartbeat 9 times to push past the round budget of 8.
  for _ in 1 2 3 4 5 6 7 8 9; do
    "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' >/dev/null 2>&1 || true
  done
  cd - >/dev/null
  [ -f "$workspace/ESCALATION.md" ] || return 1
  grep -q 'anti-runaway-cap' "$workspace/.claude/goal-state/heartbeat-stop.log"
}

check_register_goal_rubric_flag() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  home="$tmp/home"
  launcher="$tmp/launcher.sh"
  mkdir -p "$workspace" "$home"
  printf '#!/usr/bin/env bash\n' > "$launcher"
  chmod +x "$launcher"
  HOME="$home" "$PLUGIN_DIR/scripts/register-goal.sh" --agent verify --channel 0 --workspace "$workspace" --launcher "$launcher" --rubric frontend --round-budget 4 "rubric test" >/dev/null
  [ -f "$workspace/.claude/goal-state/goal-state.json" ] || return 1
  python3 -c '
import json
d=json.load(open("'"$workspace"'/.claude/goal-state/goal-state.json"))
assert d.get("rubric") == "frontend", d
assert d.get("round_budget") == 4, d
'
  [ -d "$workspace/playwright-mcp/round-1" ] || return 1
  [ -f "$workspace/.claude/goal-state/round-budget" ] || return 1
  grep -q '^4$' "$workspace/.claude/goal-state/round-budget"
}

check_register_goal_rejects_bad_rubric() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  home="$tmp/home"
  launcher="$tmp/launcher.sh"
  mkdir -p "$workspace" "$home"
  printf '#!/usr/bin/env bash\n' > "$launcher"
  chmod +x "$launcher"
  set +e
  HOME="$home" "$PLUGIN_DIR/scripts/register-goal.sh" --agent verify --channel 0 --workspace "$workspace" --launcher "$launcher" --rubric not-a-rubric "bad rubric" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ]
}

check_calibrate_evaluator_records_override() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state"
  printf 'PASS\nEvidence checked.\n' > "$workspace/QA_REPORT.md"
  "$PLUGIN_DIR/scripts/calibrate-evaluator.sh" \
    --workspace "$workspace" \
    --operator-verdict NEEDS_WORK \
    --axes "Originality,Craft" \
    --reason "Purple gradient hero is generic; lowered originality to 2." >/dev/null
  [ -f "$workspace/.claude/goal-state/evaluator-calibration.jsonl" ] || return 1
  grep -q '"operator_verdict":"NEEDS_WORK"' "$workspace/.claude/goal-state/evaluator-calibration.jsonl" || return 1
  grep -q 'Originality' "$workspace/.claude/goal-state/evaluator-calibration.jsonl"
}

check_calibrate_evaluator_rejects_match() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state"
  printf 'PASS\n' > "$workspace/QA_REPORT.md"
  set +e
  output="$("$PLUGIN_DIR/scripts/calibrate-evaluator.sh" --workspace "$workspace" --operator-verdict PASS --reason "agree" 2>&1)"
  set -e
  printf '%s' "$output" | grep -q 'nothing to calibrate'
}

check_run_contract_review_handles_missing_plan() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace"
  cd "$workspace"
  set +e
  "$PLUGIN_DIR/scripts/run-contract-review.sh" --workspace "$workspace" >/dev/null 2>&1
  status=$?
  set -e
  cd - >/dev/null
  [ "$status" -eq 1 ] || return 1
  [ -f "$workspace/CONTRACT_REVIEW.md" ] || return 1
  grep -q '^CONTRACT_REWRITE' "$workspace/CONTRACT_REVIEW.md"
}

check_run_contract_review_dry_run() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace"
  printf '# BUILD_PLAN\n\n## Acceptance Contract\n1. C1: x\n' > "$workspace/BUILD_PLAN.md"
  set +e
  output="$("$PLUGIN_DIR/scripts/run-contract-review.sh" --workspace "$workspace" --dry-run 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" | grep -q 'would invoke'
}

check_run_evaluator_dry_run() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace"
  set +e
  output="$("$PLUGIN_DIR/scripts/run-evaluator.sh" --workspace "$workspace" --dry-run 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 0 ] || return 1
  printf '%s' "$output" | grep -q 'would invoke'
}

check_diff_rounds_smoke() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/screenshots/round-1" "$workspace/screenshots/round-2"
  touch "$workspace/screenshots/round-1/c1.png" "$workspace/screenshots/round-2/c1.png" "$workspace/screenshots/round-2/c2.png"
  printf 'NEEDS_WORK\n\nAxis scores\nDesign: 2/5\nOriginality: 1\nCraft: 3\nFunctionality: 3\n\nAcceptance criteria\n' > "$workspace/QA_REPORT.md"
  printf '{"criteria":[{"id":"C1","passes":false,"description":"d1"}]}\n' > "$workspace/test-results.json"
  output="$("$PLUGIN_DIR/scripts/diff-rounds.sh" 1 2 --workspace "$workspace" 2>&1)"
  printf '%s' "$output" | grep -q 'Round diff' || return 1
  printf '%s' "$output" | grep -q 'screenshots/round-1' || return 1
  printf '%s' "$output" | grep -q 'screenshots/round-2'
}

check_bench_pilot_present() {
  [ -f "$PLUGIN_DIR/bench/pilots/express-server/goal.txt" ] || return 1
  [ -f "$PLUGIN_DIR/bench/pilots/express-server/README.md" ] || return 1
  grep -q 'Express server' "$PLUGIN_DIR/bench/pilots/express-server/goal.txt"
}

check_bench_score_handles_inputs() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  cat > "$tmp/a.json" <<'JSON'
{"pilot":"x","completed":true,"wall_clock_seconds":120,"rounds_to_pass":3,"total_io_bytes_estimate":1000,"false_pass":false}
JSON
  cat > "$tmp/b.json" <<'JSON'
{"pilot":"x","completed":true,"wall_clock_seconds":80,"rounds_to_pass":2,"total_io_bytes_estimate":700,"false_pass":false}
JSON
  output="$("$PLUGIN_DIR/scripts/bench-score.py" "$tmp/a.json" "$tmp/b.json" --json 2>&1)"
  printf '%s' "$output" | grep -q 'wall_clock_seconds' || return 1
  printf '%s' "$output" | grep -q '"baseline": 120'
}

check_session_start_surfaces_calibration() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"session_id":"s","rubric":"frontend","model":"claude-opus-4-7"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"at":1,"operator_verdict":"NEEDS_WORK","axes_in_dispute":["Originality"],"reason":"generic"}\n' > "$workspace/.claude/goal-state/evaluator-calibration.jsonl"
  output="$(CLAUDE_PROJECT_DIR="$workspace" "$PLUGIN_DIR/hooks/session-start.sh" 2>/dev/null)"
  printf '%s' "$output" | grep -q 'Rubric: frontend' || return 1
  printf '%s' "$output" | grep -qi 'evaluator calibration' || return 1
  printf '%s' "$output" | grep -q 'Originality'
}

check_rounds_json_stamps_model_and_rubric() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"session_id":"stamp","goal":"stamp","rubric":"api","model":"claude-opus-4-7","codex_model":"gpt-5.5"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$workspace/test-results.json"
  printf 'PASS\n' > "$workspace/QA_REPORT.md"
  cd "$workspace"
  "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' >/dev/null 2>&1 || true
  cd - >/dev/null
  [ -f "$workspace/.claude/goal-state/rounds.json" ] || return 1
  python3 -c '
import json, sys
d=json.load(open("'"$workspace"'/.claude/goal-state/rounds.json"))
last = d["rounds"][-1]
assert last["verdict"] == "PASS", last
assert last["rubric"] == "api", last
assert last["model"] == "claude-opus-4-7", last
assert last["codex_model"] == "gpt-5.5", last
'
}

check_watchdog_respects_round_budget_file() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  mkdir -p "$workspace/.claude/goal-state" "$tmp/sessions"
  printf '%s\n' "$(date +%s)" > "$workspace/.claude/goal-state/last-beat"
  printf 'NEEDS_WORK\n' > "$workspace/QA_REPORT.md"
  printf '{"items":[{"id":"C1","passes":false}]}\n' > "$workspace/test-results.json"
  printf '2\n' > "$workspace/.claude/goal-state/round-budget"
  cat > "$workspace/.claude/goal-state/rounds.json" <<'JSON'
{"rounds":[{"n":1,"verdict":"NEEDS_WORK"},{"n":2,"verdict":"NEEDS_WORK"}]}
JSON
  launcher="$tmp/launcher.sh"
  printf '#!/usr/bin/env bash\n' > "$launcher"
  chmod +x "$launcher"
  cat > "$tmp/sessions/active.jsonl" <<EOF
{"session_id":"rb","agent":"verify","channel":"0","goal":"rb","started_at":"2026-01-01T00:00:00Z","workspace":"$workspace","launcher":"$launcher"}
EOF
  # Set --max-rounds 99 to prove the workspace round-budget=2 takes precedence.
  "$PLUGIN_DIR/scripts/goal-watchdog.py" --active-file "$tmp/sessions/active.jsonl" --kick --max-rounds 99 --json > "$tmp/out.json" 2>/dev/null
  grep -q 'max-rounds-escalated' "$tmp/out.json" || return 1
  grep -q '"effective_max": 2' "$tmp/out.json"
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
  # Accept the v0.4 four-stage flow OR the v0.3 three-stage flow.
  grep -Eq 'planner -> (contract-reviewer -> )?generator -> evaluator' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'QA_REPORT.md' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'contract-reviewer' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'playwright-mcp/round-' "$PLUGIN_DIR/README.md" || return 1
  grep -q 'computer-use/round-' "$PLUGIN_DIR/README.md"
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
check "new scripts executable" check_new_scripts_executable
check ".mcp.json valid with playwright wired" check_mcp_json_valid
check "contract-reviewer agent present with verdict tokens" check_contract_reviewer_agent
check "desktop rubric present with computer-use evidence contract" check_desktop_rubric_present
check "evaluator reads calibration + interaction trace paths" check_evaluator_reads_calibration
check "planner honors pinned rubric + contract-review handshake" check_planner_honors_pinned_rubric
check "heartbeat blocks PASS without interaction evidence (frontend)" check_heartbeat_blocks_missing_interaction_evidence
check "heartbeat allows PASS with Playwright trace" check_heartbeat_accepts_playwright_trace
check "heartbeat allows PASS with computer-use session" check_heartbeat_accepts_computer_use_session
check "heartbeat always escalates (writes ESCALATION.md) at runaway cap" check_heartbeat_always_escalates
check "register-goal --rubric pins and seeds round-1" check_register_goal_rubric_flag
check "register-goal rejects unknown rubric" check_register_goal_rejects_bad_rubric
check "calibrate-evaluator records operator override" check_calibrate_evaluator_records_override
check "calibrate-evaluator skips when verdicts already match" check_calibrate_evaluator_rejects_match
check "run-contract-review handles missing plan" check_run_contract_review_handles_missing_plan
check "run-contract-review --dry-run reports invocation" check_run_contract_review_dry_run
check "run-evaluator --dry-run reports invocation" check_run_evaluator_dry_run
check "diff-rounds prints round comparison" check_diff_rounds_smoke
check "bench pilot present and well-formed" check_bench_pilot_present
check "bench-score compares two score files" check_bench_score_handles_inputs
check "session-start surfaces calibration + pinned rubric" check_session_start_surfaces_calibration
check "rounds.json stamps model, rubric, and codex_model" check_rounds_json_stamps_model_and_rubric
check "watchdog honors workspace round-budget file" check_watchdog_respects_round_budget_file

exit "$failures"
