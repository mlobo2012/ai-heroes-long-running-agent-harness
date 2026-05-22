# Scope Policies

Scope policies control what it means for a goal to be complete after every
`passes:false` row in `test-results.json` has turned green.

The field is optional:

```json
{
  "scope_policy": "production_hardening",
  "items": [
    { "id": "S18_example", "passes": false }
  ]
}
```

If `scope_policy` is missing, the harness treats the run as `fixed_scope`.

## Policies

| Policy | Completion behavior | Use it for |
|---|---|---|
| `fixed_scope` | Existing behavior. Completion depends only on `passes` booleans in `test-results.json`. | Planned implementation sprints, documentation tasks, narrow bug fixes, and research goals where adjacent findings should not move the finish line. |
| `production_hardening` | Completion also requires the blocker ledger to be clean. Latest blocker records with `status: open`, or `status: triaged` and no `evidence_paths`, block goal completion. | Reliability, security, launch readiness, auth, delivery, migration, or recovery work where discovering adjacent production blockers is part of the job. |
| `research_only` | Blockers can be recorded, but never block completion. | Audits, exploratory investigations, option analysis, and discovery work where the output is the findings list rather than a hardened system. |

Valid values are `fixed_scope`, `production_hardening`, and `research_only`.
Any present value outside that set is invalid.

## Blocker Ledger

The canonical ledger is:

```text
.claude/goal-state/blockers.jsonl
```

It is append-only. A new blocker is one JSON line. A status update is another
JSON line with the same `id`. Readers fold the file latest-wins by `id`.

Each line uses this schema:

```json
{
  "id": "B-auth-callback-state",
  "title": "Auth callback loses OAuth state after router restart",
  "severity": "critical",
  "status": "open",
  "discovered_at": "2026-05-22T12:00:00Z",
  "discovered_by": "codex-executor",
  "evidence_paths": ["evidence/sprint-18/auth-callback-log.txt"],
  "reproduction_notes": "Restart the router between login and callback.",
  "affected_area": "auth/callback",
  "resolution_notes": ""
}
```

Enums:

| Field | Values |
|---|---|
| `severity` | `critical`, `high`, `medium`, `low`, `nit` |
| `status` | `open`, `triaged`, `resolved`, `wontfix` |

## Recording Blockers

Create a blocker:

```bash
scripts/blocker-record.sh \
  --title "Delivery retries are dropped after worker restart" \
  --severity high \
  --evidence evidence/sprint-18/retry-log.txt \
  --reproduction "Restart the worker while a retry is queued." \
  --area "delivery/retry-worker" \
  --by "codex-executor"
```

If `--id` is omitted, the script generates one as `B-<slug-from-title>`.
The initial status is always `open`.

Update a blocker:

```bash
scripts/blocker-update.sh \
  --id B-delivery-retries-are-dropped-after-worker-restart \
  --status resolved \
  --evidence evidence/sprint-18/retry-fix-output.txt \
  --resolution "Retry queue now survives worker restart."
```

`blocker-update.sh` rejects unknown IDs. Resolved blockers must have evidence.
`wontfix` blockers must have resolution notes.

## Completion Gate

On every potential goal completion, `hooks/heartbeat-stop.sh` reads
`test-results.json`.

For `fixed_scope` and `research_only`, it writes a skip snapshot and preserves
the old completion behavior.

For `production_hardening`, it reads `.claude/goal-state/blockers.jsonl`,
folds latest record per `id`, and blocks completion if any latest record is:

- `status: open`
- `status: triaged` with an empty `evidence_paths` array

The hook always writes the audit snapshot:

```text
.claude/goal-state/blocker-gate.json
```

Example snapshot:

```json
{
  "policy": "production_hardening",
  "open_count": 1,
  "triaged_unevidenced_count": 0,
  "decision": "block",
  "timestamp": "2026-05-22T12:00:00Z"
}
```

Missing `blockers.jsonl` means zero blockers.

## Lifecycle

1. Start a goal with `scope_policy` set or omitted.
2. Builders flip planned `test-results.json` rows only through the existing evidence gate.
3. In `production_hardening`, builders record newly discovered production blockers with `scripts/blocker-record.sh`.
4. Builders resolve or explicitly update blockers with `scripts/blocker-update.sh`.
5. Evaluators check `blockers.jsonl` before returning PASS for production-hardening goals.
6. The heartbeat hook allows completion only when rows are green and the production-hardening blocker gate is clean.

## Troubleshooting

If a production-hardening goal keeps looping after all rows are green, inspect:

```bash
cat .claude/goal-state/blocker-gate.json
cat .claude/goal-state/blockers.jsonl
```

If `open_count` is non-zero, update or resolve the open blocker IDs.

If `triaged_unevidenced_count` is non-zero, add evidence to the triaged
blockers or move them to a terminal status with the required notes.

If a fixed-scope or research-only run is blocked, the blocker ledger is not the
cause. Check `test-results.json`, `STEER.md`, and `.claude/goal-state/block-count`.
