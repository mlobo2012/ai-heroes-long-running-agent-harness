# OpenClaw Codex Long-Running Harness

This toolkit packages the proven OpenClaw-native Codex durable-goal pattern into files that can be reused for Schmidty, Jian-Yang, Gilfoyle, or future agents. It does not add a new runtime. It parameterizes the working pattern: a recurring OpenClaw cron tick re-enters one on-disk goal contract until every `items[].passes` value is `true`.

## Primitive Map

- Cron tick = task-scoped heartbeat. `openclaw cron` runs the agent every interval with the same `agent:<agent>:goal:<slug>` session key.
- Disk contract = Default-FAIL terminator. `contract.json` stays red until the agent verifies one item and sets `passes:true`.
- `GOAL.md` = per-tick protocol. Each run rereads the contract, checks the lock, does at most one red item, records progress, and stops.
- Watchdog = stall recovery. It detects terminal task states or stale locks and refires the cron id.
- Supervisor = outer pulse. It reads the unified ledger and branches on `"runtime":"codex-openclaw"` so Codex goals are judged by contract/lock progress rather than Claude `last-beat` files.

## Register A Goal

Dry-run first:

```bash
openclaw-codex/register-codex-goal.sh \
  --dry-run \
  --agent schmidty \
  --slug tilores-reddit-batch \
  --goal "Produce the simplified Tilores Reddit review batch" \
  --channel 1507399218850041906
```

Create it disabled by default:

```bash
openclaw-codex/register-codex-goal.sh \
  --agent schmidty \
  --slug tilores-reddit-batch \
  --goal "Produce the simplified Tilores Reddit review batch" \
  --channel 1507399218850041906 \
  --contract /path/to/contract.json
```

Create it enabled:

```bash
openclaw-codex/register-codex-goal.sh \
  --enable \
  --agent schmidty \
  --slug tilores-reddit-batch \
  --goal "Produce the simplified Tilores Reddit review batch" \
  --channel 1507399218850041906 \
  --interval 5m \
  --timeout-seconds 720 \
  --contract /path/to/contract.json
```

The installer creates `<workspace-root>/<slug>/`, `docs/`, `state/`, installs `contract.json`, renders `GOAL.md`, adds the session-keyed OpenClaw cron, and appends the unified ledger line:

```json
{"session_id":"<cron-id>","agent":"<agent>","channel":"<channel>","goal":"<goal>","started_at":"<iso>","workspace":"<workspace>","launcher":"openclaw-cron","runtime":"codex-openclaw","cron_id":"<cron-id>","session_key":"agent:<agent>:goal:<slug>","contract":"<workspace>/contract.json","lock":"<workspace>/state/running.lock"}
```

## Watchdog And Supervisor

`watchdog-codex-goal.sh` is copied from the fixed live watchdog. Use `com.aiheroes.codex-goal-watchdog.plist` as the launchd template; customize its cron id, session key, contract path, lock path, and state dir for the registered goal. Running the installer with `--enable` enables the OpenClaw cron and prints the launchd commands used to wire this watchdog template.

Launchd enable command after installing the customized plist:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.aiheroes.codex-goal-watchdog.plist
launchctl enable gui/$(id -u)/com.aiheroes.codex-goal-watchdog
```

Merge `SUPERVISOR-CODEX-PATCH.md` into the goal supervisor heartbeat and create `state/alerting-enabled` in the supervisor workspace before expecting scoped Discord alerts.

## Known Gotchas

1. `openclaw cron run` takes the cron id positionally: `openclaw cron run "$goal_cron_id"`. Do not use `--id`.
2. In the watchdog, terminal task status (`timed_out|lost|failed`) must be checked before the fresh-lock noop branch. Otherwise a dead-but-locked tick reads as alive.
