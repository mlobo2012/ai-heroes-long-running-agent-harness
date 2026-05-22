# BUILD_PLAN

## Goal

Round 2 of v0.5.x self-improvement. Round 1 closed the three critical
bugs and shipped ralph-loop, re-simplify, AGENTS.md, and the SDK doc.
Round 2 closes the remaining re-simplify wiring (the v0.6 candidates
PROGRESS.md called out), adds slash commands for one-keystroke harness
operations from inside Claude Code, and runs the bench rig
end-to-end against the express-server pilot to replace the round-1
synthesised delta with real numbers.

## Product Spec

The shipped artifact is still this repo. After round 2 a consumer
should be able to:

1. Install the plugin and immediately have `/orient`, `/blueprint`,
   `/verify-gate`, `/qa`, `/simplify`, and `/bench` available.
2. Toggle every re-simplify target end-to-end (not just
   `playwright-trace`) and have the harness actually behave as if
   the target were removed.
3. Run `scripts/bench-harness.sh` against the pilot in the same
   workspace and produce a real measured score JSON.

## Acceptance Contract

1. **C13 — re-simplify `bash-gate` target disables verify-gate-bash.**
   With override set, a `sed -i s/false/true/ test-results.json`
   passes the Bash gate. Without override, it blocks.
2. **C14 — re-simplify `session-start` target makes session-start
   emit a single-line "(disabled by re-simplify override)" notice
   and skip the orientation block.**
3. **C15 — re-simplify `pre-compact` target makes pre-compact emit
   a single-line skip notice and write no snapshot.**
4. **C16 — re-simplify `per-criterion-gate` target makes verify-gate
   fall back to session-level even when the results file uses the
   criteria array shape.**
5. **C17 — re-simplify `contract-reviewer` target documented (not
   wired into the planner directly because the planner is the agent
   that consults the override).** Round-2 evidence: the override
   appears in `re-simplify.sh --list` and a structured comment in
   `agents/planner.md` instructs the planner to honor the override
   if set.
6. **C18 — re-simplify `evaluator` target makes the heartbeat hook
   skip the QA_REPORT.md PASS requirement.** RISKY by design;
   documented as such.
7. **C19 — slash commands ship under `.claude-plugin/commands/` (or
   the harness equivalent path):** `/orient`, `/blueprint`, `/qa`,
   `/simplify`, `/bench`, `/round` (jump to a specific round's
   evidence dir).
8. **C20 — bench-harness.sh runs end-to-end against the
   express-server pilot in a throwaway workspace, the heartbeat
   accepts completion, and bench-score reports the candidate
   baseline.** If `claude` CLI is missing, the test still validates
   the harness up to the planner kick and records the gap honestly
   in the evidence.
9. **C21 — verify-install grows to cover every C13–C20 wiring** and
   stays green.

## Evidence Required

| Criterion | Evidence path                                              |
|-----------|------------------------------------------------------------|
| C13       | evidence/round-2/c13-bash-gate-override.txt                |
| C14       | evidence/round-2/c14-session-start-override.txt            |
| C15       | evidence/round-2/c15-pre-compact-override.txt              |
| C16       | evidence/round-2/c16-per-criterion-gate-override.txt       |
| C17       | evidence/round-2/c17-contract-reviewer-override.txt        |
| C18       | evidence/round-2/c18-evaluator-override.txt                |
| C19       | evidence/round-2/c19-slash-commands.txt                    |
| C20       | evidence/round-2/c20-bench-real.txt                        |
| C21       | evidence/round-2/c21-verify-install.txt                    |

## Evaluator Rubric

(Same library rubric as round 1; not duplicated here for brevity.
The 4 axes are: Public Surface, Correctness, Craft, Consumer
Experience. PASS requires every axis >= 3 and no `passes:false` row.)

## Suggested Build Path

1. Wire bash-gate, session-start, pre-compact, per-criterion-gate,
   evaluator overrides into their relevant hooks. Each gets a
   verify-install test.
2. Plant the contract-reviewer override doc and the planner-side
   comment.
3. Ship slash commands.
4. Run bench against express-server.
5. Re-run verify-install.

## Out of Scope

- Real Codex spawn (Codex CLI not present in this environment).
- Real Playwright browser run (no browser in this container).

## Interaction Evidence

Library rubric, so no Playwright/computer-use required.
