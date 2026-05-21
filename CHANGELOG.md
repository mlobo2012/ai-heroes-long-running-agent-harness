# Changelog

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
