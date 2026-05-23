<!-- Copyright 2026 AI Heroes -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# BUILD_PLAN — Heartbeat-during-spawn fix

## The bug

The harness inner pulse relies on `hooks/heartbeat-stop.sh`, which fires only on `Stop` / `SubagentStop` hook events — i.e., when the agent's turn ends. During a long Codex spawn invoked via `bin/codex-spawn.sh`, the orchestrator's turn does **not** end until the spawn returns; that's often 10–45 minutes for an `xhigh` reasoning generation. While the spawn is alive:

- `.claude/goal-state/last-beat` is never touched. The file may not exist at all in the workspace (confirmed in the wild: both `~/conductor/workspaces/schmidt-slack-up/.claude/goal-state/` and `~/conductor/workspaces/claude-discord-threads-v1/harden/.claude/goal-state/` had no `last-beat` despite active Codex spawns at the time of inspection).
- The deployed dashboard reads `heartbeat: { lastBeatAt: null, ageSeconds: null }` for healthy live sessions.
- The outer-pulse supervisor (`scripts/supervisor-runner.sh`, default stall threshold 1200s) can mark a session as stalled when it is actually generating output, because there is no fresh beat to read.

## The fix shape (recommended; codex-executor may revise with explicit reasoning)

1. **New helper script `scripts/spawn-heartbeat.sh`.**
   - Usage: `scripts/spawn-heartbeat.sh <target_pid> <state_dir> [--interval 30] [--command codex]`.
   - Self-contained bash (`set -euo pipefail`). No `jq` dependency — use python3 fallback as the rest of the harness does.
   - On launch: writes `<state_dir>/spawn-active.json` with `{pid, started_at, last_refreshed, command}` (ISO-8601 UTC for times) and touches `<state_dir>/last-beat` (epoch seconds, identical format to the Stop hook).
   - Every `--interval` seconds (default 30): re-touches `<state_dir>/last-beat` (refreshes epoch) and rewrites `<state_dir>/spawn-active.json` with updated `last_refreshed`.
   - Exit conditions: target PID gone (poll via `kill -0`), receives `SIGTERM`/`SIGINT`, or its own `--max-runtime` (safety cap, default 7200s = 2h matching the existing codex-spawn TTL elsewhere in the harness).
   - On exit: removes `<state_dir>/spawn-active.json` (best-effort) and exits 0.
   - Treats missing `<state_dir>` as a no-op success (don't fail the spawn just because we're not in a registered workspace).

2. **`bin/codex-spawn.sh` rewires to use the helper.**
   - Replace the final `exec codex exec ...` with: fork codex into the background, capture its PID, fork the heartbeat helper with that PID and the workspace state-dir, `wait` on codex, capture exit, `kill` the helper (best-effort), `exit` with the codex code.
   - Choose `state_dir = ${CODEX_SPAWN_WORKDIR:-$PWD}/.claude/goal-state`. If that directory does not exist, skip launching the helper entirely (no-op path; spawn behavior identical to today).
   - Trap `EXIT` / `INT` / `TERM` to make sure the helper is killed even on operator Ctrl-C.

3. **`hooks/heartbeat-stop.sh` records source.**
   - Add `"source": "stop-hook"` (and the existing `hook_event_name`) to `last-beat-state.json`. Keep the existing keys.
   - This is purely additive; no behavior change for the Default-FAIL contract, block-cap, or SubagentStop short-circuit.

4. **`dashboard/lib/collect-state.mjs` surfaces the spawn-active signal.**
   - When `<workspace>/.claude/goal-state/spawn-active.json` exists and `last_refreshed` is within `300s`, the bundle's `heartbeat` becomes `{ lastBeatAt: <last_refreshed>, ageSeconds: <now - last_refreshed>, lastStatus: "active", source: "spawn-active", spawn: { pid, started_at, command } }`.
   - When only `last-beat` / `last-beat-state.json` exist (existing path), surface `source: "stop-hook"` for clarity.
   - When neither is present or both are stale (> 1200s), leave `lastBeatAt: null` as today.

5. **`scripts/supervisor-runner.sh` honors the spawn signal.**
   - Existing stall detection reads `last-beat`. Because the helper touches that file every 30s, no additional supervisor change is strictly required for correctness — but the recovery log entry should record the source if available, so a recovery alert during a spawn surfaces "spawn appears stuck" instead of "no beat".
   - Acceptable to defer the supervisor wording change if test H3 still passes (the test asserts no false stall, not the message body).

6. **Tests.**
   - `tests/heartbeat/spawn-refresh.sh` — uses a mocked `codex` binary on `$PATH` that sleeps 75s, runs `bin/codex-spawn.sh` in a tempdir workspace, asserts `last-beat` mtime advances ≥ 2 times during the spawn, asserts `spawn-active.json` exists during the spawn and is removed after, asserts the script's exit code equals the mock's exit code (e.g., 0 and 7 in two sub-tests).
   - `tests/heartbeat/supervisor-no-false-stall.sh` — seeds an active-ledger entry pointing at a tempdir workspace, writes a fresh `last-beat` (now - 100s) and a fresh `spawn-active.json`, runs `supervisor-runner.sh` with `SUPERVISOR_STALL_THRESHOLD=1200`, asserts the recovery log gets no entry and no webhook curl is queued.
   - `dashboard/tests/collect-state-spawn-active.mjs` (Node, no test framework required — just `node --check` plus a tiny `assert` script following the pattern of the other dashboard checks) — seeds a tempdir workspace with `active.jsonl` + `spawn-active.json` + no `last-beat`; asserts `collectHarnessBundle` returns `heartbeat.source === "spawn-active"` and `lastBeatAt` matches the `last_refreshed` field.
   - All existing tests must still pass: enumerate them via `find tests -maxdepth 3 -name '*.sh' -perm -u+x` (run each), record exit codes to `evidence/sprint-heartbeat/regression.txt`.

7. **Docs.**
   - `README.md` — under "Why two pulses" or "How it works", add a 3–5 line paragraph naming the two heartbeat sources (`stop-hook`, `spawn-active`) and what each means.
   - `docs/observability.md` — add a `spawn-active.json` paragraph describing the schema and how to interpret it in the four-pane tmux layout.

## Non-goals (do not touch this sprint)

- Do not change the block-cap, the Default-FAIL contract, the verify-gate, or the evaluator agent definitions.
- Do not touch `register-goal.sh` or `active.jsonl` semantics.
- Do not deploy or re-link the dashboard; deployment is a separate operator step after the sprint lands.
- Do not change Codex model pinning or any of the `gpt-5.5` / `xhigh` enforcement.
- Do not add a new top-level dependency to either the harness or the dashboard `package.json`.

## H7 — Discord launcher plugin-wiring audit (contract amendment 2026-05-22T17:14Z)

Surfaced after Richard's `start-richard.sh` was found to silently invoke Claude without `--plugin-dir /Users/marco/.claude/plugins/discord-long-running-harness`. The harness's Stop/SubagentStop hooks therefore never loaded into any Richard session, so `last-beat` was never written even at turn boundaries (different layer from the spawn-active bug, identical surface symptom). Richard was hand-touching `last-beat` as a workaround. Same drift could exist for any other Discord agent in the fleet.

Deliverable:

1. NEW `scripts/audit-discord-launchers.sh` (executable, `set -euo pipefail`, no new dependencies beyond bash+grep+python3 fallback).
   - Enumerates every executable file matching `~/.claude/channels/discord/start-*.sh`.
   - For each, statically inspects the file for a recognised plugin-loading directive (an `--plugin-dir <path>` arg pointing at the long-running-harness install, OR a `settings.json` directive sourced from that install, OR an explicit env var the launcher exports that the harness will honour). Document the accepted directives at the top of the script.
   - Emits one line per launcher: `PASS <slug> <method>` if a directive is found, `FAIL <slug> <reason>` otherwise.
   - Prints a final summary line: `audit total=<N> pass=<P> fail=<F>`.
   - Exit code 0 if F == 0, non-zero otherwise.
2. NEW `tests/heartbeat/launcher-audit-detects-missing-flag.sh` — creates a tempdir with two fixture launchers (one good, one missing the flag), points the audit script at that tempdir via an env override (e.g., `AUDIT_LAUNCHER_DIR`), asserts exit code != 0 and that the FAIL line is present.
3. README addition: a short subsection titled "Discord launcher audit" naming the script, its trigger condition (new Discord agent added, or any time hooks aren't firing as expected), and the canonical fix (`--plugin-dir /Users/marco/.claude/plugins/discord-long-running-harness`).
4. CHANGELOG.md mention of the audit script in the same Heartbeat-during-spawn entry.

Non-goals for H7:
- Do NOT mutate the actual Discord launchers under `~/.claude/channels/discord/start-*.sh` in this sprint. Detection only. Operator decides remediation per agent.

## Acceptance contract

See `test-results.json` for the 7 acceptance items (H1–H7). All must be `"passes": true` with evidence under `evidence/sprint-heartbeat/`.

## Evidence convention

- Put per-test artefacts under `evidence/sprint-heartbeat/<H#>-<name>/*.txt`.
- A diff of the implementation goes to `evidence/sprint-heartbeat/diff.patch` (`git diff main..feat/heartbeat-during-spawn`).
- The codex-spawn execution log lands at the standard `.claude/goal-state/codex-spawn-heartbeat-*.log` path (managed by the executor wrapper; do not write it manually).
- The evaluator verdict is saved to `.claude/goal-state/sprint-heartbeat-verdict.txt` after grading.
