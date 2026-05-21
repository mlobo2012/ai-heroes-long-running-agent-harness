# Changelog

## 0.3.0 - 2026-05-21

Klaus-review parity + 150% performance pass against Anthropic's March 2026
harness-design article and `anthropics/cwc-long-running-agents`.

- Added `agents/rubrics/{frontend,api,library,data-pipeline}.md` — the
  four-axis rubric library (design quality / originality / craft /
  functionality, plus task-appropriate equivalents). Planner now picks
  one and copies it verbatim into `BUILD_PLAN.md`.
- Hardened `agents/evaluator.md` with mandatory Playwright MCP for UI
  tasks, explicit 0–5 score anchors, and few-shot calibration examples
  so verdicts are consistent run-to-run.
- Added `hooks/verify-gate-bash.sh` to close the upstream Bash bypass:
  `sed -i`, `jq … > test-results.json`, redirected python/node writes
  to the results file are now caught at PreToolUse.
- Extended `hooks/verify-gate.sh` to per-criterion enforcement when
  `test-results.json` uses the new `criteria` array with
  `evidence_paths`. Each criterion's flip from false to true requires
  that criterion's evidence file to have been Read.
- Added `hooks/session-start.sh` to re-seed the agent with acceptance
  contract, last QA verdict + open NEEDS_WORK items, recent commits,
  recent PROGRESS.md, and the status of `init.sh` on every new session.
- Added `hooks/pre-compact.sh` to snapshot the contract state into
  `.claude/goal-state/post-compact-orientation.md` before context
  compaction (context-anxiety mitigation per March 2026 article).
- `hooks/heartbeat-stop.sh` now appends a per-round entry to
  `.claude/goal-state/rounds.json` so the watchdog can enforce a
  round budget.
- `scripts/goal-watchdog.py` gains `--kick` and `--max-rounds`. When
  `QA_REPORT.md` ends NEEDS_WORK and the last beat is fresh, the
  watchdog launches the next build round via the registered launcher.
  Beyond `--max-rounds` it writes `ESCALATION.md` and notifies.
- `scripts/register-goal.sh` now seeds `PROGRESS.md` and `init.sh`
  alongside `BUILD_PLAN.md`, closing the November 2025 article's
  primitives gap.
- `agents/codex-executor.md` no longer hardcodes `/Users/marco/...`.
  It uses `$HOME/.claude/plugins/...` as the last fallback and fails
  loud if no harness root resolves.
- `settings.json` wires the new `SessionStart`, `PreCompact`, and
  Bash-matcher hooks.
- `scripts/verify-install.sh` expanded from 17 to 29 PASS checks
  covering every new primitive end-to-end (per-criterion gate,
  Bash bypass, session-start orientation, pre-compact snapshot,
  rounds telemetry, watchdog `--kick`, register-goal seeding).
- README and CLAUDE.md restructured around the four-axis rubric,
  active outer driver, context-anxiety hooks, and explicit
  downscoping of the Discord claim to webhook-only one-way.

## 0.2.0 - 2026-05-21

March 2026 harness alignment.

- Added `agents/planner.md` so goals become `BUILD_PLAN.md`, acceptance criteria, evidence requirements, and evaluator rubrics before implementation.
- Updated `agents/evaluator.md` to write `QA_REPORT.md` with a required first-line `PASS` or `NEEDS_WORK` verdict.
- Changed `heartbeat-stop.sh` so final completion requires green `test-results.json` and `QA_REPORT.md` starting with `PASS`.
- Updated `goal-watchdog.py` and `discord-notify.sh` so completed sessions are only pruned/reported after evaluator PASS.
- Updated `register-goal.sh` to seed `BUILD_PLAN.md` and print a `/goal` condition that requires planner, results, and evaluator output.
- Reframed README around planner -> generator -> evaluator. Sprint mode is now optional, not the core architecture.
- Expanded `verify-install.sh` to test planner/evaluator presence, evaluator-gated heartbeat completion, watchdog pruning, and BUILD_PLAN seeding.

## 0.1.1 - 2026-05-21

Public watchdog release.

- Added `scripts/goal-watchdog.py`, a standalone outer-pulse watchdog for users who do not run OpenClaw.
- The watchdog reads `~/.claude/goal-sessions/active.jsonl`, detects stale `.claude/goal-state/last-beat` files, writes recovery notes to `STEER.md`, optionally posts webhook alerts, and prunes completed sessions.
- README now explains the two outer-pulse options: standalone watchdog as the public default, OpenClaw supervisor as the native adapter for OpenClaw users.
- `verify-install.sh` no longer requires OpenClaw for the base public install check.

## 0.1.0 — 2026-05-21

Initial public release.

- Plugin scaffold: CLAUDE.md, settings.json, plugin.json.
- Inner pulse: `heartbeat-stop.sh` on Stop + SubagentStop. Writes `last-beat`, enforces Default-FAIL goal check, respects Anthropic's 8-block cap, halts on `AGENT_STOP`.
- Operator controls: `kill-switch.sh`, `steer.sh`, `commit-on-stop.sh` (all vendored from `anthropics/cwc-long-running-agents`).
- Evidence gating: `track-read.sh` (PreToolUse Read), `verify-gate.sh` (PreToolUse Write|Edit). Vendored.
- Codex executor: `bin/codex-spawn.sh` reads `~/.claude/codex-current-model.env`, rejects `gpt-5.5-codex` and `gpt-5.4`, runs `codex exec -m gpt-5.5 -c model_reasoning_effort=xhigh --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check`.
- Sprint subagent: `agents/codex-executor.md`.
- Fresh-context grader: `agents/evaluator.md` (vendored).
- Active-session ledger: `~/.claude/goal-sessions/active.jsonl`.
- Registration: `scripts/register-goal.sh` — appends ledger line, seeds workspace goal state, prints `/goal` kick command.
- Rollout: `bin/enable-for-launcher.sh` — dry-run by default, backs up launcher before edit.
- Verification: `scripts/verify-install.sh` — 13 PASS checks.
- Discord notify: `hooks/discord-notify.sh` — stub today (logs to disk); real POST when `DISCORD_NOTIFY_WEBHOOK` is set.
- OpenClaw outer pulse: 15-minute `goal-supervisor` heartbeat reads the active-session ledger, alerts on stalls (>20m), posts completion notifications, trims the ledger.
