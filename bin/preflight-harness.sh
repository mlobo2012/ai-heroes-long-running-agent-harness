#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: preflight-harness.sh --plugin-dir <dir> --workspace <dir> [--webhook <url>]
USAGE
}

PLUGIN_DIR=""
WORKSPACE=""
WEBHOOK=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --plugin-dir)
      PLUGIN_DIR="${2:-}"
      shift 2
      ;;
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --webhook)
      WEBHOOK="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 2
      ;;
    *)
      echo "preflight: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$PLUGIN_DIR" ] || [ -z "$WORKSPACE" ]; then
  usage >&2
  exit 2
fi

HOOKS_JSON="$PLUGIN_DIR/hooks/hooks.json"
HEARTBEAT_HOOK="$PLUGIN_DIR/hooks/heartbeat-stop.sh"
STATE_DIR="$WORKSPACE/.claude/goal-state"
PREFLIGHT_JSON="$STATE_DIR/harness-preflight.json"

failures=()
json_valid=0

json_escape() {
  value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

write_preflight_state() {
  status="$1"
  checked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if ! mkdir -p "$STATE_DIR"; then
    return 1
  fi
  if ! tmp="$(mktemp "$STATE_DIR/harness-preflight.json.tmp.XXXXXX")"; then
    return 1
  fi
  if ! {
    printf '{"status":"%s","checked_at":"%s","plugin_dir":"%s"' \
      "$(json_escape "$status")" \
      "$(json_escape "$checked_at")" \
      "$(json_escape "$PLUGIN_DIR")"
    if [ "$status" = "failed" ]; then
      printf ',"missing":['
      first=1
      for reason in "${failures[@]}"; do
        if [ "$first" -eq 0 ]; then
          printf ','
        fi
        first=0
        printf '"%s"' "$(json_escape "$reason")"
      done
      printf ']'
    fi
    printf '}\n'
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv "$tmp" "$PREFLIGHT_JSON"; then
    rm -f "$tmp"
    return 1
  fi
}

hooks_json_valid() {
  file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq empty "$file" >/dev/null 2>&1
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$file" >/dev/null 2>&1
    return $?
  fi
  return 127
}

stop_wires_heartbeat() {
  file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e '
      (.hooks.Stop? // [])
      | select(type == "array")
      | .. | objects | .command? // empty
      | strings
      | select(contains("heartbeat-stop.sh"))
    ' "$file" >/dev/null 2>&1
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY' >/dev/null 2>&1
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

def walk(value):
    if isinstance(value, dict):
        command = value.get("command")
        if isinstance(command, str) and "heartbeat-stop.sh" in command:
            return True
        return any(walk(child) for child in value.values())
    if isinstance(value, list):
        return any(walk(child) for child in value)
    return False

stop_hooks = data.get("hooks", {}).get("Stop", [])
raise SystemExit(0 if isinstance(stop_hooks, list) and walk(stop_hooks) else 1)
PY
    return $?
  fi
  return 127
}

post_failure_webhook() {
  [ -n "$WEBHOOK" ] || return 0

  reason_text=""
  for reason in "${failures[@]}"; do
    if [ -n "$reason_text" ]; then
      reason_text="${reason_text}. "
    fi
    reason_text="${reason_text}${reason}"
  done
  message="⚠️ harness preflight FAILED for ${WORKSPACE}: ${reason_text}. The long-running pulse will NOT run for this session."
  payload="{\"content\":\"$(json_escape "$message")\"}"

  attempts=0
  ok=0
  while [ "$attempts" -lt 3 ]; do
    attempts=$((attempts + 1))
    if curl -fsS -X POST -H 'Content-Type: application/json' \
      --max-time 10 \
      -d "$payload" "$WEBHOOK" >/dev/null 2>&1; then
      ok=1
      break
    fi
    if [ "$attempts" -lt 3 ]; then
      sleep_for=$((2 ** (attempts - 1)))
      sleep "$sleep_for"
    fi
  done

  [ "$ok" -eq 1 ] || true
}

if [ ! -d "$PLUGIN_DIR" ]; then
  failures+=("plugin directory not found: $PLUGIN_DIR")
fi

if [ ! -f "$HOOKS_JSON" ]; then
  failures+=("hooks.json not found: $HOOKS_JSON")
else
  if hooks_json_valid "$HOOKS_JSON"; then
    json_valid=1
  else
    if command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
      failures+=("hooks.json is not valid JSON: $HOOKS_JSON")
    else
      failures+=("hooks.json could not be validated because jq and python3 are unavailable: $HOOKS_JSON")
    fi
  fi
fi

if [ ! -f "$HEARTBEAT_HOOK" ]; then
  failures+=("heartbeat-stop.sh not found: $HEARTBEAT_HOOK")
elif [ ! -x "$HEARTBEAT_HOOK" ]; then
  failures+=("heartbeat-stop.sh is not executable: $HEARTBEAT_HOOK")
fi

if [ "$json_valid" -eq 1 ] && ! stop_wires_heartbeat "$HOOKS_JSON"; then
  failures+=("hooks.json Stop hook does not reference heartbeat-stop.sh: $HOOKS_JSON")
fi

if [ "${#failures[@]}" -eq 0 ]; then
  if ! write_preflight_state "ok"; then
    echo "preflight: could not write $PREFLIGHT_JSON" >&2
    exit 1
  fi
  echo "preflight: harness OK"
  exit 0
fi

for reason in "${failures[@]}"; do
  echo "$reason" >&2
done

if ! write_preflight_state "failed"; then
  echo "preflight: could not write $PREFLIGHT_JSON" >&2
fi
post_failure_webhook
exit 1
