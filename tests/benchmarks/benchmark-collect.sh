#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
COLLECT="$REPO_ROOT/scripts/benchmark-collect.sh"
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

WORKSPACE="$TMPDIR/workspace"
STATE_DIR="$WORKSPACE/.claude/goal-state"
mkdir -p "$STATE_DIR" "$WORKSPACE/.claude" "$WORKSPACE/evidence/sprint-8"

cat > "$STATE_DIR/heartbeat-stop.log" <<'LOG'
2026-05-22T10:00:00Z block goal-not-met
2026-05-22T10:00:10Z allow subagent-stop
2026-05-22T10:01:10Z block goal-not-met
2026-05-22T10:03:10Z allow subagent-stop
2026-05-22T10:07:10Z block goal-not-met
2026-05-22T10:15:10Z allow subagent-stop
LOG

cat > "$STATE_DIR/codex-spawn-alpha.log" <<'LOG'
2026-05-22T10:00:00Z OpenAI Codex start
alpha work
2026-05-22T10:05:00Z OpenAI Codex done
{"decision":"block","reason":"Cannot modify the results file: no evidence has been Read this session. Open the evidence file with the Read tool first, then retry."}
LOG

cat > "$STATE_DIR/codex-spawn-beta.log" <<'LOG'
2026-05-22T10:06:00Z OpenAI Codex start
beta work
2026-05-22T10:16:00Z OpenAI Codex done
LOG

cat > "$WORKSPACE/.claude/.evidence-reads" <<'LOG'
evidence/sprint-8/alpha-result.txt
evidence/sprint-8/beta-result.txt
LOG

cat > "$WORKSPACE/evidence/sprint-8/alpha-result.txt" <<'LOG'
alpha
LOG
cat > "$WORKSPACE/evidence/sprint-8/beta-result.txt" <<'LOG'
beta
LOG

output="$("$COLLECT" "$WORKSPACE")"

python3 - "$output" <<'PY' || fail "collector output did not match expectations"
import json
import sys

data = json.loads(sys.argv[1])
assert data["codex_sprints"]["count"] == 2, data
assert data["codex_sprints"]["items"][0]["line_count"] == 4, data
assert data["inner_pulse"]["interval_count"] == 5, data
assert data["inner_pulse"]["median_interval_seconds"] == 120, data
assert data["evidence_gate"]["verify_gate_block_count"] == 1, data
assert data["evidence_gate"]["evidence_read_count"] == 2, data
assert data["evidence_gate"]["evidence_artifact_count"] == 2, data
assert abs(data["evidence_gate"]["blocks_per_evidence_read"] - 0.5) < 0.00001, data
PY

echo "PASS benchmark collector"
