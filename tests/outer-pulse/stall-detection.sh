#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNNER="$PLUGIN_DIR/scripts/supervisor-runner.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/outer-pulse-stall.XXXXXX")"

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

stalled_root="$SCRATCH_ROOT/stalled"
stalled_workspace="$stalled_root/workspace"
stalled_state="$stalled_workspace/.claude/goal-state"
stalled_ledger="$stalled_root/active.jsonl"
stalled_recovery="$stalled_root/recovery.log"
stalled_curl_capture="$stalled_root/curl-calls.log"
mkdir -p "$stalled_state"

now="$(date +%s)"
stale_beat=$((now - 1500))
printf '%s\n' "$stale_beat" > "$stalled_state/last-beat"
printf '%s\n' '{"status":"running","session_id":"stall-session","goal":"stall test"}' > "$stalled_state/goal-state.json"
printf '{"session_id":"stall-session","agent":"klaus","channel":"test-channel","goal":"stall test","started_at":%s,"workspace":"%s","launcher":"test"}\n' \
  "$now" "$stalled_workspace" > "$stalled_ledger"

SUPERVISOR_ACTIVE_LEDGER="$stalled_ledger" \
SUPERVISOR_STALL_THRESHOLD=1200 \
SUPERVISOR_RECOVERY_LOG="$stalled_recovery" \
SUPERVISOR_DISCORD_WEBHOOK="https://discord.example/webhook" \
SUPERVISOR_CURL_CAPTURE="$stalled_curl_capture" \
DISCORD_NOTIFY_MAX_ATTEMPTS=1 \
"$RUNNER" > "$stalled_root/output.txt"

assert_line_count "$stalled_recovery" 1
python3 - "$stalled_recovery" <<'PY'
import json
import sys
from pathlib import Path

entry = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert entry["event"] == "stalled", entry
assert entry["session_id"] == "stall-session", entry
assert entry["last_beat_age_seconds"] >= 1500, entry
assert entry["missing_paths"] == [], entry
PY

[ -s "$stalled_curl_capture" ] || fail "webhook curl override was not called"

fresh_root="$SCRATCH_ROOT/fresh"
fresh_workspace="$fresh_root/workspace"
fresh_state="$fresh_workspace/.claude/goal-state"
fresh_ledger="$fresh_root/active.jsonl"
fresh_recovery="$fresh_root/recovery.log"
mkdir -p "$fresh_state"

fresh_now="$(date +%s)"
printf '%s\n' "$fresh_now" > "$fresh_state/last-beat"
printf '%s\n' '{"status":"running","session_id":"fresh-session","goal":"fresh test"}' > "$fresh_state/goal-state.json"
printf '{"session_id":"fresh-session","agent":"klaus","channel":"test-channel","goal":"fresh test","started_at":%s,"workspace":"%s","launcher":"test"}\n' \
  "$fresh_now" "$fresh_workspace" > "$fresh_ledger"

SUPERVISOR_ACTIVE_LEDGER="$fresh_ledger" \
SUPERVISOR_STALL_THRESHOLD=1200 \
SUPERVISOR_RECOVERY_LOG="$fresh_recovery" \
"$RUNNER" > "$fresh_root/output.txt"

[ ! -s "$fresh_recovery" ] || fail "fresh session unexpectedly wrote a recovery note"

echo "PASS - outer pulse stall detection"
