#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# SessionStart hook. Idempotent bootstrap for a long-running goal workspace:
#   - PROGRESS.md (4 sections) if missing
#   - test-results.json (empty items array) if missing
#   - .claude/goal-state/ directory + an empty block-count file if missing
#
# Blocks session start with exit 2 if bootstrap cannot create readable,
# non-empty harness artefacts. The Default-FAIL contract (via heartbeat-stop's
# Stop hook) still enforces goal-not-met after the session starts. Closes
# matrix gap row 35 (SessionStart hook not used by upstream cwc) and the Nov
# article's Initializer Agent pattern.

WORKDIR="${PWD}"
PROGRESS="$WORKDIR/PROGRESS.md"
RESULTS="$WORKDIR/test-results.json"
STATE_DIR="$WORKDIR/.claude/goal-state"
input="$(cat 2>/dev/null || true)"

fail_bootstrap() {
  echo "session-start: $1" >&2
  exit 2
}

require_readable_nonempty_file() {
  file="$1"
  label="$2"
  [ -f "$file" ] || fail_bootstrap "$label was not created: $file"
  [ -r "$file" ] || fail_bootstrap "$label is not readable: $file"
  [ -s "$file" ] || fail_bootstrap "$label is empty: $file"
}

require_readable_nonempty_dir() {
  dir="$1"
  label="$2"
  [ -d "$dir" ] || fail_bootstrap "$label directory was not created: $dir"
  [ -r "$dir" ] || fail_bootstrap "$label directory is not readable: $dir"
  [ -s "$dir" ] || fail_bootstrap "$label directory is empty: $dir"
}

write_harness_loaded_beacon() {
  set +e
  session_id=""
  if command -v jq >/dev/null 2>&1; then
    session_id="$(printf '%s' "$input" | jq -r '.session_id // ""' 2>/dev/null || true)"
  elif command -v python3 >/dev/null 2>&1; then
    session_id="$(INPUT_JSON="$input" python3 - <<'PY' 2>/dev/null || true
import json
import os

try:
    data = json.loads(os.environ.get("INPUT_JSON", "") or "{}")
except json.JSONDecodeError:
    data = {}
print(data.get("session_id") or "")
PY
)"
  fi
  session_id="$(printf '%s' "$session_id" | tr -d '\r\n')"
  printf '%s %s\n' "$(date +%s)" "$session_id" > "$STATE_DIR/harness-loaded" 2>/dev/null || true
  set -e
}

mkdir -p "$STATE_DIR" || fail_bootstrap "could not create goal-state directory: $STATE_DIR"
# This beacon's presence proves the plugin loaded for the session; its absence for a registered goal proves it did not (the silent-load detector).
write_harness_loaded_beacon || true
require_readable_nonempty_dir "$STATE_DIR" ".claude/goal-state"

if [ ! -f "$PROGRESS" ]; then
  if ! cat > "$PROGRESS" <<'EOF'
<!-- Auto-bootstrapped by hooks/session-start.sh. Edit freely. -->

# PROGRESS

## Done

_Nothing yet._

## In progress

_Nothing yet._

## Next

_Nothing yet._

## Notes

Set the goal with `scripts/register-goal.sh` (see README §"Register and run a goal").
EOF
  then
    fail_bootstrap "could not write PROGRESS.md: $PROGRESS"
  fi
fi
require_readable_nonempty_file "$PROGRESS" "PROGRESS.md"

if [ ! -f "$RESULTS" ]; then
  if ! cat > "$RESULTS" <<'EOF'
{
  "_note": "Auto-bootstrapped by hooks/session-start.sh. Edit before registering a goal.",
  "goal": "Set me — the inner pulse blocks turn-end until every items[].passes is true.",
  "items": []
}
EOF
  then
    fail_bootstrap "could not write test-results.json: $RESULTS"
  fi
fi
require_readable_nonempty_file "$RESULTS" "test-results.json"

if [ ! -f "$STATE_DIR/block-count" ]; then
  printf '0\n' > "$STATE_DIR/block-count" || fail_bootstrap "could not write block-count: $STATE_DIR/block-count"
fi
require_readable_nonempty_file "$STATE_DIR/block-count" "block-count"
require_readable_nonempty_dir "$STATE_DIR" ".claude/goal-state"

exit 0
