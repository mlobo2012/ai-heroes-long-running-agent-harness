#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
KEEPALIVE="$REPO_ROOT/scripts/liveness-keepalive.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/heartbeat-liveness-keepalive.XXXXXX")"
INTERVAL=5

SESSION_PIDS=()
KEEPALIVE_PIDS=()
STARTED_DUMMY_PID=""
STARTED_KEEPALIVE_PID=""

cleanup() {
  set +e
  for pid in "${KEEPALIVE_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${SESSION_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${KEEPALIVE_PIDS[@]}" "${SESSION_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

mtime() {
  path="$1"
  if stat -f %m "$path" >/dev/null 2>&1; then
    stat -f %m "$path"
  else
    stat -c %Y "$path"
  fi
}

iso_from_epoch() {
  python3 - "$1" <<'PY'
import datetime
import sys

epoch = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"))
PY
}

iso_to_epoch() {
  python3 - "$1" <<'PY'
import datetime
import sys

text = sys.argv[1]
try:
    parsed = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=datetime.timezone.utc)
    print(int(parsed.astimezone(datetime.timezone.utc).timestamp()))
except Exception:
    print(0)
PY
}

read_last_beat() {
  file="$1"
  sed -n '1p' "$file" 2>/dev/null || printf '0\n'
}

read_active_last_beat() {
  ledger="$1"
  session_id="$2"
  python3 - "$ledger" "$session_id" <<'PY'
import json
import sys
from pathlib import Path

ledger = Path(sys.argv[1])
session_id = sys.argv[2]
if not ledger.exists():
    print("")
    raise SystemExit(0)
for raw in ledger.read_text(encoding="utf-8").splitlines():
    if not raw.strip():
        continue
    try:
        record = json.loads(raw)
    except json.JSONDecodeError:
        continue
    if isinstance(record, dict) and record.get("session_id") == session_id:
        print(record.get("last_beat") or "")
        raise SystemExit(0)
print("")
PY
}

write_active_ledger() {
  home_dir="$1"
  session_id="$2"
  workspace="$3"
  last_beat="$4"
  ledger="$home_dir/.claude/goal-sessions/active.jsonl"
  mkdir -p "$(dirname "$ledger")"
  python3 - "$ledger" "$session_id" "$workspace" "$last_beat" <<'PY'
import json
import sys
from pathlib import Path

ledger = Path(sys.argv[1])
record = {
    "session_id": sys.argv[2],
    "agent": "klaus",
    "channel": "test-channel",
    "goal": "liveness keepalive test",
    "started_at": 0,
    "workspace": sys.argv[3],
    "launcher": "test",
    "last_beat": sys.argv[4],
}
ledger.write_text(json.dumps(record, separators=(",", ":")) + "\n", encoding="utf-8")
PY
}

wait_for_file() {
  file="$1"
  attempts="$2"
  while [ "$attempts" -gt 0 ]; do
    [ -f "$file" ] && return 0
    attempts=$((attempts - 1))
    sleep 0.1
  done
  return 1
}

wait_for_absent() {
  file="$1"
  attempts="$2"
  while [ "$attempts" -gt 0 ]; do
    [ ! -e "$file" ] && return 0
    attempts=$((attempts - 1))
    sleep 0.1
  done
  return 1
}

wait_for_pid_exit() {
  pid="$1"
  attempts="$2"
  while [ "$attempts" -gt 0 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 0.5
  done
  return 1
}

wait_for_pid_file_owner() {
  file="$1"
  expected="$2"
  attempts="$3"
  while [ "$attempts" -gt 0 ]; do
    if [ -f "$file" ] && [ "$(sed -n '1p' "$file" 2>/dev/null || true)" = "$expected" ]; then
      return 0
    fi
    attempts=$((attempts - 1))
    sleep 0.2
  done
  return 1
}

start_dummy_session() {
  sleep 600 >/dev/null 2>&1 &
  STARTED_DUMMY_PID="$!"
  SESSION_PIDS+=("$STARTED_DUMMY_PID")
}

start_keepalive() {
  home_dir="$1"
  session_pid="$2"
  workspace="$3"
  session_id="$4"
  HOME="$home_dir" "$KEEPALIVE" "$session_pid" "$workspace" --interval "$INTERVAL" --session-id "$session_id" --max-runtime 300 &
  STARTED_KEEPALIVE_PID="$!"
  KEEPALIVE_PIDS+=("$STARTED_KEEPALIVE_PID")
}

setup_workspace() {
  case_root="$1"
  session_id="$2"
  mkdir -p "$case_root/home" "$case_root/workspace/.claude/goal-state"
  workspace="$(cd "$case_root/workspace" && pwd -P)"
  state_dir="$workspace/.claude/goal-state"
  now="$(date +%s)"
  old_epoch=$((now - 120))
  old_iso="$(iso_from_epoch "$old_epoch")"
  printf '%s\n' "$old_epoch" > "$state_dir/last-beat"
  printf '{"status":"running","session_id":"%s","goal":"liveness keepalive"}\n' "$session_id" > "$state_dir/goal-state.json"
  printf '{"items":[{"name":"still red","passes":false}]}\n' > "$workspace/test-results.json"
  write_active_ledger "$case_root/home" "$session_id" "$workspace" "$old_iso"
}

[ -x "$KEEPALIVE" ] || fail "liveness-keepalive.sh is not executable"

case1="$SCRATCH_ROOT/t1"
session_id="liveness-main"
setup_workspace "$case1" "$session_id"
workspace="$case1/workspace"
workspace="$(cd "$workspace" && pwd -P)"
state_dir="$workspace/.claude/goal-state"
home_dir="$case1/home"
ledger="$home_dir/.claude/goal-sessions/active.jsonl"
last_beat="$state_dir/last-beat"
pid_file="$state_dir/liveness-keepalive.pid"

start_dummy_session
dummy_pid="$STARTED_DUMMY_PID"
initial_epoch="$(read_last_beat "$last_beat")"
initial_iso="$(read_active_last_beat "$ledger" "$session_id")"
start_keepalive "$home_dir" "$dummy_pid" "$workspace" "$session_id"
keepalive_pid="$STARTED_KEEPALIVE_PID"
wait_for_file "$last_beat" 20 || fail "last-beat missing after keepalive start"
wait_for_pid_file_owner "$pid_file" "$keepalive_pid" 30 || fail "keepalive did not own pid-file"

echo "T1 initial last-beat=$initial_epoch active_last_beat=$initial_iso keepalive_pid=$keepalive_pid session_pid=$dummy_pid"

last_seen_epoch="$initial_epoch"
last_seen_iso_epoch="$(iso_to_epoch "$initial_iso")"
epoch_advances=0
iso_advances=0
samples=0
deadline=$(( $(date +%s) + 130 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep 10
  now="$(date +%s)"
  current_epoch="$(read_last_beat "$last_beat")"
  current_iso="$(read_active_last_beat "$ledger" "$session_id")"
  current_iso_epoch="$(iso_to_epoch "$current_iso")"
  current_mtime="$(mtime "$last_beat")"
  age=$((now - current_epoch))
  iso_age=$((now - current_iso_epoch))
  samples=$((samples + 1))
  if [ "$current_epoch" -gt "$last_seen_epoch" ]; then
    epoch_advances=$((epoch_advances + 1))
  fi
  if [ "$current_iso_epoch" -gt "$last_seen_iso_epoch" ]; then
    iso_advances=$((iso_advances + 1))
  fi
  [ "$age" -lt 60 ] || fail "last-beat became stale during T1: age=$age"
  [ "$iso_age" -lt 60 ] || fail "active.jsonl last_beat became stale during T1: age=$iso_age"
  echo "T1 sample=$samples last-beat=$current_epoch age=${age}s mtime=$current_mtime active_last_beat=$current_iso active_age=${iso_age}s"
  last_seen_epoch="$current_epoch"
  last_seen_iso_epoch="$current_iso_epoch"
done

[ "$epoch_advances" -ge 2 ] || fail "last-beat did not advance across at least two intervals"
[ "$iso_advances" -ge 2 ] || fail "active.jsonl last_beat did not advance across at least two intervals"
final_epoch="$(read_last_beat "$last_beat")"
final_iso="$(read_active_last_beat "$ledger" "$session_id")"
final_now="$(date +%s)"
final_iso_epoch="$(iso_to_epoch "$final_iso")"
[ $((final_now - final_epoch)) -lt 60 ] || fail "final last-beat was not fresh"
[ $((final_now - final_iso_epoch)) -lt 60 ] || fail "final active.jsonl last_beat was not fresh"
echo "PASS T1 freshness while alive+active with no Stop: last-beat $initial_epoch -> $final_epoch, active $initial_iso -> $final_iso"

printf '{"items":[{"name":"green one","passes":true},{"name":"green two","passes":true}]}\n' > "$workspace/test-results.json"
wait_for_pid_exit "$keepalive_pid" 40 || fail "keepalive did not self-exit after all-green"
set +e
wait "$keepalive_pid"
green_status="$?"
set -e
[ "$green_status" -eq 0 ] || fail "keepalive all-green exit status $green_status"
green_epoch="$(read_last_beat "$last_beat")"
green_iso="$(read_active_last_beat "$ledger" "$session_id")"
sleep 7
after_green_epoch="$(read_last_beat "$last_beat")"
[ "$after_green_epoch" = "$green_epoch" ] || fail "last-beat advanced after all-green exit: $green_epoch -> $after_green_epoch"
wait_for_absent "$pid_file" 20 || fail "pid-file remained after all-green exit"
echo "PASS T2 all-green self-exit: last-beat stopped at $green_epoch active_last_beat=$green_iso"

kill "$dummy_pid" 2>/dev/null || true
wait "$dummy_pid" 2>/dev/null || true

case3="$SCRATCH_ROOT/t3"
session_id3="liveness-process-gone"
setup_workspace "$case3" "$session_id3"
workspace3="$case3/workspace"
workspace3="$(cd "$workspace3" && pwd -P)"
state_dir3="$workspace3/.claude/goal-state"
home3="$case3/home"
pid_file3="$state_dir3/liveness-keepalive.pid"
start_dummy_session
dummy_pid3="$STARTED_DUMMY_PID"
start_keepalive "$home3" "$dummy_pid3" "$workspace3" "$session_id3"
keepalive_pid3="$STARTED_KEEPALIVE_PID"
wait_for_pid_file_owner "$pid_file3" "$keepalive_pid3" 30 || fail "T3 keepalive did not own pid-file"
kill "$dummy_pid3"
wait "$dummy_pid3" 2>/dev/null || true
wait_for_pid_exit "$keepalive_pid3" 40 || fail "keepalive did not self-exit when session process died"
set +e
wait "$keepalive_pid3"
gone_status="$?"
set -e
[ "$gone_status" -eq 0 ] || fail "keepalive process-gone exit status $gone_status"
wait_for_absent "$pid_file3" 20 || fail "pid-file remained after process-gone exit"
echo "PASS T3 process-gone self-exit removed pid-file"

case4="$SCRATCH_ROOT/t4"
session_id4="liveness-singleton"
setup_workspace "$case4" "$session_id4"
workspace4="$case4/workspace"
workspace4="$(cd "$workspace4" && pwd -P)"
state_dir4="$workspace4/.claude/goal-state"
home4="$case4/home"
pid_file4="$state_dir4/liveness-keepalive.pid"
last_beat4="$state_dir4/last-beat"
start_dummy_session
dummy_pid4="$STARTED_DUMMY_PID"
start_keepalive "$home4" "$dummy_pid4" "$workspace4" "$session_id4"
keepalive_pid4="$STARTED_KEEPALIVE_PID"
wait_for_pid_file_owner "$pid_file4" "$keepalive_pid4" 30 || fail "T4 first keepalive did not own pid-file"
HOME="$home4" "$KEEPALIVE" "$dummy_pid4" "$workspace4" --interval "$INTERVAL" --session-id "$session_id4" --max-runtime 300 &
keepalive_pid4_b="$!"
KEEPALIVE_PIDS+=("$keepalive_pid4_b")
wait_for_pid_exit "$keepalive_pid4_b" 10 || fail "T4 second keepalive did not exit immediately"
set +e
wait "$keepalive_pid4_b"
singleton_status="$?"
set -e
[ "$singleton_status" -eq 0 ] || fail "T4 second keepalive exit status $singleton_status"
[ "$(sed -n '1p' "$pid_file4" 2>/dev/null || true)" = "$keepalive_pid4" ] || fail "T4 first keepalive no longer owns pid-file"
kill -0 "$keepalive_pid4" 2>/dev/null || fail "T4 first keepalive is not still alive"
beat4_a="$(read_last_beat "$last_beat4")"
sleep 7
beat4_b="$(read_last_beat "$last_beat4")"
[ "$beat4_b" -gt "$beat4_a" ] || fail "T4 first keepalive did not keep beating"
kill "$keepalive_pid4"
wait_for_pid_exit "$keepalive_pid4" 20 || fail "T4 first keepalive did not exit after TERM"
set +e
wait "$keepalive_pid4"
term_status="$?"
set -e
[ "$term_status" -eq 0 ] || fail "T4 first keepalive TERM exit status $term_status"
wait_for_absent "$pid_file4" 20 || fail "T4 first keepalive did not remove owned pid-file"
kill "$dummy_pid4" 2>/dev/null || true
wait "$dummy_pid4" 2>/dev/null || true
echo "PASS T4 singleton guard: second exited 0, first owned pid-file and beat $beat4_a -> $beat4_b"

echo "PASS - liveness keepalive refreshes session heartbeat and self-exits cleanly"
