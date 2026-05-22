# Evaluator Rubric — Frontend / UI

The four axes are from Anthropic's March 2026 harness-design article. The
planner copies this block verbatim into `BUILD_PLAN.md > Evaluator Rubric`
when the task is UI-facing. The evaluator scores each axis 0–5 in
`QA_REPORT.md`. PASS requires every axis at >= 3 AND no `passes: false`
criterion remaining.

Browser evidence is mandatory for this rubric. The evaluator must drive
the running app through **Playwright MCP** (preferred for browser
work) or, on environments where the browser surface is part of a wider
desktop interaction, via **native computer use** (Claude's `computer_*`
tool family or Codex's equivalent invoked via the configured MCP
server). The heartbeat hook refuses goal-completion if neither a
non-empty `playwright-mcp/round-N/trace.zip` nor a non-empty
`computer-use/round-N/session.jsonl` exists. Static-diff review is not
enough.

## Interaction-evidence contract

Round-N evidence must land at exactly one of these paths:

- `playwright-mcp/round-N/trace.zip` — Playwright trace covering at
  least the primary flow. The `PLAYWRIGHT_TRACE_DIR` env var in
  `.mcp.json` already points the MCP server here; the evaluator must
  not write elsewhere.
- `computer-use/round-N/session.jsonl` — append-only action log if the
  evaluator used native computer use instead. Same shape as the desktop
  rubric: one JSON object per line.

If both are produced, the gate is doubly satisfied. If neither is, the
heartbeat hook treats QA_REPORT.md `PASS` as `awaiting-interaction-evidence`
and refuses to allow goal-completion.

## Axis 1 — Design Quality (0–5)

"Does the design feel like a coherent whole rather than a collection of
parts?"

- 0 — incoherent: clashing styles, mismatched components, no shared system.
- 1 — visibly stitched together; primary surfaces don't agree.
- 2 — passable but generic; reads as default library output.
- 3 — coherent system across the changed surfaces.
- 4 — coherent and intentional; clear visual hierarchy and rhythm.
- 5 — coherent, intentional, and tuned: spacing, typography, and color
  reinforce each other.

## Axis 2 — Originality (0–5)

"Is there evidence of custom decisions, or is this template layouts,
library defaults, and AI-generated patterns?"

- 0 — pure template / shadcn defaults / gradient-card-stack cliché.
- 1 — minor cosmetic tweaks over a known template.
- 2 — visible attempt at customization but still derivative.
- 3 — clear custom design choices for the primary surfaces.
- 4 — distinctive identity; competitors' work would not be mistaken for it.
- 5 — distinctive identity AND a defensible reason for each major choice.

Avoid: purple-gradient hero, three-cards-in-a-row marketing layout,
generic dashboard chrome, AI-pastel palettes.

## Axis 3 — Craft (0–5)

"Technical execution: typography hierarchy, spacing consistency, color
harmony, contrast ratios."

- 0 — broken layout, overlapping text, wrong colors, failing contrast.
- 1 — alignment off, inconsistent spacing, hierarchy unclear.
- 2 — acceptable in calm states; breaks under interaction or at smaller
  viewports.
- 3 — consistent spacing/typography/contrast across the primary flow.
- 4 — consistent across all flows including hover/focus/active/disabled.
- 5 — pixel-considered: motion, microcopy, empty states, loading states
  and error states all handled.

Contrast must clear WCAG AA on text. The evaluator should spot-check.

## Axis 4 — Functionality (0–5)

"Usability independent of aesthetics."

- 0 — primary flow does not work.
- 1 — primary flow works only on the happy path.
- 2 — happy path works; common edge cases break.
- 3 — primary and one secondary flow work, edge cases handled.
- 4 — all advertised flows work, keyboard accessible, errors are
  recoverable.
- 5 — all flows work, accessible, performant, and the affordances make
  the intended action obvious.

## Evidence the evaluator must capture

- Screenshot of each acceptance-criterion screen at desktop (>= 1280px)
  and mobile (<= 414px), under `screenshots/round-N/`.
- Console-log capture for the same flows (no uncaught errors, no
  unhandled promise rejections), under `evidence/round-N/console-*.txt`.
- Either a Playwright trace at `playwright-mcp/round-N/trace.zip` OR a
  computer-use session log at `computer-use/round-N/session.jsonl`. One
  of these is mandatory; the heartbeat gate enforces it.
- Contrast spot-check for primary text and primary CTA.

## PASS bar

- Every axis >= 3.
- No `passes: false` in `test-results.json`.
- Every acceptance criterion has at least one piece of evidence opened
  with the Read tool.
- The evaluator personally drove the app this round (via Playwright or
  native computer use), not just reviewed artifacts.
- A non-empty interaction trace exists under
  `playwright-mcp/round-N/trace.zip` or `computer-use/round-N/session.jsonl`.

## NEEDS_WORK triggers

- Any axis at <= 2.
- Generic / template-feeling output even if functionally correct.
- "Looks impressive in screenshots but the interaction is broken when
  driven."
- Evidence list contains files that do not open or do not show what they
  claim.
