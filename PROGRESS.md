<!-- Copyright 2026 AI Heroes -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# PROGRESS — Heartbeat-during-spawn sprint

**Goal:** Fix the harness's inner-pulse blind spot during long Codex spawns. The Stop/SubagentStop hook is currently the only writer to `.claude/goal-state/last-beat`; while a Codex spawn runs (often 10–45 min), no turn ends → no hook fires → `last-beat` never gets written. The dashboard renders `heartbeat: null` for healthy live sessions and the supervisor can false-stall a session that is actually generating output.

**Pass signal:** Every item in `test-results.json` flips to `"passes": true` with evidence opened via the `Read` tool and the verdict graded by a fresh-context evaluator agent.

**Tally:** 🎯 **7 / 7 PASS. SPRINT MET.** Verdict at `.claude/goal-state/sprint-heartbeat-verdict.txt` (evaluator subagent_id `a589ea099629a6ff8`).

**Contract amendment 2026-05-22T17:14Z:** added H7 — Discord launcher plugin-wiring audit. Surfaced after discovering Richard's `start-richard.sh` was silently missing the `--plugin-dir` flag, which is why the harness's Stop hook never fired in his sessions and the watchdog stall-alerted him repeatedly. Same surface symptom as the heartbeat-during-spawn bug, different layer; both need to ship together so the launcher-drift class never recurs silently.

## Done

- **Sprint H — heartbeat-during-spawn (7 items).** Codex-executor (`6099b0e`) generated the spawn-active heartbeat, dashboard surface, supervisor regression test, launcher audit, docs, and CHANGELOG. Fresh-context evaluator (`a589ea099629a6ff8`) graded PASS x7 with independent re-runs of 4 tests/scripts.
  - `H1_codex_spawn_refreshes_last_beat_while_running` — `bin/codex-spawn.sh` now runs Codex as a child + a background `scripts/spawn-heartbeat.sh` watcher; mocked 75s spawn shows 1 initial + 2 mtime advances for exit codes 0 and 7, codex exit propagated.
  - `H2_spawn_active_state_file_written` — `spawn-active.json` schema `{pid:int, started_at:iso8601, last_refreshed:iso8601, command:"codex"}` validated during the spawn and removed within 5s of exit.
  - `H3_supervisor_does_not_false_stall_during_active_spawn` — `tests/heartbeat/supervisor-no-false-stall.sh` proves `supervisor-runner.sh` reports `sessions_stalled=0 sessions_ok=1` with a fresh spawn beat; no recovery log, no webhook curl.
  - `H4_dashboard_collect_state_exposes_spawn_active_source` — `dashboard/lib/collect-state.mjs` surfaces `heartbeat.source` ∈ {`stop-hook`, `spawn-active`}; `dashboard/tests/collect-state-spawn-active.mjs` covers both paths.
  - `H5_existing_heartbeat_unit_tests_still_pass` — 19 `.sh` tests + `npm --prefix dashboard run check` all PASS rc=0.
  - `H6_change_documented` — README two-source heartbeat paragraph + Discord launcher audit subsection, `docs/observability.md` spawn-active schema, `CHANGELOG.md` 0.14.0 entry.
  - `H7_discord_launcher_plugin_wiring_audited` — `scripts/audit-discord-launchers.sh` ships + `tests/heartbeat/launcher-audit-detects-missing-flag.sh` proves detection. Operator carve-out: `--plugin-dir` added to `start-don-draper.sh`, `start-ray-kroc.sh`, `start-schmidt.sh` (backups at `~/.claude/channels/discord/start-<slug>.sh.bak.1779488519.heartbeat-h7`); audit re-run shows 6/6 PASS, exit 0. The three remediated agents need a screen-session restart for the flag to take effect at runtime.

## In progress

_None — sprint complete. Awaiting operator merge of `feat/heartbeat-during-spawn` into `main`._

## Next

- Operator: restart `don-draper`, `ray-kroc`, `schmidt` screen sessions so the new `--plugin-dir` flag takes effect at runtime.
- Operator: merge `feat/heartbeat-during-spawn` into `ai-heroes-long-running-agent-harness` `main` (tag candidate: `0.14.0`).
- Operator: retire the session from `~/.claude/goal-sessions/active.jsonl` once merge lands.

## Notes

- Design constraints: keep the SubagentStop short-circuit in `hooks/heartbeat-stop.sh`. Don't break the block-cap. Don't introduce hard dependencies (must work without `jq` present). Heartbeat written from the spawn must include a source marker so the dashboard can distinguish `stop-hook` vs `spawn-active`.
- Final architecture (matches sketch with one refinement — Codex chose `set +e ; wait ; codex_status=$? ; set -e` instead of `wait ; codex_status=$?` to be defensive against the `set -e` interaction with backgrounded children):
  - `scripts/spawn-heartbeat.sh <target_pid> <state_dir> [--interval 30] [--command codex] [--max-runtime 7200]` — backgrounded watcher; refreshes `last-beat` epoch + rewrites `spawn-active.json` per interval; cleans up on EXIT trap.
  - `bin/codex-spawn.sh` — runs `codex exec ... &`, captures PID, launches the heartbeat helper, `wait`s on codex, then `kill`s the helper via cleanup trap, propagates codex exit.
  - `dashboard/lib/collect-state.mjs` — when `spawn-active.json` exists with `last_refreshed` ≤ 300s old, surfaces `heartbeat.source: "spawn-active"`, `heartbeat.lastBeatAt` = `last_refreshed`, and a `spawn: {pid, started_at, command}` block. Otherwise falls back to stop-hook path unchanged.
- See `BUILD_PLAN.md` for the original brief, `.claude/goal-state/sprint-heartbeat-verdict.txt` for the per-criterion evaluator verdict, and `evidence/sprint-heartbeat/diff.patch` for the full 921-line implementation diff.
