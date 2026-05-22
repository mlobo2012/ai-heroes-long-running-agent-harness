#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness

usage() {
  cat <<'USAGE'
Usage: enable-for-launcher.sh --slug <klaus|richard|...> [--dry-run] [--apply]

Default is dry-run. Use --apply to edit the launcher after reviewing the diff.

This helper targets Claude Code 2.1.x, where local plugins are loaded with
--plugin-dir <path>. Do not use the obsolete --plugin <name> form.
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
PLUGIN_DIR="$HOME/.claude/plugins/discord-long-running-harness"
if [ ! -f "$LAUNCHER" ]; then
  echo "enable-for-launcher: missing launcher $LAUNCHER" >&2
  exit 3
fi
if [ ! -d "$PLUGIN_DIR" ]; then
  echo "enable-for-launcher: missing plugin dir $PLUGIN_DIR" >&2
  exit 3
fi

if grep -Eq -- '--plugin-dir[[:space:]]+[^[:space:]]*discord-long-running-harness' "$LAUNCHER" \
  && { ! grep -q -- 'plugin:discord-router@claude-discord-threads' "$LAUNCHER" \
    || grep -Eq -- 'DISCORD_WORKER_PLUGIN_DIRS=[^[:space:]]*discord-long-running-harness' "$LAUNCHER"; }; then
  echo "Launcher already includes --plugin-dir for discord-long-running-harness: $LAUNCHER"
  exit 0
fi

make_proposed() {
  python3 - "$LAUNCHER" "$PLUGIN_DIR" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
plugin_dir = str(Path(sys.argv[2]).expanduser().resolve())
text = path.read_text()
plugin_flag = f"--plugin-dir {plugin_dir}"

def with_router_worker_env(value: str) -> str:
    if "plugin:discord-router@claude-discord-threads" not in value:
        return value
    if "DISCORD_WORKER_PLUGIN_DIRS" in value:
        return value
    updated = value.replace(
        'exec env DISCORD_STATE_DIR="$STATE_DIR" claude',
        f'exec env DISCORD_STATE_DIR="$STATE_DIR" DISCORD_WORKER_PLUGIN_DIRS={plugin_dir} claude',
        1,
    )
    if updated != value:
        return updated
    return re.sub(
        r"(exec env\s+DISCORD_STATE_DIR=(?:(?:\"\\$STATE_DIR\")|(?:\\S+)))\s+claude",
        rf"\1 DISCORD_WORKER_PLUGIN_DIRS={plugin_dir} claude",
        value,
        count=1,
    )

if re.search(r"--plugin-dir\s+\S*discord-long-running-harness", text):
    sys.stdout.write(with_router_worker_env(text))
    raise SystemExit(0)

legacy = "--plugin discord-long-running-harness"
if legacy in text:
    sys.stdout.write(with_router_worker_env(text.replace(legacy, plugin_flag)))
    raise SystemExit(0)

patterns = [
    (r"claude \\\n", f"claude \\\n      {plugin_flag} \\\n", 1),
    (r" claude --", f" claude {plugin_flag} --", 1),
    (r" exec claude ", f" exec claude {plugin_flag} ", 1),
]

for pattern, replacement, count in patterns:
    updated, n = re.subn(pattern, replacement, text, count=count)
    if n:
        sys.stdout.write(with_router_worker_env(updated))
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

timestamp="$(date +%s)"
backup="${LAUNCHER}.bak.${timestamp}.enable-for-launcher"
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
