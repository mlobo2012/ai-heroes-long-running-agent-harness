# Evaluator Rubric — Desktop / Native computer-use task

Four axes for work whose final surface is **not a browser**: a CLI that
launches a GUI, a desktop app under test, an installer flow, an OS-level
agent driving another piece of software. The planner copies this block
verbatim into `BUILD_PLAN.md > Evaluator Rubric` for any non-browser
interactive task. The evaluator scores each axis 0-5 in `QA_REPORT.md`.

The evaluator must drive the live surface using **native computer use**
(Claude's `computer_*` tool family or the Codex equivalent invoked via
the configured MCP server) and capture a session log plus at least one
screenshot. Static-diff review is not enough. The heartbeat hook
**rejects PASS** if the interaction-evidence path is missing or empty
for this rubric.

## Interaction-evidence contract

Round-N evidence must land at exactly these paths (the heartbeat hook
checks them by name):

- `computer-use/round-N/session.jsonl` — append-only log of every action
  taken (mouse, keyboard, screenshot, wait). One JSON object per line:
  `{"at":"<iso>","action":"click|type|key|wait|screenshot","target":"...","result":"ok|fail"}`.
- `computer-use/round-N/screenshots/*.png` — at least one screenshot per
  acceptance criterion that touches an interactive surface.
- `computer-use/round-N/notes.md` (optional) — human-readable narration
  of what was observed.

If Playwright would also apply (e.g., the task has both a CLI and a
browser surface), the evaluator may *also* drop a trace at
`playwright-mcp/round-N/trace.zip`. Either path satisfies the gate; both
satisfies it harder.

## Axis 1 — Behavior Under Real Input (0-5)

"Does the system do the right thing when a real user pokes at it?"

- 0 — primary flow does not run when launched the documented way.
- 1 — happy path runs only with the author's exact input.
- 2 — happy path runs broadly; errors leak to the user as raw stack
  traces or silent failures.
- 3 — happy path + common error inputs produce sensible behavior the
  user can recover from.
- 4 — same plus accessibility affordances (keyboard, screen-reader, OS
  text-size respected).
- 5 — same plus a recorded session of an adversarial input (truncated
  paste, network drop, permission denial) handled cleanly.

## Axis 2 — Integration With The OS (0-5)

"How well does this co-operate with the platform it claims to run on?"

- 0 — leaves the OS in a broken state (orphan processes, locked files,
  registry/keyring garbage).
- 1 — runs but ignores OS conventions (wrong file locations, ignores
  dark mode, ignores keyboard locale).
- 2 — respects file-location conventions but ignores other affordances.
- 3 — respects file locations, theme, locale, and shutdown handling.
- 4 — same plus first-run experience is clean (no leftover prompts,
  permissions requested with reason).
- 5 — same plus a clean uninstall path documented and demonstrated.

## Axis 3 — Craft (0-5)

"Engineering quality from a maintainer's point of view."

- 0 — no tests, no logs, no entrypoint script.
- 1 — sparse tests covering the happy path only.
- 2 — tests cover happy + obvious errors; logs are noisy or unstructured.
- 3 — tests + structured logs + a documented entrypoint (`init.sh` or
  equivalent).
- 4 — same plus a property test or fuzz where applicable.
- 5 — same plus a regression suite that would catch a previously fixed
  bug if it returned.

## Axis 4 — Operational Fitness (0-5)

"Can a stranger pick this up tomorrow and ship it again?"

- 0 — only the author can build or run it.
- 1 — buildable elsewhere if the reader hunts for the secret.
- 2 — README explains startup but values still hardcoded.
- 3 — `init.sh` + env config; doctor / preflight check present.
- 4 — same plus a documented rollback / undo story.
- 5 — same plus telemetry (rows in / out / errors) that an operator can
  graph.

## Evidence the evaluator must capture

- `computer-use/round-N/session.jsonl` proving each acceptance criterion
  was actually driven.
- At least one screenshot per criterion at the moment the verifier-
  visible state of the system shows the criterion is satisfied.
- A short narrative in `computer-use/round-N/notes.md` describing what
  the evaluator observed AND what surprised them.
- Test runner output (where applicable) opened with Read.
- Log capture from at least one realistic flow.

## PASS bar

- Every axis >= 3.
- No `passes: false` in `test-results.json`.
- `computer-use/round-N/session.jsonl` exists with at least one logged
  action per criterion, OR the task has a browser surface and
  `playwright-mcp/round-N/trace.zip` is present and non-empty.
- Every acceptance criterion has at least one piece of evidence opened
  with the Read tool.
- The evaluator personally drove the live surface this round.

## NEEDS_WORK triggers

- Any axis at <= 2.
- "Tested manually" with no `computer-use/round-N/` evidence.
- Session log exists but has zero entries for one or more criteria.
- Screenshots present but show a state inconsistent with the claim.
- Evaluator narrative omits any mention of what surprised them. If
  nothing surprised the evaluator, the evaluator did not actually drive
  the app.

## Guardrails for native computer use

The same skepticism applied to Playwright applies here. The evaluator
must not:

- claim a flow worked without a logged screenshot at the success state,
- log actions that were not actually executed (the log is append-only;
  never rewrite it),
- exit the round without dumping a session log, even if everything passed.

If the configured computer-use MCP server is missing or refuses to
connect, the evaluator must return `NEEDS_WORK` with a finding that
points at the missing capability instead of approving the work.
