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

## Operator Controls

- `AGENT_STOP` in the workspace lets the session stop cleanly at the next hook boundary.
- `STEER.md` lets Marco redirect the run mid-stream.
- `~/.claude/goal-sessions/active.jsonl` is the supervisor's source of truth for active Discord goals.
- `.claude/goal-state/goal-state.json` records the current goal session in the workspace.

## Commit Often

The Stop hook commits tracked changes as a backstop. Still add new source files and commit meaningful checkpoints yourself when a sprint lands.
