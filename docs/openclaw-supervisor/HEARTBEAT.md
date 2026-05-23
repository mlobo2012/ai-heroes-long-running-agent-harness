# HEARTBEAT.md - Goal Supervisor

On every heartbeat, run these checks silently. Only speak up if something needs attention.

## 1. Active Goal Sessions

- Resolve the active ledger from `GOAL_SESSIONS_LEDGER`, defaulting it to the absolute path of the operator's real `.claude/goal-sessions/active.jsonl`.
- Use the absolute path, never `~`/`$HOME` — a sandboxed supervisor agent's home resolves to its sandbox home, so a tilde path silently reads an empty location and the supervisor wrongly reports zero active goals. This exact bug made the supervisor blind in production.
- Read the resolved active ledger path.
- If the file is missing or empty, write `state/last-tick.json` with zero counts and reply exactly: `HEARTBEAT_OK`.
- Parse each non-empty line as one active session:
  - `session_id`
  - `agent`
  - `channel`
  - `goal`
  - `started_at`
  - `workspace`
  - `launcher`

Do not perform broad ACP scans. This heartbeat supervises only sessions explicitly listed in `active.jsonl`.

## 2. Per-Session Checks

For each session line:

- Read `<workspace>/.claude/goal-state/last-beat` as a Unix timestamp.
- Compute `last_beat_age = now - last_beat`.
- If `last_beat_age > 1200` seconds, flag the session as stalled.
- Read `<workspace>/.claude/goal-state/goal-state.json`.
- If `status == "complete"`, flag the session as completed.

If a workspace file is missing or invalid for an active session, treat it as a stall and include the missing path in the recovery note.

## 3. Stall Handling

On stall:

- Send one explicit Discord `message` tool call to the session's `channel`. This is the only user-visible delivery path for the stall alert.
- Message shape: `Goal '<goal>' for <agent> has been silent for <minutes> minutes. Last beat file: <path>. I added a recovery note to STEER.md.`
- Append a recovery note to `<workspace>/STEER.md` with the timestamp, session id, stale age, and instruction to run `!status`, inspect `.claude/goal-state/last-beat-state.json`, or resume with `/goal-resume`.

Do not also rely on assistant final text for this alert.

## 4. Completion Handling

On completion:

- Send one explicit Discord `message` tool call to the session's `channel` with the duration from `started_at` to now.
- Remove that session line from the resolved active ledger path atomically by reading all lines, filtering out the matching `session_id`, writing a temp file in the same directory, then moving it over the original.

## 5. Debug State

Every tick, write `state/last-tick.json` with:

```json
{"tick_at":"<iso8601>","sessions_seen":0,"sessions_stalled":0,"sessions_completed":0}
```

## If Nothing Needs Attention

Reply exactly: HEARTBEAT_OK

## Reference Implementation

`scripts/supervisor-runner.sh` is the runnable reference fixture for this
protocol. It accepts synthetic-state overrides for the active ledger, stall
threshold, recovery log, completion log, and optional Discord webhook, so CI
and community installers can validate the outer-pulse behavior without a live
OpenClaw Codex agent or the live operator goal-session ledger. Public
supervisors should expose `GOAL_SESSIONS_LEDGER` and default it to the absolute
path of the operator's real `.claude/goal-sessions/active.jsonl`.

The fixture is covered by:

- `tests/outer-pulse/stall-detection.sh`
- `tests/outer-pulse/completion-trim.sh`
