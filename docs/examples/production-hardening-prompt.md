# Production Hardening Reference Brief

## Sprint 12 / 1.1.0 - Discord Router Production Hardening

**Workspace:** `/Users/marco/conductor/workspaces/router/hardening`
**Branch:** `router-production-hardening`
**Sprint slug:** `s12-router-production-hardening`

## Objective

Harden the Discord router's auth, delivery, and recovery paths for production.
This is a `production_hardening` run: planned acceptance rows still matter, and
newly discovered production blockers must be recorded in
`.claude/goal-state/blockers.jsonl` instead of being hidden in prose.

`test-results.json` must declare:

```json
{
  "scope_policy": "production_hardening",
  "items": []
}
```

## Items In Scope

1. `S12_auth_callback_recovery` - OAuth callbacks survive worker restart and stale state is rejected with a clear operator-visible error.
2. `S12_delivery_idempotency` - Discord message delivery is idempotent across retry, timeout, and process restart.
3. `S12_recovery_resume` - A stalled thread can resume from the latest durable cursor without duplicating a worker.
4. `S12_operator_evidence` - Auth, delivery, and recovery checks each produce evidence under `evidence/sprint-12/`.

## Blocker Policy

Record a blocker when a discovered issue can break production auth, delivery,
or recovery outside the fixed acceptance rows.

Examples that must be recorded:

- Auth tokens can be leaked, replayed, or stranded after restart.
- Delivery can drop or duplicate user-visible Discord messages.
- Recovery can resume the wrong thread, spawn duplicate workers, or lose the latest cursor.
- A verification command passes only because it bypasses the production path.

Use:

```bash
scripts/blocker-record.sh \
  --title "short production blocker" \
  --severity high \
  --evidence evidence/sprint-12/path.txt \
  --reproduction "exact steps" \
  --area "auth|delivery|recovery" \
  --by "codex-executor"
```

Open blockers and triaged blockers without evidence block completion.

## Files Allowed

- `router/auth/**`
- `router/delivery/**`
- `router/recovery/**`
- `tests/router/**`
- `scripts/router-smoke.sh`
- `docs/router-production-runbook.md`
- `.claude/goal-state/blockers.jsonl`
- `.claude/goal-state/blocker-gate.json`
- `evidence/sprint-12/**`

## Files Forbidden

- `test-results.json` except after evaluator PASS and fresh evidence Read
- `~/.claude/goal-sessions/**`
- `~/.openclaw/**`
- unrelated launchers, plugin manifests, or operator channel config

## Acceptance

### S12_auth_callback_recovery

- Restart the router between OAuth authorization and callback.
- Valid callbacks complete once.
- Stale or replayed callbacks fail closed.
- Evidence includes a command transcript and the relevant auth log excerpt.

### S12_delivery_idempotency

- Simulate Discord API timeout, retry, and process restart.
- A message with the same durable delivery key is sent at most once.
- Evidence includes the retry transcript and the persisted delivery ledger.

### S12_recovery_resume

- Kill the worker during an active thread.
- Recovery resumes from the latest durable cursor.
- No duplicate worker is spawned for the same thread.
- Evidence includes the recovery transcript and worker registry snapshot.

### S12_operator_evidence

- `evidence/sprint-12/auth-result.txt` exists.
- `evidence/sprint-12/delivery-result.txt` exists.
- `evidence/sprint-12/recovery-result.txt` exists.
- `evidence/sprint-12/blocker-ledger-result.txt` summarizes blocker state.

## Verification

```bash
bash -n scripts/router-smoke.sh
scripts/router-smoke.sh --case auth-callback-restart
scripts/router-smoke.sh --case delivery-retry-restart
scripts/router-smoke.sh --case recovery-resume
python3 -m pytest tests/router
cat .claude/goal-state/blocker-gate.json
```

Before returning PASS, confirm the latest `.claude/goal-state/blockers.jsonl`
view has zero `open` blockers and zero `triaged` blockers with empty
`evidence_paths`.

## Definition Of Done

- All scoped `test-results.json` rows are `passes:true`.
- All verification commands pass.
- Production blockers discovered during the sprint are recorded through
  `scripts/blocker-record.sh`.
- Every blocker is resolved with evidence, or explicitly updated to `wontfix`
  with resolution notes.
- `.claude/goal-state/blocker-gate.json` shows
  `"policy":"production_hardening"` and `"decision":"allow"`.
