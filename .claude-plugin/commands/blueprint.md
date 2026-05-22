---
description: Invoke the planner subagent to produce BUILD_PLAN.md and a default-fail test-results.json against the operator goal.
---

Invoke the bundled `planner` subagent. It will:

1. Read the operator goal (everything after the slash command).
2. Honor `.claude/goal-state/goal-state.json`'s pinned rubric if set.
3. Pick a rubric from `agents/rubrics/` if none is pinned.
4. Write `BUILD_PLAN.md` with Goal, Product Spec, Acceptance Contract
   (numbered, observable, evidence-bound), Evidence Required (with
   round-N namespaced paths), Evaluator Rubric (copied verbatim),
   Suggested Build Path, Out of Scope, and Interaction Evidence.
5. Write `test-results.json` with every acceptance criterion set to
   `passes:false` and bound to an `evidence_paths` list.
6. Run the contract-reviewer subagent. Loop until `CONTRACT_OK` or
   the `--max-rounds` cap (3 by default).
7. Return a concise summary.

Operator goal: $ARGUMENTS
