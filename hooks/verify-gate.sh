#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
#
# Denies any Write/Edit to the results file unless the agent has opened
# evidence since the gate last fired.
#
# Two modes:
#   1. Per-criterion: if test-results.json uses the `criteria` array with
#      `evidence_paths`, the gate inspects the proposed edit (via tool_input
#      content) and requires every newly-flipped criterion's evidence_paths
#      to have been Read this session.
#   2. Session-level fallback: if criteria/evidence_paths are absent, any
#      evidence read unlocks any write (the legacy upstream behavior).
#
# The matching Bash gate is verify-gate-bash.sh — it stops `sed`/`jq`/python
# rewrites of test-results.json from bypassing this check.

log="${VERIFY_READ_LOG:-./.claude/.evidence-reads}"
results="${RESULTS_FILE:-test-results.json}"

input=$(cat)
target=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)

# Only guard the results file (anchor on path separator so e.g. vitest-results.json doesn't match)
case "$target" in "$results"|*/"$results") ;; *) exit 0 ;; esac

# Per-criterion mode if results file already uses criteria array with evidence_paths
PER_CRITERION=0
if [ -f "$results" ] && python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1]))
    items=d.get("criteria") if isinstance(d,dict) else None
    if isinstance(items,list) and any(isinstance(c,dict) and c.get("evidence_paths") for c in items):
        sys.exit(0)
except Exception:
    pass
sys.exit(1)
' "$results" 2>/dev/null; then
  PER_CRITERION=1
fi

if [ "$PER_CRITERION" = "1" ]; then
  # Per-criterion enforcement: pull the proposed new content out of tool_input.
  # We pass $input via env var because heredocs replace stdin so a piped
  # `printf ... | python3 - <<'PY'` would leave sys.stdin empty.
  proposed=$(INPUT_JSON="$input" python3 - <<'PY' 2>/dev/null
import json, os
raw = os.environ.get("INPUT_JSON", "")
try:
    d = json.loads(raw)
    ti = d.get("tool_input", {}) if isinstance(d, dict) else {}
    # Write tool: full content. Edit tool: best-effort reconstruct using new_string.
    if "content" in ti:
        print(ti["content"])
    elif "new_string" in ti:
        print(ti["new_string"])
    else:
        print("")
except Exception:
    print("")
PY
)
  RESULTS_FILE="$results" LOG="$log" PROPOSED="$proposed" python3 - <<'PY'
import json, os, sys
results = os.environ["RESULTS_FILE"]
log_path = os.environ["LOG"]
proposed = os.environ.get("PROPOSED", "")

def passes_set(text):
    try:
        d = json.loads(text)
    except Exception:
        return {}
    out = {}
    if isinstance(d, dict) and isinstance(d.get("criteria"), list):
        for c in d["criteria"]:
            if isinstance(c, dict) and "id" in c:
                out[c["id"]] = (c.get("passes") is True, c.get("evidence_paths") or [])
    return out

try:
    old = open(results).read()
except FileNotFoundError:
    old = ""
old_state = passes_set(old)
new_state = passes_set(proposed) if proposed else {}

# If we cannot parse the proposed payload (e.g. Edit), fall back to session-level
if not new_state:
    if not os.path.exists(log_path) or os.path.getsize(log_path) == 0:
        print('{"decision":"block","reason":"Cannot modify the results file: no evidence has been Read this session. Open the evidence file with the Read tool first, then retry."}')
    else:
        open(log_path, "w").close()
    sys.exit(0)

# Identify criteria flipping from false (or absent) to true
newly_passing = []
for cid, (passes_now, ev_paths) in new_state.items():
    was_passing = old_state.get(cid, (False, []))[0]
    if passes_now and not was_passing:
        newly_passing.append((cid, ev_paths))

if not newly_passing:
    # No new passes claimed; allow the write
    sys.exit(0)

# Read the evidence-reads log
try:
    seen = {line.strip() for line in open(log_path) if line.strip()}
except FileNotFoundError:
    seen = set()

missing = []
for cid, ev_paths in newly_passing:
    if not ev_paths:
        missing.append((cid, "no evidence_paths declared"))
        continue
    if not any(p in seen or os.path.abspath(p) in seen for p in ev_paths):
        missing.append((cid, "none of " + ", ".join(ev_paths) + " were Read this session"))

if missing:
    detail = "; ".join(f"{c}: {r}" for c, r in missing)
    print('{"decision":"block","reason":"Cannot flip criteria to pass without reading their evidence_paths first. ' + detail + '"}')
    sys.exit(0)

# All newly-passing criteria have at least one evidence file that was Read.
# Consume the log so the next round needs fresh proof.
open(log_path, "w").close()
PY
  exit 0
fi

# Session-level fallback (upstream-compatible)
if [ ! -s "$log" ]; then
  cat <<'JSON'
{"decision":"block","reason":"Cannot modify the results file: no screenshot or console-log evidence has been Read this session. Open the evidence file with the Read tool first, then retry."}
JSON
  exit 0
fi
# consume the evidence so the next change needs fresh proof
: > "$log"
