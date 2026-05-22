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
printf '1\n' > "$CURL_CALLED"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d)
      shift
      printf '%s\n' "$1" > "$PAYLOAD_LOG"
      ;;
  esac
  shift || break
done
exit 0
SH
chmod +x "$FAKE_BIN/curl"

WORKSPACE="$TMPDIR/workspace"
STATE_DIR="$WORKSPACE/.claude/goal-state"
PROJECTS_DIR="$TMPDIR/projects"
SESSION_ID="cost-test-session"
mkdir -p "$STATE_DIR" "$PROJECTS_DIR/project-id"

printf '{"items":[{"id":"cost","passes":true}]}\n' > "$WORKSPACE/test-results.json"
printf '{"goal":"cost telemetry test","session_id":"%s"}\n' "$SESSION_ID" > "$STATE_DIR/goal-state.json"

cat > "$PROJECTS_DIR/project-id/$SESSION_ID.jsonl" <<'JSONL'
{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1000,"output_tokens":200,"cache_creation_input_tokens":100,"cache_read_input_tokens":400}}}
{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":2000,"output_tokens":300}}}
JSONL

set +e
output="$(cd "$WORKSPACE" && PATH="$FAKE_BIN:$PATH" CURL_CALLED="$TMPDIR/curl-called" PAYLOAD_LOG="$TMPDIR/payload.log" CLAUDE_PROJECTS_DIR="$PROJECTS_DIR" DISCORD_NOTIFY_WEBHOOK="http://127.0.0.1:9/webhook" DISCORD_NOTIFY_MAX_ATTEMPTS=1 DISCORD_NOTIFY_TIMEOUT=1 "$HOOK" 2>&1)"
status=$?
set -e

[ "$status" -eq 0 ] || fail "hook exit = $status, want 0; output: $output"
[ -f "$TMPDIR/curl-called" ] || fail "curl was not called"
[ -f "$TMPDIR/payload.log" ] || fail "payload was not captured"

grep -q 'Goal complete: cost telemetry test' "$TMPDIR/payload.log" || fail "payload missing goal-complete text"
grep -q 'input_tokens=3000' "$TMPDIR/payload.log" || fail "payload missing input token total"
grep -q 'output_tokens=500' "$TMPDIR/payload.log" || fail "payload missing output token total"
grep -q 'cache_creation_input_tokens=100' "$TMPDIR/payload.log" || fail "payload missing cache creation token total"
grep -q 'cache_read_input_tokens=400' "$TMPDIR/payload.log" || fail "payload missing cache read token total"
grep -q 'estimated_cost_usd=$0.0850' "$TMPDIR/payload.log" || fail "payload missing estimated cost"

echo "PASS discord-notify cost telemetry"
