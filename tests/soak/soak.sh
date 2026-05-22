#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNNER="$PLUGIN_DIR/scripts/supervisor-runner.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/soak-synthetic.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

assert_line_count() {
  file="$1"
  expected="$2"
  [ -f "$file" ] || fail "$file does not exist"
  actual="$(wc -l < "$file" | tr -d ' ')"
  [ "$actual" = "$expected" ] || fail "$file has $actual lines, expected $expected"
}

curl() {
  printf 'curl %s\n' "$*" >> "$SUPERVISOR_CURL_CAPTURE"
  return 0
}
export -f curl

workspace="$SCRATCH_ROOT/workspace"
state_dir="$workspace/.claude/goal-state"
ledger="$SCRATCH_ROOT/active.jsonl"
recovery_log="$SCRATCH_ROOT/recovery.log"
completion_log="$SCRATCH_ROOT/completion.log"
curl_capture="$SCRATCH_ROOT/curl-calls.log"
sim_log="$SCRATCH_ROOT/simulation.log"
mkdir -p "$state_dir"

now="$(date +%s)"
session_id="soak-session"

log_sim() {
  printf 'minute=%s %s\n' "$1" "$2" >> "$sim_log"
}

write_last_beat_for_runner() {
  runner_minute="$1"
  beat_minute="$2"
  age_seconds=$(((runner_minute - beat_minute) * 60))
  printf '%s\n' "$((now - age_seconds))" > "$state_dir/last-beat"
}

write_goal_state() {
  status="$1"
  printf '{"status":"%s","session_id":"%s","goal":"synthetic soak"}\n' \
    "$status" "$session_id" > "$state_dir/goal-state.json"
}

write_goal_state "running"
write_last_beat_for_runner 110 0
printf '{"session_id":"%s","agent":"klaus","channel":"test-channel","goal":"synthetic soak","started_at":%s,"workspace":"%s","launcher":"test"}\n' \
  "$session_id" "$((now - (110 * 60)))" "$workspace" > "$ledger"
log_sim 0 "workspace created; last-beat written"

write_last_beat_for_runner 110 30
log_sim 30 "last-beat refreshed"

write_last_beat_for_runner 110 60
log_sim 60 "last-beat refreshed"

log_sim 90 "INJECTED HANG; last-beat intentionally not refreshed"

SUPERVISOR_ACTIVE_LEDGER="$ledger" \
SUPERVISOR_STALL_THRESHOLD=1200 \
SUPERVISOR_RECOVERY_LOG="$recovery_log" \
SUPERVISOR_COMPLETION_LOG="$completion_log" \
SUPERVISOR_DISCORD_WEBHOOK="https://discord.example/webhook" \
SUPERVISOR_CURL_CAPTURE="$curl_capture" \
SUPERVISOR_BACKUP_TS="soak" \
DISCORD_NOTIFY_MAX_ATTEMPTS=1 \
"$RUNNER" > "$SCRATCH_ROOT/minute-110.out"
log_sim 110 "supervisor invoked; expected one stall alert"

assert_line_count "$recovery_log" 1
assert_line_count "$curl_capture" 1
python3 - "$recovery_log" "$SCRATCH_ROOT/minute-110.out" <<'PY'
import json
import sys
from pathlib import Path

entry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert entry["event"] == "stalled", entry
assert entry["session_id"] == "soak-session", entry
assert entry["last_beat_age_seconds"] >= 3000, entry
assert entry["missing_paths"] == [], entry
output = Path(sys.argv[2]).read_text(encoding="utf-8")
assert "sessions_stalled=1" in output, output
PY

write_goal_state "complete"
log_sim 120 "workspace marked complete"

SUPERVISOR_ACTIVE_LEDGER="$ledger" \
SUPERVISOR_STALL_THRESHOLD=1200 \
SUPERVISOR_RECOVERY_LOG="$recovery_log" \
SUPERVISOR_COMPLETION_LOG="$completion_log" \
SUPERVISOR_BACKUP_TS="soak" \
"$RUNNER" > "$SCRATCH_ROOT/minute-130.out"
log_sim 130 "supervisor invoked; expected one completion trim"

assert_line_count "$recovery_log" 1
assert_line_count "$completion_log" 1
[ ! -s "$ledger" ] || fail "completed session was not trimmed from active ledger"
python3 - "$completion_log" "$SCRATCH_ROOT/minute-130.out" <<'PY'
import json
import sys
from pathlib import Path

entry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert entry["event"] == "completed", entry
assert entry["session_id"] == "soak-session", entry
output = Path(sys.argv[2]).read_text(encoding="utf-8")
assert "sessions_completed=1" in output, output
PY

for minute in 150 180 210 240 270 300 330 360; do
  log_sim "$minute" "synthetic six-hour horizon advanced without sleeping"
done

grep -q 'minute=360' "$sim_log" || fail "six-hour synthetic horizon was not recorded"

echo "PASS - synthetic soak test"
