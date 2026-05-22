#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Bench rig. Runs one pilot goal against the harness with timing, round
# count, and result-correctness tracking. Output is a JSON score file
# suitable for "harness A vs harness B" comparison.
#
# The CHANGELOG claimed "150% performance pass" without measurements.
# This script is how we replace that rhetoric with numbers.
#
# What it measures:
#   - wall_clock_seconds: time from /goal kick to heartbeat allow.
#   - rounds_to_pass: number of evaluator rounds before PASS.
#   - planner_seconds, evaluator_seconds: per-phase timings if available.
#   - false_pass: 1 if evaluator returned PASS but the smoke test fails.
#   - total_tokens_estimate: sum of stdout sizes as a crude proxy.
#
# What it does NOT do: actually drive Claude. It harnesses the launcher
# and watches the workspace. Spawning Claude is the operator's job; this
# script measures whatever the operator's launcher produced.

usage() {
  cat <<'USAGE'
Usage: bench-harness.sh \
    --pilot <pilot-name> \
    --workspace <abs_path> \
    [--launcher <abs_path>] \
    [--timeout-seconds N] \
    [--smoke-cmd "<shell command>"] \
    [--out <path/to/score.json>] \
    [--no-cleanup]

Pilots available: express-server (others under bench/pilots/ as added).

The benchmark expects either:
  --launcher <path>  - shell script that backgrounds a Claude session
                       against the workspace (will be called once); or
  no --launcher      - operator launches Claude manually and the bench
                       watches the workspace for completion.

--smoke-cmd is a final "did it actually work" check whose exit code
flags false_pass=1 when the evaluator said PASS but the smoke fails.
USAGE
}

PILOT=""
WORKSPACE=""
LAUNCHER=""
TIMEOUT=3600
SMOKE_CMD=""
OUT=""
CLEANUP=1

while [ "$#" -gt 0 ]; do
  case "$1" in
    --pilot) PILOT="${2:-}"; shift 2 ;;
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --launcher) LAUNCHER="${2:-}"; shift 2 ;;
    --timeout-seconds) TIMEOUT="${2:-}"; shift 2 ;;
    --smoke-cmd) SMOKE_CMD="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --no-cleanup) CLEANUP=0; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "bench-harness: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$PILOT" ] || { echo "bench-harness: --pilot required" >&2; exit 2; }
[ -n "$WORKSPACE" ] || { echo "bench-harness: --workspace required" >&2; exit 2; }
case "$WORKSPACE" in /*) ;; *) echo "bench-harness: --workspace must be absolute" >&2; exit 2 ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PILOT_DIR="$PLUGIN_DIR/bench/pilots/$PILOT"
[ -d "$PILOT_DIR" ] || { echo "bench-harness: unknown pilot: $PILOT" >&2; exit 2; }
[ -f "$PILOT_DIR/goal.txt" ] || { echo "bench-harness: pilot missing goal.txt: $PILOT_DIR" >&2; exit 2; }

mkdir -p "$WORKSPACE"
[ -z "$OUT" ] && OUT="$WORKSPACE/.claude/goal-state/bench-score.json"
mkdir -p "$(dirname "$OUT")"

started_at=$(date +%s)
echo "bench-harness: pilot=$PILOT workspace=$WORKSPACE started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# If --launcher was given, fire it now.
if [ -n "$LAUNCHER" ]; then
  [ -x "$LAUNCHER" ] || { echo "bench-harness: launcher not executable: $LAUNCHER" >&2; exit 2; }
  echo "bench-harness: firing launcher $LAUNCHER"
  "$LAUNCHER" &
  LAUNCHER_PID=$!
else
  echo "bench-harness: no --launcher; operator should start Claude against $WORKSPACE now."
  LAUNCHER_PID=""
fi

deadline=$((started_at + TIMEOUT))
completed=0
final_verdict=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -f "$WORKSPACE/QA_REPORT.md" ] && [ -f "$WORKSPACE/test-results.json" ]; then
    verdict=$(sed -n '/^[[:space:]]*$/d; s/[[:space:]]*$//; 1p' "$WORKSPACE/QA_REPORT.md")
    has_pass_fields=0
    has_failures=0
    if grep -q '"passes"[[:space:]]*:' "$WORKSPACE/test-results.json" 2>/dev/null; then has_pass_fields=1; fi
    if grep -q '"passes"[[:space:]]*:[[:space:]]*false' "$WORKSPACE/test-results.json" 2>/dev/null; then has_failures=1; fi
    if [ "$verdict" = "PASS" ] && [ "$has_pass_fields" = "1" ] && [ "$has_failures" = "0" ]; then
      completed=1
      final_verdict="PASS"
      break
    fi
  fi
  sleep 5
done

ended_at=$(date +%s)
wall_clock=$((ended_at - started_at))

rounds_to_pass=0
if [ -f "$WORKSPACE/.claude/goal-state/rounds.json" ]; then
  rounds_to_pass=$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    r = d.get("rounds") if isinstance(d, dict) else None
    print(len(r) if isinstance(r, list) else 0)
except Exception:
    print(0)
' "$WORKSPACE/.claude/goal-state/rounds.json")
fi

false_pass=0
if [ "$final_verdict" = "PASS" ] && [ -n "$SMOKE_CMD" ]; then
  set +e
  bash -c "$SMOKE_CMD" >/dev/null 2>&1
  smoke_status=$?
  set -e
  if [ "$smoke_status" -ne 0 ]; then
    false_pass=1
  fi
fi

token_estimate=0
if [ -d "$WORKSPACE/.claude/goal-state" ]; then
  token_estimate=$(find "$WORKSPACE/.claude/goal-state" -type f \( -name '*.log' -o -name '*-stdout.log' \) -exec wc -c {} + 2>/dev/null | tail -1 | awk '{print $1}')
fi
case "$token_estimate" in ''|*[!0-9]*) token_estimate=0 ;; esac

python3 - "$OUT" "$PILOT" "$WORKSPACE" "$started_at" "$ended_at" "$wall_clock" "$rounds_to_pass" "$completed" "$final_verdict" "$false_pass" "$token_estimate" <<'PY'
import json, sys
out, pilot, ws, started, ended, wall, rounds, completed, verdict, false_pass, tokens = sys.argv[1:12]
data = {
    "pilot": pilot,
    "workspace": ws,
    "started_at_epoch": int(started),
    "ended_at_epoch": int(ended),
    "wall_clock_seconds": int(wall),
    "rounds_to_pass": int(rounds),
    "completed": completed == "1",
    "final_verdict": verdict or "TIMEOUT",
    "false_pass": false_pass == "1",
    "total_io_bytes_estimate": int(tokens),
}
open(out, "w").write(json.dumps(data, indent=2) + "\n")
print(json.dumps(data, indent=2))
PY

if [ -n "$LAUNCHER_PID" ] && [ "$CLEANUP" = "1" ]; then
  kill "$LAUNCHER_PID" 2>/dev/null || true
fi

[ "$completed" = "1" ] || exit 1
[ "$false_pass" = "0" ] || exit 1
exit 0
