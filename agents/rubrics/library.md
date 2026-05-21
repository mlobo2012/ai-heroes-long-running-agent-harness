# Evaluator Rubric — Library / Package

Four axes for code that other code will consume. The planner copies this
block verbatim into `BUILD_PLAN.md > Evaluator Rubric` when the task is
shipping a library, package, SDK, or reusable module. The evaluator
scores each axis 0–5 in `QA_REPORT.md`.

Evidence is test output, type-check output, generated docs, and an
import-and-use smoke from a consumer.

## Axis 1 — Public Surface (0–5)

"Is the API a thing a reasonable consumer can use without reading the
source?"

- 0 — exports unstable, names misleading, no contract.
- 1 — exports work but only with insider knowledge.
- 2 — basic public surface; missing types or docs.
- 3 — typed, documented, named consistently with peers in the ecosystem.
- 4 — typed + documented + deprecation policy.
- 5 — typed + documented + deprecation policy + a tested upgrade path
  from the prior version.

## Axis 2 — Correctness (0–5)

"Does it do what it says, including the edges?"

- 0 — happy path only; obvious bugs in non-happy paths.
- 1 — happy path tested; edges untested.
- 2 — edge cases listed in tests but assertions are weak.
- 3 — edge cases tested with meaningful assertions.
- 4 — property tests, fuzz tests, or generative tests where applicable.
- 5 — same plus a regression suite proving previously-broken inputs stay
  fixed.

## Axis 3 — Craft (0–5)

"Implementation quality from a maintainer's point of view."

- 0 — no tests, no types.
- 1 — sparse tests.
- 2 — tests cover the surface; internals are a maze.
- 3 — tests + clear internal structure; one read-through is enough.
- 4 — tests + structure + readable commit history.
- 5 — same plus a meaningful benchmark or perf guard.

## Axis 4 — Consumer Experience (0–5)

"What is it like to actually import and use this?"

- 0 — import fails or has hidden side effects.
- 1 — import works; first call is confusing.
- 2 — works after reading the README twice.
- 3 — README's quickstart works verbatim.
- 4 — quickstart works, types autocomplete in the consumer's IDE.
- 5 — same plus a runnable example in the repo that the evaluator opens
  and exercises.

## Evidence the evaluator must capture

- Test runner output for the library.
- Type-check output (tsc, mypy, etc.).
- A minimal consumer script that imports and exercises the public
  surface, with its output captured.
- README quickstart exercised verbatim.

## PASS bar

- Every axis >= 3.
- No `passes: false` in `test-results.json`.
- Every acceptance criterion has at least one piece of evidence opened
  with the Read tool.
- The evaluator imported and used the library, not just inspected it.

## NEEDS_WORK triggers

- Any axis at <= 2.
- "All tests pass" with no consumer-side exercise.
- Public API drift from documented contract.
- README claims behavior that isn't covered by a test.
