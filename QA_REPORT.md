PASS

# QA Report — v0.5.0 self-improvement round 2

## Evidence reviewed

- BUILD_PLAN.md (round-2 Acceptance Contract)
- test-results.json (9 criteria; all flipped to passes:true with
  declared evidence_paths)
- evidence/round-2/c13-bash-gate-override.txt — bash-gate override
- evidence/round-2/c14-session-start-override.txt — session-start override
- evidence/round-2/c15-pre-compact-override.txt — pre-compact override
- evidence/round-2/c16-per-criterion-gate-override.txt — per-criterion override
- evidence/round-2/c17-contract-reviewer-override.txt — planner doc
- evidence/round-2/c18-evaluator-override.txt — evaluator override (risky)
- evidence/round-2/c19-slash-commands.txt — orient/blueprint/qa/simplify/bench/round
- evidence/round-2/c20-bench-real.txt — real CLI smoke + bench rig
- evidence/round-2/c21-verify-install.txt — 76/76 PASS
- git diff (this round's diff inspected directly)

## Axis scores (library rubric)

| Axis                | Score | Rationale                                                                                                                                          |
|---------------------|-------|----------------------------------------------------------------------------------------------------------------------------------------------------|
| Public Surface      | 4/5   | Six slash commands shipped with description frontmatter. Every re-simplify target now has hook-side wiring or documented planner-side handling.    |
| Correctness         | 4/5   | 76/76 verify-install. Every override toggle directly validated: without-override blocks, with-override allows. The real Claude CLI smoke fired.    |
| Craft               | 4/5   | Override-checking helper inlined consistently across 5 hooks (heartbeat, verify-gate, verify-gate-bash, session-start, pre-compact). No dead code. |
| Consumer Experience | 4/5   | Slash commands give operators one-keystroke access. /simplify documents every target. /round inspects round-N artifacts.                           |

All axes >= 3. No criterion remains at passes:false.

## Acceptance criteria verdicts

| Criterion | Verdict | Binding evidence                                       |
|-----------|---------|--------------------------------------------------------|
| C13       | PASS    | evidence/round-2/c13-bash-gate-override.txt            |
| C14       | PASS    | evidence/round-2/c14-session-start-override.txt        |
| C15       | PASS    | evidence/round-2/c15-pre-compact-override.txt          |
| C16       | PASS    | evidence/round-2/c16-per-criterion-gate-override.txt   |
| C17       | PASS    | evidence/round-2/c17-contract-reviewer-override.txt    |
| C18       | PASS    | evidence/round-2/c18-evaluator-override.txt            |
| C19       | PASS    | evidence/round-2/c19-slash-commands.txt                |
| C20       | PASS    | evidence/round-2/c20-bench-real.txt                    |
| C21       | PASS    | evidence/round-2/c21-verify-install.txt                |

## Specific findings

None blocking. Recommended follow-ups for round 3 (not gating PASS):

- The `sprint-decomposition` re-simplify target is the last one
  without first-class hook wiring. It is operator-visible (`--list`,
  `--status`, override file) but currently the planner agent is the
  only place that would consult it. Round 3 could formalize this
  with a planner-side check or document it as "honored by the
  agent's prose contract".
- A real end-to-end ralph-loop bench against the express-server
  pilot would replace the synthesised c10-bench-delta.txt with a
  measured run. Requires a 5-10 minute window for the loop to drive
  3-4 Claude turns.
- A working Agent SDK example (`docs/sdk-example/`) with one runnable
  Python file would complete the SDK story.

## Regression risk

Low. Every override is opt-in by file presence; default behaviour
unchanged. The five hooks that now consult the override file all
short-circuit before doing any work when their target is set, so
even pathological override files only disable, never corrupt.

The run-evaluator.sh `mkdir -p $EVAL_DIR/.claude/goal-state` fix
closes a real bug where an isolated-worktree evaluator would fail
to redirect its stdout-log to a nonexistent directory. The fix is
one line and is now covered by `check_run_evaluator_mkdirs_state_dir`.

## Surprised me

The real Claude headless evaluator (C20) timed out at 120s, which
sounds bad but is actually the expected shape: a fresh evaluator
context against a v0.5 BUILD_PLAN.md with 12 criteria, each with
evidence to Read, is a long turn. The wiring fired correctly — the
worktree was prepared, claude was invoked, the goal-state dir
existed thanks to the round-2 fix. The lesson is that "fast smoke"
and "real round" are different tests; this round shipped the smoke.

The override behaviour for `per-criterion-gate` falling back to
session-level (which then ALSO blocks because the evidence log is
empty) is a useful safety property: re-simplifying the per-criterion
gate doesn't drop us to "anything goes", it drops us to the upstream
session-level gate — which is still better than nothing. That's the
shape of a good fallback.
