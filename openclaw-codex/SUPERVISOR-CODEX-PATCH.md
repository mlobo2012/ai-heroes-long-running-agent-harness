# Supervisor Codex Patch

Merge the two sections below into `/Users/marco/.openclaw/workspace-goal-supervisor/HEARTBEAT.md` after the existing section 2 liveness checks and before stall handling. The section text is copied from the live Codex-aware supervisor patch.

Create the rollout gate file in the goal supervisor workspace before expecting Discord alerts:

```bash
touch /Users/marco/.openclaw/workspace-goal-supervisor/state/alerting-enabled
```

Ledger lines for OpenClaw-native Codex goals use this shape:

```json
{"session_id":"<cron-id>","agent":"<agent>","channel":"<discord-channel-id>","goal":"<goal>","started_at":"<iso8601-z>","workspace":"<goal-workspace>","launcher":"openclaw-cron","runtime":"codex-openclaw","cron_id":"<cron-id>","session_key":"agent:<agent>:goal:<slug>","contract":"<goal-workspace>/contract.json","lock":"<goal-workspace>/state/running.lock"}
```

## 2b. Codex durable-goal checks (OpenClaw-native goals) — runtime branch

Some ledger lines carry `"runtime": "codex-openclaw"`. These are OpenClaw-native
Codex durable goals (e.g. Schmidty), NOT Claude sessions. They do NOT write a Claude
`last-beat` file, so the section 2 check would always false-stall them. Branch on runtime:

For each line where `runtime == "codex-openclaw"`:

- Read the goal's disk contract at its `contract` path (a JSON file with `items[].passes`).
- **Complete?** If every `items[].passes` is `true`, flag the session as completed
  (handle per section 4, scoped per 2c).
- **Stalled?** Otherwise, judge liveness from disk, not from a Claude last-beat:
  - If `lock` exists and its ISO timestamp is younger than 15 minutes → the goal is
    actively running this beat. NOT stalled. Skip.
  - If `lock` is missing or older than 15 minutes AND the contract file's mtime is
    older than 20 minutes (no recent progress) → flag as **stalled**.
  - Otherwise (recent contract progress, between ticks) → healthy. Skip.
- A codex-openclaw goal that is making contract progress (green count rising over ticks)
  is healthy even with no lock — it is simply between 5-minute heartbeat ticks.

This is how the outer pulse sees Codex goals at all. Without this branch the supervisor
is structurally blind to every OpenClaw Codex agent — the exact gap that let Schmidty's
Reddit work die silently.

## 2c. Alerting scope during Schmidty-only-first rollout

- `codex-openclaw` goals: alert per section 3 when `state/alerting-enabled` exists
  (it does). Deliver the alert to the goal line's own `channel`, never to unrelated channels.
- Legacy Claude sessions (no `runtime`, or `runtime != codex-openclaw`): remain
  **record-only** (append to `state/pending-alerts.json`, count in `last-tick.json`) UNLESS
  `state/legacy-alerting-enabled` exists. This keeps the Codex rollout from surprising
  other channels. Do not flip legacy alerting on without operator instruction.
