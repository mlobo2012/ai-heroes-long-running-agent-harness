# Changelog

## 0.4.0 - 2026-05-22

Closes the remaining gaps the previous critique surfaced against the
March 2026 article. Replaces the "150% performance pass" rhetoric with
a benchmark rig you can actually run.

### Interaction-evidence enforcement (Playwright MCP + native computer use)

- Added `.mcp.json` wiring `@playwright/mcp` for browser-driven
  evaluation. Trace lands at `playwright-mcp/round-N/trace.zip` via the
  `PLAYWRIGHT_TRACE_DIR` env var.
- Added `agents/rubrics/desktop.md` — a new rubric variant for
  non-browser interactive tasks. Evidence shape:
  `computer-use/round-N/session.jsonl` (append-only action log) plus
  `computer-use/round-N/screenshots/*.png`.
- Updated `agents/rubrics/frontend.md` to accept **either** path. Same
  guardrails for both.
- `hooks/heartbeat-stop.sh` now reads the active rubric from
  `goal-state.json`. For `frontend` or `desktop`, the heartbeat
  **refuses goal-completion** unless a non-empty trace exists under one
  of the two paths. The evaluator can no longer rubber-stamp a UI by
  writing `PASS` without driving it.
- `goal-watchdog.py::goal_is_complete` mirrors the same gate so the
  watchdog never reports a session complete while the inner gate is
  still blocking on interaction-evidence.

### Sprint-contract handshake

- Added `agents/contract-reviewer.md` — a third agent that reviews
  `BUILD_PLAN.md` before the generator starts. Returns `CONTRACT_OK`
  or `CONTRACT_REWRITE` with per-criterion rewrites.
- Added `scripts/run-contract-review.sh` — headless wrapper with
  configurable `--max-rounds` (default 3) and soft-pass-with-
  Concessions when the cap is hit.
- `agents/planner.md` now runs the handshake before returning the plan.

### Unified runaway counter + always-explicit escalation

- `hooks/heartbeat-stop.sh` no longer silently allows after 8 blocks.
  When the cap is hit it writes `ESCALATION.md`, notifies the
  configured webhook, and logs `escalated anti-runaway-cap:...`.
- The cap reads from `.claude/goal-state/round-budget` (set by
  `register-goal --round-budget`). The watchdog `--max-rounds` honors
  the same file via `workspace_round_budget()` so both pulses agree
  on the budget.
- Watchdog escalation now stamps the rubric and model into
  `ESCALATION.md`.

### Evaluator calibration capture

- Added `scripts/calibrate-evaluator.sh` — operator override recorder.
  Writes one JSON line to `.claude/goal-state/evaluator-calibration.jsonl`
  per override with `{at, round, evaluator_verdict, operator_verdict,
  axes_in_dispute, reason, goal_id}`.
- `agents/evaluator.md` now reads the tail of that file on every
  invocation and applies the operator's past corrections.
- `hooks/session-start.sh` surfaces the last 5 calibration entries.

### Per-round artifact namespacing + round diff

- Planner declares `screenshots/round-N/`, `evidence/round-N/`,
  `playwright-mcp/round-N/`, `computer-use/round-N/` paths so old
  evidence cannot masquerade as fresh.
- `scripts/diff-rounds.sh` produces a markdown diff between any two
  rounds: verdicts, axis scores, criterion deltas, artifact counts,
  and a git-stat between the rounds' recorded commit shas.

### Pinned rubric + model identity stamping

- `scripts/register-goal.sh` accepts `--rubric`, `--model`,
  `--codex-model`, and `--round-budget`. All four land in
  `goal-state.json` and (for round-budget) in a dedicated file the
  heartbeat hook reads.
- `agents/planner.md` honors the pinned rubric instead of picking
  freely. Rejects rubric drift mid-run.
- `hooks/heartbeat-stop.sh::append_round` now stamps `rubric`, `model`,
  `codex_model`, `evidence_count`, and best-effort `axis_scores` into
  every `rounds.json` entry. "Re-simplify on upgrade" finally has the
  data it needs.

### Headless entry points + worktree isolation

- Added `scripts/run-evaluator.sh` — runs the evaluator subagent
  headless so CI/cron can mirror the harness's PASS gate. Supports
  `--isolated` to evaluate in a `git worktree` so the evaluator cannot
  mutate the builder's working tree. Exit codes:
  0=PASS, 1=NEEDS_WORK, 3=no report, 4=missing interaction evidence.

### Bench rig

- Added `bench/pilots/express-server/` — small but real pilot covering
  three routes, a 422 path, and four observable acceptance criteria.
- Added `scripts/bench-harness.sh` — runs a pilot end-to-end and
  records wall-clock, rounds-to-pass, false-pass rate, and I/O bytes
  to a score JSON.
- Added `scripts/bench-score.py` — diffs two score files (e.g.
  upstream vs this harness) with absolute and percentage deltas.
- The README's "150% performance" claim now has a way to be earned or
  retracted with measurement.

### Verify-install expansion

- `scripts/verify-install.sh` grew from 29 to 48 PASS checks covering:
  .mcp.json, contract-reviewer, desktop rubric, evaluator-calibration
  reading, planner pinned-rubric, heartbeat interaction-evidence gate
  (block + allow paths for both trace shapes), always-explicit
  escalation, register-goal --rubric (accept + reject), calibrate
  capture, headless entry points, diff-rounds, bench rig presence,
  session-start calibration surfacing, rounds.json stamping, and
  watchdog round-budget-file honoring.

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
