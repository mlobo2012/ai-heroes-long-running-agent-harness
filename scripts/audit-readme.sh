#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
README="$ROOT/README.md"

failures=0

fail() {
  echo "FAIL - $1" >&2
  failures=$((failures + 1))
}

grep -q 'Capabilities and where they are tested' "$README" \
  || fail "README missing capability-to-test map"

grep -q 'sync-to-install.sh' "$README" \
  || fail "README missing install sync instructions"

if grep -Eiq 'Anthropic[^[:cntrl:]]*platform cap|platform cap' "$README"; then
  fail "README still contains an unsourced platform-cap claim"
fi

python3 - "$README" "$ROOT" <<'PY'
import re
import sys
from pathlib import Path

readme = Path(sys.argv[1])
root = Path(sys.argv[2])
text = readme.read_text(encoding="utf-8")
missing = []
for target in re.findall(r"\[[^\]]+\]\((\./[^)#]+)", text):
    path = root / target[2:]
    if not path.exists():
        missing.append(target)
if missing:
    for target in missing:
        print(f"missing README link target: {target}", file=sys.stderr)
    raise SystemExit(1)
PY

exit "$failures"
