#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
# If STEER.md has content, surface it to the agent once and clear the file.
# Write to STEER.md (or pipe from a UI) to redirect the agent mid-run.
# Note: this is a convenience channel, not a trust boundary; if the agent has
# Write access to the project it can write STEER.md itself.
#
# AI Heroes addition (0.4.0): on consumption, also touch the marker
# .claude/goal-state/steered-this-turn so that the inner pulse
# (heartbeat-stop.sh) can reset the block counter even when STEER.md has
# already been emptied by this hook earlier in the same turn. Without the
# marker, heartbeat-stop sees an empty STEER.md at Stop time and keeps
# counting blocks — bug D14 in docs/parity-gap-analysis.md.
f="${AGENT_STEER_FILE:-${WORKDIR:-$PWD}/STEER.md}"
if [ -s "$f" ]; then
  note=$(cat "$f")
  reason=$(python3 -c 'import json,sys; print(json.dumps("OPERATOR STEERING: " + sys.argv[1] + "\n\nPause what you were about to do, incorporate this guidance, then continue toward the feature goal."))' "$note" 2>/dev/null) || exit 0
  printf '{"decision":"block","reason":%s}\n' "$reason"
  : > "$f"
  state_dir="${WORKDIR:-$PWD}/.claude/goal-state"
  mkdir -p "$state_dir" 2>/dev/null
  touch "$state_dir/steered-this-turn" 2>/dev/null
fi
