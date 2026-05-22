#!/usr/bin/env bash
set -euo pipefail
# AI Heroes / Marco - discord-long-running-harness
#
# UserPromptSubmit hook: surface current operator steering as additional
# context before the next model turn. The PreToolUse steer hook still owns
# interruption semantics; this hook only reduces steer-to-act latency.

cat >/dev/null

WORKDIR="${PWD}"
STEER_FILE="$WORKDIR/STEER.md"
MAX_BYTES=8192

[ -s "$STEER_FILE" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

python3 - "$STEER_FILE" "$MAX_BYTES" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
max_bytes = int(sys.argv[2])
raw = path.read_bytes()
if not raw.strip():
    raise SystemExit(0)

truncated = len(raw) > max_bytes
text = raw[:max_bytes].decode("utf-8", errors="replace")
if truncated:
    text += "\n\n[Truncated by user-prompt-submit hook at 8192 bytes.]"

context = "[STEER.md, surfaced by user-prompt-submit hook]\n\n" + text
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    }
}, separators=(",", ":")))
PY
