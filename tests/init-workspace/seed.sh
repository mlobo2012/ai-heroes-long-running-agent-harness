#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
INIT="$REPO_ROOT/scripts/init-workspace.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/init-workspace.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

WORKSPACE="$SCRATCH_ROOT/workspace"
mkdir -p "$WORKSPACE"
git -C "$WORKSPACE" init -q
git -C "$WORKSPACE" config user.email "test@example.invalid"
git -C "$WORKSPACE" config user.name "Harness Test"

"$INIT" "$WORKSPACE" >/dev/null

[ -f "$WORKSPACE/PROGRESS.md" ] || fail "PROGRESS.md missing"
[ -f "$WORKSPACE/test-results.json" ] || fail "test-results.json missing"
[ -f "$WORKSPACE/STEER.md" ] || fail "STEER.md missing"
[ -f "$WORKSPACE/.claude/goal-state/block-count" ] || fail "block-count missing"
[ "$(sed -n '1p' "$WORKSPACE/.claude/goal-state/block-count")" = "0" ] || fail "block-count is not 0"

grep -q '^## Done$' "$WORKSPACE/PROGRESS.md" || fail "PROGRESS.md missing Done section"
grep -q '^## In progress$' "$WORKSPACE/PROGRESS.md" || fail "PROGRESS.md missing In progress section"
grep -q '^## Next$' "$WORKSPACE/PROGRESS.md" || fail "PROGRESS.md missing Next section"
grep -q '^## Notes$' "$WORKSPACE/PROGRESS.md" || fail "PROGRESS.md missing Notes section"

python3 - "$WORKSPACE/test-results.json" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert isinstance(data.get("goal"), str) and data["goal"], data
assert data.get("items") == [], data
PY

subject="$(git -C "$WORKSPACE" log -1 --format=%s)"
[ "$subject" = "init: seed workspace for long-running goal" ] || fail "unexpected commit subject: $subject"
[ "$(git -C "$WORKSPACE" rev-list --count HEAD)" = "1" ] || fail "expected exactly one commit"
[ -z "$(git -C "$WORKSPACE" status --porcelain --untracked-files=all)" ] || fail "workspace dirty after initial seed"

progress_before="$(cksum "$WORKSPACE/PROGRESS.md")"
results_before="$(cksum "$WORKSPACE/test-results.json")"
steer_before="$(cksum "$WORKSPACE/STEER.md")"
block_before="$(cksum "$WORKSPACE/.claude/goal-state/block-count")"

"$INIT" "$WORKSPACE" >/dev/null

[ "$(cksum "$WORKSPACE/PROGRESS.md")" = "$progress_before" ] || fail "PROGRESS.md changed on rerun"
[ "$(cksum "$WORKSPACE/test-results.json")" = "$results_before" ] || fail "test-results.json changed on rerun"
[ "$(cksum "$WORKSPACE/STEER.md")" = "$steer_before" ] || fail "STEER.md changed on rerun"
[ "$(cksum "$WORKSPACE/.claude/goal-state/block-count")" = "$block_before" ] || fail "block-count changed on rerun"
[ "$(git -C "$WORKSPACE" rev-list --count HEAD)" = "1" ] || fail "rerun created another commit"

echo "PASS - init-workspace seeds files, commits once, and is idempotent"
