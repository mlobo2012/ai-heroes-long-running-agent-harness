---
description: Set, inspect, or restore a re-simplify override. Disable one harness piece, run the bench, decide if it is still load-bearing on the current model.
---

Invoke the re-simplify procedure described in the March 2026 article:
"Every component encodes assumptions about model limitations. These
assumptions warrant continuous stress-testing because they become
stale as capabilities improve."

Use this command to set or clear a re-simplify override:

- `--list` — show available targets.
- `--status` — show currently-set overrides.
- `--target X --reason "..."` — disable X for this workspace.
- `--restore [--target X]` — clear one or all overrides.

Valid targets and what each disables when set:

| Target               | Effect                                                                |
|----------------------|-----------------------------------------------------------------------|
| contract-reviewer    | Planner skips the contract-reviewer handshake.                        |
| sprint-decomposition | Builder uses longest coherent run instead of forced sprints.          |
| evaluator            | Heartbeat allows goal-completion without QA_REPORT.md=PASS. RISKY.    |
| per-criterion-gate   | verify-gate falls back to session-level evidence check.               |
| bash-gate            | verify-gate-bash is bypassed entirely.                                |
| session-start        | SessionStart hook emits skip notice; no orientation re-seed.          |
| pre-compact          | PreCompact hook emits skip notice; no snapshot written.               |
| playwright-trace     | heartbeat-stop skips the interaction-evidence gate for frontend/desktop. |

Run the bench with the override in place, restore, run the bench
without. Compare with `scripts/bench-score.py` to decide whether the
disabled piece is still earning its complexity on the current model.

Operator command: `scripts/re-simplify.sh $ARGUMENTS`
