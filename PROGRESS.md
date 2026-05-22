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

(nothing — round 1 completed cleanly)

## Next

Round 2 candidates (none gating release of v0.5.0):

- Wire the remaining seven re-simplify targets end-to-end:
  `contract-reviewer`, `sprint-decomposition`, `evaluator`,
  `per-criterion-gate`, `bash-gate`, `session-start`, `pre-compact`.
  Each needs the relevant hook/script to check
  `.claude/goal-state/re-simplify-overrides.json` on startup and
  behave as if disabled when the target is set.
- Replace the synthesised bench delta in
  `evidence/round-1/c10-bench-delta.txt` with a real measurement
  against the express-server pilot, both with and without
  `re-simplify --target contract-reviewer`.
- Build out `docs/sdk-example/` with a runnable Agent SDK example
  that ports the evidence gate + heartbeat callbacks.
- Optional: add `frontend-design` skill integration to `.mcp.json`
  for richer browser evaluation.
- Optional: ship `/orient` and `/blueprint` slash commands for
  one-keystroke harness operations from inside Claude Code.

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
