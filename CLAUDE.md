<!-- Copyright 2026 Anthropic PBC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Discord Long-Running Harness

Discord is your operator console. Treat the bound Discord channel as the place where Marco starts goals, steers live work, asks for status, and stops a run. Keep visible replies concise and state-based: blocker, approval needed, plan ready, QA needs work, stall, completion, or final result.

## The Loop

The default shape is the March 2026 planner -> generator -> evaluator loop:

1. Planner turns the operator goal into `BUILD_PLAN.md` and initializes `test-results.json` with every criterion set to `"passes": false`.
2. Generator builds against that plan and produces real evidence.
3. Evaluator reviews from fresh context and writes `QA_REPORT.md`.
4. The heartbeat hook only allows completion when `test-results.json` is green and `QA_REPORT.md` starts with `PASS`.

Do not treat builder-written tests as final truth. The evaluator is the release gate.

## Always Start Here

Before doing anything else, read:

1. `BUILD_PLAN.md` if it exists.
2. `PROGRESS.md` if it exists.
3. `QA_REPORT.md` if it exists.
4. `git log --oneline -10`.

If `BUILD_PLAN.md` does not exist, invoke the bundled `planner` agent or create the same structure yourself before implementation. If `PROGRESS.md` does not exist, create it with `## Done`, `## In progress`, `## Next`, and `## Notes`.

Run the project's smoke test once before editing so you know whether you inherited a working tree or a broken handoff.

## Build Mode

Use the longest coherent builder run the model can handle. Do not force artificial sprints by default. Strict sprinting is a fallback for weaker models, risky changes, or work that naturally decomposes.

When a bounded code-heavy execution unit is useful, use the bundled `codex-executor` agent. It invokes `bin/codex-spawn.sh`, reads `~/.claude/codex-current-model.env`, and runs Codex with xhigh reasoning. This is an AI Heroes executor choice, not the core harness architecture.

Never silently fall through to `gpt-5.4`, and never use `gpt-5.5-codex`.

## Proof Before Passing

A criterion is only passing after you have:

1. Run it against the real target.
2. Produced evidence listed in `BUILD_PLAN.md`.
3. Opened the screenshot, console log, test output, trace, or result file with the Read tool.
4. Confirmed the evidence shows what it should.

The `verify-gate` hook denies writes to `test-results.json` until evidence has been opened. Do not work around it.

## Evaluator Gate

Before final completion, invoke the bundled `evaluator` agent or perform the same fresh-context review. The evaluator must write `QA_REPORT.md` with `PASS` or `NEEDS_WORK` as the first line.

If the verdict is `NEEDS_WORK`, fix the findings and run evaluation again. If the verdict is `PASS`, leave the report in place. The heartbeat hook reads it.

## Keep State Current

Keep `PROGRESS.md` current as durable handoff. It is not the magic. It is the black box flight recorder. Newer models need fewer hard resets, but long-running work still needs disk state when something goes wrong.

The Stop/SubagentStop heartbeat hook writes `.claude/goal-state/last-beat` so the standalone watchdog or OpenClaw supervisor can detect stalls without polling Discord.

## Operator Controls

- `AGENT_STOP` in the workspace lets the session stop cleanly at the next hook boundary.
- `STEER.md` lets Marco redirect the run mid-stream.
- `~/.claude/goal-sessions/active.jsonl` is the supervisor's source of truth for active goals.
- `.claude/goal-state/goal-state.json` records the current goal session in the workspace.

## Commit Often

The Stop hook commits tracked changes as a backstop. Still add new source files and commit meaningful checkpoints yourself when a coherent unit lands.
