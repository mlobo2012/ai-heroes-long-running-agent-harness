#!/usr/bin/env bash

timeout_seconds=720
cooldown_seconds=300
goal_cron_id=
session_key=
contract_path=
lock_path=
state_dir=
dry_run=0

usage() {
  printf '%s\n' "Usage: $0 --goal-cron-id ID --session-key KEY --contract PATH --lock PATH [--timeout-seconds N] [--cooldown-seconds N] [--state-dir PATH] [--once] [--dry-run] [--self-test]"
}

iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log_msg() {
  ts=$(iso_now)
  line="$ts $*"
  printf '%s\n' "$line"
  if [ "${dry_run:-0}" -eq 0 ] && [ -n "${state_dir:-}" ]; then
    mkdir -p "$state_dir" 2>/dev/null || true
    printf '%s\n' "$line" >> "$state_dir/watchdog.log" 2>/dev/null || true
  fi
}

iso_to_epoch() {
  value=$1
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$value" <<'PY' 2>/dev/null
import datetime
import sys

value = sys.argv[1].strip()
if not value:
    raise SystemExit(1)
if value.endswith("Z"):
    value = value[:-1] + "+00:00"
dt = datetime.datetime.fromisoformat(value)
if dt.tzinfo is None:
    dt = dt.replace(tzinfo=datetime.timezone.utc)
print(int(dt.timestamp()))
PY
    return $?
  fi
  return 1
}

file_mtime_epoch() {
  file=$1
  if stat -f '%m' "$file" >/dev/null 2>&1; then
    stat -f '%m' "$file" 2>/dev/null
    return $?
  fi
  if stat -c '%Y' "$file" >/dev/null 2>&1; then
    stat -c '%Y' "$file" 2>/dev/null
    return $?
  fi
  return 1
}

lock_age_seconds() {
  file=$1
  [ -f "$file" ] || return 1

  now_epoch=$(date +%s)
  stamp=$(sed -n '1p' "$file" 2>/dev/null)
  lock_epoch=
  if [ -n "$stamp" ]; then
    lock_epoch=$(iso_to_epoch "$stamp" 2>/dev/null)
  fi
  if [ -z "$lock_epoch" ]; then
    lock_epoch=$(file_mtime_epoch "$file" 2>/dev/null)
  fi
  [ -n "$lock_epoch" ] || return 1

  age=$((now_epoch - lock_epoch))
  if [ "$age" -lt 0 ]; then
    age=0
  fi
  printf '%s\n' "$age"
}

contract_state() {
  file=$1
  if [ ! -f "$file" ]; then
    printf '%s\n' "unknown"
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '
      if (type == "object" and (.items | type == "array")) then
        if all(.items[]; .passes == true) then "complete" else "incomplete" end
      else
        "unknown"
      end
    ' "$file" 2>/dev/null || printf '%s\n' "unknown"
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY' 2>/dev/null || printf '%s\n' "unknown"
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    print("unknown")
    raise SystemExit(0)

items = data.get("items") if isinstance(data, dict) else None
if not isinstance(items, list):
    print("unknown")
elif all(isinstance(item, dict) and item.get("passes") is True for item in items):
    print("complete")
else:
    print("incomplete")
PY
    return 0
  fi

  printf '%s\n' "unknown"
}

extract_recent_task() {
  key=$1
  tasks_json=$(openclaw tasks list --json 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$tasks_json" ]; then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$tasks_json" | jq -r --arg key "$key" '
      def task_list:
        if type == "array" then .
        elif type == "object" then (.tasks? // .items? // .data? // [])
        else [] end;
      task_list
      | map(select((.childSessionKey // "") == $key))
      | sort_by(.createdAt // .endedAt // "")
      | last as $task
      | if $task == null then empty
        else [($task.status // ""), ($task.createdAt // ""), ($task.endedAt // ""), ($task.label // "")] | @tsv
        end
    ' 2>/dev/null
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    TASKS_JSON=$tasks_json python3 - "$key" <<'PY' 2>/dev/null
import json
import os
import sys

key = sys.argv[1]
try:
    data = json.loads(os.environ.get("TASKS_JSON", ""))
except Exception:
    raise SystemExit(0)

if isinstance(data, list):
    tasks = data
elif isinstance(data, dict):
    tasks = data.get("tasks") or data.get("items") or data.get("data") or []
else:
    tasks = []

matches = [task for task in tasks if isinstance(task, dict) and task.get("childSessionKey") == key]
if not matches:
    raise SystemExit(0)

matches.sort(key=lambda task: task.get("createdAt") or task.get("endedAt") or "")
task = matches[-1]
print("\t".join([
    str(task.get("status") or ""),
    str(task.get("createdAt") or ""),
    str(task.get("endedAt") or ""),
    str(task.get("label") or ""),
]))
PY
    return 0
  fi

  return 0
}

last_refire_age() {
  file=$1
  [ -f "$file" ] || return 1
  now_epoch=$(date +%s)
  stamp=$(sed -n '1p' "$file" 2>/dev/null)
  [ -n "$stamp" ] || return 1
  epoch=$(iso_to_epoch "$stamp" 2>/dev/null)
  if [ -z "$epoch" ]; then
    epoch=$(printf '%s\n' "$stamp" | sed 's/[^0-9].*$//' 2>/dev/null)
  fi
  case "$epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  age=$((now_epoch - epoch))
  if [ "$age" -lt 0 ]; then
    age=0
  fi
  printf '%s\n' "$age"
}

refire() {
  decision=$1
  detected_status=$2
  last_refire_file="$state_dir/watchdog-last-refire"
  events_file="$state_dir/watchdog-events.log"

  last_age=$(last_refire_age "$last_refire_file" 2>/dev/null)
  if [ -n "$last_age" ] && [ "$last_age" -lt "$cooldown_seconds" ]; then
    log_msg "decision=cooldown, skip detected_status=$detected_status last_refire_age=${last_age}s cooldown=${cooldown_seconds}s"
    return 0
  fi

  log_msg "decision=$decision detected_status=$detected_status action=refire dry_run=$dry_run"

  if [ "$dry_run" -eq 1 ]; then
    return 0
  fi

  if [ -f "$lock_path" ]; then
    rm -f "$lock_path" 2>/dev/null || log_msg "warning=lock-delete-failed path=$lock_path"
  fi

  mkdir -p "$state_dir" 2>/dev/null || true
  printf '%s detected_status=%s action=refire session_key=%s cron_id=%s\n' "$(iso_now)" "$detected_status" "$session_key" "$goal_cron_id" >> "$events_file" 2>/dev/null || true

  openclaw cron run "$goal_cron_id" >/dev/null 2>&1
  rc=$?
  printf '%s\n' "$(iso_now)" > "$last_refire_file" 2>/dev/null || true
  if [ "$rc" -ne 0 ]; then
    log_msg "warning=cron-run-failed cron_id=$goal_cron_id exit=$rc"
  fi
  return 0
}

run_once() {
  if [ -z "$goal_cron_id" ] || [ -z "$session_key" ] || [ -z "$contract_path" ] || [ -z "$lock_path" ]; then
    log_msg "decision=config-error, noop missing-required-flags"
    return 0
  fi

  if [ -z "$state_dir" ]; then
    state_dir=$(dirname "$lock_path")
  fi

  state=$(contract_state "$contract_path")
  case "$state" in
    complete)
      log_msg "decision=complete, noop contract=$contract_path"
      return 0
      ;;
    unknown)
      log_msg "decision=contract-unknown, noop contract=$contract_path"
      return 0
      ;;
  esac

  task_line=$(extract_recent_task "$session_key")
  task_status=
  task_created=
  task_ended=
  task_label=
  if [ -n "$task_line" ]; then
    old_ifs=$IFS
    IFS='	'
    set -- $task_line
    IFS=$old_ifs
    task_status=${1:-}
    task_created=${2:-}
    task_ended=${3:-}
    task_label=${4:-}
  fi

  lock_exists=0
  lock_age=
  if [ -f "$lock_path" ]; then
    lock_exists=1
    lock_age=$(lock_age_seconds "$lock_path" 2>/dev/null)
  fi

  if [ "$task_status" = "running" ]; then
    log_msg "decision=active, noop reason=task-running status=$task_status createdAt=$task_created"
    return 0
  fi

  # A terminal task status means the run that wrote any lock is DEAD. Recover regardless of
  # lock age — checking lock freshness first would treat a dead-but-locked tick as "alive".
  case "$task_status" in
    timed_out|lost|failed)
      refire "stall, refire" "$task_status"
      return 0
      ;;
  esac

  if [ "$lock_exists" -eq 1 ] && [ -n "$lock_age" ] && [ "$lock_age" -lt "$timeout_seconds" ]; then
    log_msg "decision=active, noop reason=fresh-lock lock_age=${lock_age}s timeout=${timeout_seconds}s"
    return 0
  fi

  if [ "$lock_exists" -eq 1 ] && [ -z "$lock_age" ]; then
    log_msg "decision=active, noop reason=unknown-lock-age lock=$lock_path"
    return 0
  fi

  if [ "$lock_exists" -eq 1 ] && [ -n "$lock_age" ] && [ "$lock_age" -ge "$timeout_seconds" ]; then
    refire "stall, refire" "stale_lock"
    return 0
  fi

  refire "idle-red, refire" "${task_status:-none}"
  return 0
}

write_selftest_fake_openclaw() {
  fake_openclaw=$1
  cat > "$fake_openclaw" <<'EOF'
#!/usr/bin/env bash

if [ "$1" = "tasks" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
  case "${OPENCLAW_FAKE_MODE:-timed_out}" in
    timed_out)
      printf '%s\n' '[{"childSessionKey":"agent:test:goal","status":"timed_out","createdAt":"2026-05-29T10:00:00Z","endedAt":"2026-05-29T10:15:00Z","label":"fake timed out goal"}]'
      ;;
    none)
      printf '%s\n' '[]'
      ;;
    running)
      printf '%s\n' '[{"childSessionKey":"agent:test:goal","status":"running","createdAt":"2026-05-29T10:00:00Z","label":"fake running goal"}]'
      ;;
    nonjson)
      printf '%s\n' 'not json'
      ;;
  esac
  exit 0
fi

if [ "$1" = "cron" ] && [ "$2" = "run" ]; then
  printf '%s\n' "cron run unexpectedly called" >&2
  printf '%s\n' "cron-run $*" >> "${OPENCLAW_FAKE_FIRE_LOG:-/dev/null}"
  exit 44
fi

if [ "$1" = "cron" ] && [ "$2" = "get" ]; then
  printf '%s\n' '{"id":"fake-cron"}'
  exit 0
fi

exit 0
EOF
  chmod +x "$fake_openclaw"
}

self_test() {
  script_path=${BASH_SOURCE[0]}
  case "$script_path" in
    /*) ;;
    *) script_path=$(pwd)/$script_path ;;
  esac

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-goal-watchdog.XXXXXX") || {
    printf '%s\n' "SELFTEST: FAIL mktemp"
    return 1
  }
  trap 'rm -rf "$tmp_dir"' EXIT

  fake_bin="$tmp_dir/bin"
  mkdir -p "$fake_bin" "$tmp_dir/state-complete" "$tmp_dir/state-active" "$tmp_dir/state-refire" || {
    printf '%s\n' "SELFTEST: FAIL mkdir"
    return 1
  }
  write_selftest_fake_openclaw "$fake_bin/openclaw"

  green_contract="$tmp_dir/green-contract.json"
  red_contract="$tmp_dir/red-contract.json"
  fresh_lock="$tmp_dir/state-active/running.lock"
  stale_lock="$tmp_dir/state-refire/running.lock"
  fire_log="$tmp_dir/fired.log"

  printf '%s\n' '{"items":[{"passes":true},{"passes":true}]}' > "$green_contract"
  printf '%s\n' '{"items":[{"passes":true},{"passes":false}]}' > "$red_contract"
  printf '%s\n' "$(iso_now)" > "$fresh_lock"
  printf '%s\n' '2000-01-01T00:00:00Z' > "$stale_lock"

  complete_out=$(PATH="$fake_bin:$PATH" OPENCLAW_FAKE_MODE=timed_out OPENCLAW_FAKE_FIRE_LOG="$fire_log" "$script_path" --goal-cron-id fake-cron --session-key agent:test:goal --contract "$green_contract" --lock "$tmp_dir/state-complete/running.lock" --state-dir "$tmp_dir/state-complete" --timeout-seconds 1 --cooldown-seconds 0 --dry-run 2>&1)
  active_out=$(PATH="$fake_bin:$PATH" OPENCLAW_FAKE_MODE=none OPENCLAW_FAKE_FIRE_LOG="$fire_log" "$script_path" --goal-cron-id fake-cron --session-key agent:test:goal --contract "$red_contract" --lock "$fresh_lock" --state-dir "$tmp_dir/state-active" --timeout-seconds 720 --cooldown-seconds 0 --dry-run 2>&1)
  refire_out=$(PATH="$fake_bin:$PATH" OPENCLAW_FAKE_MODE=timed_out OPENCLAW_FAKE_FIRE_LOG="$fire_log" "$script_path" --goal-cron-id fake-cron --session-key agent:test:goal --contract "$red_contract" --lock "$stale_lock" --state-dir "$tmp_dir/state-refire" --timeout-seconds 1 --cooldown-seconds 0 --dry-run 2>&1)

  printf '%s\n' "$complete_out"
  printf '%s\n' "$active_out"
  printf '%s\n' "$refire_out"

  fail_reason=
  printf '%s\n' "$complete_out" | grep -q 'decision=complete, noop' || fail_reason="missing complete decision"
  if [ -z "$fail_reason" ]; then
    printf '%s\n' "$active_out" | grep -q 'decision=active, noop' || fail_reason="missing active decision"
  fi
  if [ -z "$fail_reason" ]; then
    printf '%s\n' "$refire_out" | grep -q 'refire' || fail_reason="missing refire decision"
  fi
  if [ -z "$fail_reason" ] && [ -s "$fire_log" ]; then
    fail_reason="cron fired during dry-run"
  fi

  if [ -n "$fail_reason" ]; then
    printf '%s\n' "SELFTEST: FAIL $fail_reason"
    return 1
  fi

  printf '%s\n' "SELFTEST: PASS"
  return 0
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit $?
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --goal-cron-id)
      shift
      goal_cron_id=${1:-}
      ;;
    --session-key)
      shift
      session_key=${1:-}
      ;;
    --contract)
      shift
      contract_path=${1:-}
      ;;
    --lock)
      shift
      lock_path=${1:-}
      ;;
    --timeout-seconds)
      shift
      timeout_seconds=${1:-720}
      ;;
    --cooldown-seconds)
      shift
      cooldown_seconds=${1:-300}
      ;;
    --state-dir)
      shift
      state_dir=${1:-}
      ;;
    --once)
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_msg "decision=config-error, noop unknown-arg=$1"
      exit 0
      ;;
  esac
  shift
done

case "$timeout_seconds" in
  ''|*[!0-9]*) timeout_seconds=720 ;;
esac
case "$cooldown_seconds" in
  ''|*[!0-9]*) cooldown_seconds=300 ;;
esac

run_once
exit 0
