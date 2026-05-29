#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  register-codex-goal.sh --agent <id> --slug <goal-slug> --goal "<one-line goal>" --channel <discord-channel-id> [options]

Required:
  --agent <id>                 OpenClaw agent id, e.g. schmidty
  --slug <goal-slug>           Durable goal slug, e.g. tilores-reddit-batch
  --goal "<one-line goal>"     Human-readable goal summary
  --channel <discord-id>       Discord channel id for delivery

Options:
  --interval <duration>        Cron interval, default: 5m
  --timeout-seconds <n>        Per-tick timeout, default: 720
  --contract <path>            Contract JSON file to install
  --contract-stdin             Read contract JSON from stdin
  --workspace-root <path>      Default: /Users/marco/.openclaw/workspace-<agent>/goals
  --enable                     Create the cron enabled. Default creates it disabled.
  --ledger <path>              Default: /Users/marco/.claude/goal-sessions/active.jsonl
  --force                      Do not refuse when an existing marker is found
  --dry-run                    Print all planned actions, change nothing, call no OpenClaw commands
  -h, --help                   Show this help
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_value() {
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    die "$1 requires a value"
  fi
}

iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

shell_join() {
  local first=1
  local arg
  for arg in "$@"; do
    if [ "$first" -eq 0 ]; then
      printf ' '
    fi
    printf '%q' "$arg"
    first=0
  done
  printf '\n'
}

json_line() {
  if ! command -v python3 >/dev/null 2>&1; then
    die "python3 is required to build the ledger JSON safely"
  fi

  python3 - "$@" <<'PY'
import json
import sys

keys = [
    "session_id",
    "agent",
    "channel",
    "goal",
    "started_at",
    "workspace",
    "launcher",
    "runtime",
    "cron_id",
    "session_key",
    "contract",
    "lock",
]
values = sys.argv[1:]
print(json.dumps(dict(zip(keys, values)), ensure_ascii=False))
PY
}

extract_cron_id() {
  local payload=$1

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$payload" <<'PY' 2>/dev/null || true
import json
import re
import sys

payload = sys.argv[1]
try:
    data = json.loads(payload)
except Exception:
    match = re.search(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', payload)
    if match:
        print(match.group(0))
    raise SystemExit(0)

def walk(value):
    if isinstance(value, dict):
        for key in ("id", "cron_id", "cronId", "jobId"):
            candidate = value.get(key)
            if isinstance(candidate, str) and candidate:
                return candidate
        for child in value.values():
            found = walk(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = walk(child)
            if found:
                return found
    return None

found = walk(data)
if found:
    print(found)
PY
    return 0
  fi

  printf '%s\n' "$payload" | sed -nE 's/.*([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}).*/\1/p' | head -n 1
}

ledger_has_session_key() {
  local ledger_file=$1
  local key=$2

  [ -f "$ledger_file" ] || return 1

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$ledger_file" "$key" <<'PY' 2>/dev/null
import json
import sys

ledger_file, key = sys.argv[1], sys.argv[2]
try:
    with open(ledger_file, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
            except Exception:
                continue
            if data.get("session_key") == key:
                raise SystemExit(0)
except FileNotFoundError:
    raise SystemExit(1)
raise SystemExit(1)
PY
    return $?
  fi

  grep -F "\"session_key\": \"$key\"" "$ledger_file" >/dev/null 2>&1 || grep -F "\"session_key\":\"$key\"" "$ledger_file" >/dev/null 2>&1
}

cron_has_session_key() {
  local key=$1
  local cron_json

  cron_json=$(openclaw cron list --json 2>/dev/null) || return 1
  [ -n "$cron_json" ] || return 1

  if command -v python3 >/dev/null 2>&1; then
    CRON_JSON=$cron_json python3 - "$key" <<'PY' 2>/dev/null
import json
import os
import sys

key = sys.argv[1]
try:
    data = json.loads(os.environ.get("CRON_JSON", ""))
except Exception:
    raise SystemExit(1)

if isinstance(data, list):
    jobs = data
elif isinstance(data, dict):
    jobs = data.get("jobs") or data.get("items") or data.get("data") or data.get("crons") or []
else:
    jobs = []

for job in jobs:
    if not isinstance(job, dict):
        continue
    value = job.get("sessionKey") or job.get("session_key")
    if value == key:
        raise SystemExit(0)

raise SystemExit(1)
PY
    return $?
  fi

  printf '%s\n' "$cron_json" | grep -F "$key" >/dev/null 2>&1
}

summarize_text() {
  local label=$1
  local text=$2
  local bytes
  local lines

  bytes=$(printf '%s' "$text" | wc -c | tr -d ' ')
  lines=$(printf '%s' "$text" | wc -l | tr -d ' ')
  printf '%s: %s bytes, %s newline(s)\n' "$label" "$bytes" "$lines"
}

write_file_guarded() {
  local path=$1
  local content=$2
  local force=$3

  if [ -e "$path" ] && [ "$force" -ne 1 ]; then
    die "$path already exists; use --force to overwrite"
  fi
  printf '%s\n' "$content" > "$path"
}

agent=
slug=
goal=
channel=
interval=5m
timeout_seconds=720
contract_file=
contract_stdin=0
workspace_root=
enable=0
ledger=/Users/marco/.claude/goal-sessions/active.jsonl
force=0
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      need_value "$1" "${2:-}"
      agent=$2
      shift 2
      ;;
    --slug)
      need_value "$1" "${2:-}"
      slug=$2
      shift 2
      ;;
    --goal)
      need_value "$1" "${2:-}"
      goal=$2
      shift 2
      ;;
    --channel)
      need_value "$1" "${2:-}"
      channel=$2
      shift 2
      ;;
    --interval)
      need_value "$1" "${2:-}"
      interval=$2
      shift 2
      ;;
    --timeout-seconds)
      need_value "$1" "${2:-}"
      timeout_seconds=$2
      shift 2
      ;;
    --contract)
      need_value "$1" "${2:-}"
      contract_file=$2
      shift 2
      ;;
    --contract-stdin)
      contract_stdin=1
      shift
      ;;
    --workspace-root)
      need_value "$1" "${2:-}"
      workspace_root=$2
      shift 2
      ;;
    --enable)
      enable=1
      shift
      ;;
    --ledger)
      need_value "$1" "${2:-}"
      ledger=$2
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[ -n "$agent" ] || die "--agent is required"
[ -n "$slug" ] || die "--slug is required"
[ -n "$goal" ] || die "--goal is required"
[ -n "$channel" ] || die "--channel is required"

if [ -n "$contract_file" ] && [ "$contract_stdin" -eq 1 ]; then
  die "use --contract or --contract-stdin, not both"
fi

case "$timeout_seconds" in
  ''|*[!0-9]*) die "--timeout-seconds must be a positive integer" ;;
esac

if [ -z "$workspace_root" ]; then
  workspace_root="/Users/marco/.openclaw/workspace-${agent}/goals"
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
goal_template_path="$script_dir/templates/GOAL.template.md"
contract_template_path="$script_dir/templates/contract.template.json"

[ -f "$goal_template_path" ] || die "missing template: $goal_template_path"
[ -f "$contract_template_path" ] || die "missing template: $contract_template_path"

workspace="${workspace_root%/}/$slug"
docs_dir="$workspace/docs"
state_dir="$workspace/state"
goal_path="$workspace/GOAL.md"
contract_path="$workspace/contract.json"
lock_path="$state_dir/running.lock"
session_key="agent:${agent}:goal:${slug}"
cron_name="Codex goal ${agent}/${slug}"
message="Durable goal tick for ${slug}. Read ${goal_path} and follow it exactly; do one heartbeat tick only."
started_at=$(iso_now)

goal_template=$(<"$goal_template_path")
rendered_goal=${goal_template//\{\{WORKSPACE\}\}/$workspace}
rendered_goal=${rendered_goal//\{\{SLUG\}\}/$slug}
rendered_goal=${rendered_goal//\{\{CHANNEL\}\}/$channel}

contract_source_label=
contract_payload=
if [ -n "$contract_file" ]; then
  [ -f "$contract_file" ] || die "contract file not found: $contract_file"
  contract_source_label="$contract_file"
  contract_payload=$(<"$contract_file")
elif [ "$contract_stdin" -eq 1 ]; then
  contract_source_label="stdin"
  contract_payload=$(cat)
else
  contract_source_label="$contract_template_path"
  contract_payload=$(<"$contract_template_path")
fi

cron_cmd=(
  openclaw cron add
  --name "$cron_name"
)
if [ "$enable" -eq 0 ]; then
  cron_cmd+=(--disabled)
fi
cron_cmd+=(
  --agent "$agent"
  --session-key "$session_key"
  --every "$interval"
  --thinking xhigh
  --timeout-seconds "$timeout_seconds"
  --channel discord
  --to "$channel"
  --account "$agent"
  --announce
  --best-effort-deliver
  --message "$message"
  --json
)

dry_cron_id="<cron-id-from-openclaw>"
dry_ledger_line=$(json_line "$dry_cron_id" "$agent" "$channel" "$goal" "$started_at" "$workspace" "openclaw-cron" "codex-openclaw" "$dry_cron_id" "$session_key" "$contract_path" "$lock_path")

if [ "$dry_run" -eq 1 ]; then
  printf 'DRY RUN: no files, directories, OpenClaw jobs, or ledger entries will be changed.\n'
  printf '\n'
  printf 'Would create directories:\n'
  printf '  mkdir -p %q %q\n' "$docs_dir" "$state_dir"
  printf '\n'
  printf 'Would write files:\n'
  printf '  %s from %s\n' "$contract_path" "$contract_source_label"
  printf '    '
  summarize_text "contract.json" "$contract_payload"
  printf '  %s rendered from %s\n' "$goal_path" "$goal_template_path"
  printf '    '
  summarize_text "GOAL.md" "$rendered_goal"
  printf '\n'
  printf 'Would run OpenClaw command:\n'
  printf '  '
  shell_join "${cron_cmd[@]}"
  printf '\n'
  printf 'Would append ledger line to %s:\n' "$ledger"
  printf '  %s\n' "$dry_ledger_line"
  printf '\n'
  printf 'Cron would be created %s.\n' "$([ "$enable" -eq 1 ] && printf 'enabled' || printf 'disabled')"
  if [ "$enable" -eq 1 ]; then
    printf 'Watchdog launchd enable command after customizing the plist template:\n'
    printf '  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.aiheroes.codex-goal-watchdog.plist\n'
    printf '  launchctl enable gui/$(id -u)/com.aiheroes.codex-goal-watchdog\n'
  fi
  exit 0
fi

if [ "$force" -ne 1 ]; then
  if ledger_has_session_key "$ledger" "$session_key"; then
    die "ledger already contains session_key $session_key; use --force to continue"
  fi
  if cron_has_session_key "$session_key"; then
    die "OpenClaw already has a cron with session_key $session_key; use --force to continue"
  fi
fi

mkdir -p "$docs_dir" "$state_dir"
write_file_guarded "$contract_path" "$contract_payload" "$force"
write_file_guarded "$goal_path" "$rendered_goal" "$force"

cron_output=$("${cron_cmd[@]}")
cron_id=$(extract_cron_id "$cron_output")
[ -n "$cron_id" ] || die "could not parse cron id from OpenClaw output: $cron_output"

ledger_line=$(json_line "$cron_id" "$agent" "$channel" "$goal" "$started_at" "$workspace" "openclaw-cron" "codex-openclaw" "$cron_id" "$session_key" "$contract_path" "$lock_path")
mkdir -p "$(dirname "$ledger")"
printf '%s\n' "$ledger_line" >> "$ledger"

printf 'Created OpenClaw Codex durable goal.\n'
printf 'Cron id: %s\n' "$cron_id"
printf 'Session key: %s\n' "$session_key"
printf 'Workspace: %s\n' "$workspace"
printf 'Contract: %s\n' "$contract_path"
printf 'GOAL.md: %s\n' "$goal_path"
printf 'Cron status: %s\n' "$([ "$enable" -eq 1 ] && printf 'enabled' || printf 'disabled')"
printf '\n'
printf 'Next steps:\n'
if [ "$enable" -ne 1 ]; then
  printf '  Enable or run the OpenClaw cron only when ready.\n'
else
  printf '  Customize and install the watchdog plist template, then run:\n'
  printf '  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.aiheroes.codex-goal-watchdog.plist\n'
  printf '  launchctl enable gui/$(id -u)/com.aiheroes.codex-goal-watchdog\n'
fi
