# Optional outer pulse: OpenClaw `goal-supervisor`

The harness's inner pulse (Claude Code `Stop` + `SubagentStop` hooks) writes
`<workspace>/.claude/goal-state/last-beat` on every turn boundary. That's
enough to detect "the goal is met" or "the agent is blocking" — *as long
as turns keep ending.*

The outer pulse is the answer to "what if turns stop ending?" A subagent
hangs, the Claude process dies, the operator forgets the run. The inner
pulse can't notice silence because it only fires on events. So we add a
second timer at a different cadence on different infrastructure.

We run it as an [OpenClaw](https://github.com/mlobo2012/openclaw) agent
called `goal-supervisor`. OpenClaw drives a 15-minute heartbeat tick that
calls into a tiny supervisor workspace; the supervisor reads the
active-session ledger at `~/.claude/goal-sessions/active.jsonl` and alerts
only when something needs attention.

**Without OpenClaw, the harness still runs.** You lose stall detection
and the auto-completion message, but the inner pulse, Default-FAIL
contract, kill switch, steering, commit-on-stop, Discord state notifier,
and pinned Codex executor all work standalone.

## What this directory contains

- `README.md` — this file.
- `HEARTBEAT.md` — the heartbeat behavior contract. Copy to
  `~/.openclaw/workspace-goal-supervisor/HEARTBEAT.md`.
- `openclaw.json.example` — the agent entry to merge into your
  `~/.openclaw/openclaw.json` `agents.list` array.
- `workspace-README.md` — the README that lives inside
  `~/.openclaw/workspace-goal-supervisor/`. Copy as `README.md`.

## Install

```bash
# Create the supervisor workspace.
mkdir -p ~/.openclaw/workspace-goal-supervisor/state
cp docs/openclaw-supervisor/HEARTBEAT.md ~/.openclaw/workspace-goal-supervisor/HEARTBEAT.md
cp docs/openclaw-supervisor/workspace-README.md ~/.openclaw/workspace-goal-supervisor/README.md

# Back up your openclaw.json before editing.
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak.pre-goal-supervisor.$(date +%Y%m%dT%H%M%SZ)

# Merge openclaw.json.example into agents.list of ~/.openclaw/openclaw.json.
# (Manual edit. The merge is structural — not a script.)
```

After OpenClaw next picks up its config, the supervisor ticks every 15
minutes. Confirm with:

```bash
scripts/verify-install.sh --scope all   # exits 0 once supervisor is wired
```

## Tuning

| Knob | Where | Default |
|---|---|---|
| Heartbeat cadence | `heartbeat.every` in `openclaw.json.example` | `15m` |
| Stall threshold | `last_beat_age > 1200` in `HEARTBEAT.md` | 20 minutes |
| Model | `model.primary` | `openai-codex/gpt-5.5` |
| Thinking | `thinkingDefault` | `high` |
