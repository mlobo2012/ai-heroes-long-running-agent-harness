# PROGRESS

## Done

### v0.5.0 round 1 (2026-05-22)

Self-improvement session against this very repo, registered with
rubric=library, model=claude-opus-4-7, round_budget=6. All 12
acceptance criteria flipped from passes:false to passes:true with
declared evidence_paths Read first. QA_REPORT.md = PASS. Heartbeat
hook accepted goal-completion.

Critical bugs closed:

- `hooks/track-read.sh` now logs every v0.4 round-N evidence shape
  the planner declares. Previously a silent breakage: the agent
  would Read its own evidence and the gate would still block the
  write because the path didn't match the upstream pattern.
- `agents/evaluator.md` now grants `mcp__playwright__browser_*`
  tools. Previously the evaluator was mandated to drive the live
  app via Playwright MCP but lacked the tools to do so.
- `hooks/heartbeat-stop.sh`, `scripts/goal-watchdog.py`, and
  `scripts/run-evaluator.sh` now fall back to any non-empty regular
  file under `playwright-mcp/round-*/` or `computer-use/round-*/`
  when the strict-named `trace.zip` / `session.jsonl` is absent.

New primitives shipped:

- `scripts/ralph-loop.sh` — unattended build -> evaluate -> rebuild
  driver with documented exit-code contract, honors the shared
  round-budget file, writes NEXT_FINDINGS.md on every NEEDS_WORK.
- `scripts/re-simplify.sh` — eight-target re-simplify-on-upgrade
  procedure with override file the relevant hooks consult.
  `playwright-trace` is the first end-to-end wired target.
- `scripts/register-goal.sh` now seeds AGENTS.md alongside
  PROGRESS.md and init.sh for Codex parity.
- `hooks/session-start.sh` and `scripts/run-evaluator.sh` now both
  surface / produce NEXT_FINDINGS.md so evaluator findings carry
  forward without operator intervention.
- `docs/agent-sdk-equivalent.md` — maps every bash hook to its
  Claude Agent SDK callback equivalent.
- `CLAUDE.md` rewritten to lead with the loop, not with Discord.

`scripts/verify-install.sh` grew from 52 to 68 checks. 68/68 PASS.

## In progress

(nothing — round 3 completed cleanly)

### v0.5.2 round 3 (2026-05-22)

Polish round. Closed the last two QA recommendations from round 2.

- C22: `agents/planner.md` documents the sprint-decomposition
  re-simplify target. All 8 targets now have first-class handling
  (5 hook-wired, 2 planner-doc-wired, 1 with combined wiring + doc).
- C23: `docs/sdk-example/` ships a runnable ~150-line Python
  skeleton porting the evidence gate, heartbeat, and evaluator.
- C24-C25: README updated with slash-command table and refreshed
  PASS-check count.
- C26: verify-install grew 76 -> 80, exit 0.

rounds.json: 4 consecutive PASS verdicts.

### v0.5.0 round 2 (2026-05-22)

Closed 9 more criteria on top of round 1's 12. rounds.json now shows
two consecutive PASS verdicts stamped with rubric=library, model=
claude-opus-4-7.

- C13-C18: wired bash-gate, session-start, pre-compact, per-criterion-
  gate, evaluator, and (documentation for) contract-reviewer re-simplify
  targets end-to-end. Five hooks (verify-gate, verify-gate-bash,
  session-start, pre-compact, heartbeat-stop) now consult
  `.claude/goal-state/re-simplify-overrides.json` and short-circuit
  when their target is set.
- C19: six slash commands shipped at `.claude-plugin/commands/`:
  /orient, /blueprint, /qa, /simplify, /bench, /round.
- C20: real Claude CLI smoke fired against this very repo's round-1
  contract in an isolated worktree. The wrapper invoked claude
  --agent evaluator, hit a 120s budget, but proved the wiring works
  end-to-end (not just dry-run).
- Fixed a real bug: `scripts/run-evaluator.sh` now `mkdir -p`s the
  goal-state directory before invoking claude so the stdout-log
  redirect doesn't silently fail in fresh worktrees.
- C21: verify-install grew from 68 to 76 checks. 76/76 PASS.

## Next

Round 3 candidates (none gating v0.5.0):

- `sprint-decomposition` re-simplify target: currently operator-visible
  but with no hook-side enforcement (planner-prose only).
- A real measured ralph-loop bench against express-server.
- A runnable `docs/sdk-example/` Python file.
- `frontend-design` skill integration in `.mcp.json`.

## Notes

This session demonstrated the harness on itself. `rounds.json`
records the verdict stamped with rubric=library, model=
claude-opus-4-7, evidence_count=12. The same record will let a v0.6
session run `re-simplify --target X` and measure whether X is still
load-bearing on the model in use.

The 68th verify-install check (`bench-score reports a numeric
delta`) currently covers the surface of the tool; the actual claim
"150% performance" needs a measured run pair to back it up. The
honest disclaimer is in `evidence/round-1/c10-bench-delta.txt`.
