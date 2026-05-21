# Evaluator Rubric — API / Backend service

Four axes adapted from the March 2026 harness-design article for
backend work. The planner copies this block verbatim into
`BUILD_PLAN.md > Evaluator Rubric` when the task is a backend service,
job, or API. The evaluator scores each axis 0–5 in `QA_REPORT.md`.

Evidence is curl/HTTPie/test-runner output plus, when relevant, log
captures. Static-diff review is not enough.

## Axis 1 — Contract Correctness (0–5)

"Does the implementation match the documented request/response contract
exactly?"

- 0 — endpoints missing or wrong path/verb.
- 1 — endpoints reachable but response shapes wrong.
- 2 — happy path matches, error paths drift from spec.
- 3 — happy and error paths match documented shapes.
- 4 — happy, error, and edge cases match; status codes correct.
- 5 — contract matches AND the openapi/typespec/JSON-schema is committed
  alongside the code.

## Axis 2 — Reliability (0–5)

"Behavior under realistic load and adversarial input."

- 0 — crashes on the second request.
- 1 — handles valid input only; malformed payloads crash.
- 2 — validates input but leaks raw stack traces.
- 3 — validates input, returns safe errors, idempotent where required.
- 4 — survives concurrent requests, retries are safe, timeouts handled.
- 5 — graceful degradation under failure of downstream dependencies.

## Axis 3 — Craft (0–5)

"Technical execution of the codebase itself."

- 0 — no tests, no types, no logs.
- 1 — sparse tests covering only the happy path.
- 2 — tests cover happy + obvious errors; logging present but noisy.
- 3 — tests cover spec'd behavior; logs are structured and useful.
- 4 — tests, logs, types/contracts, plus a smoke test that runs end-to-end.
- 5 — tests + logs + types + smoke + a meaningful benchmark or regression
  guard.

## Axis 4 — Operational Fitness (0–5)

"Can a human ship and run this without holding the author's hand?"

- 0 — only starts on the author's laptop.
- 1 — starts elsewhere if the reader hunts for the secret.
- 2 — README mentions startup; values still hardcoded.
- 3 — `init.sh` or equivalent gets a fresh checkout running.
- 4 — `init.sh`, env-driven config, health endpoint, basic observability.
- 5 — `init.sh`, env config, healthz, structured logs, metrics, and a
  documented rollback path.

## Evidence the evaluator must capture

- curl / HTTPie output for every endpoint listed in the acceptance
  contract (request + response).
- Test runner output (pytest/jest/go-test/etc.) opened with Read.
- One adversarial-input test (oversized, malformed, wrong type) and its
  response.
- Log capture from at least one realistic flow.
- For services that talk to a DB or external API: a record proving the
  external dependency was actually exercised (or mocked deliberately,
  with the mock noted).

## PASS bar

- Every axis >= 3.
- No `passes: false` in `test-results.json`.
- Every acceptance criterion has at least one piece of evidence opened
  with the Read tool.
- The evaluator personally exercised at least one endpoint, not just
  reviewed logs.

## NEEDS_WORK triggers

- Any axis at <= 2.
- "All tests pass" with no record of the tests actually running.
- Endpoints documented but never hit during evaluation.
- Error paths look plausible in code but never tested.
