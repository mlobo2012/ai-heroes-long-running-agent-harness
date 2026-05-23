#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# Accepted plugin-loading directives:
#  - claude receives --plugin-dir <path-containing-discord-long-running-harness>
#  - the launcher references a settings.json path from discord-long-running-harness
#  - the launcher exports CLAUDE_PLUGIN_DIR, CLAUDE_PLUGIN_DIRS, or
#    CLAUDE_PLUGIN_ROOT with a discord-long-running-harness path before
#    invoking claude.
#
# AUDIT_LAUNCHER_DIR can point tests at a fixture directory. By default the
# audit scans ~/.claude/channels/discord/start-*.sh and mutates nothing.

LAUNCHER_DIR="${AUDIT_LAUNCHER_DIR:-$HOME/.claude/channels/discord}"
PLUGIN_NAME="${AUDIT_PLUGIN_NAME:-discord-long-running-harness}"

detect_method_python() {
  python3 - "$1" "$PLUGIN_NAME" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
plugin_name = re.escape(sys.argv[2])
text = path.read_text(encoding="utf-8", errors="replace")

if not re.search(r"\bclaude\b", text):
    print("no-claude-invocation")
    raise SystemExit(0)

patterns = [
    ("plugin-dir", rf"--plugin-dir(?:=|\s+)['\"]?[^\s'\"\\]*{plugin_name}[^\s'\"\\]*['\"]?"),
    ("settings-json", rf"{plugin_name}[^\n]*settings\.json|settings\.json[^\n]*{plugin_name}"),
    ("exported-plugin-env", rf"(?:export\s+)?(?:CLAUDE_PLUGIN_DIRS?|CLAUDE_PLUGIN_ROOT)=['\"]?[^\s'\"\\]*{plugin_name}[^\s'\"\\]*['\"]?"),
]

for method, pattern in patterns:
    if re.search(pattern, text, re.MULTILINE):
        print(method)
        raise SystemExit(0)

raise SystemExit(1)
PY
}

detect_method_grep() {
  file="$1"
  if ! grep -Eq '\bclaude\b' "$file"; then
    printf 'no-claude-invocation\n'
    return 0
  fi
  if grep -Eq -- "--plugin-dir([=[:space:]]+)[^[:space:]]*${PLUGIN_NAME}" "$file"; then
    printf 'plugin-dir\n'
    return 0
  fi
  if grep -Eq -- "${PLUGIN_NAME}.*settings\\.json|settings\\.json.*${PLUGIN_NAME}" "$file"; then
    printf 'settings-json\n'
    return 0
  fi
  if grep -Eq -- "(export[[:space:]]+)?(CLAUDE_PLUGIN_DIRS?|CLAUDE_PLUGIN_ROOT)=[^[:space:]]*${PLUGIN_NAME}" "$file"; then
    printf 'exported-plugin-env\n'
    return 0
  fi
  return 1
}

detect_method() {
  file="$1"
  if command -v python3 >/dev/null 2>&1; then
    detect_method_python "$file"
    return $?
  fi
  detect_method_grep "$file"
}

total=0
passed=0
failed=0

shopt -s nullglob
for launcher in "$LAUNCHER_DIR"/start-*.sh; do
  [ -f "$launcher" ] || continue
  [ -x "$launcher" ] || continue

  total=$((total + 1))
  name="$(basename "$launcher")"
  slug="${name#start-}"
  slug="${slug%.sh}"

  set +e
  method="$(detect_method "$launcher" 2>/dev/null)"
  status="$?"
  set -e

  if [ "$status" -eq 0 ] && [ -n "$method" ]; then
    passed=$((passed + 1))
    printf 'PASS %s %s\n' "$slug" "$method"
  else
    failed=$((failed + 1))
    printf 'FAIL %s missing-plugin-dir\n' "$slug"
  fi
done

printf 'audit total=%s pass=%s fail=%s\n' "$total" "$passed" "$failed"

[ "$failed" -eq 0 ]
