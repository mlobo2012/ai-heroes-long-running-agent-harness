#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

usage() {
  cat <<'USAGE'
Usage: enable-for-launcher.sh --slug <klaus|richard|...> [--dry-run] [--apply]

Default is dry-run. Use --apply to edit the launcher after reviewing the diff.
USAGE
}

SLUG=""
APPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --slug)
      SLUG="${2:-}"
      shift 2
      ;;
    --dry-run)
      APPLY=0
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 2
      ;;
    *)
      echo "enable-for-launcher: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$SLUG" ]; then
  usage >&2
  exit 2
fi

LAUNCHER="$HOME/.claude/channels/discord/start-${SLUG}.sh"
if [ ! -f "$LAUNCHER" ]; then
  echo "enable-for-launcher: missing launcher $LAUNCHER" >&2
  exit 3
fi

if grep -q -- '--plugin[[:space:]]\+discord-long-running-harness' "$LAUNCHER"; then
  echo "Launcher already includes --plugin discord-long-running-harness: $LAUNCHER"
  exit 0
fi

make_proposed() {
  python3 - "$LAUNCHER" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
plugin = "--plugin discord-long-running-harness"

if plugin in text:
    sys.stdout.write(text)
    raise SystemExit(0)

patterns = [
    (r"claude \\\n", "claude \\\n      --plugin discord-long-running-harness \\\n", 1),
    (r" claude --", " claude --plugin discord-long-running-harness --", 1),
    (r" exec claude ", " exec claude --plugin discord-long-running-harness ", 1),
]

for pattern, replacement, count in patterns:
    updated, n = re.subn(pattern, replacement, text, count=count)
    if n:
        sys.stdout.write(updated)
        raise SystemExit(0)

raise SystemExit("could not find claude invocation to patch")
PY
}

PROPOSED_FILE="${TMPDIR:-/tmp}/discord-harness-${SLUG}-proposed.$$"
trap 'rm -f "$PROPOSED_FILE"' EXIT
if ! make_proposed > "$PROPOSED_FILE"; then
  echo "enable-for-launcher: could not render proposed launcher" >&2
  exit 4
fi

echo "Proposed change for $LAUNCHER:"
diff -u "$LAUNCHER" "$PROPOSED_FILE" || true

if [ "$APPLY" -ne 1 ]; then
  echo "Dry-run only. Re-run with --apply to edit after Marco approves rollout."
  exit 0
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup="${LAUNCHER}.bak.pre-harness.${timestamp}"
cp -p "$LAUNCHER" "$backup"
tmp="${LAUNCHER}.tmp.pre-harness.${timestamp}"
cp "$PROPOSED_FILE" "$tmp"
mv "$tmp" "$LAUNCHER"
chmod +x "$LAUNCHER"
echo "Updated $LAUNCHER"
echo "Backup: $backup"
echo "Re-run the launcher to pick up the plugin."

trap - EXIT
exit 0
