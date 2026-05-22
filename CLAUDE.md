<!-- Copyright 2026 Anthropic PBC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Discord Long-Running Harness

Discord is your operator console. Treat the bound Discord channel as the place where Marco starts goals, steers live work, asks for status, and stops a run. Keep visible replies concise and state-based: blocker, approval needed, sprint pass, stall, completion, or final result.

## Always Start Here

Before doing anything else, read `PROGRESS.md`. It is your handoff note from the previous session. If it does not exist yet, create it with four sections (`## Done`, `## In progress`, `## Next`, `## Notes`) and leave them empty. Then run `git log --oneline -10` to see what was just committed, and run the project's smoke test once so you know whether you are starting from a working handoff.

## One Sprint At A Time

Work on exactly one sprint-sized item from `PROGRESS.md` per session. Finish it with evidence before starting another. If Marco gives a new task mid-run, record it in `PROGRESS.md`, incorporate the steering, and keep moving toward the active goal unless he stops the run.

## Proof Before Passing

A test is only passing after you have:

1. Run it against the live app or relevant target.
2. Opened the screenshot, console log, or result file with the Read tool.
3. Confirmed the evidence shows what it should.

The `verify-gate` hook denies writes to `test-results.json` until evidence has been opened. Do not work around it.

## Keep State Current

After each completed sprint, update `PROGRESS.md`, write or update `test-results.json`, and leave enough evidence for a fresh reviewer to understand the verdict. The Stop/SubagentStop heartbeat hook writes `.claude/goal-state/last-beat` so the OpenClaw supervisor can detect stalls without polling Discord.

## Codex Executes Sprints

For code-heavy sprint work, use the bundled `codex-executor` agent. It invokes `bin/codex-spawn.sh`, which reads the pinned model from `~/.claude/codex-current-model.env` and runs Codex GPT-5.5 with xhigh reasoning. Never silently fall through to `gpt-5.4`, and never use `gpt-5.5-codex`.

## Generator → Evaluator Loop

The harness is a *generator+evaluator* pattern, not a single grinder. Every sprint pass must be graded by a fresh-context agent before you flip `test-results.json`:

1. **Plan the sprint.** Identify which `test-results.json` row(s) close. Write the sprint brief as the agent's own prose (no separate file required, but feel free to save under `tests/sprints/<n>.md`).
2. **Generate.** Use `scripts/build-eval-loop.sh` to spawn the Codex generator with telemetry pinned, or delegate to the `codex-executor` subagent with the brief. The only self-execution carve-outs are read-only, single-file, <10 minutes, and fully reversible work.
3. **Capture evidence.** Save concrete artefacts the evaluator can `Read` — `evidence/sprint-<n>/*-result.txt`, `evidence/sprint-<n>/diff.patch`, or any file matching `track-read.sh`'s pattern allowlist. `Read` each one yourself so the `verify-gate` records it.
4. **Grade.** Invoke a fresh-context evaluator subagent — `evaluator.md` for engineering goals (Bash granted for `git diff`), `evaluator-strict.md` for content goals (Read-only enforcement at the tool-grant level). Pass it the exact acceptance criteria and the evidence-file paths. Require `PASS` on its own line; reject any `NEEDS_WORK` and surface findings via STEER.md.
5. **Flip.** Only on `PASS`, Write the new `test-results.json`. The `verify-gate` will allow exactly one Write per evidence Read, then consume the log.
6. **Capture verdict.** Save the evaluator's verdict at `.claude/goal-state/sprint-<n>-verdict.txt` for the next session's audit trail.

If you skip step 4 you are violating the Default-FAIL contract and the inner pulse will keep blocking. If you skip step 6 the audit trail is broken and a fresh session can't tell what was graded vs. what was self-attested.

### Codex Routing Rule and Soft Boundary

Code-heavy sprint work goes through `codex-executor`, which means `bin/codex-spawn.sh` and a pinned `.claude/goal-state/codex-spawn-<slug>.log`. Before claiming generation is done, verify that the fresh spawn log exists; the codex-executor result is not an evaluator verdict and cannot justify flipping `test-results.json` on its own.

`verify-gate.sh` partially enforces this when a code-heavy row flips: it accepts a recent codex spawn log or a `Co-Authored-By: codex` trailer on the latest commit. This is still a soft boundary around orchestrator self-execution; see the README's "Codex routing: soft boundary on the generator side" section for operator practice.

## Operator Controls

- `AGENT_STOP` in the workspace lets the session stop cleanly at the next hook boundary.
- `STEER.md` lets Marco redirect the run mid-stream.
- `~/.claude/goal-sessions/active.jsonl` is the supervisor's source of truth for active Discord goals.
- `.claude/goal-state/goal-state.json` records the current goal session in the workspace.

## Commit Often

The Stop hook commits tracked changes as a backstop. Still add new source files and commit meaningful checkpoints yourself when a sprint lands.
