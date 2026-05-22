# Parity Decisions

Date: 2026-05-22
Sprint: `s14-final-gate`
Source matrix: `docs/parity-gap-analysis.md`

This file is the release rollup for the historical parity matrix. The matrix is
kept as the original audit record; this file records the current 0.13.0
decision for every row and every follow-on B/D gap.

Status meanings:

- `closed`: the repo now ships the behavior, with a `test-results.json` row and
  commit SHA named here.
- `partial-closed`: the repo ships a bounded implementation and documents the
  remaining soft boundary.
- `deferred`: deliberately not implemented in 0.13.0, with rationale.
- `deliberately-different`: intentionally not identical to upstream because the
  plugin runtime or AI Heroes operating model uses a different boundary.

## Primitive Matrix Rows

| Row | Matrix primitive | Decision | Closing item / commit | Notes |
|---:|---|---|---|---|
| 1 | `/goal` overlay engagement | deliberately-different | `S0_repo_reflects_installed_harness` / `0da52ea`; initial package `91572a4` | `scripts/register-goal.sh` records state and prints the `/goal` command for an operator or agent to paste. We do not auto-invoke the overlay because Claude Code slash-command execution is session UI behavior, not a plugin file operation. |
| 2 | Default-FAIL contract | closed | `S3_verify_gate_per_row_evidence_binding` / `b8487f9`; `S18_scope_policy_field` / `6ad252f` | The inner pulse still terminates on literal `"passes": false`, while `verify-gate.sh` binds passing flips to matching evidence paths. Optional `scope_policy` preserves default behavior when absent. |
| 3 | `test-results.json` shape | partial-closed | `S10_init_workspace_script` / `eaf8c1f`; `S18_scope_policy_field` / `6ad252f` | We deliberately keep a flexible JSON shape rather than enforcing Anthropic's exact `description`/`steps` schema. The initializer seeds a valid default-fail file and README troubleshooting states the literal `"passes": false` contract. |
| 4 | Evidence-gated flips (`verify-gate`) | partial-closed | `S3_verify_gate_per_row_evidence_binding` / `b8487f9`; `S3_verify_gate_bash_disclosure` / `b8487f9` | The upstream Write/Edit gate is retained and tightened with per-row evidence binding. Bash rewrites remain a disclosed shell boundary; strict evaluator removes Bash on grader-side content goals. |
| 5 | `track-read` evidence log | closed | `S3_track_read_recognizes_general_evidence` / `b8487f9` | Evidence reads now cover non-UI work such as result text, JSON, logs, markdown evidence, patches, and images under evidence-oriented paths. |
| 6 | `kill-switch` | closed | `S5_kill_switch_workdir_default` / `0da52ea` | `AGENT_STOP` now resolves through `${WORKDIR:-$PWD}` so a root workspace stop file is honored even when the current directory drifts. |
| 7 | `steer` / `STEER.md` | closed | `S5_steer_counter_reset_marker` / `0da52ea`; `S14_user_prompt_submit_hook` / `acca4bb` | `steer.sh` leaves a one-shot marker so `heartbeat-stop.sh` resets the block counter even after `STEER.md` was consumed earlier in the turn. `UserPromptSubmit` also surfaces non-empty steering notes. |
| 8 | `commit-on-stop` | deliberately-different | `S0_repo_reflects_installed_harness` / `0da52ea`; initial package `91572a4` | We keep the upstream tracked-files-only commit hook. The limitation is accepted because new files are a generator responsibility and the README documents rollback/reversibility paths separately. |
| 9 | Generator/evaluator loop | closed | `S6_generator_evaluator_loop_documented` / `15d136a`; `S6_generator_routes_through_codex_enforced` / `15d136a` | `scripts/build-eval-loop.sh` documents and drives the Codex-then-evaluator path. `verify-gate.sh` partially enforces code-heavy Codex provenance before accepting results-file flips. |
| 10 | Evaluator agent contract | partial-closed | `S6_evaluator_strict_no_bash` / `b8487f9`; `S3_verify_gate_bash_disclosure` / `b8487f9` | The default evaluator remains upstream-compatible with Bash for diffs/logs. The strict evaluator is the hard no-Bash alternative for content/design goals, and README names the soft boundary. |
| 11 | Fresh-context grader | deliberately-different | `S1_parity_matrix_complete` / `0da52ea` | Fresh context is provided by the Claude Code subagent runtime, not by repo code. The final full-diff evaluator invocation remains the orchestrator-owned `S17_final_evaluator_full_diff_pass` item. |
| 12 | 8-block cap | closed | `S9_eight_block_cap_documented_and_correct` / `acca4bb` | The cap is now documented as this harness's anti-runaway cap, not an Anthropic platform claim, and has a regression test. |
| 13 | Subagent context isolation | deliberately-different | `S1_parity_matrix_complete` / `0da52ea` | Isolation is a runtime property of subagent invocation. The repo's contract is to require a fresh-context evaluator verdict before a flip, not to reimplement context isolation. |
| 14 | Sprint/turn structure | partial-closed | `S6_generator_evaluator_loop_documented` / `15d136a`; `S6_generator_routes_through_codex_enforced` / `15d136a` | The repo now has a generator/evaluator handoff and code-heavy provenance signal. A formal sprint-contract negotiation script is deferred because this plugin consumes sprint briefs supplied by the orchestrator. |
| 15 | `Stop` / `SubagentStop` hooks | closed | `D2_subagentstop_does_not_eat_block_counter` / `bc8bd93`; `S9_eight_block_cap_documented_and_correct` / `acca4bb` | Both events write heartbeats, but only real `Stop` events count toward the anti-runaway cap. |
| 16 | Environment / secrets handling | closed | `S0_repo_reflects_installed_harness` / `0da52ea`; `S4_discord_notify_real_post_or_honest_docs` / `acca4bb` | Codex model pinning and Discord webhook opt-in are verified by install checks and notification tests. |
| 17 | `PROGRESS.md` handoff | closed | `S5_session_start_hook_bootstrap` / `b8487f9`; `S10_init_workspace_script` / `eaf8c1f` | `SessionStart` validates required handoff files, and the initializer seeds them for new workspaces. |
| 18 | Agent-maintained handoff | closed | `S0_repo_reflects_installed_harness` / `0da52ea`; initial package `91572a4` | The upstream commit-on-stop convention remains, with README reversibility and session-ledger additions for operational handoff. |
| 19 | `init.sh` / initializer pattern | closed | `S10_init_workspace_script` / `eaf8c1f` | `scripts/init-workspace.sh` seeds `PROGRESS.md`, `test-results.json`, `STEER.md`, goal-state, and a safe initial commit when the worktree is clean. |
| 20 | `claude-progress.txt` / structured progress log | closed | `S13_session_ledger` / `eaf8c1f`; `S13_observability_docs` / `eaf8c1f` | `.claude/goal-state/sessions.jsonl` provides the machine-readable session ledger; `PROGRESS.md` remains the human handoff. |
| 21 | Per-feature one-shot mode | deferred | n/a | We keep one-sprint discipline as an agent contract instead of a hard hook rule. Multi-sprint product goals and production-hardening runs sometimes need related fixes in one turn, so a blanket "one flip only" gate would create false blocks. |
| 22 | Sprint contract negotiation | deferred | n/a | The orchestrator supplies sprint briefs and invokes the evaluator. A repo-local negotiation script would need to spawn fresh evaluator agents, which is outside Codex's final-gate scope and overlaps `S17_final_evaluator_full_diff_pass`. |
| 23 | Browser-verified evaluator | deferred | n/a | The plugin does not ship browser/MCP tool grants. Frontend/browser verification should be run by the orchestrator or project-specific QA tools; this harness records evidence and strict rubrics without assuming browser availability. |
| 24 | Grading rubrics for subjective work | closed | `S11_rubric_template_and_one_concrete` / `34565e5` | The repo ships a rubric template, a GEO article rubric, and strict-evaluator instructions to read a named rubric before verdict. |
| 25 | Planner agent | closed | `S10_planner_agent_optional` / `eaf8c1f` | `agents/planner.md` can expand a one-line goal into `BUILD_PLAN.md` and default-fail result rows when the orchestrator opts in. |
| 26 | Context reset vs compaction | deferred | n/a | Automatic `/clear` or process restart from a plugin hook is unsafe and runtime-specific. The implemented boundary is session-ledger handoff plus observability; operators can restart with state preserved. |
| 27 | Outer pulse / stall detector | closed | `S7_outer_pulse_detects_stall_test` / `d5c7297`; `S7_outer_pulse_trims_completed_test` / `d5c7297`; `S16_soak_test_synthetic` / `34565e5` | The OpenClaw supervisor docs and synthetic runner cover stale heartbeat alerts, completion trimming, and a six-hour synthetic soak. |
| 28 | Pinned Codex executor | closed | `S0_repo_reflects_installed_harness` / `0da52ea`; `S14_codex_spawn_exit_codes_documented` / `0da52ea` | `verify-install.sh` checks the dry-run model, env file, and forbidden model refusals. README documents exit codes 2 through 5. |
| 29 | Active-session ledger | closed | `S2a_verify_install_universal_vs_openclaw_split` / `23a3dfb`; `S5_register_goal_dedupe` / `0da52ea` | The ledger is verified during install and `register-goal.sh` deduplicates by workspace. |
| 30 | Inner pulse heartbeat write | closed | `D2_subagentstop_does_not_eat_block_counter` / `bc8bd93`; `S13_session_ledger` / `eaf8c1f` | Stop and SubagentStop both refresh heartbeat state; terminal Stop paths append a session summary. |
| 31 | Discord notify | closed | `S4_discord_notify_real_post_or_honest_docs` / `acca4bb`; `S12_cost_telemetry` / `6a4a043` | Notifications have retry/dead-letter coverage and goal-complete token/cost telemetry. |
| 32 | Discord operator console | deliberately-different | `S0_repo_reflects_installed_harness` / `0da52ea` | This is an operating convention, not an upstream primitive with a hook-level enforcement point. The harness still works outside Discord-routed sessions. |
| 33 | Rollout helper / dry-run | closed | `S0_repo_reflects_installed_harness` / `0da52ea`; `S15_every_install_op_reversible` / `34565e5` | `enable-for-launcher.sh` dry-runs by default, uses `--plugin-dir`, and writes timestamped backups on apply. |
| 34 | Install verifier | closed | `S2a_verify_install_universal_vs_openclaw_split` / `23a3dfb`; `S15_readme_honest_and_complete` / 0.13.0 final-gate changes | `verify-install.sh` is split into core/setup scopes and now also checks this rollup plus the install sync script. |
| 35 | SessionStart hook | closed | `S5_session_start_hook_bootstrap` / `b8487f9` | `hooks/session-start.sh` is wired in `hooks/hooks.json` and validates bootstrap files. |
| 36 | UserPromptSubmit hook | closed | `S14_user_prompt_submit_hook` / `acca4bb` | `hooks/user-prompt-submit.sh` is wired and tested for empty, non-empty, and truncated steering notes. |
| 37 | Plugin manifest hooks reference | closed | `S2b_settings_json_canonicalization` / `23a3dfb`; `S0_repo_reflects_installed_harness` / `0da52ea` | `hooks/hooks.json` is the canonical plugin manifest. The old root `settings.json` was removed from the repo. |

## Article Recommendation Decisions

| Gap | Recommendation | Decision | Closing item / commit | Rationale |
|---|---|---|---|---|
| B1 | Per-feature one-feature-at-a-time discipline | deferred | n/a | Kept as a CLAUDE/codex-executor contract rather than a hard hook. Enforcing one result flip per session would block legitimate tightly-coupled fixes in production-hardening runs. |
| B2 | Reset on long session, structured handoff | deferred | n/a | Context reset is runtime/operator behavior. We closed the handoff side through `S13_session_ledger` / `eaf8c1f`, but auto-reset is unsafe from a plugin hook. |
| B3 | Rubric for subjective evaluation | closed | `S11_rubric_template_and_one_concrete` / `34565e5` | Template and GEO rubric are shipped, and strict evaluator reads named rubrics before verdict. |
| B4 | Sprint contract handshake | deferred | n/a | The orchestrator owns fresh evaluator invocation and sprint acceptance. A negotiation script would be a higher-level runner, not an installable plugin primitive. |
| B5 | Browser-verified evaluator | deferred | n/a | Browser/MCP tool availability is project-specific. The harness remains evidence-based and can consume browser evidence generated by QA tooling. |
| B6 | Initializer Agent | closed | `S10_init_workspace_script` / `eaf8c1f`; `S10_planner_agent_optional` / `eaf8c1f` | Workspace seeding and optional planning are now present. |
| B7 | Live observability | closed | `S13_observability_docs` / `eaf8c1f`; `S16_soak_test_synthetic` / `34565e5` | The watch/tmux panel set and soak fixture document the live monitoring workflow. |
| B8 | Re-simplify on model upgrades | deferred | n/a | Model-upgrade simplification is a maintenance practice, not a runtime primitive. README now maps capabilities to tests so future pruning can remove checks deliberately. |
| B9 | Agent SDK translation | deferred | n/a | This package is a Claude Code plugin. An Agent SDK port would be a separate distribution and is intentionally outside 0.13.0. |
| B10 | Unattended loop / restart next session | deferred | n/a | The outer pulse detects stalls and trims completed sessions, but process restart is launcher/OpenClaw-specific and should not be hard-coded into the plugin. |

## Trap Decisions

| Trap | Issue | Decision | Closing item / commit | Notes |
|---|---|---|---|---|
| D1 | `AGENT_STOP` path drift | closed | `S5_kill_switch_workdir_default` / `0da52ea` | Kill switch now uses the workspace-rooted default. |
| D2 | `Stop` + `SubagentStop` double-fire counter bug | closed | `D2_subagentstop_does_not_eat_block_counter` / `bc8bd93`; `S9_eight_block_cap_documented_and_correct` / `acca4bb` | SubagentStop writes heartbeat state but does not increment the block counter. |
| D3 | Root `settings.json` not canonical | closed | `S2b_settings_json_canonicalization` / `23a3dfb` | `hooks/hooks.json` is canonical. |
| D4 | `verify-gate.sh` evidence consumption race | deferred | n/a | Claude Code serializes tool calls in normal operation, so the race risk is low. We did not add locking in 0.13.0 because per-row binding solved the higher-risk false-positive path. |
| D5 | `verify-install.sh` Marco-specific checks | closed | `S2a_verify_install_universal_vs_openclaw_split` / `23a3dfb` | Core/setup/all scopes split community checks from AI Heroes launcher checks. |
| D6 | Evaluator Bash soft boundary | partial-closed | `S3_verify_gate_bash_disclosure` / `b8487f9`; `S6_evaluator_strict_no_bash` / `b8487f9` | Default evaluator keeps Bash for engineering diffs; strict evaluator drops Bash for content/design goals. |
| D7 | Pass-count over-counting | closed | `S4_discord_notify_count_regex_strict` / `0da52ea` | Counting now uses schema-aware traversal with stricter fallback coverage. |
| D8 | `register-goal.sh` re-registration duplicates | closed | `S5_register_goal_dedupe` / `0da52ea` | Re-registering a workspace replaces the existing active-ledger row. |
| D9 | `commit-on-stop` silent failure | deferred | n/a | This upstream limitation remains. The final-gate scope did not add git identity preflighting; operators still rely on normal git configuration and explicit evidence. |
| D10 | `codex-spawn.sh` exit-code docs drift | closed | `S14_codex_spawn_exit_codes_documented` / `0da52ea` | README troubleshooting documents exit codes 2, 3, 4, and 5. |
| D11 | Missing `docs/openclaw-supervisor/` reference | closed | `S2c_openclaw_supervisor_docs_present_or_removed` / `bc8bd93` | The reference supervisor docs now ship in the repo. |
| D12 | CHANGELOG described external supervisor behavior | deliberately-different | `S2a_verify_install_universal_vs_openclaw_split` / `23a3dfb`; `S15_readme_honest_and_complete` / 0.13.0 final-gate changes | Historical changelog entries stay as release history. Current README and verify scopes clearly mark OpenClaw as optional/setup-specific. |
| D13 | Heartbeat snapshot fallback without `jq`/`python3` | deferred | n/a | README prerequisites require `jq` or `python3`. Bash-only operation is outside supported install conditions, so the fallback remains best-effort. |
| D14 | STEER counter-reset hook ordering | closed | `S5_steer_counter_reset_marker` / `0da52ea`; `S14_user_prompt_submit_hook` / `acca4bb` | A marker file survives PreToolUse consumption and is cleared by the Stop hook. |

## Final-Gate Additions

0.13.0 adds three release-gate artefacts without flipping
`test-results.json` directly:

- `S1_every_upstream_primitive_addressed`: this file is the evidence rollup.
- `S15_readme_honest_and_complete`: README now contains a capability-to-test
  map and local link audit.
- `S17_repo_in_sync_with_install_final`: `scripts/sync-to-install.sh` copies
  repo package files to the installed plugin and the required filtered diff
  returns zero output after sync.

