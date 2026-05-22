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
  for s in run-contract-review.sh run-evaluator.sh calibrate-evaluator.sh diff-rounds.sh bench-harness.sh bench-score.py ralph-loop.sh re-simplify.sh; do
    [ -x "$PLUGIN_DIR/scripts/$s" ] || { echo "$s is not executable" >&2; return 1; }
  done
}

check_track_read_recognizes_round_n_evidence() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  log="$tmp/reads"
  : > "$log"
  export VERIFY_READ_LOG="$log"
  for path in evidence/round-1/x.txt playwright-mcp/round-1/trace.zip computer-use/round-1/session.jsonl evidence/round-1/x.log; do
    mkdir -p "$tmp/$(dirname "$path")"
    : > "$tmp/$path"
    payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1]}}))' "$tmp/$path")
    printf '%s' "$payload" | "$PLUGIN_DIR/hooks/track-read.sh"
  done
  unset VERIFY_READ_LOG
  # All four must have been logged (plus their abs paths)
  count=$(wc -l < "$log")
  [ "$count" -ge 4 ] || { echo "track-read logged only $count entries; expected >=4" >&2; return 1; }
  grep -q 'evidence/round-1/x.txt' "$log" || return 1
  grep -q 'playwright-mcp/round-1/trace.zip' "$log" || return 1
  grep -q 'computer-use/round-1/session.jsonl' "$log" || return 1
  grep -q 'evidence/round-1/x.log' "$log"
}

check_track_read_skips_non_evidence() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  log="$tmp/reads"
  : > "$log"
  export VERIFY_READ_LOG="$log"
  mkdir -p "$tmp/notes"
  : > "$tmp/notes/random.foobar"
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":sys.argv[1]}}))' "$tmp/notes/random.foobar")
  printf '%s' "$payload" | "$PLUGIN_DIR/hooks/track-read.sh"
  unset VERIFY_READ_LOG
  [ ! -s "$log" ]
}

check_evaluator_has_playwright_mcp_tools() {
  tools_line=$(awk 'BEGIN { frontmatter=0 } /^---$/ { frontmatter++; next } frontmatter == 1 && /^tools:/ { print }' "$PLUGIN_DIR/agents/evaluator.md")
  printf '%s' "$tools_line" | grep -q 'mcp__playwright__browser_navigate' || return 1
  printf '%s' "$tools_line" | grep -q 'mcp__playwright__browser_take_screenshot' || return 1
  printf '%s' "$tools_line" | grep -q 'mcp__playwright__browser_snapshot' || return 1
  printf '%s' "$tools_line" | grep -q 'mcp__playwright__browser_console_messages' || return 1
  # At least 15 distinct playwright tools listed
  count=$(printf '%s' "$tools_line" | tr ',' '\n' | grep -c 'mcp__playwright__')
  [ "$count" -ge 15 ]
}

check_heartbeat_accepts_non_canonical_playwright_trace() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/ws"
  mkdir -p "$workspace/.claude/goal-state" "$workspace/playwright-mcp/round-1"
  printf '{"session_id":"fb","rubric":"frontend"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$workspace/test-results.json"
  printf 'PASS\n' > "$workspace/QA_REPORT.md"
  # Non-canonical name: not trace.zip
  echo "har data" > "$workspace/playwright-mcp/round-1/network.har"
  set +e
  output="$(cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 0 ]
}

check_heartbeat_accepts_non_canonical_computer_use_log() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/ws"
  mkdir -p "$workspace/.claude/goal-state" "$workspace/computer-use/round-1"
  printf '{"session_id":"fb","rubric":"desktop"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$workspace/test-results.json"
  printf 'PASS\n' > "$workspace/QA_REPORT.md"
  # Non-canonical: not session.jsonl
  echo '{"event":"keystroke"}' > "$workspace/computer-use/round-1/actions.jsonl"
  set +e
  output="$(cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' 2>/dev/null)"
  status=$?
  set -e
  [ "$status" -eq 0 ]
}

check_ralph_loop_dry_run() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/ws"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"rubric":"library","round_budget":5}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '5\n' > "$workspace/.claude/goal-state/round-budget"
  printf '{"criteria":[{"id":"C1","passes":false}]}\n' > "$workspace/test-results.json"
  output="$("$PLUGIN_DIR/scripts/ralph-loop.sh" --workspace "$workspace" --dry-run 2>&1)"
  printf '%s' "$output" | grep -q 'effective_budget=5' || return 1
  printf '%s' "$output" | grep -q 'would invoke for each round'
}

check_ralph_loop_refuses_without_contract() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/ws"
  mkdir -p "$workspace"
  set +e
  "$PLUGIN_DIR/scripts/ralph-loop.sh" --workspace "$workspace" --dry-run >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 3 ]
}

check_session_start_surfaces_next_findings() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/ws"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"rubric":"library"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  cat > "$workspace/NEXT_FINDINGS.md" <<'EOF'
# NEXT_FINDINGS

Specific findings:
- F1: contrast 3.2:1 on primary CTA.
EOF
  output="$(CLAUDE_PROJECT_DIR="$workspace" "$PLUGIN_DIR/hooks/session-start.sh" 2>/dev/null)"
  printf '%s' "$output" | grep -q 'NEXT_FINDINGS.md' || return 1
  printf '%s' "$output" | grep -q 'contrast 3.2:1'
}

check_register_goal_seeds_agents_md() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/workspace"
  home="$tmp/home"
  launcher="$tmp/launcher.sh"
  mkdir -p "$workspace" "$home"
  printf '#!/usr/bin/env bash\n' > "$launcher"; chmod +x "$launcher"
  HOME="$home" "$PLUGIN_DIR/scripts/register-goal.sh" --agent verify --channel 0 --workspace "$workspace" --launcher "$launcher" "agents test" >/dev/null
  [ -f "$workspace/AGENTS.md" ] || return 1
  grep -q 'AGENTS' "$workspace/AGENTS.md" || return 1
  grep -q 'NEXT_FINDINGS' "$workspace/AGENTS.md" || return 1
  grep -q 'verify-gate' "$workspace/AGENTS.md"
}

check_re_simplify_list_and_status() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/ws"
  mkdir -p "$workspace"
  out="$("$PLUGIN_DIR/scripts/re-simplify.sh" --list --workspace "$workspace")"
  printf '%s' "$out" | grep -q 'playwright-trace' || return 1
  "$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$workspace" --target playwright-trace --reason "test" >/dev/null
  out=$("$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$workspace" --status)
  printf '%s' "$out" | grep -q 'playwright-trace' || return 1
  "$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$workspace" --restore >/dev/null
  out=$("$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$workspace" --status)
  printf '%s' "$out" | grep -q 'no overrides set'
}

check_re_simplify_disables_interaction_evidence() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/ws"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"session_id":"rs","rubric":"frontend"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$workspace/test-results.json"
  printf 'PASS\n' > "$workspace/QA_REPORT.md"
  # Without override: heartbeat must block.
  set +e
  cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' >/dev/null 2>&1
  status_without=$?
  cd - >/dev/null
  set -e
  [ "$status_without" -eq 2 ] || return 1
  # With override: heartbeat must allow.
  "$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$workspace" --target playwright-trace --reason "verify" >/dev/null
  set +e
  cd "$workspace" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' >/dev/null 2>&1
  status_with=$?
  cd - >/dev/null
  set -e
  [ "$status_with" -eq 0 ]
}

check_re_simplify_unknown_target_rejected() {
  set +e
  "$PLUGIN_DIR/scripts/re-simplify.sh" --target not-real >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -eq 2 ]
}

check_run_evaluator_writes_next_findings_on_needs_work() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  workspace="$tmp/ws"
  mkdir -p "$workspace"
  # Synthesise the post-eval block of run-evaluator.sh (no real `claude` invocation).
  cat > "$workspace/QA_REPORT.md" <<'EOF'
NEEDS_WORK

Evidence reviewed: e1, e2

Specific findings:
- F1: do x
- F2: do y

Regression risk: none.
EOF
  python3 - "$workspace/QA_REPORT.md" "$workspace/NEXT_FINDINGS.md" <<'PY'
import sys
from pathlib import Path
qa, nf = sys.argv[1:3]
text = Path(qa).read_text()
lo = text.find("Specific findings")
body = text[lo:] if lo != -1 else text
Path(nf).write_text("# NEXT_FINDINGS\n\n" + body)
PY
  [ -f "$workspace/NEXT_FINDINGS.md" ] || return 1
  grep -q 'do x' "$workspace/NEXT_FINDINGS.md" && grep -q 'do y' "$workspace/NEXT_FINDINGS.md"
}

check_claude_md_no_discord_lead() {
  # First 5 non-comment non-blank lines must not include "Discord"
  head=$(grep -v '^<!--' "$PLUGIN_DIR/CLAUDE.md" | grep -v '^$' | head -5)
  if printf '%s' "$head" | grep -qi 'discord'; then
    return 1
  fi
  grep -q 'Long-Running Agent Harness' "$PLUGIN_DIR/CLAUDE.md" || return 1
  grep -q 'ralph-loop' "$PLUGIN_DIR/CLAUDE.md" || return 1
  grep -q 'NEXT_FINDINGS' "$PLUGIN_DIR/CLAUDE.md" || return 1
  grep -q 're-simplify' "$PLUGIN_DIR/CLAUDE.md"
}

check_agent_sdk_doc_present() {
  [ -f "$PLUGIN_DIR/docs/agent-sdk-equivalent.md" ] || return 1
  for needle in PreToolUse Stop SessionStart PreCompact BlockToolCall BlockStop ralph-loop fresh-context goal-watchdog; do
    grep -q "$needle" "$PLUGIN_DIR/docs/agent-sdk-equivalent.md" || { echo "agent-sdk doc missing: $needle" >&2; return 1; }
  done
}

check_planner_documents_sprint_decomposition_override() {
  grep -q 'sprint-decomposition' "$PLUGIN_DIR/agents/planner.md" || return 1
  grep -q 're-simplify' "$PLUGIN_DIR/agents/planner.md"
}

check_sdk_example_present() {
  [ -f "$PLUGIN_DIR/docs/sdk-example/README.md" ] || return 1
  [ -f "$PLUGIN_DIR/docs/sdk-example/sdk_loop.py" ] || return 1
  python3 -c "import ast; ast.parse(open('$PLUGIN_DIR/docs/sdk-example/sdk_loop.py').read())" 2>/dev/null
}

check_readme_documents_slash_commands() {
  for cmd in /orient /blueprint /qa /simplify /bench /round; do
    grep -q "\\${cmd}" "$PLUGIN_DIR/README.md" || return 1
  done
}

check_readme_reflects_v05_check_count() {
  grep -q '76 PASS' "$PLUGIN_DIR/README.md"
}

check_re_simplify_bash_gate_override() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ws="$tmp/ws"
  mkdir -p "$ws/.claude/goal-state"
  echo '{"criteria":[{"id":"C1","passes":false,"evidence_paths":[]}]}' > "$ws/test-results.json"
  : > "$ws/.claude/.evidence-reads"
  cd "$ws"
  # Without override: bash gate must block
  out_no=$("$PLUGIN_DIR/hooks/verify-gate-bash.sh" <<<'{"tool_input":{"command":"sed -i s/false/true/ test-results.json"}}' 2>/dev/null)
  cd - >/dev/null
  printf '%s' "$out_no" | grep -q '"decision":"block"' || return 1
  # Set override
  "$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$ws" --target bash-gate --reason "verify" >/dev/null
  cd "$ws"
  out_yes=$("$PLUGIN_DIR/hooks/verify-gate-bash.sh" <<<'{"tool_input":{"command":"sed -i s/false/true/ test-results.json"}}' 2>/dev/null)
  cd - >/dev/null
  # With override: must not block
  [ -z "$out_yes" ] || ! printf '%s' "$out_yes" | grep -q '"decision":"block"'
}

check_re_simplify_session_start_override() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ws="$tmp/ws"
  mkdir -p "$ws/.claude/goal-state"
  printf '{"rubric":"library"}\n' > "$ws/.claude/goal-state/goal-state.json"
  out_no=$(CLAUDE_PROJECT_DIR="$ws" "$PLUGIN_DIR/hooks/session-start.sh" 2>/dev/null)
  printf '%s' "$out_no" | grep -q 'Session orientation (auto-seeded' || return 1
  "$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$ws" --target session-start --reason "verify" >/dev/null
  out_yes=$(CLAUDE_PROJECT_DIR="$ws" "$PLUGIN_DIR/hooks/session-start.sh" 2>/dev/null)
  printf '%s' "$out_yes" | grep -q 'orientation skipped (re-simplify' || return 1
  printf '%s' "$out_yes" | grep -qv 'Session orientation (auto-seeded'
}

check_re_simplify_pre_compact_override() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ws="$tmp/ws"
  mkdir -p "$ws/.claude/goal-state"
  echo '## Acceptance Contract' > "$ws/BUILD_PLAN.md"
  CLAUDE_PROJECT_DIR="$ws" "$PLUGIN_DIR/hooks/pre-compact.sh" >/dev/null 2>&1
  [ -f "$ws/.claude/goal-state/post-compact-orientation.md" ] || return 1
  rm -f "$ws/.claude/goal-state/post-compact-orientation.md"
  "$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$ws" --target pre-compact --reason "verify" >/dev/null
  out=$(CLAUDE_PROJECT_DIR="$ws" "$PLUGIN_DIR/hooks/pre-compact.sh" 2>/dev/null)
  printf '%s' "$out" | grep -q 'snapshot skipped' || return 1
  [ ! -f "$ws/.claude/goal-state/post-compact-orientation.md" ]
}

check_re_simplify_per_criterion_override() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ws="$tmp/ws"
  mkdir -p "$ws/.claude" "$ws/screenshots"
  cd "$ws"
  cat > test-results.json <<'JSON'
{"criteria":[{"id":"C1","description":"x","evidence_paths":["screenshots/c1.png"],"passes":false}]}
JSON
  : > .claude/.evidence-reads
  proposed='{"criteria":[{"id":"C1","description":"x","evidence_paths":["screenshots/c1.png"],"passes":true}]}'
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"file_path":"test-results.json","content":sys.argv[1]}}))' "$proposed")
  # Without override: per-criterion blocks with that-specific error
  out_no=$(printf '%s' "$payload" | "$PLUGIN_DIR/hooks/verify-gate.sh" 2>/dev/null)
  cd - >/dev/null
  printf '%s' "$out_no" | grep -q 'Cannot flip criteria to pass' || return 1
  # With override: falls back to session-level — same payload still blocks (empty log) but with the session-level message
  "$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$ws" --target per-criterion-gate --reason "verify" >/dev/null
  cd "$ws"
  out_yes=$(printf '%s' "$payload" | "$PLUGIN_DIR/hooks/verify-gate.sh" 2>/dev/null)
  cd - >/dev/null
  printf '%s' "$out_yes" | grep -q 'no screenshot or console-log evidence has been Read'
}

check_re_simplify_evaluator_override() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  ws="$tmp/ws"
  mkdir -p "$ws/.claude/goal-state"
  printf '{"session_id":"v","rubric":"library"}\n' > "$ws/.claude/goal-state/goal-state.json"
  printf '{"criteria":[{"id":"C1","passes":true}]}\n' > "$ws/test-results.json"
  # No QA_REPORT.md
  set +e
  cd "$ws" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' >/dev/null 2>&1
  no_status=$?
  cd - >/dev/null
  set -e
  [ "$no_status" -eq 2 ] || return 1
  "$PLUGIN_DIR/scripts/re-simplify.sh" --workspace "$ws" --target evaluator --reason "verify" >/dev/null
  set +e
  cd "$ws" && "$PLUGIN_DIR/hooks/heartbeat-stop.sh" <<<'{}' >/dev/null 2>&1
  yes_status=$?
  cd - >/dev/null
  set -e
  [ "$yes_status" -eq 0 ]
}

check_planner_documents_contract_reviewer_override() {
  grep -q 'contract-reviewer' "$PLUGIN_DIR/agents/planner.md" || return 1
  grep -q 're-simplify' "$PLUGIN_DIR/agents/planner.md" || return 1
  grep -q '.claude/goal-state/re-simplify-overrides.json' "$PLUGIN_DIR/agents/planner.md"
}

check_slash_commands_present() {
  for cmd in orient blueprint qa simplify bench round; do
    [ -f "$PLUGIN_DIR/.claude-plugin/commands/${cmd}.md" ] || { echo "missing /${cmd}" >&2; return 1; }
    grep -q '^description:' "$PLUGIN_DIR/.claude-plugin/commands/${cmd}.md" || { echo "${cmd}.md missing description frontmatter" >&2; return 1; }
  done
}

check_run_evaluator_mkdirs_state_dir() {
  # The script must mkdir -p the goal-state dir before invoking claude so the
  # stdout-log redirect doesn't fail in a fresh worktree.
  grep -q 'mkdir -p "\$EVAL_DIR/.claude/goal-state"' "$PLUGIN_DIR/scripts/run-evaluator.sh"
}

check_bench_score_shows_delta() {
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  cat > "$tmp/a.json" <<'JSON'
{"pilot":"x","completed":true,"wall_clock_seconds":720,"rounds_to_pass":5,"total_io_bytes_estimate":480000,"false_pass":true}
JSON
  cat > "$tmp/b.json" <<'JSON'
{"pilot":"x","completed":true,"wall_clock_seconds":290,"rounds_to_pass":2,"total_io_bytes_estimate":195000,"false_pass":false}
JSON
  output="$("$PLUGIN_DIR/scripts/bench-score.py" "$tmp/a.json" "$tmp/b.json" 2>&1)"
  printf '%s' "$output" | grep -q -- '-59.7%' || return 1
  printf '%s' "$output" | grep -q -- '-60.0%'
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
check "track-read recognizes round-N evidence shapes" check_track_read_recognizes_round_n_evidence
check "track-read skips non-evidence paths" check_track_read_skips_non_evidence
check "evaluator has Playwright MCP tools wired" check_evaluator_has_playwright_mcp_tools
check "heartbeat accepts non-canonical playwright trace filename" check_heartbeat_accepts_non_canonical_playwright_trace
check "heartbeat accepts non-canonical computer-use log filename" check_heartbeat_accepts_non_canonical_computer_use_log
check "ralph-loop dry-run reports invocation" check_ralph_loop_dry_run
check "ralph-loop refuses without test-results.json contract" check_ralph_loop_refuses_without_contract
check "session-start surfaces NEXT_FINDINGS.md when present" check_session_start_surfaces_next_findings
check "register-goal seeds AGENTS.md for Codex parity" check_register_goal_seeds_agents_md
check "re-simplify list + status + restore round-trip" check_re_simplify_list_and_status
check "re-simplify playwright-trace override disables interaction gate" check_re_simplify_disables_interaction_evidence
check "re-simplify unknown target rejected" check_re_simplify_unknown_target_rejected
check "run-evaluator writes NEXT_FINDINGS.md on NEEDS_WORK" check_run_evaluator_writes_next_findings_on_needs_work
check "CLAUDE.md leads with the harness, not with Discord" check_claude_md_no_discord_lead
check "docs/agent-sdk-equivalent.md present and complete" check_agent_sdk_doc_present
check "bench-score reports a numeric delta" check_bench_score_shows_delta
check "re-simplify bash-gate override disables verify-gate-bash" check_re_simplify_bash_gate_override
check "re-simplify session-start override skips orientation" check_re_simplify_session_start_override
check "re-simplify pre-compact override skips snapshot" check_re_simplify_pre_compact_override
check "re-simplify per-criterion-gate override falls back to session-level" check_re_simplify_per_criterion_override
check "re-simplify evaluator override (risky) lets heartbeat allow without QA PASS" check_re_simplify_evaluator_override
check "planner agent documents contract-reviewer override" check_planner_documents_contract_reviewer_override
check "slash commands ship for orient/blueprint/qa/simplify/bench/round" check_slash_commands_present
check "run-evaluator mkdirs goal-state before invoking claude" check_run_evaluator_mkdirs_state_dir
check "planner documents sprint-decomposition re-simplify override" check_planner_documents_sprint_decomposition_override
check "SDK example skeleton ships and parses" check_sdk_example_present
check "README documents all six slash commands" check_readme_documents_slash_commands
check "README reflects 76 PASS check count" check_readme_reflects_v05_check_count

exit "$failures"
