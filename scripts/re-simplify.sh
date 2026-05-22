#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Re-simplify on model upgrade.
#
# The March 2026 article's closing principle: "Every component encodes
# assumptions about model limitations. These assumptions warrant
# continuous stress-testing because they become stale as capabilities
# improve." rounds.json stamps the model used per round, but it only
# tells you the *what*, not the *whether*. This script lets the
# operator disable one harness piece, re-run the bench rig, and decide
# if the piece is still load-bearing.
#
# Workflow:
#
#   1. Pick a piece to challenge:
#        --target contract-reviewer   # the planner -> reviewer handshake
#        --target sprint-decomposition # forces longer coherent builds
#        --target evaluator           # disable QA gate entirely (RISKY)
#        --target per-criterion-gate  # fall back to session-level gate
#        --target bash-gate           # disable verify-gate-bash
#        --target session-start       # disable SessionStart re-seed
#        --target pre-compact         # disable PreCompact snapshot
#        --target playwright-trace    # accept QA PASS without trace
#
#   2. The script writes a one-line override to
#      .claude/goal-state/re-simplify-overrides.json. The relevant hook /
#      script reads it and behaves as if that piece were absent.
#
#   3. Run the bench rig with the override in place. Compare against
#      the baseline (no overrides). If the score regresses by less than
#      a configurable threshold, the piece can be removed.
#
#   4. Restore with `--restore` (clears all overrides) or
#      `--restore --target X` (clears one).
#
# This script does not itself decide what to remove; it makes the
# experiment reproducible.

usage() {
  cat <<'USAGE'
Usage:
  re-simplify.sh --target <name> [--workspace <abs_path>] [--reason "<text>"]
  re-simplify.sh --restore [--target <name>] [--workspace <abs_path>]
  re-simplify.sh --list [--workspace <abs_path>]
  re-simplify.sh --status [--workspace <abs_path>]
  re-simplify.sh --dry-run --target <name> [--workspace <abs_path>]

Targets:
  contract-reviewer    Skip the planner -> contract-reviewer handshake.
  sprint-decomposition Force longer coherent builds (no sprint splits).
  evaluator            Disable the evaluator gate (heartbeat does not
                       require QA_REPORT.md PASS). RISKY.
  per-criterion-gate   Fall back to session-level evidence gate.
  bash-gate            Disable verify-gate-bash (Bash bypass possible).
  session-start        Skip SessionStart re-seed.
  pre-compact          Skip PreCompact snapshot.
  playwright-trace     Accept QA PASS without playwright-mcp trace.
USAGE
}

WORKSPACE="$PWD"
TARGET=""
REASON=""
ACTION="set"  # set | restore | list | status

while [ "$#" -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --restore) ACTION="restore"; shift ;;
    --list) ACTION="list"; shift ;;
    --status) ACTION="status"; shift ;;
    --dry-run) ACTION="dry-run"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "re-simplify: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$WORKSPACE" in /*) ;; *) echo "re-simplify: --workspace must be absolute" >&2; exit 2 ;; esac
[ -d "$WORKSPACE" ] || { echo "re-simplify: workspace not found: $WORKSPACE" >&2; exit 2; }

VALID_TARGETS="contract-reviewer sprint-decomposition evaluator per-criterion-gate bash-gate session-start pre-compact playwright-trace"

validate_target() {
  case " $VALID_TARGETS " in
    *" $1 "*) return 0 ;;
    *) echo "re-simplify: unknown target: $1" >&2
       echo "re-simplify: valid targets: $VALID_TARGETS" >&2
       return 1 ;;
  esac
}

STATE_DIR="$WORKSPACE/.claude/goal-state"
mkdir -p "$STATE_DIR"
OVERRIDE_FILE="$STATE_DIR/re-simplify-overrides.json"

case "$ACTION" in
  list)
    echo "Available re-simplify targets:"
    for t in $VALID_TARGETS; do echo "  - $t"; done
    ;;
  status)
    if [ ! -s "$OVERRIDE_FILE" ]; then
      echo "re-simplify: no overrides set in $OVERRIDE_FILE"
      exit 0
    fi
    echo "Current overrides:"
    python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
for k, v in d.items():
    print(f"  - {k}: {v}")
' "$OVERRIDE_FILE"
    ;;
  restore)
    if [ -z "$TARGET" ]; then
      # Restore all.
      rm -f "$OVERRIDE_FILE"
      echo "re-simplify: cleared all overrides"
      exit 0
    fi
    validate_target "$TARGET" || exit 2
    TARGET="$TARGET" OVR="$OVERRIDE_FILE" python3 - <<'PY'
import json, os, sys
from pathlib import Path
ovr = Path(os.environ["OVR"])
try:
    d = json.loads(ovr.read_text())
except Exception:
    d = {}
d.pop(os.environ["TARGET"], None)
if d:
    ovr.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
else:
    ovr.unlink(missing_ok=True)
PY
    echo "re-simplify: cleared override for $TARGET"
    ;;
  set|dry-run)
    [ -n "$TARGET" ] || { usage >&2; exit 2; }
    validate_target "$TARGET" || exit 2
    if [ "$ACTION" = "dry-run" ]; then
      echo "re-simplify: would set override target=$TARGET reason='${REASON:-(none)}' in $OVERRIDE_FILE"
      exit 0
    fi
    TARGET="$TARGET" REASON="${REASON:-experiment}" OVR="$OVERRIDE_FILE" python3 - <<'PY'
import json, os, time
from pathlib import Path
ovr = Path(os.environ["OVR"])
try:
    d = json.loads(ovr.read_text())
except Exception:
    d = {}
d[os.environ["TARGET"]] = {
    "set_at": int(time.time()),
    "reason": os.environ.get("REASON") or "experiment",
}
ovr.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
    echo "re-simplify: set override target=$TARGET reason='${REASON:-experiment}'"
    echo "re-simplify: relevant hook/script must check $OVERRIDE_FILE on startup."
    echo "re-simplify: run a bench round; compare to baseline; restore with --restore --target $TARGET"
    ;;
esac
