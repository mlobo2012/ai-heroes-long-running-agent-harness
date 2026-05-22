#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# When a webhook is available, this script posts with retry/backoff:
#   curl -fsS -X POST -H 'Content-Type: application/json' \
#     --max-time "${DISCORD_NOTIFY_TIMEOUT:-10}" \
#     -d '{"content":"<message>"}' "$DISCORD_NOTIFY_WEBHOOK"
# Env vars:
#   DISCORD_NOTIFY_WEBHOOK     Discord webhook URL for the bound channel.
#   DISCORD_NOTIFY_CHANNEL_ID  Optional channel id for log context.
#   DISCORD_NOTIFY_MAX_ATTEMPTS Optional curl attempts before dead-letter (default: 3).
#   DISCORD_NOTIFY_TIMEOUT     Optional curl --max-time seconds (default: 10).

WORKDIR="${PWD}"
STATE_DIR="$WORKDIR/.claude/goal-state"
mkdir -p "$STATE_DIR"

RESULTS_FILE="$WORKDIR/test-results.json"
LAST_STATUS_FILE="$STATE_DIR/last-status"
LAST_PASS_COUNT_FILE="$STATE_DIR/last-pass-count"
LOG_FILE="$STATE_DIR/discord-notify.log"
DEADLETTER_FILE="$STATE_DIR/discord-notify-deadletter.log"

results_count() {
  # Count `"passes"` boolean values matching $value at any nesting depth.
  # Prefers jq for schema-robustness (won't double-count future keys like
  # "prior_passes" or "sub_passes"). Falls back to an anchored regex that
  # requires a key-position character before "passes".
  # Closes Trap D7 in docs/parity-gap-analysis.md.
  file="$1"
  value="$2"
  [ -f "$file" ] || { printf '0\n'; return 0; }
  if command -v jq >/dev/null 2>&1; then
    count=$(jq --argjson v "$value" -r '[.. | objects | select(has("passes")) | .passes] | map(select(. == $v)) | length' "$file" 2>/dev/null) || count=""
    if [ -n "$count" ] && printf '%s' "$count" | grep -Eq '^[0-9]+$'; then
      printf '%s\n' "$count"
      return 0
    fi
  fi
  case "$value" in
    true) pat='[{,[:space:]]"passes"[[:space:]]*:[[:space:]]*true' ;;
    false) pat='[{,[:space:]]"passes"[[:space:]]*:[[:space:]]*false' ;;
    *) printf '0\n'; return 0 ;;
  esac
  { grep -oE "$pat" "$file" 2>/dev/null || true; } | wc -l | tr -d ' '
}

cost_telemetry_summary() {
  session="$1"
  if [ -z "$session" ]; then
    echo "cost-telemetry warning: no session_id in goal-state.json" >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "cost-telemetry warning: python3 unavailable" >&2
    return 1
  fi

  # Pricing constants are intentionally inline and conservative. They use the
  # current claude-opus-4-7 public-rate shape from the sprint brief:
  # input $15/MTok, output $75/MTok, cache creation $18.75/MTok, cache read
  # $1.50/MTok. The estimate is only for operator visibility.
  SESSION_ID="$session" CLAUDE_PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-}" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

session_id = os.environ.get("SESSION_ID", "")
projects_env = os.environ.get("CLAUDE_PROJECTS_DIR", "")
projects_root = Path(projects_env).expanduser() if projects_env else Path.home() / ".claude" / "projects"

INPUT_PER_MTOK = 15.00
OUTPUT_PER_MTOK = 75.00
CACHE_CREATION_PER_MTOK = 18.75
CACHE_READ_PER_MTOK = 1.50


def warn(message):
    print(f"cost-telemetry warning: {message}", file=sys.stderr)


def token_value(usage, key):
    try:
        return int(usage.get(key) or 0)
    except (TypeError, ValueError):
        return 0


if not session_id:
    warn("empty session id")
    raise SystemExit(2)
if not projects_root.exists():
    warn(f"Claude projects directory not found: {projects_root}")
    raise SystemExit(2)

candidates = [
    path
    for path in projects_root.glob(f"*/{session_id}.jsonl")
    if path.is_file() and path.stat().st_size > 0
]
if not candidates:
    warn(f"no non-empty Claude session log found for session_id={session_id}")
    raise SystemExit(2)

session_log = max(candidates, key=lambda path: path.stat().st_mtime)
input_tokens = 0
output_tokens = 0
cache_creation_tokens = 0
cache_read_tokens = 0
usage_records = 0
model = ""

try:
    handle = session_log.open("r", encoding="utf-8", errors="replace")
except OSError as exc:
    warn(f"could not read {session_log}: {exc}")
    raise SystemExit(2)

with handle:
    for raw in handle:
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        message = entry.get("message")
        if not isinstance(message, dict):
            continue
        usage = message.get("usage")
        if not isinstance(usage, dict):
            continue
        usage_records += 1
        model = str(message.get("model") or model)
        input_tokens += token_value(usage, "input_tokens")
        output_tokens += token_value(usage, "output_tokens")
        cache_creation_tokens += token_value(usage, "cache_creation_input_tokens")
        cache_read_tokens += token_value(usage, "cache_read_input_tokens")

if usage_records == 0:
    warn(f"no usage records found in {session_log}")
    raise SystemExit(2)

cost = (
    (input_tokens * INPUT_PER_MTOK)
    + (output_tokens * OUTPUT_PER_MTOK)
    + (cache_creation_tokens * CACHE_CREATION_PER_MTOK)
    + (cache_read_tokens * CACHE_READ_PER_MTOK)
) / 1_000_000

model_part = f"; model {model}" if model else ""
print(
    "Claude usage: "
    f"input_tokens={input_tokens}; "
    f"output_tokens={output_tokens}; "
    f"cache_creation_input_tokens={cache_creation_tokens}; "
    f"cache_read_input_tokens={cache_read_tokens}; "
    f"estimated_cost_usd=${cost:.4f} "
    "(claude-opus-4-7 rates: $15/MTok input, $75/MTok output, "
    "$18.75/MTok cache creation, $1.50/MTok cache read"
    f"{model_part}; source {session_log})"
)
PY
}

true_count="$(results_count "$RESULTS_FILE" true)"
false_count="$(results_count "$RESULTS_FILE" false)"

status="running"
if [ -f "$RESULTS_FILE" ] && [ "$true_count" -gt 0 ] && [ "$false_count" -eq 0 ]; then
  status="goal-complete"
else
  last_pass_count="0"
  if [ -f "$LAST_PASS_COUNT_FILE" ]; then
    last_pass_count="$(sed -n '1p' "$LAST_PASS_COUNT_FILE" 2>/dev/null || printf '0')"
  fi
  case "$last_pass_count" in
    ''|*[!0-9]*) last_pass_count="0" ;;
  esac
  if [ "$true_count" -gt "$last_pass_count" ]; then
    status="sprint-pass"
  fi
fi

last_status=""
if [ -f "$LAST_STATUS_FILE" ]; then
  last_status="$(sed -n '1p' "$LAST_STATUS_FILE" 2>/dev/null || true)"
fi

should_post="false"
if [ "$status" != "running" ] && [ "$status" != "$last_status" ]; then
  should_post="true"
elif [ "$status" = "sprint-pass" ]; then
  last_pass_count="0"
  if [ -f "$LAST_PASS_COUNT_FILE" ]; then
    last_pass_count="$(sed -n '1p' "$LAST_PASS_COUNT_FILE" 2>/dev/null || printf '0')"
  fi
  case "$last_pass_count" in
    ''|*[!0-9]*) last_pass_count="0" ;;
  esac
  if [ "$true_count" -gt "$last_pass_count" ]; then
    should_post="true"
  fi
fi

goal="goal"
session_id=""
if [ -f "$STATE_DIR/goal-state.json" ] && command -v python3 >/dev/null 2>&1; then
  goal="$(python3 - "$STATE_DIR/goal-state.json" <<'PY' 2>/dev/null || printf 'goal'
import json
import sys
data = json.load(open(sys.argv[1]))
print(data.get("goal") or "goal")
PY
)"
  session_id="$(python3 - "$STATE_DIR/goal-state.json" <<'PY' 2>/dev/null || true
import json
import sys
data = json.load(open(sys.argv[1]))
print(data.get("session_id") or "")
PY
)"
fi

message=""
case "$status" in
  goal-complete)
    message="Goal complete: ${goal}"
    cost_summary=""
    if cost_summary="$(cost_telemetry_summary "$session_id" 2>>"$LOG_FILE")"; then
      if [ -n "$cost_summary" ]; then
        message="${message} | ${cost_summary}"
      fi
    else
      printf '%s session=%s status=%s cost-telemetry-unavailable\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$session_id" "$status" >> "$LOG_FILE"
    fi
    ;;
  sprint-pass)
    message="Sprint PASS for goal: ${goal}"
    ;;
esac

printf '%s\n' "$status" > "$LAST_STATUS_FILE"
printf '%s\n' "$true_count" > "$LAST_PASS_COUNT_FILE"

if [ "$should_post" != "true" ] || [ -z "$message" ]; then
  exit 0
fi

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
channel="${DISCORD_NOTIFY_CHANNEL_ID:-unknown-channel}"
printf '%s channel=%s session=%s status=%s message=%s\n' "$timestamp" "$channel" "$session_id" "$status" "$message" >> "$LOG_FILE"

if [ -n "${DISCORD_NOTIFY_WEBHOOK:-}" ]; then
  if command -v python3 >/dev/null 2>&1; then
    payload="$(MESSAGE="$message" python3 - <<'PY'
import json
import os
print(json.dumps({"content": os.environ.get("MESSAGE", "")}))
PY
)"
    max_attempts="${DISCORD_NOTIFY_MAX_ATTEMPTS:-3}"
    case "$max_attempts" in
      ''|*[!0-9]*) max_attempts="3" ;;
    esac
    if [ "$max_attempts" -lt 1 ]; then
      max_attempts="1"
    fi

    timeout="${DISCORD_NOTIFY_TIMEOUT:-10}"
    case "$timeout" in
      ''|*[!0-9]*) timeout="10" ;;
    esac

    ok=0
    attempts=0
    while [ "$attempts" -lt "$max_attempts" ]; do
      attempts=$((attempts + 1))
      if curl -fsS -X POST -H 'Content-Type: application/json' \
        --max-time "$timeout" \
        -d "$payload" "$DISCORD_NOTIFY_WEBHOOK" >/dev/null 2>&1; then
        ok=1
        break
      fi
      if [ "$attempts" -lt "$max_attempts" ]; then
        sleep_for=$((2 ** (attempts - 1)))
        sleep "$sleep_for"
      fi
    done

    if [ "$ok" -eq 1 ]; then
      printf '%s channel=%s status=%s webhook-posted attempts=%s\n' "$timestamp" "$channel" "$status" "$attempts" >> "$LOG_FILE"
    else
      printf '%s channel=%s status=%s webhook-error attempts=%s\n' "$timestamp" "$channel" "$status" "$attempts" >> "$LOG_FILE"
      printf '%s channel=%s status=%s attempts=%s payload=%s\n' "$timestamp" "$channel" "$status" "$attempts" "$payload" >> "$DEADLETTER_FILE"
    fi
  fi
fi

exit 0
