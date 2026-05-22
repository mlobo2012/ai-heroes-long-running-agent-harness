---
description: Show artifacts under a specific round-N directory. Useful for inspecting what the evaluator produced last round.
---

List every artifact under the round-N namespaced directories for the
round number passed as $ARGUMENTS (default: current round).

Specifically inspect:

- `screenshots/round-N/`
- `evidence/round-N/`
- `playwright-mcp/round-N/`
- `computer-use/round-N/`

Output a markdown table:

| Path | Size | Modified |
|------|------|----------|
| ...  | ...  | ...      |

Then run `scripts/diff-rounds.sh N $((N-1))` (if N > 1) to compare
this round to the previous one — verdicts, axis scores, criterion
deltas, artifact counts, and the git diff between recorded commit
shas.

Round number: $ARGUMENTS
