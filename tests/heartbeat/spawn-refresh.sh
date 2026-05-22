#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SPAWN="$REPO_ROOT/bin/codex-spawn.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/heartbeat-spawn-refresh.XXXXXX")"

cleanup() {
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

read_spawn_field() {
  file="$1"
  field="$2"
  python3 - "$file" "$field" <<'PY'
import datetime
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
field = sys.argv[2]
data = json.loads(path.read_text(encoding="utf-8"))
assert isinstance(data, dict), data
assert isinstance(data.get("pid"), int), data
assert isinstance(data.get("started_at"), str) and data["started_at"], data
assert isinstance(data.get("last_refreshed"), str) and data["last_refreshed"], data
assert data.get("command") == "codex", data
datetime.datetime.fromisoformat(data["started_at"].replace("Z", "+00:00"))
datetime.datetime.fromisoformat(data["last_refreshed"].replace("Z", "+00:00"))
print(data[field])
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

mock_bin="$SCRATCH_ROOT/mock-bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'mock codex invoked: %s\n' "$*" >> "$MOCK_CODEX_LOG"
sleep "${MOCK_CODEX_SLEEP_SECONDS:-75}"
exit "${MOCK_CODEX_EXIT_CODE:-0}"
MOCK
chmod +x "$mock_bin/codex"

model_env="$SCRATCH_ROOT/codex-current-model.env"
printf 'CODEX_MODEL=gpt-5.5\n' > "$model_env"

run_case() {
  expected_exit="$1"
  case_root="$SCRATCH_ROOT/case-$expected_exit"
  workspace="$case_root/workspace"
  state_dir="$workspace/.claude/goal-state"
  output="$case_root/codex-spawn.out"
  codex_log="$case_root/mock-codex.log"
  mkdir -p "$state_dir"

  start_epoch="$(date +%s)"
  set +e
  CODEX_MODEL_ENV_FILE="$model_env" \
  CODEX_SPAWN_WORKDIR="$workspace" \
  PATH="$mock_bin:$PATH" \
  MOCK_CODEX_LOG="$codex_log" \
  MOCK_CODEX_SLEEP_SECONDS=75 \
  MOCK_CODEX_EXIT_CODE="$expected_exit" \
    "$SPAWN" "synthetic heartbeat test exit $expected_exit" > "$output" 2>&1 &
  spawn_pid="$!"
  set -e

  last_beat="$state_dir/last-beat"
  spawn_active="$state_dir/spawn-active.json"

  wait_for_file "$last_beat" 20 || fail "last-beat was not created within 2s for exit $expected_exit"
  first_seen="$(date +%s)"
  [ $((first_seen - start_epoch)) -le 2 ] || fail "last-beat creation took more than 2s for exit $expected_exit"
  first_mtime="$(mtime "$last_beat")"
  wait_for_file "$spawn_active" 20 || fail "spawn-active.json missing during spawn for exit $expected_exit"
  first_refreshed="$(read_spawn_field "$spawn_active" last_refreshed)"
  first_pid="$(read_spawn_field "$spawn_active" pid)"

  echo "PASS exit=$expected_exit initial last-beat mtime=$first_mtime target_pid=$first_pid"
  echo "LIVE spawn-active.json exit=$expected_exit"
  cat "$spawn_active"

  sleep 35
  second_mtime="$(mtime "$last_beat")"
  [ "$second_mtime" -gt "$first_mtime" ] || fail "last-beat mtime did not advance after first refresh for exit $expected_exit"
  second_refreshed="$(read_spawn_field "$spawn_active" last_refreshed)"
  [ "$second_refreshed" != "$first_refreshed" ] || fail "last_refreshed did not advance after first refresh for exit $expected_exit"
  echo "PASS exit=$expected_exit mtime advance 1: $first_mtime -> $second_mtime"
  echo "PASS exit=$expected_exit last_refreshed advance 1: $first_refreshed -> $second_refreshed"

  sleep 35
  third_mtime="$(mtime "$last_beat")"
  [ "$third_mtime" -gt "$second_mtime" ] || fail "last-beat mtime did not advance after second refresh for exit $expected_exit"
  third_refreshed="$(read_spawn_field "$spawn_active" last_refreshed)"
  [ "$third_refreshed" != "$second_refreshed" ] || fail "last_refreshed did not advance after second refresh for exit $expected_exit"
  echo "PASS exit=$expected_exit mtime advance 2: $second_mtime -> $third_mtime"
  echo "PASS exit=$expected_exit last_refreshed advance 2: $second_refreshed -> $third_refreshed"

  set +e
  wait "$spawn_pid"
  actual_exit="$?"
  set -e
  [ "$actual_exit" -eq "$expected_exit" ] || fail "codex-spawn exit $actual_exit, expected $expected_exit"
  echo "PASS exit=$expected_exit codex-spawn exit propagated"

  wait_for_absent "$spawn_active" 50 || fail "spawn-active.json was not removed within 5s for exit $expected_exit"
  echo "AFTER exit=$expected_exit spawn-active ls:"
  ls -l "$spawn_active" 2>&1 || true
  echo "PASS exit=$expected_exit spawn-active removed"
}

run_case 0
run_case 7

echo "PASS - spawn heartbeat refreshes last-beat and preserves codex exit codes"
