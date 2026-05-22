#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$REPO_ROOT/hooks/discord-notify.sh"
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

FAKE_BIN="$TMPDIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
count=0
if [ -f "$CURL_COUNT_FILE" ]; then
  count="$(sed -n '1p' "$CURL_COUNT_FILE")"
fi
case "$count" in
  ''|*[!0-9]*) count=0 ;;
esac
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT_FILE"
printf '%s\n' "$*" >> "$CURL_ARGS_LOG"
case "${CURL_MODE:-fail}" in
  success) exit 0 ;;
  fail) exit 22 ;;
  *) exit 2 ;;
esac
SH

cat > "$FAKE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SLEEP_LOG"
exit 0
SH

chmod +x "$FAKE_BIN/curl" "$FAKE_BIN/sleep"

make_workspace() {
  workspace="$TMPDIR/workspace-$1"
  mkdir -p "$workspace/.claude/goal-state"
  printf '{"items":[{"id":"notify","passes":true}]}\n' > "$workspace/test-results.json"
  printf '{"goal":"notify test","session_id":"notify-test"}\n' > "$workspace/.claude/goal-state/goal-state.json"
  printf '%s\n' "$workspace"
}

reset_fakes() {
  rm -f "$TMPDIR/curl-count" "$TMPDIR/curl-args.log" "$TMPDIR/sleep.log"
}

run_unset_webhook() {
  workspace="$1"
  set +e
  output="$(cd "$workspace" && unset DISCORD_NOTIFY_WEBHOOK && PATH="$FAKE_BIN:$PATH" CURL_COUNT_FILE="$TMPDIR/curl-count" CURL_ARGS_LOG="$TMPDIR/curl-args.log" SLEEP_LOG="$TMPDIR/sleep.log" "$HOOK" 2>&1)"
  status=$?
  set -e
}

run_with_webhook() {
  workspace="$1"
  mode="$2"
  set +e
  output="$(cd "$workspace" && PATH="$FAKE_BIN:$PATH" CURL_MODE="$mode" CURL_COUNT_FILE="$TMPDIR/curl-count" CURL_ARGS_LOG="$TMPDIR/curl-args.log" SLEEP_LOG="$TMPDIR/sleep.log" DISCORD_NOTIFY_WEBHOOK="http://127.0.0.1:9/webhook" DISCORD_NOTIFY_MAX_ATTEMPTS=2 DISCORD_NOTIFY_TIMEOUT=1 "$HOOK" 2>&1)"
  status=$?
  set -e
}

count_calls() {
  if [ -f "$TMPDIR/curl-count" ]; then
    sed -n '1p' "$TMPDIR/curl-count"
  else
    printf '0\n'
  fi
}

workspace="$(make_workspace unset)"
reset_fakes
run_unset_webhook "$workspace"
[ "$status" -eq 0 ] || fail "unset webhook exit = $status, want 0; output: $output"
[ "$(count_calls)" = "0" ] || fail "unset webhook called curl $(count_calls) times"
[ ! -f "$workspace/.claude/goal-state/discord-notify-deadletter.log" ] || fail "unset webhook wrote a dead-letter"

workspace="$(make_workspace fail)"
reset_fakes
run_with_webhook "$workspace" "fail"
[ "$status" -eq 0 ] || fail "failing webhook exit = $status, want 0; output: $output"
[ "$(count_calls)" = "2" ] || fail "failing webhook curl calls = $(count_calls), want 2"
grep -q '^1$' "$TMPDIR/sleep.log" || fail "failing webhook did not back off for 1 second"
deadletter="$workspace/.claude/goal-state/discord-notify-deadletter.log"
[ -f "$deadletter" ] || fail "failing webhook did not write dead-letter"
grep -q 'payload={"content": "Goal complete: notify test"}' "$deadletter" || fail "dead-letter did not include payload"
grep -q 'webhook-error attempts=2' "$workspace/.claude/goal-state/discord-notify.log" || fail "failure log missing attempts"

workspace="$(make_workspace success)"
reset_fakes
run_with_webhook "$workspace" "success"
[ "$status" -eq 0 ] || fail "successful webhook exit = $status, want 0; output: $output"
[ "$(count_calls)" = "1" ] || fail "successful webhook curl calls = $(count_calls), want 1"
[ ! -f "$workspace/.claude/goal-state/discord-notify-deadletter.log" ] || fail "successful webhook wrote a dead-letter"
grep -q 'webhook-posted attempts=1' "$workspace/.claude/goal-state/discord-notify.log" || fail "success log missing"

echo "PASS discord-notify retry and dead-letter"
