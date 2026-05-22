---
name: rubric-template
description: Copy this scaffold when a strict evaluator needs named dimensions.
---

# Rubric Template

Use this scaffold when a brief names an optional rubric path for
`agents/evaluator-strict.md`. Replace the placeholder dimensions with the
goal-specific criteria before grading.

## Verdict Rule

Return `PASS` only when every dimension is `PASS`. Return `NEEDS_WORK` when any
dimension is `NEEDS_WORK`, and name the failing dimension or dimensions in the
verdict.

## Dimensions

| Dimension | Weight | PASS | NEEDS_WORK |
|---|---:|---|---|
| Dimension 1: Goal fit | 20% | The work directly satisfies the stated goal and acceptance criteria. | The work misses, narrows, or changes a required part of the goal. |
| Dimension 2: Evidence quality | 20% | Evidence files are readable, specific, and support the claimed outcome. | Evidence is missing, stale, inaccessible, or only loosely related to the claim. |
| Dimension 3: Completeness | 20% | All required deliverables are present and integrated into the expected paths. | One or more required deliverables are absent, partial, or in the wrong location. |
| Dimension 4: Correctness | 20% | The implementation or content is internally consistent and technically accurate. | The work contains factual, logical, behavioral, or integration errors. |
| Dimension 5: Maintainability | 20% | The result follows local conventions and is easy for the next operator to inspect or extend. | The result is hard to audit, overcomplicated, undocumented where needed, or inconsistent with local patterns. |

## Grading Notes

- Keep weights equal unless the copied rubric explicitly changes them.
- Grade each dimension explicitly before the final verdict.
- Do not average away a hard failure: a single required dimension at
  `NEEDS_WORK` means the overall verdict is `NEEDS_WORK`.
