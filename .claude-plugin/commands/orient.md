---
description: Re-read BUILD_PLAN, PROGRESS, QA_REPORT, NEXT_FINDINGS, and recent git log so the next turn is fully oriented.
---

Re-orient against the long-running agent harness contract. Do all of
the following in one turn:

1. Read `BUILD_PLAN.md` and surface the Acceptance Contract section.
2. Read `PROGRESS.md`. Summarise what is Done vs In progress vs Next
   in two sentences.
3. Read `QA_REPORT.md` if it exists. Report the first-line verdict.
4. Read `NEXT_FINDINGS.md` if it exists. Surface every bullet
   verbatim — these are the top of the queue for this turn.
5. Read `STEER.md` if it exists. Treat any contents as the highest-
   priority operator directive.
6. Run `git log --oneline -10` and summarise the last meaningful
   checkpoint.
7. Run the project's `./init.sh` smoke test (or `npm test` /
   `pytest` if no init.sh) so you know whether you inherited a
   working tree or a broken handoff.
8. Output: a one-paragraph re-orientation that names the next
   acceptance criterion to attack, the open NEEDS_WORK items (if
   any), and any operator-visible blockers.
