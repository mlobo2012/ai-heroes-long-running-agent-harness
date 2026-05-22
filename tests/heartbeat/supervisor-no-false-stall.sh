#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
RUNNER="$PLUGIN_DIR/scripts/supervisor-runner.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/heartbeat-supervisor-fresh.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
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
output="$SCRATCH_ROOT/supervisor.out"
mkdir -p "$state_dir"

now="$(date +%s)"
last_beat=$((now - 100))
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '%s\n' "$last_beat" > "$state_dir/last-beat"
printf '{"status":"running","session_id":"spawn-fresh","goal":"fresh spawn"}\n' > "$state_dir/goal-state.json"
printf '{"pid":12345,"started_at":"%s","last_refreshed":"%s","command":"codex"}\n' "$now_iso" "$now_iso" > "$state_dir/spawn-active.json"
printf '{"session_id":"spawn-fresh","agent":"klaus","channel":"test-channel","goal":"fresh spawn","started_at":%s,"workspace":"%s","launcher":"test"}\n' \
  "$((now - 600))" "$workspace" > "$ledger"

SUPERVISOR_ACTIVE_LEDGER="$ledger" \
SUPERVISOR_STALL_THRESHOLD=1200 \
SUPERVISOR_RECOVERY_LOG="$recovery_log" \
SUPERVISOR_COMPLETION_LOG="$completion_log" \
SUPERVISOR_DISCORD_WEBHOOK="https://discord.example/webhook" \
SUPERVISOR_CURL_CAPTURE="$curl_capture" \
DISCORD_NOTIFY_MAX_ATTEMPTS=1 \
"$RUNNER" > "$output"

[ ! -s "$recovery_log" ] || fail "fresh spawn unexpectedly wrote recovery log"
[ ! -s "$curl_capture" ] || fail "fresh spawn unexpectedly queued webhook curl"
grep -q 'sessions_stalled=0' "$output" || fail "supervisor output did not report zero stalled sessions"
grep -q 'sessions_ok=1' "$output" || fail "supervisor output did not report one ok session"

cat "$output"
echo "RECOVERY_LOG:"
if [ -f "$recovery_log" ]; then
  cat "$recovery_log"
else
  echo "(absent)"
fi
echo "WEBHOOK_CAPTURE:"
if [ -f "$curl_capture" ]; then
  cat "$curl_capture"
else
  echo "(absent)"
fi
echo "PASS - supervisor does not false-stall a workspace with fresh spawn heartbeat"
