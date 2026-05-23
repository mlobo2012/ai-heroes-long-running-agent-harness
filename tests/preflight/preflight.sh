#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
PREFLIGHT="$REPO_ROOT/bin/preflight-harness.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1"
  exit 1
}

make_plugin() {
  plugin_dir="$1"
  mkdir -p "$plugin_dir/hooks"
  cat > "$plugin_dir/hooks/hooks.json" <<'JSON'
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "\"${CLAUDE_PLUGIN_ROOT}/hooks/heartbeat-stop.sh\""
          }
        ]
      }
    ]
  }
}
JSON
  cat > "$plugin_dir/hooks/heartbeat-stop.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exit 0
SH
  chmod +x "$plugin_dir/hooks/heartbeat-stop.sh"
}

json_status() {
  file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r '.status' "$file"
    return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle).get("status", ""))
PY
    return 0
  fi
  fail "jq or python3 is required to inspect preflight JSON"
}

missing_mentions() {
  file="$1"
  needle="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -e --arg needle "$needle" '.missing | any(.[]; contains($needle))' "$file" >/dev/null
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$needle" <<'PY' >/dev/null
import json
import sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
needle = sys.argv[2]
raise SystemExit(0 if any(needle in item for item in data.get("missing", [])) else 1)
PY
    return $?
  fi
  fail "jq or python3 is required to inspect preflight JSON"
}

run_preflight() {
  set +e
  output="$("$PREFLIGHT" "$@" 2>&1)"
  status=$?
  set -e
}

[ -x "$PREFLIGHT" ] || fail "preflight script is not executable"

case_a="$SCRATCH_ROOT/case-a"
case_a_plugin="$case_a/plugin"
case_a_workspace="$case_a/workspace"
mkdir -p "$case_a_workspace"
make_plugin "$case_a_plugin"

run_preflight --plugin-dir "$case_a_plugin" --workspace "$case_a_workspace"
[ "$status" -eq 0 ] || fail "case A exit $status, output: $output"
case_a_state="$case_a_workspace/.claude/goal-state/harness-preflight.json"
[ -f "$case_a_state" ] || fail "case A did not write harness-preflight.json"
[ "$(json_status "$case_a_state")" = "ok" ] || fail "case A status was not ok"

case_b="$SCRATCH_ROOT/case-b"
case_b_plugin="$case_b/plugin"
case_b_workspace="$case_b/workspace"
mkdir -p "$case_b_workspace"
make_plugin "$case_b_plugin"
rm -f "$case_b_plugin/hooks/heartbeat-stop.sh"

start_time="$(date +%s)"
run_preflight --plugin-dir "$case_b_plugin" --workspace "$case_b_workspace" --webhook "http://127.0.0.1:9/deadbeef"
end_time="$(date +%s)"
elapsed=$((end_time - start_time))

[ "$status" -eq 1 ] || fail "case B exit $status, output: $output"
[ "$elapsed" -le 8 ] || fail "case B took ${elapsed}s"
case_b_state="$case_b_workspace/.claude/goal-state/harness-preflight.json"
[ -f "$case_b_state" ] || fail "case B did not write harness-preflight.json"
[ "$(json_status "$case_b_state")" = "failed" ] || fail "case B status was not failed"
missing_mentions "$case_b_state" "heartbeat-stop.sh" || fail "case B missing list did not mention heartbeat-stop.sh"

echo "PASS - preflight"
