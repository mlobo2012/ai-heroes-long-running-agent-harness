# Goal Observability

This observability page describes a cwc-style `watch -n 2` panel set for monitoring a live long-running goal. Run it from the workspace root so relative paths resolve against the active session.

## Panel Set

Panel 1: inner-pulse and notification logs.

```bash
tail -F .claude/goal-state/heartbeat-stop.log .claude/goal-state/discord-notify.log
```

This surfaces every `Stop` decision, `SubagentStop` heartbeat tick, sprint pass notification, and goal-complete notification. It is most useful when a session appears silent in the chat UI but the hook chain is still active.

Panel 2: current PASS/FAIL split in `test-results.json`.

```bash
watch -n 2 'jq -r '\''[.. | objects | select(has("passes")) | .passes] | map(if . then "PASS" else "FAIL" end) | .[]'\'' test-results.json | sort | uniq -c'
```

This shows whether the default-fail ledger is moving. A run with no rows printed usually has an empty or invalid result ledger, not a completed goal.

Panel 3: consecutive blocked parent turns.

```bash
watch -n 2 cat .claude/goal-state/block-count
```

This shows how close the current session is to the anti-runaway cap. `SubagentStop` events do not increment this value; only parent `Stop` turns do.

Panel 4: evidence as it lands.

```bash
tail -F evidence/*/*-result.txt evidence/*-result.txt 2>/dev/null
```

This surfaces builder and evaluator artefacts as they are written. It is useful for checking whether a claimed pass has concrete command output, screenshots, or review notes behind it.

## Tmux Layout

One practical four-pane layout:

```bash
tmux new-session -d -s goal-watch -c "$PWD" \
  'tail -F .claude/goal-state/heartbeat-stop.log .claude/goal-state/discord-notify.log'
tmux split-window -h -t goal-watch:0 -c "$PWD" \
  "watch -n 2 'jq -r '\''[.. | objects | select(has(\"passes\")) | .passes] | map(if . then \"PASS\" else \"FAIL\" end) | .[]'\'' test-results.json | sort | uniq -c'"
tmux split-window -v -t goal-watch:0.0 -c "$PWD" \
  'watch -n 2 cat .claude/goal-state/block-count'
tmux split-window -v -t goal-watch:0.1 -c "$PWD" \
  'tail -F evidence/*/*-result.txt evidence/*-result.txt 2>/dev/null'
tmux select-layout -t goal-watch:0 tiled
tmux attach -t goal-watch
```

Use this while a goal is actively running. After completion, `.claude/goal-state/sessions.jsonl` gives a compact session ledger with the final session id, start/end times, pass count, evidence-read count, branch-ahead count, and exit reason.
