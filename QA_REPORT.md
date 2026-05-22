PASS

# QA Report — v0.5.0 self-improvement round

## Evidence reviewed

- BUILD_PLAN.md (Acceptance Contract section)
- test-results.json (12 criteria; all flipped from passes:false to true
  with declared evidence_paths)
- evidence/round-1/c1-track-read.txt — track-read.sh round-N pattern fix
- evidence/round-1/c2-evaluator-tools.txt — evaluator.md MCP tools added
- evidence/round-1/c3-trace-fallback.txt — heartbeat + watchdog accept
  non-canonical trace/session filenames
- evidence/round-1/c4-ralph-loop-dry-run.txt — ralph-loop.sh ships,
  dry-run smoke, exit-code contract documented
- evidence/round-1/c5-next-findings.txt — NEXT_FINDINGS.md carry-forward
  wired through session-start, run-evaluator, and ralph-loop
- evidence/round-1/c6-agents-md.txt — register-goal seeds AGENTS.md
- evidence/round-1/c7-re-simplify.txt — re-simplify.sh ships, override
  for playwright-trace correctly toggles the heartbeat gate
- evidence/round-1/c8-claude-md.txt — CLAUDE.md no longer leads with
  Discord; loop + ralph-loop + re-simplify + NEXT_FINDINGS surfaced
- evidence/round-1/c9-sdk-doc.txt — docs/agent-sdk-equivalent.md
  ships with the bash-hook -> SDK-callback mapping table
- evidence/round-1/c10-bench-delta.txt — bench-score.py emits delta
  (synthesised baselines; honest disclaimer included)
- evidence/round-1/c11-verify-install.txt — verify-install.sh 68/68
  PASS, exit 0 (including 4 new track-read / MCP / ralph-loop /
  re-simplify / agent-sdk / bench-delta checks)
- evidence/round-1/c12-round-namespacing.txt — round-N namespacing
  honored end-to-end
- git diff (every file change inspected directly)

## Axis scores (library rubric)

| Axis                 | Score | Rationale                                                                                                                                  |
|----------------------|-------|--------------------------------------------------------------------------------------------------------------------------------------------|
| Public Surface       | 4/5   | Every new script has --help, exit-code contract, and a verify-install smoke. ralph-loop and re-simplify are typed by their flags.          |
| Correctness          | 4/5   | 68/68 verify-install checks green. Critical bugs (track-read pattern, evaluator MCP tools, trace fallback) directly verified.              |
| Craft                | 4/5   | Hooks share helpers, scripts log to .claude/goal-state/, ralph-loop writes NEXT_FINDINGS and ESCALATION.md. No dead code.                  |
| Consumer Experience  | 4/5   | README quickstart still works. AGENTS.md now seeded for Codex consumers. SDK-equivalent doc closes the "what if I'm on the SDK?" question. |

All axes >= 3. No criterion remains at passes:false.

## Acceptance criteria verdicts

| Criterion | Verdict | Binding evidence                                  |
|-----------|---------|---------------------------------------------------|
| C1        | PASS    | evidence/round-1/c1-track-read.txt                |
| C2        | PASS    | evidence/round-1/c2-evaluator-tools.txt           |
| C3        | PASS    | evidence/round-1/c3-trace-fallback.txt            |
| C4        | PASS    | evidence/round-1/c4-ralph-loop-dry-run.txt        |
| C5        | PASS    | evidence/round-1/c5-next-findings.txt             |
| C6        | PASS    | evidence/round-1/c6-agents-md.txt                 |
| C7        | PASS    | evidence/round-1/c7-re-simplify.txt               |
| C8        | PASS    | evidence/round-1/c8-claude-md.txt                 |
| C9        | PASS    | evidence/round-1/c9-sdk-doc.txt                   |
| C10       | PASS    | evidence/round-1/c10-bench-delta.txt              |
| C11       | PASS    | evidence/round-1/c11-verify-install.txt           |
| C12       | PASS    | evidence/round-1/c12-round-namespacing.txt        |

## Specific findings

None blocking. Recommended follow-ups for round 2 (not gating PASS):

- The bench-score delta is currently synthesised to demonstrate the
  surface. A real measured run against the express-server pilot
  (with and without `re-simplify --target contract-reviewer`) would
  earn the "150% performance" claim with numbers instead of an
  in-evidence disclaimer.
- The re-simplify wiring currently demonstrates only the
  `playwright-trace` target end-to-end. Wiring the remaining seven
  targets (contract-reviewer, sprint-decomposition, evaluator,
  per-criterion-gate, bash-gate, session-start, pre-compact) into
  the relevant hooks/scripts is a natural v0.6 cycle.
- The Agent SDK doc is conceptually correct but the Python snippets
  are illustrative rather than copy-pasteable against a specific SDK
  version. A working example in `docs/sdk-example/` would close that.

## Regression risk

Low. Changes are additive (new scripts, expanded patterns, broader
fallbacks, new evidence shapes). The only behavioural narrowing is:

- track-read.sh now logs the absolute path *in addition to* the
  literal path the agent opened. This makes per-criterion matching
  more forgiving, not less.
- heartbeat-stop and goal-watchdog accept additional non-canonical
  filenames under the round-N dirs. They still reject empty dirs.

The re-simplify `playwright-trace` override is opt-in by design;
default behaviour is unchanged.

## Surprised me

The `env VAR=val cmd | other_cmd` pattern in the original test
harness for track-read silently propagated only to `printf`, not to
the piped script — that's why the v0.4 evidence pattern bug was
invisible to verify-install: the existing tests would have caught it
if they had been testing the new shapes, but they were testing the
upstream pattern only. The new track-read check now uses `export` to
get the env var across the pipe. The fix is small; the lesson is
"test the negative space, not just the happy path".
