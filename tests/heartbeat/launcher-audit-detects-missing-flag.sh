#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
AUDIT="$REPO_ROOT/scripts/audit-discord-launchers.sh"
SCRATCH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/launcher-audit.XXXXXX")"

cleanup() {
  rm -rf "$SCRATCH_ROOT"
}
trap cleanup EXIT

fail() {
  echo "FAIL - $1" >&2
  exit 1
}

cat > "$SCRATCH_ROOT/start-good.sh" <<'GOOD'
#!/usr/bin/env bash
set -euo pipefail
exec claude \
  --plugin-dir /Users/marco/.claude/plugins/discord-long-running-harness \
  "$@"
GOOD

cat > "$SCRATCH_ROOT/start-missing.sh" <<'BAD'
#!/usr/bin/env bash
set -euo pipefail
exec claude "$@"
BAD

chmod +x "$SCRATCH_ROOT/start-good.sh" "$SCRATCH_ROOT/start-missing.sh"

set +e
AUDIT_LAUNCHER_DIR="$SCRATCH_ROOT" "$AUDIT" > "$SCRATCH_ROOT/audit.out" 2>&1
status="$?"
set -e

[ "$status" -ne 0 ] || fail "audit unexpectedly passed with a missing plugin flag"
grep -q '^PASS good plugin-dir$' "$SCRATCH_ROOT/audit.out" || fail "good launcher did not PASS via plugin-dir"
grep -q '^FAIL missing missing-plugin-dir$' "$SCRATCH_ROOT/audit.out" || fail "missing launcher did not FAIL"
grep -q '^audit total=2 pass=1 fail=1$' "$SCRATCH_ROOT/audit.out" || fail "audit summary was unexpected"

cat "$SCRATCH_ROOT/audit.out"
echo "PASS - launcher audit detects a missing --plugin-dir flag"
