# BUILD_PLAN

## Goal

Take the AI Heroes long-running agent harness from v0.4.0 ("planner /
contract-reviewer / generator / evaluator with rubric library + watchdog +
bench rig") to unequivocal **100% parity** with
`anthropics/cwc-long-running-agents` plus the **March 2026 article's
"Going further" patterns**, and **150% performance** measured by the
in-repo bench rig. Fix the critical bugs that silently break primitives.
Close the architecture gaps the previous critique missed. Generalize the
framing so the harness no longer reads as Discord-specific.

## Product Spec

The shipped artifact is this repo. The user installs it as a Claude Code
plugin, registers a goal, and the loop runs unattended until the
evaluator says PASS with the interaction trace to back it up.

The harness must:

1. Run every official upstream primitive correctly (default-FAIL
   contract, fresh-context evaluator, agent-maintained handoff,
   kill-switch, steering).
2. Add the article's "Going further" patterns end-to-end: unattended
   loop, planner agent, sprint contracts, grading rubrics, browser-
   verified evaluator, re-simplify-on-upgrade procedure.
3. Carry NEEDS_WORK findings into the next session automatically
   without operator intervention.
4. Be invokable from headless / cron without an external launcher.
5. Be measurable: bench rig produces a score JSON; `bench-score.py`
   diffs against an upstream baseline.
6. Be model-portable: every component that depends on a Claude or Codex
   model identity is stamped in `rounds.json` so the operator can
   re-simplify on upgrade.

## Acceptance Contract

1. **C1 — track-read.sh recognizes every evidence shape the planner
   declares.** `evidence/round-N/*.txt`, `evidence/round-N/*.log`,
   `playwright-mcp/round-N/trace.zip` (and `.zip`), and
   `computer-use/round-N/session.jsonl` are all logged when Read.
2. **C2 — evaluator agent has Playwright MCP tools.** The agent's
   `tools:` frontmatter includes `mcp__playwright__*` so it can drive
   a browser when invoked via `claude --agent evaluator -p`.
3. **C3 — heartbeat-stop.sh and goal-watchdog.py both accept any
   non-empty interaction artifact under `playwright-mcp/round-N/`
   (not only `trace.zip`) and any non-empty file under
   `computer-use/round-N/` (not only `session.jsonl`).** Strict-name
   path stays as the preferred contract; the fallback is the floor.
4. **C4 — `scripts/ralph-loop.sh` ships and runs the full
   build → evaluate → re-build cycle headless** with a documented exit
   contract (0 on PASS, 1 on max-rounds, 2 on usage error). It honors
   the shared round-budget file. It writes `NEXT_FINDINGS.md` on every
   NEEDS_WORK. It is idempotent and safe to re-run.
5. **C5 — `NEXT_FINDINGS.md` carry-forward is wired.** The session-start
   hook surfaces it on top of orientation. The evaluator's NEEDS_WORK
   findings flow into it. The ralph-loop and the planner both honor it.
6. **C6 — Workspace AGENTS.md is seeded.** `register-goal.sh` writes a
   minimal `AGENTS.md` template alongside `PROGRESS.md` and `init.sh`
   so Codex sessions get the same orientation contract.
7. **C7 — Re-simplify procedure ships.** A `scripts/re-simplify.sh`
   that lets the operator disable one harness piece, re-run the bench,
   and decide if the piece is still load-bearing.
8. **C8 — Plugin framing is general.** Top-of-CLAUDE.md no longer leads
   with "Discord is the status channel". README and CLAUDE.md make
   clear Discord is one optional adapter.
9. **C9 — Agent SDK equivalence is documented.** A `docs/agent-sdk-equivalent.md`
   maps every hook to its `PreToolUse` / `Stop` callback equivalent.
10. **C10 — Bench rig produces an upstream baseline and a candidate
    score, and `bench-score.py` reports the delta.** This is how the
    "150% performance" claim becomes earnable, not rhetoric.
11. **C11 — `verify-install.sh` grows to cover every C1-C10 fix** and
    every PASS check stays green on this machine (modulo the 4
    expected codex-env failures that need a `~/.claude/codex-current-model.env`).
12. **C12 — Round artifact namespacing is honored end-to-end.** The
    planner declares round-N paths; the evaluator writes only to
    round-N; the heartbeat reads round-N; old rounds are never
    overwritten silently.

## Evidence Required

| Criterion | Evidence path                                                          |
|-----------|------------------------------------------------------------------------|
| C1        | `evidence/round-1/c1-track-read.txt` (output of track-read smoke)      |
| C2        | `evidence/round-1/c2-evaluator-tools.txt` (grep of mcp__playwright__*) |
| C3        | `evidence/round-1/c3-trace-fallback.txt` (heartbeat smoke with .trace) |
| C4        | `evidence/round-1/c4-ralph-loop-dry-run.txt`                           |
| C5        | `evidence/round-1/c5-next-findings.txt`                                |
| C6        | `evidence/round-1/c6-agents-md.txt` (register-goal seeds AGENTS.md)    |
| C7        | `evidence/round-1/c7-re-simplify.txt` (re-simplify dry-run)            |
| C8        | `evidence/round-1/c8-claude-md.txt` (head of new CLAUDE.md)            |
| C9        | `evidence/round-1/c9-sdk-doc.txt` (head of new doc)                    |
| C10       | `evidence/round-1/c10-bench-delta.txt` (bench-score output)            |
| C11       | `evidence/round-1/c11-verify-install.txt` (full PASS output)           |
| C12       | `evidence/round-1/c12-round-namespacing.txt` (find playwright-mcp + computer-use round dirs) |

All evidence files live under `evidence/round-1/` so the round-N
namespacing pattern is honored from this run forward.

## Evaluator Rubric

(Copy of `agents/rubrics/library.md`. This task ships a reusable
Claude Code plugin; consumers are other operators installing the
plugin into their own workspaces.)

### Axis 1 — Public Surface (0–5)

"Is the API a thing a reasonable consumer can use without reading the
source?"

- 0 — exports unstable, names misleading, no contract.
- 1 — exports work but only with insider knowledge.
- 2 — basic public surface; missing types or docs.
- 3 — typed, documented, named consistently with peers in the ecosystem.
- 4 — typed + documented + deprecation policy.
- 5 — typed + documented + deprecation policy + a tested upgrade path
  from the prior version.

### Axis 2 — Correctness (0–5)

"Does it do what it says, including the edges?"

- 0 — happy path only; obvious bugs in non-happy paths.
- 1 — happy path tested; edges untested.
- 2 — edge cases listed in tests but assertions are weak.
- 3 — edge cases tested with meaningful assertions.
- 4 — property tests, fuzz tests, or generative tests where applicable.
- 5 — same plus a regression suite proving previously-broken inputs stay
  fixed.

### Axis 3 — Craft (0–5)

"Implementation quality from a maintainer's point of view."

- 0 — no tests, no types.
- 1 — sparse tests.
- 2 — tests cover the surface; internals are a maze.
- 3 — tests + clear internal structure; one read-through is enough.
- 4 — tests + structure + readable commit history.
- 5 — same plus a meaningful benchmark or perf guard.

### Axis 4 — Consumer Experience (0–5)

"What is it like to actually install this plugin and run a goal?"

- 0 — install fails or hidden side effects.
- 1 — install works; first run is confusing.
- 2 — works after reading the README twice.
- 3 — README quickstart works verbatim.
- 4 — quickstart works AND `verify-install.sh` greens on first try.
- 5 — same plus a runnable bench pilot the operator opens and exercises.

## Suggested Build Path

1. Fix C1, C2, C3 (critical bugs) in one batch and add a verify-install
   check each.
2. Ship C4 (ralph-loop) + C5 (NEXT_FINDINGS) + C6 (AGENTS.md) as a unit
   since they all live in the wrapper-loop architecture.
3. Add C7 (re-simplify), C8 (generalized framing), C9 (SDK doc).
4. Run the bench rig and produce C10 (delta vs. upstream baseline).
5. Expand `verify-install.sh` to cover everything (C11), run it, paste
   the output as C11 evidence.
6. Update CHANGELOG and README. Commit. Push.

## Out of Scope

- Renaming the plugin slug (rename would break existing installs;
  generalize framing in docs instead).
- Wiring real Discord bot ingestion (still operator-via-STEER.md).
- Computer-use MCP server install (commented example only).
- Hosted Claude Managed Agents integration.

## Interaction Evidence

This rubric is `library`, not `frontend` or `desktop`, so no Playwright
trace or computer-use session log is required by the heartbeat hook.
The evaluator must instead:

- import the plugin into a throwaway workspace,
- run `verify-install.sh`,
- run `scripts/ralph-loop.sh --dry-run` and `scripts/re-simplify.sh --dry-run`,
- run `scripts/bench-harness.sh` against the express-server pilot,
- open every evidence file under `evidence/round-1/` with the Read tool.
