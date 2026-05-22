# BUILD_PLAN

## Goal

Round 3 polish. Round 2 closed the re-simplify wiring and added slash
commands. Round 3 closes the small remaining gaps the round-2 QA
report called out: sprint-decomposition planner-side handling, an
SDK example skeleton consumers can actually run, and README
freshness on the slash-command surface and the verify-install
count.

## Product Spec

After round 3, every recommendation from the round-1 QA "Specific
findings" section and the round-2 QA "Specific findings" section is
either landed or explicitly out-of-scope and documented. The README
matches the shipped state. The plugin is the genuine "world's best
Claude harness for long-running agents" claim — earned, not declared.

## Acceptance Contract

1. **C22 — planner agent documents the sprint-decomposition
   re-simplify override.** When the override is set, the planner
   collapses Suggested Build Path to a single bullet noting the
   override.
2. **C23 — `docs/sdk-example/` ships a runnable Python skeleton**
   that ports the PreToolUse evidence gate and Stop heartbeat into
   Agent SDK callbacks. The file parses with `python3 -c "import ast; ast.parse(open(...).read())"`.
3. **C24 — README documents all six slash commands** (orient,
   blueprint, qa, simplify, bench, round) in a dedicated table.
4. **C25 — README's "48 PASS checks" / "68 PASS checks" stale
   references updated to 76.**
5. **C26 — verify-install grows to 80 checks** covering C22, C23,
   C24, C25 and stays green.

## Evidence Required

| Criterion | Evidence path                                |
|-----------|----------------------------------------------|
| C22       | evidence/round-3/c22-sprint-decomposition.txt|
| C23       | evidence/round-3/c23-sdk-example.txt         |
| C24       | evidence/round-3/c24-readme-commands.txt     |
| C25       | evidence/round-3/c25-readme-count.txt        |
| C26       | evidence/round-3/c26-verify-install.txt      |

## Evaluator Rubric

Same library rubric.

## Suggested Build Path

1. Add planner doc for sprint-decomposition.
2. Ship docs/sdk-example/{README.md, sdk_loop.py}.
3. Update README with slash command table and 76 PASS count.
4. Add 4 verify-install checks. Run. Capture.

## Out of Scope

- A real end-to-end ralph-loop bench (still requires 10+ minute
  budget per round; documented in round-2 QA).
- frontend-design skill integration (cosmetic; round 2 noted as
  optional).

## Interaction Evidence

Library rubric.
