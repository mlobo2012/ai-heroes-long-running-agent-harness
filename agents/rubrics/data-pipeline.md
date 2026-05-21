# Evaluator Rubric — Data pipeline / Job

Four axes for batch jobs, ETL, data transformations, and scheduled
pipelines. The planner copies this block verbatim into
`BUILD_PLAN.md > Evaluator Rubric` when the task is data-processing.

Evidence is sample input/output, run logs, and a record of the pipeline
actually executing end-to-end against real or representative data.

## Axis 1 — Output Correctness (0–5)

"Does the output match the documented schema and semantics?"

- 0 — output schema wrong or pipeline crashes.
- 1 — schema right, values wrong on the happy path.
- 2 — happy path values correct, edge cases wrong.
- 3 — all documented inputs produce documented outputs.
- 4 — same plus tests for null/missing/duplicate/late-arriving rows.
- 5 — same plus an idempotency proof (re-running produces the same
  output).

## Axis 2 — Robustness (0–5)

"What happens when the input is real-world noisy?"

- 0 — assumes perfect input; crashes on anything else.
- 1 — handles some malformed rows by crashing the whole batch.
- 2 — quarantines bad rows but reports nothing.
- 3 — quarantines, logs, and continues; produces a clear failure report.
- 4 — same plus a retry/backfill mechanism for transient failures.
- 5 — same plus dead-letter handling that an operator can inspect.

## Axis 3 — Craft (0–5)

"Implementation, tests, observability."

- 0 — no tests, no logs.
- 1 — tests on synthetic input only; sparse logs.
- 2 — tests + logs but logs lack context (no row id, no batch id).
- 3 — tests + structured logs + a metrics counter per stage.
- 4 — same plus a fixture set covering representative production
  distributions.
- 5 — same plus a property/golden-file test that would catch silent
  schema drift.

## Axis 4 — Operational Fitness (0–5)

"Can the on-call human run this, kill this, or backfill this safely?"

- 0 — no entrypoint or hidden runtime dependencies.
- 1 — runs locally but not idempotent.
- 2 — runs locally and idempotent on happy path.
- 3 — has `init.sh` / runbook; idempotent; safe to re-run.
- 4 — same plus a documented backfill mode and a kill-and-resume story.
- 5 — same plus structured metrics on rows in/out/quarantined the
  operator can graph.

## Evidence the evaluator must capture

- Sample input opened with Read.
- Resulting output opened with Read.
- Run log opened with Read, with at least one realistic batch.
- A demonstrated kill-and-resume or re-run if the pipeline claims to
  support it.

## PASS bar

- Every axis >= 3.
- No `passes: false` in `test-results.json`.
- Every acceptance criterion has at least one piece of evidence opened
  with the Read tool.
- The evaluator ran the pipeline end-to-end at least once.

## NEEDS_WORK triggers

- Any axis at <= 2.
- "Pipeline runs" with no record of input/output rows examined.
- No story for malformed or duplicate input.
- Idempotency claimed but not demonstrated.
