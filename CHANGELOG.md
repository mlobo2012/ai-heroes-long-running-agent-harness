# Changelog

## 0.14.0 — 2026-05-22

Heartbeat-during-spawn coverage for long Codex executor runs.

- Added the `spawn-active` heartbeat source so `codex-spawn.sh` keeps
  `.claude/goal-state/last-beat` fresh while Codex is still running, plus
  dashboard source reporting and Discord launcher plugin-wiring audit coverage.

## 0.13.0 — 2026-05-22

Final gate documentation and install sync. Closes the Sprint 1 parity rollup,
Sprint 15 README honesty audit, and Sprint 17 repo/install sync items.

- Added `docs/parity-decisions.md`, the exhaustive current-state rollup for all
  37 parity-matrix rows plus B1-B10 and D1-D14 follow-on gaps.
- Added a README "Capabilities and where they are tested" section mapping
  operational claims to integration tests, verify-install checks, or explicit
  soft-boundary disclosures.
- Added `scripts/sync-to-install.sh`, an idempotent package-file mirror from
  the workspace into `~/.claude/plugins/discord-long-running-harness`.
- Added `scripts/audit-readme.sh` for README local-link and claim-surface
  checks.
- Extended `scripts/verify-install.sh` with final-gate checks for the parity
  decisions rollup, sync script, and README capability map.

`.claude-plugin/plugin.json` bumped to `0.13.0`.

## 0.12.0 — 2026-05-22

Rubric templates, reversible state edits, and synthetic soak coverage. Closes
the Sprint 11 rubric item, Sprint 15 reversibility item, and Sprint 16 soak
test item.

- Added `agents/rubrics/_template.md` and `agents/rubrics/geo-article.md` so
  strict evaluator briefs can name an optional rubric path and receive
  dimension-by-dimension grading.
- Extended `agents/evaluator-strict.md` to require reading a named rubric path
  before verdict and naming failing dimensions on `NEEDS_WORK`.
- Added timestamped backup behavior to `scripts/register-goal.sh` and
  `scripts/supervisor-runner.sh`, and made `bin/enable-for-launcher.sh`
  backup names script-specific.
- Expanded README Reversibility docs with each modification path and rollback
  command.
- Added `tests/soak/soak.sh`, a seconds-fast synthetic six-hour supervisor
  scenario with one injected minute-90 hang, one stall alert, and one
  completion trim.
- `scripts/verify-install.sh` now checks rubric files, reversibility docs, and
  the synthetic soak test.

`.claude-plugin/plugin.json` bumped to `0.12.0`.

## 0.11.0 — 2026-05-22

Workspace bootstrap and live-goal observability. Closes the Sprint 10
initializer/planner items and Sprint 13 session-ledger/observability items.

- Added `scripts/init-workspace.sh`, an idempotent workspace initializer that
  seeds `PROGRESS.md`, `test-results.json`, `STEER.md`, `.claude/goal-state/`,
  and an initial clean-worktree git commit.
- Added optional `agents/planner.md` for orchestrators that want to expand a
  one-line goal into `BUILD_PLAN.md` plus default-fail `test-results.json`
  rows before implementation starts.
- Extended `hooks/heartbeat-stop.sh` with a best-effort
  `.claude/goal-state/sessions.jsonl` append on terminal Stop paths.
- Added `docs/observability.md` with a four-pane `watch -n 2` / `tail -F`
  tmux layout for live goal monitoring.
- Added unit coverage for workspace seeding and session-ledger append, and
  expanded `scripts/verify-install.sh` with bootstrap/ledger checks.

`.claude-plugin/plugin.json` bumped to `0.11.0`.

## 0.10.0 — 2026-05-22

Benchmarks and goal-complete cost telemetry. Closes the Sprint 11 benchmark
and Sprint 12 cost-transparency items.

- Added `docs/benchmarks.md` with stall-detection latency, sprint throughput,
  and evidence-gate enforcement snapshots for the current harness session.
- Added `scripts/benchmark-collect.sh`, a reusable JSON collector for Codex
  sprint log timings, heartbeat-stop intervals, and evidence-read counts.
- Extended `hooks/discord-notify.sh` goal-complete notifications with
  best-effort Claude session usage totals and an estimated USD cost.
- Added unit coverage for benchmark collection and Discord cost telemetry.
- `scripts/verify-install.sh` now checks that the benchmark docs exist and
  the collector is executable.

`.claude-plugin/plugin.json` bumped to `0.10.0`.

## 0.9.0 — 2026-05-22

Scope policies for completion semantics. Closes the S18 scope-policy sprint.

- Added optional top-level `scope_policy` semantics for `test-results.json`:
  missing means `fixed_scope`, `production_hardening` gates completion on the
  blocker ledger, and `research_only` records blockers without blocking.
- Added `.claude/goal-state/blockers.jsonl` tooling through
  `scripts/blocker-record.sh` and `scripts/blocker-update.sh`, with
  append-only latest-wins updates and schema validation.
- Extended `hooks/heartbeat-stop.sh` to write
  `.claude/goal-state/blocker-gate.json` snapshots and block
  `production_hardening` completion when blockers are open or triaged without
  evidence.
- Updated evaluator and Codex executor agent contracts to name the
  production-hardening blocker rule.
- Added six scope-policy lifecycle tests, user-facing docs, and a reference
  production-hardening sprint brief.

`.claude-plugin/plugin.json` bumped to `0.9.0`.

## 0.8.0 — 2026-05-22

Outer-pulse supervisor fixture coverage. Closes the S7 stall-detection and
completion-trim test items.

- Added `scripts/supervisor-runner.sh`, a deterministic implementation of the
  OpenClaw `HEARTBEAT.md` active-ledger protocol with synthetic-state env
  overrides, JSONL recovery/completion logs, atomic completion trimming, and
  Discord webhook retry behavior.
- Added `tests/outer-pulse/stall-detection.sh` and
  `tests/outer-pulse/completion-trim.sh` so CI and community installs can
  validate the outer pulse without running the actual OpenClaw Codex agent.
- `scripts/verify-install.sh` now checks that the runner is executable and the
  outer-pulse fixture tests are present.

`.claude-plugin/plugin.json` bumped to `0.8.0`.

## 0.7.0 — 2026-05-22

Sprint 8 hardening pass. Closes S4, S9, and S14.

- **`hooks/discord-notify.sh` now does real webhook delivery with retry,
  exponential backoff, and dead-letter logging.** Live notifications remain
  gated by `DISCORD_NOTIFY_WEBHOOK`; without it, the hook writes the local
  `.claude/goal-state/discord-notify.log` line only. Failed webhook payloads
  after `DISCORD_NOTIFY_MAX_ATTEMPTS` land in
  `.claude/goal-state/discord-notify-deadletter.log`.
- **The 8-block stop behavior is documented as the harness's own
  anti-runaway cap.** The cap remains 8 consecutive `Stop` blocks; the next
  `Stop` allows and logs `anti-runaway-cap`, while `SubagentStop` does not
  increment the counter.
- **Added `hooks/user-prompt-submit.sh` and wired `UserPromptSubmit`.** When
  `STEER.md` is non-empty, the hook surfaces it as additional model context,
  capped at 8KB with a truncation note.
- Added unit coverage for discord notify retry/dead-letter behavior, the
  eight-block anti-runaway cap, and UserPromptSubmit STEER surfacing.

`.claude-plugin/plugin.json` bumped to `0.7.0`.

## 0.4.0 — 2026-05-22

Hooks hardening pass. Closes parity-matrix traps D1, D7, D8, D10, and D14.

- **`hooks/steer.sh` writes the `.claude/goal-state/steered-this-turn`
  marker.** Heartbeat-stop's STEER counter-reset is no longer dependent on
  hook ordering — even when steer.sh fires earlier in the turn and empties
  STEER.md before Stop, the marker survives so the inner pulse resets the
  block counter. Closes Trap D14. Also fixed default path: now
  `${WORKDIR:-$PWD}/STEER.md` instead of `./STEER.md` so it matches
  heartbeat-stop's workspace-rooted convention.
- **`hooks/kill-switch.sh` defaults to `${WORKDIR:-$PWD}/AGENT_STOP`** so
  the kill switch fires consistently when the agent's cwd has drifted
  into a subdirectory. Previously kill-switch looked for `./AGENT_STOP`
  (cwd-relative) while heartbeat-stop looked for `$WORKDIR/AGENT_STOP`
  (workspace-absolute), causing the two pulses to diverge on operator
  intent. Closes Trap D1.
- **`hooks/heartbeat-stop.sh` and `hooks/discord-notify.sh` count
  `"passes"` booleans via jq with an anchored-regex fallback.** Schema-
  robust — a future `"prior_passes"` or `"sub_passes"` key will no longer
  pollute the counts. The fallback regex requires a key-position character
  (`{`, comma, or whitespace) immediately before `"passes"` so substring
  matches inside a longer key cannot occur. Closes Trap D7. Verified by
  test against `{"items":[{"passes":true,"prior_passes":false}]}` —
  reports 1 true, 0 false (not 1 true, 1 false).
- **`scripts/register-goal.sh` deduplicates `active.jsonl` by workspace.**
  Re-registering a goal for the same workspace replaces the prior line
  instead of appending a duplicate, so the outer pulse sees one canonical
  session per workspace. Different workspaces still append a new line.
  Held under the same `flock` / `fcntl.flock` as before. Closes Trap D8.
- **README troubleshooting documents codex-spawn exit code 5** (empty
  sprint prompt) alongside 2/3/4. Closes Trap D10. (Already landed in
  0.3.0; re-asserted here to keep CHANGELOG honest.)
- **`hooks/heartbeat-stop.sh` snapshot includes `hook_event_name`.** No
  behavior change beyond the D2 fix; surfaces the event in the
  `last-beat-state.json` snapshot so the outer pulse can tell whether the
  last heartbeat was a real Stop or a SubagentStop tick.

`.claude-plugin/plugin.json` bumped to `0.4.0`.

## 0.3.0 — 2026-05-22

Install honesty pass. Closes parity-matrix traps D2, D3, D5, and D11.

- **`hooks/heartbeat-stop.sh` distinguishes `Stop` from `SubagentStop`.**
  The inner pulse now parses `hook_event_name` from the hook payload. On
  `SubagentStop`, it writes `last-beat` + state snapshot (so the outer
  pulse keeps seeing fresh heartbeats) and exits 0 — does NOT increment
  the block counter or run the goal-met check. Only `Stop` (real turn
  boundary) runs the full Default-FAIL contract. Without this fix a
  20-tool-use subagent could exhaust the 8-block cap in seconds and the
  evaluator agent would never get to produce a verdict (closes trap D2).
  Unit-tested with synthetic Stop / SubagentStop payloads.
- **`hooks/heartbeat-stop.sh` honors a steer marker.** `steer.sh` writes
  `.claude/goal-state/steered-this-turn` when it consumes STEER.md;
  heartbeat-stop resets the block counter if the marker exists even when
  STEER.md is empty by Stop time (closes trap D14, but the marker write
  in steer.sh ships in 0.4.0).
- **`scripts/verify-install.sh` now has `--scope core|setup|all`.** Community
  installs run `--scope core` (11 universal checks) and get exit 0 without
  OpenClaw or Marco's specific Discord launchers. `--scope setup` covers
  the AI Heroes outer-pulse + launcher layout (6 checks). `--scope all`
  (default) runs both. Closes trap D5 (the script was previously Marco-
  specific without disclosure).
- **`docs/openclaw-supervisor/` now ships the supervisor reference.** Four
  files: `README.md` (install + tuning), `HEARTBEAT.md` (the supervisor
  behavior contract), `openclaw.json.example` (the agent entry to merge),
  and `workspace-README.md` (the README that lives in the supervisor
  workspace). README §"Optional: enable the outer pulse" now points at
  these and shows the exact copy commands. Closes trap D11 — the README
  reference to `docs/openclaw-supervisor/` is no longer a dead link.
- **Repo `settings.json` removed.** Was dead code masquerading as the
  canonical hook manifest. Claude Code loads the plugin via
  `--plugin-dir`, which reads `hooks/hooks.json`. The root `settings.json`
  was never loaded. README §Components updated. Closes trap D3.
- **`hooks/heartbeat-stop.sh` snapshot now includes `hook_event_name`** so
  the supervisor can see whether the last heartbeat was a real Stop or a
  SubagentStop tick.

## 0.2.0 — 2026-05-22

Repo now reflects the working installed plugin shape. Previous public install
instructions produced a worse harness than what AI Heroes actually runs in
production — closed that gap.

- Added `hooks/hooks.json` — the canonical Claude Code plugin hook manifest.
  This is what `--plugin-dir <path>` actually loads. `settings.json` at the
  repo root is retained for backward compatibility with older Claude Code
  installs but is no longer the primary wiring.
- `bin/enable-for-launcher.sh` now writes `--plugin-dir <abs-path>` instead
  of the obsolete `--plugin <name>` form. Refuses to roll forward if the
  plugin dir is missing. Threads `DISCORD_WORKER_PLUGIN_DIRS=<plugin-dir>`
  through `exec env ... claude` for Discord-router launchers so spawned
  workers inherit the plugin too. Migrates existing legacy `--plugin
  discord-long-running-harness` flags in place.
- `scripts/verify-install.sh` expanded from 13 checks to 17 PASS checks:
  - `claude plugin validate` schema pass on the manifest.
  - `hooks/hooks.json` discoverable and every required hook command
    resolves under `${CLAUDE_PLUGIN_ROOT}`.
  - `claude --help` advertises `--plugin-dir <path>`.
  - No launcher uses the obsolete `--plugin` flag (covers `klaus`,
    `richard`, `ted-mosby`).
  - Discord-router launchers thread `DISCORD_WORKER_PLUGIN_DIRS` through
    to spawned workers.
- `.claude-plugin/plugin.json` bumped to `0.2.0`. Author field switched to
  the object form (`{"name": "..."}`) the plugin schema validator expects.

## 0.1.0 — 2026-05-21

Initial public release.

- Plugin scaffold: CLAUDE.md, settings.json, plugin.json.
- Inner pulse: `heartbeat-stop.sh` on Stop + SubagentStop. Writes `last-beat`, enforces Default-FAIL goal check, respects the harness's 8-block anti-runaway cap, halts on `AGENT_STOP`.
- Operator controls: `kill-switch.sh`, `steer.sh`, `commit-on-stop.sh` (all vendored from `anthropics/cwc-long-running-agents`).
- Evidence gating: `track-read.sh` (PreToolUse Read), `verify-gate.sh` (PreToolUse Write|Edit). Vendored.
- Codex executor: `bin/codex-spawn.sh` reads `~/.claude/codex-current-model.env`, rejects `gpt-5.5-codex` and `gpt-5.4`, runs `codex exec -m gpt-5.5 -c model_reasoning_effort=xhigh --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check`.
- Sprint subagent: `agents/codex-executor.md`.
- Fresh-context grader: `agents/evaluator.md` (vendored).
- Active-session ledger: `~/.claude/goal-sessions/active.jsonl`.
- Registration: `scripts/register-goal.sh` — appends ledger line, seeds workspace goal state, prints `/goal` kick command.
- Rollout: `bin/enable-for-launcher.sh` — dry-run by default, backs up launcher before edit.
- Verification: `scripts/verify-install.sh` — 13 PASS checks.
- Discord notify: `hooks/discord-notify.sh` — logs to disk; POSTs when `DISCORD_NOTIFY_WEBHOOK` is set.
- OpenClaw outer pulse: 15-minute `goal-supervisor` heartbeat reads the active-session ledger, alerts on stalls (>20m), posts completion notifications, trims the ledger.
