# Pilot: Express server

A small but real long-running pilot. Small enough to land quickly,
large enough to exercise the whole loop: planner -> contract-reviewer
-> generator -> evaluator -> heartbeat gate -> watchdog.

## Run it with the harness

```bash
"$HOME/.claude/plugins/discord-long-running-harness/scripts/register-goal.sh" \
  --agent bench-pilot \
  --channel 0 \
  --workspace "$PWD" \
  --launcher /tmp/noop-launcher.sh \
  --rubric api \
  "$(cat goal.txt)"
```

Then in the Claude session, run the printed `/goal` command.

## Bench it

`scripts/bench-harness.sh` runs this pilot end-to-end and writes a
machine-readable score file. See `scripts/bench-harness.sh --help`.
