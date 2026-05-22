# Scope policies — design note

Status: design-locked 2026-05-22. Implementation lands in 0.9.0.

## Problem

The harness's Default-FAIL contract blocks completion only on existing
`test-results.json` rows. If a sprint discovers a new production blocker
that was not anticipated in the kickoff, the discovery is honest commentary
in PROGRESS.md or commits but does not mechanically block the goal. That is
the right default for fixed-scope research goals, but the wrong default for
production-hardening runs where adjacent failure discovery is the entire
point.

Marco's spec names three policies: `fixed_scope` (today's behaviour),
`production_hardening` (discoveries must be tracked and block), and
`research_only` (discoveries recorded, never block).

## Non-goals

- **No daemon.** No background blocker discovery engine.
- **No model judgment in the inner pulse.** The heartbeat hook stays a
  small bash script that reads structural state. Free-form reasoning about
  whether something is a "real blocker" stays where it belongs: in the
  generator+evaluator loop.
- **No new persistence layer.** Stable JSONL on disk under
  `.claude/goal-state/`, same as `last-beat`, `last-pass-count`, and the
  `codex-spawn-*.log` family.
- **No always-on scope creep.** Only opt-in goals get blocker-gated
  completion. The default is `fixed_scope` and is fully backward-compatible
  with every existing run.
- **No Discord-specific shape.** Blocker schema is generic; project-level
  rules live in a separate text field (`blocker_policy`).

## Integration points (smallest coherent set)

The mechanism touches four surfaces, each minimally:

1. **Goal-level config.** Add a top-level field to `test-results.json`:
   `"scope_policy": "fixed_scope" | "production_hardening" | "research_only"`.
   When the field is missing, treat as `fixed_scope`. This is the
   single source of truth for the run's completion semantics.

2. **Blocker ledger.** A new append-only JSONL file at
   `.claude/goal-state/blockers.jsonl`. One JSON object per line, schema:
   ```json
   {
     "id": "B-<short-slug>",
     "title": "<one line>",
     "severity": "critical|high|medium|low|nit",
     "status": "open|triaged|resolved|wontfix",
     "discovered_at": "<ISO8601>",
     "discovered_by": "<agent_id|operator>",
     "evidence_paths": ["evidence/.../*.txt", "..."],
     "reproduction_notes": "<freeform>",
     "affected_area": "<e.g. hooks/verify-gate.sh, agents/codex-executor.md>",
     "resolution_notes": "<freeform; required when status=resolved or wontfix>"
   }
   ```
   Append-only by convention (status updates land as new lines whose
   `id` matches an existing line; latest-wins on read). Lifecycle:
   `open` → `triaged` → `resolved` (or `wontfix`). `untriaged` is a
   computed view of records that are still `open`.

3. **Completion gate.** `hooks/heartbeat-stop.sh` gets a small additional
   block before `log_status "allow" "goal-met"`:
   ```
   if production_hardening:
     read blockers.jsonl, fold to latest-per-id
     count := records where status in (open) OR (status=triaged AND no evidence_paths)
     if count > 0:
       do NOT mark goal-met; continue to the normal block path
   ```
   `fixed_scope` and `research_only` skip the check; their completion
   semantics are unchanged from today.

   To make this auditable without grepping bash, the result is also
   recorded in `.claude/goal-state/blocker-gate.json` on every Stop:
   `{"policy": "...", "open_count": N, "triaged_unevidenced_count": M, "decision": "allow|block"}`.

4. **Evaluator contract.** `agents/evaluator.md` and
   `agents/evaluator-strict.md` get one paragraph each: "Before returning
   PASS, if `test-results.json` declares `scope_policy:
   production_hardening`, read `.claude/goal-state/blockers.jsonl` and
   confirm zero records are `open` or `triaged-without-evidence`. If any
   exist, return NEEDS_WORK and surface the blocker IDs."

   The builder/codex-executor brief template also gets a paragraph in
   `agents/codex-executor.md`: "In `production_hardening`, when you
   discover a production blocker, record it via
   `scripts/blocker-record.sh <fields...>` — do not bury it in commit
   messages or evidence prose."

5. **Operator tooling.** Two thin scripts:
   - `scripts/blocker-record.sh` — appends a new blocker JSON line with
     timestamp + caller; validates schema.
   - `scripts/blocker-update.sh` — appends a status-update line for an
     existing id (or rejects unknown id).
   No CLI library — `python3` + `argparse` is fine.

## How this preserves cwc principles

- **Default-FAIL stays the terminator.** The completion gate is one
  additional `count > 0` check that lives in the SAME hook that already
  enforces `passes:false` counts. No new event sources, no new daemons.
- **Fresh-context evaluator separation stays intact.** The evaluator
  just gets one extra read (`blockers.jsonl`) before deciding. No
  cross-agent state sharing beyond what the existing evidence trail
  already does.
- **Evidence gating still rules.** A blocker can only move out of the
  open/untriaged sets when it has at least one evidence path or a
  documented `wontfix` resolution. The existing `verify-gate.sh` is
  untouched; blocker-record.sh is its lateral cousin for a different
  kind of artefact.
- **Backward compatible.** Missing `scope_policy` defaults to
  `fixed_scope`; missing `blockers.jsonl` is treated as zero blockers;
  every existing run continues to behave identically.
- **Inspectable.** Everything is JSONL on disk. `cat blockers.jsonl` is
  the audit trail. No opaque state.
- **Bounded.** Blockers must have severity. Project policy text can
  declare which severities block (e.g., `production_hardening` mode
  by default blocks on `critical` and `high`; medium/low/nit are
  recorded but don't block unless the project's `blocker_policy` text
  says so).

## Backlog items (`S18_*`)

The six items I'm adding to `test-results.json`:

1. `S18_scope_policy_field` — Add the `scope_policy` field with
   backward-compat default. Add a verify-install check.
2. `S18_blocker_ledger` — Implement `blockers.jsonl` schema +
   `scripts/blocker-record.sh` + `scripts/blocker-update.sh`. Add
   verify-install checks.
3. `S18_production_hardening_completion_gate` — Add the
   `heartbeat-stop.sh` check; write `blocker-gate.json` snapshot.
4. `S18_evaluator_blocker_check` — Update `agents/evaluator.md` and
   `agents/evaluator-strict.md` + `agents/codex-executor.md` paragraph.
5. `S18_lifecycle_tests` — Tests covering: fixed_scope unchanged;
   production_hardening blocks on open; production_hardening blocks on
   triaged-without-evidence; production_hardening allows when all
   passes:true AND all blockers resolved with evidence; research_only
   records but never blocks; existing per-row evidence gating still
   works.
6. `S18_docs_and_examples` — `docs/scope-policies.md` user-facing doc
   + a `docs/examples/production-hardening-prompt.md` reference brief
   (Discord-router-style blocker definition).

## What we are not building

- An automated blocker classifier.
- An OpenClaw supervisor extension. The supervisor's job is stall
  detection; it does not need to read blockers.jsonl (it can, but the
  initial implementation does not require it).
- A blocker UI in Discord. The discord-notify hook stays as-is.
- A `priority` field on top of `severity`. One axis of urgency is
  enough; project policy text can map severities to action.
- A new evaluator agent. The two existing ones (`evaluator.md`,
  `evaluator-strict.md`) get the blocker-check paragraph in their
  prose contract.

## Test taxonomy (closes `S18_lifecycle_tests`)

```
tests/scope-policy/
  fixed-scope-unchanged.sh           # missing field == fixed_scope == old behaviour
  prod-hardening-open-blocks.sh      # open blocker → goal not met even if rows green
  prod-hardening-triaged-no-evidence.sh # triaged-but-no-evidence → goal not met
  prod-hardening-completes-when-clean.sh # rows green + blockers resolved+evidenced → goal met
  research-only-records-but-allows.sh # any blocker recorded; goal still met when rows green
  evidence-gating-still-works.sh     # the existing per-row evidence binding still fires
```

Each test mints a mktemp scratchroot with synthetic state, invokes
`heartbeat-stop.sh` with the appropriate JSON payload, and asserts
exit code + log-status line.

## Risks / known gaps

- **Project blocker definitions are text.** A project that wants a
  hard-coded blocker classifier still has to write that classifier
  themselves. The harness's job is to plumb the ledger and the
  completion gate; the policy text guides the agents.
- **Blocker discovery rate is operator-monitored.** If a run records
  zero blockers in `production_hardening` mode, that may be honest
  (no production issues found) or dishonest (issues hidden). The
  evaluator's NEEDS_WORK surface and Marco's review remain the audit.
- **JSONL latest-wins read can be heavy if the ledger grows
  unboundedly.** Mitigation: the ledger is per-goal-session, not
  per-host. On goal completion the file moves to
  `.claude/goal-state/blockers-archive/<session-id>.jsonl`.
