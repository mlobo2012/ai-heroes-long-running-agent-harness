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

`watchdog-codex-goal.sh` is copied from the fixed live watchdog. It still supports the original single-goal mode:

```bash
watchdog-codex-goal.sh \
  --goal-cron-id <cron-id> \
  --session-key agent:<agent>:goal:<slug> \
  --contract <workspace>/contract.json \
  --lock <workspace>/state/running.lock
```

It also supports always-on global sweep mode:

```bash
watchdog-codex-goal.sh \
  --sweep \
  --ledger /Users/marco/.claude/goal-sessions/active.jsonl
```

Sweep mode reads the unified ledger at `/Users/marco/.claude/goal-sessions/active.jsonl` and checks every line whose `runtime` is `codex-openclaw`. Claude-style ledger rows without that runtime are skipped. Each codex-openclaw row supplies its own `cron_id`, `session_key`, `contract`, and `lock`, then the watchdog runs the same per-goal decision logic used by single-goal mode.

Sweep cooldown and event state are namespaced per session key under `/Users/marco/.openclaw/tools/watchdog-state/sweep/<session-key-slug>/` by default, where characters such as `:` are replaced with `_`. This prevents one goal's refire cooldown from suppressing another goal. Passing `--state-dir <path>` in sweep mode uses `<path>` as the sweep state root.

`com.aiheroes.codex-goal-watchdog.plist` is the always-on launchd job. It runs the live watchdog script with `--sweep --ledger /Users/marco/.claude/goal-sessions/active.jsonl`, has `RunAtLoad` set to true, and runs every 180 seconds with stdout/stderr logs under `/Users/marco/.openclaw/tools/logs/`.

Launchd load command after installing the plist:

```bash
launchctl bootout gui/$(id -u)/com.aiheroes.codex-goal-watchdog
launchctl bootstrap gui/$(id -u) /Users/marco/.openclaw/tools/com.aiheroes.codex-goal-watchdog.plist
```

Merge `SUPERVISOR-CODEX-PATCH.md` into the goal supervisor heartbeat and create `state/alerting-enabled` in the supervisor workspace before expecting scoped Discord alerts.

## Known Gotchas

1. `openclaw cron run` takes the cron id positionally: `openclaw cron run "$goal_cron_id"`. Do not use `--id`.
2. In the watchdog, terminal task status (`timed_out|lost|failed`) must be checked before the fresh-lock noop branch. Otherwise a dead-but-locked tick reads as alive.
