<!-- Copyright 2026 Anthropic PBC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Long-Running Agent Harness

You are operating inside a long-running agent harness built on the
March 2026 *Harness Design for Long-Running Application Development*
patterns. The loop is:

```
operator goal
  -> planner writes BUILD_PLAN.md + default-fail test-results.json
  -> contract-reviewer returns CONTRACT_OK or CONTRACT_REWRITE
  -> generator builds against the plan + produces round-N evidence
  -> evaluator drives the live surface (Playwright MCP / native
     computer use) from fresh context and writes QA_REPORT.md
  -> heartbeat hook blocks until test-results.json is green AND
     QA_REPORT.md starts PASS AND (for frontend/desktop) a non-empty
     interaction trace exists at the round-N path
  -> outer watchdog catches silence if the inner loop stops beating
     and auto-rekicks NEEDS_WORK rounds up to the shared round-budget
```

The default mode is **planner -> contract-reviewer -> generator -> evaluator**.

The harness is operator-channel-agnostic. Discord, Slack, email, or
none — all are valid. Operator steering arrives through `STEER.md` on
disk; operator status leaves through the optional `discord-notify.sh`
webhook hook (off by default). The "discord-long-running-harness"
plugin slug is historical; the harness itself is general.

## Always Start Here

Before doing anything else, read:

1. `BUILD_PLAN.md` if it exists.
2. `PROGRESS.md` if it exists.
3. `QA_REPORT.md` if it exists.
4. `NEXT_FINDINGS.md` if it exists — open items from the previous
   evaluator round. These are the top of the queue.
5. `STEER.md` if it exists — operator overrides.
6. `git log --oneline -10`.

If `BUILD_PLAN.md` does not exist, invoke the bundled `planner` agent
or create the same structure yourself before implementation. If
`PROGRESS.md` does not exist, create it with `## Done`, `## In progress`,
`## Next`, and `## Notes`.

Run the project's smoke test (`./init.sh` or equivalent) once before
editing so you know whether you inherited a working tree or a broken
handoff.

## Build Mode

Use the longest coherent builder run the model can handle. Do not
force artificial sprints by default. Strict sprinting is a fallback
for weaker models, risky changes, or work that naturally decomposes.

When a bounded code-heavy execution unit is useful, use the bundled
`codex-executor` agent. It invokes `bin/codex-spawn.sh`, reads
`~/.claude/codex-current-model.env`, and runs Codex with xhigh
reasoning. This is an AI Heroes executor choice, not the core harness
architecture. The Codex session reads `AGENTS.md` (industry-standard)
which `register-goal.sh` seeds alongside `PROGRESS.md` and `init.sh`.

Never silently fall through to `gpt-5.4`, and never use `gpt-5.5-codex`.

## Proof Before Passing

A criterion is only passing after you have:

1. Run it against the real target.
2. Produced evidence listed in `BUILD_PLAN.md` under the current
   round's namespaced path (`screenshots/round-N/...`,
   `evidence/round-N/...`, `playwright-mcp/round-N/trace.zip`,
   `computer-use/round-N/session.jsonl`).
3. Opened the screenshot, console log, test output, trace, or result
   file with the Read tool.
4. Confirmed the evidence shows what it should.

For UI / frontend tasks: drive the live app via Playwright MCP
(configured in `.mcp.json`). The trace lands automatically under
`playwright-mcp/round-N/` via the `PLAYWRIGHT_TRACE_DIR` env var.

For desktop / non-browser interactive tasks: drive the live surface
via native computer use. Append every action to
`computer-use/round-N/session.jsonl` (one JSON object per line). Same
guardrails as Playwright: empty session log is no session log; the
heartbeat hook will reject `PASS`.

The `verify-gate` hook denies writes to `test-results.json` until the
relevant `evidence_paths` have been opened. The companion
`verify-gate-bash` hook catches `sed`/`jq`/`python` rewrites of the
results file. The `heartbeat-stop` hook denies goal-completion for
frontend/desktop rubrics without an interaction trace. Do not work
around any of them.

## Evaluator Gate

Before final completion, invoke the bundled `evaluator` agent or
perform the same fresh-context review. The evaluator must write
`QA_REPORT.md` with `PASS` or `NEEDS_WORK` as the first line.

If the verdict is `NEEDS_WORK`, fix the findings (`NEXT_FINDINGS.md`
captures them automatically when the evaluator is invoked through
`scripts/run-evaluator.sh` or `scripts/ralph-loop.sh`) and run
evaluation again. If the verdict is `PASS`, leave the report in
place. The heartbeat hook reads it.

## Unattended Loop

For headless execution, run `scripts/ralph-loop.sh`. It cycles
build -> evaluator -> rebuild until the heartbeat would accept
completion or the shared round budget is exhausted. It writes
`NEXT_FINDINGS.md` after every NEEDS_WORK round so the next builder
turn opens with the prior evaluator's findings already on top.

```
scripts/ralph-loop.sh --workspace "$PWD" --isolated-evaluator
```

## Re-Simplify on Model Upgrade

`scripts/re-simplify.sh` lets the operator disable one harness piece,
re-run the bench rig, and decide if the piece is still load-bearing
on the current model. Combined with `rounds.json` model stamping, this
makes "is X still earning its complexity?" a measurable question
instead of an aesthetic one.

```
scripts/re-simplify.sh --target playwright-trace --reason "test on opus-4-7"
scripts/bench-harness.sh --pilot express-server --workspace /tmp/bench-with-override
scripts/re-simplify.sh --restore --target playwright-trace
scripts/bench-score.py baseline.json candidate.json
```

## Keep State Current

Keep `PROGRESS.md` current as durable handoff. It is not the magic.
It is the black box flight recorder. Newer models need fewer hard
resets, but long-running work still needs disk state when something
goes wrong.

The Stop/SubagentStop heartbeat hook writes `.claude/goal-state/last-beat`
so the standalone watchdog or OpenClaw supervisor can detect stalls
without polling external channels.

## Operator Controls

- `AGENT_STOP` in the workspace — kill switch. Next hook boundary
  stops cleanly.
- `STEER.md` — operator steering. Next tool boundary injects the note
  and resets the block counter.
- `NEXT_FINDINGS.md` — auto-generated by the evaluator on NEEDS_WORK,
  consumed by the next builder turn.
- `~/.claude/goal-sessions/active.jsonl` — supervisor source of truth
  for active goals.
- `.claude/goal-state/goal-state.json` — current goal session, pinned
  rubric, intended model, and round budget.
- `.claude/goal-state/rounds.json` — per-round verdict stamped with
  rubric, model, codex_model, evidence count, and axis scores.
  Consumed by `hooks/heartbeat-stop.sh` and
  `goal-watchdog.py --kick --max-rounds`.
- `.claude/goal-state/round-budget` — shared cap the heartbeat and
  watchdog both read; set it with `register-goal --round-budget N`.
- `.claude/goal-state/evaluator-calibration.jsonl` — operator-override
  corpus the evaluator reads on every grading pass. Append with
  `scripts/calibrate-evaluator.sh`.
- `.claude/goal-state/re-simplify-overrides.json` — operator
  experiments disabling one harness piece at a time. Set with
  `scripts/re-simplify.sh --target X`.
- `.claude/goal-state/post-compact-orientation.md` — written by the
  PreCompact hook so the agent can recover the acceptance contract
  after compaction.
- `ESCALATION.md` — written by **both** the heartbeat hook (on
  runaway-cap inside the worker), `scripts/ralph-loop.sh` (on max
  rounds exhausted), and the watchdog (on `--max-rounds` exhaustion).
  The configured webhook is notified once per escalation.
- `CONTRACT_REVIEW.md` — latest verdict from the contract-reviewer
  subagent (`CONTRACT_OK` or `CONTRACT_REWRITE`).

## Optional Discord Status Channel

`hooks/discord-notify.sh` is **one-way**: it posts goal-complete and
builder-pass events to a webhook when `DISCORD_NOTIFY_WEBHOOK` is set.
Operator replies still come back through `STEER.md` on disk. If you
do not use Discord, leave the env var unset and the hook is inert.

## Commit Often

The Stop hook commits tracked changes as a backstop. Still add new
source files and commit meaningful checkpoints yourself when a
coherent unit lands.
