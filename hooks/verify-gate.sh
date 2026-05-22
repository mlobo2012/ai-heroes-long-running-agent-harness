#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
#
# Denies any Write/Edit to the results file unless the agent has opened
# evidence since the gate last fired. Code-heavy row flips also need a
# Codex routing signal. Legacy row shapes get per-row evidence binding;
# criteria/evidence_paths shapes keep the stricter v0.5.x per-criterion gate.

log="${VERIFY_READ_LOG:-./.claude/.evidence-reads}"
results="${RESULTS_FILE:-test-results.json}"

input=$(cat)
target=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)

case "$target" in "$results"|*/"$results") ;; *) exit 0 ;; esac
mkdir -p "$(dirname "$log")" 2>/dev/null || true

PER_CRITERION_OVERRIDE=0
override_file="./.claude/goal-state/re-simplify-overrides.json"
if [ -f "$override_file" ] && command -v python3 >/dev/null 2>&1; then
  if python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if isinstance(d, dict) and "per-criterion-gate" in d else 1)
except Exception:
    sys.exit(1)
' "$override_file" 2>/dev/null; then
    PER_CRITERION_OVERRIDE=1
  fi
fi

PER_CRITERION=0
if [ "$PER_CRITERION_OVERRIDE" != "1" ] && [ -f "$results" ] && python3 -c 'import json,sys
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

codex_routing_decision=$(
  VERIFY_GATE_RESULTS="$results" CODEX_SPAWN_TTL_SECONDS="${CODEX_SPAWN_TTL_SECONDS:-7200}" python3 - "$input" <<'PY'
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CODE_HEAVY_CATEGORIES = {
    "hook-correctness",
    "evidence-gate",
    "execution-model",
    "loop-design",
    "session-hygiene",
    "operator-controls",
    "registration",
    "outer-pulse",
    "performance",
    "safety",
    "bootstrap",
    "robustness",
    "final-gate",
    "discord-surface",
    "documentation",
    "observability",
}
CODE_DIRS = ("hooks/", "scripts/", "bin/", "agents/")
RULE = "code-heavy sprint work goes through codex-executor"


def warn(message):
    print(f"verify-gate: codex routing check warning: {message}", file=sys.stderr)


def parse_json(text):
    try:
        return json.loads(text)
    except Exception:
        return None


def extract_items(data):
    if isinstance(data, dict) and isinstance(data.get("items"), list):
        return [item for item in data["items"] if isinstance(item, dict)]
    if isinstance(data, dict) and isinstance(data.get("criteria"), list):
        return [item for item in data["criteria"] if isinstance(item, dict)]
    if isinstance(data, dict) and "passes" in data:
        return [data]
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


try:
    hook_input = json.loads(sys.argv[1])
except Exception as exc:
    warn(f"could not parse hook input; skipping codex routing check: {exc}")
    raise SystemExit(0)

tool_input = hook_input.get("tool_input", {})
results_path = Path(os.environ["VERIFY_GATE_RESULTS"])

try:
    old_text = results_path.read_text()
except Exception:
    old_text = ""

old_items = extract_items(parse_json(old_text))
old_by_id = {str(item.get("id")): item for item in old_items if item.get("id") is not None}

candidates = []
content = tool_input.get("content")
if isinstance(content, str):
    candidates.append(content)

new_string = tool_input.get("new_string")
old_string = tool_input.get("old_string")
if isinstance(new_string, str):
    if isinstance(old_string, str) and old_string in old_text:
        candidates.append(old_text.replace(old_string, new_string, 1))
    candidates.append(new_string)

new_items = []
for candidate in candidates:
    items = extract_items(parse_json(candidate))
    if items:
        new_items = items
        break

code_heavy_flips = []
for index, new_item in enumerate(new_items):
    old_item = None
    row_id = new_item.get("id")
    if row_id is not None:
        old_item = old_by_id.get(str(row_id))
    if old_item is None and index < len(old_items):
        old_item = old_items[index]
    if not isinstance(old_item, dict):
        continue
    category = str(new_item.get("category", ""))
    if old_item.get("passes") is False and new_item.get("passes") is True and category in CODE_HEAVY_CATEGORIES:
        code_heavy_flips.append(new_item)

if not code_heavy_flips:
    raise SystemExit(0)


def run_git(args):
    try:
        return subprocess.run(["git", *args], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    except FileNotFoundError:
        warn("git unavailable; codex routing enforcement skipped")
        raise SystemExit(0)


inside_repo = run_git(["rev-parse", "--is-inside-work-tree"])
if inside_repo.returncode != 0 or inside_repo.stdout.strip() != "true":
    warn("workspace is not a git repo; codex routing enforcement skipped")
    raise SystemExit(0)

diff = run_git(["diff", "--name-only", "HEAD", "--", *CODE_DIRS])
if diff.returncode != 0:
    warn("could not diff against the last commit; codex routing enforcement skipped")
    raise SystemExit(0)

untracked = run_git(["ls-files", "--others", "--exclude-standard", "--", *CODE_DIRS])
if untracked.returncode != 0:
    warn("could not list untracked code files; continuing with tracked diff only")
    untracked_paths = []
else:
    untracked_paths = [line.strip() for line in untracked.stdout.splitlines() if line.strip()]

changed_paths = [line.strip() for line in diff.stdout.splitlines() if line.strip()]
changed_paths.extend(untracked_paths)
if not any(path.startswith(CODE_DIRS) for path in changed_paths):
    raise SystemExit(0)

try:
    ttl_seconds = int(os.environ.get("CODEX_SPAWN_TTL_SECONDS", "7200"))
except ValueError:
    ttl_seconds = 7200

now = time.time()
for spawn_log in Path(".claude/goal-state").glob("codex-spawn-*.log"):
    try:
        if now - spawn_log.stat().st_mtime <= ttl_seconds:
            raise SystemExit(0)
    except OSError:
        continue

latest_commit = run_git(["log", "-1", "--format=%B"])
if latest_commit.returncode == 0:
    if re.search(r"(?im)^Co-Authored-By:\s*codex\b", latest_commit.stdout):
        raise SystemExit(0)
else:
    warn("could not read the latest commit message; codex trailer unavailable")

labels = [str(item.get("id") or item.get("sprint") or "<unknown>") for item in code_heavy_flips]
reason = (
    "Codex routing detection failed for code-heavy sprint row(s) "
    + ", ".join(labels)
    + f": missing fresh .claude/goal-state/codex-spawn-*.log and missing Co-Authored-By: codex trailer; rule: \"{RULE}\"."
)
print(json.dumps({"decision": "block", "reason": reason}, separators=(",", ":")))
raise SystemExit(10)
PY
)
codex_routing_status=$?
if [ "$codex_routing_status" -eq 10 ]; then
  printf '%s\n' "$codex_routing_decision"
  exit 0
fi
if [ "$codex_routing_status" -ne 0 ]; then
  echo "verify-gate: codex routing check warning: unexpected status $codex_routing_status; continuing" >&2
fi

binding_decision=$(
  VERIFY_GATE_RESULTS="$results" VERIFY_GATE_LOG="$log" python3 - "$input" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

try:
    hook_input = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(0)

tool_input = hook_input.get("tool_input", {})
results_path = Path(os.environ["VERIFY_GATE_RESULTS"])
log_path = Path(os.environ["VERIFY_GATE_LOG"])


def parse_json(text):
    try:
        return json.loads(text)
    except Exception:
        return None


def extract_items(data):
    if isinstance(data, dict) and isinstance(data.get("items"), list):
        return [item for item in data["items"] if isinstance(item, dict)]
    if isinstance(data, dict) and isinstance(data.get("criteria"), list):
        return [item for item in data["criteria"] if isinstance(item, dict)]
    if isinstance(data, dict) and "passes" in data:
        return [data]
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


try:
    old_text = results_path.read_text()
except Exception:
    old_text = ""

old_items = extract_items(parse_json(old_text))
old_by_id = {str(item.get("id")): item for item in old_items if item.get("id") is not None}

candidates = []
content = tool_input.get("content")
if isinstance(content, str):
    candidates.append(content)

new_string = tool_input.get("new_string")
old_string = tool_input.get("old_string")
if isinstance(new_string, str):
    if isinstance(old_string, str) and old_string in old_text:
        candidates.append(old_text.replace(old_string, new_string, 1))
    candidates.append(new_string)

new_items = []
for candidate in candidates:
    items = extract_items(parse_json(candidate))
    if items:
        new_items = items
        break

flipped = []
for index, new_item in enumerate(new_items):
    if "evidence_paths" in new_item:
        continue
    old_item = None
    row_id = new_item.get("id")
    if row_id is not None:
        old_item = old_by_id.get(str(row_id))
    if old_item is None and index < len(old_items):
        old_item = old_items[index]
    if not isinstance(old_item, dict):
        continue
    if old_item.get("passes") is False and new_item.get("passes") is True:
        flipped.append(new_item)


def row_tokens(item):
    tokens = []
    row_id = item.get("id")
    if row_id is not None:
        row_id = str(row_id).strip()
        if row_id:
            tokens.append(row_id)
            tokens.append(row_id.replace("_", "-"))
            match = re.match(r"^S(\d+)(?:_|$)", row_id, re.IGNORECASE)
            if match:
                tokens.append(f"sprint-{match.group(1)}")
    sprint = item.get("sprint")
    if sprint is not None and str(sprint).strip():
        tokens.append(f"sprint-{str(sprint).strip().lower()}")
    seen = set()
    normalized = []
    for token in tokens:
        token = token.lower()
        if token and token not in seen:
            seen.add(token)
            normalized.append(token)
    return normalized


try:
    evidence_paths = [line.strip() for line in log_path.read_text().splitlines() if line.strip()]
except Exception:
    evidence_paths = []


def path_matches(tokens, evidence_path):
    parts = [part.lower() for part in re.split(r"[\\/]+", evidence_path) if part]
    return bool(parts) and any(token in part for token in tokens for part in parts)


unbound = []
for item in flipped:
    tokens = row_tokens(item)
    if not tokens or not any(path_matches(tokens, path) for path in evidence_paths):
        unbound.append(str(item.get("id", "<unknown>")))

if unbound:
    print(json.dumps({
        "decision": "block",
        "reason": "Cannot mark result row(s) passing without row-matched evidence Read this session: " + ", ".join(unbound),
    }, separators=(",", ":")))
    raise SystemExit(10)
PY
)
binding_status=$?
if [ "$binding_status" -eq 10 ]; then
  printf '%s\n' "$binding_decision"
  : > "$log"
  exit 0
fi
if [ "$binding_status" -ne 0 ]; then
  echo "verify-gate: row-binding check warning: unexpected status $binding_status; continuing" >&2
fi

if [ "$PER_CRITERION" = "1" ]; then
  proposed=$(INPUT_JSON="$input" python3 - <<'PY' 2>/dev/null
import json
import os
raw = os.environ.get("INPUT_JSON", "")
try:
    d = json.loads(raw)
    ti = d.get("tool_input", {}) if isinstance(d, dict) else {}
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
import json
import os
import sys

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

if not new_state:
    if not os.path.exists(log_path) or os.path.getsize(log_path) == 0:
        print('{"decision":"block","reason":"Cannot modify the results file: no evidence has been Read this session. Open the evidence file with the Read tool first, then retry."}')
    else:
        open(log_path, "w").close()
    sys.exit(0)

newly_passing = []
for cid, (passes_now, ev_paths) in new_state.items():
    was_passing = old_state.get(cid, (False, []))[0]
    if passes_now and not was_passing:
        newly_passing.append((cid, ev_paths))

if not newly_passing:
    sys.exit(0)

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

open(log_path, "w").close()
PY
  exit 0
fi

if [ ! -s "$log" ]; then
  cat <<'JSON'
{"decision":"block","reason":"Cannot modify the results file: no screenshot or console-log evidence has been Read this session. Open the evidence file with the Read tool first, then retry."}
JSON
  exit 0
fi

: > "$log"
