---
description: Invoke the evaluator subagent. Writes QA_REPORT.md with PASS or NEEDS_WORK. Updates NEXT_FINDINGS.md automatically on NEEDS_WORK.
---

Invoke the bundled `evaluator` subagent. It will:

1. Read `BUILD_PLAN.md`, `test-results.json`, the diff, and every
   evidence path declared in `BUILD_PLAN.md`.
2. Read the tail of `.claude/goal-state/evaluator-calibration.jsonl`
   for operator overrides on prior verdicts.
3. For frontend rubrics: drive the running app via Playwright MCP.
   Save the trace under `playwright-mcp/round-N/`.
4. For desktop rubrics: drive the live surface via native computer
   use. Append every action to `computer-use/round-N/session.jsonl`.
5. For api / library / data-pipeline rubrics: exercise the surface
   directly (curl, import-and-call, run the pipeline).
6. Score each axis 0-5.
7. Write `QA_REPORT.md` with `PASS` or `NEEDS_WORK` on line 1.

The heartbeat hook reads QA_REPORT.md. On NEEDS_WORK, the
run-evaluator wrapper auto-writes `NEXT_FINDINGS.md` so the next
builder turn opens with the actionable bullets already surfaced.

If invoked headless, prefer `scripts/run-evaluator.sh --isolated` so
the evaluator runs in a git worktree and cannot mutate the builder
tree.
