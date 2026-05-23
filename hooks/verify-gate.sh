#!/usr/bin/env bash
# Copyright 2026 Anthropic PBC
# SPDX-License-Identifier: Apache-2.0
#
# Denies false->true result flips unless the agent has opened fresh
# row-matched evidence. Edits that flip no rows are allowed without evidence.
# Batch flips bind per row and selectively consume only the evidence lines used.
#
# This is a teaching example, not a security boundary. Known gaps a real
# enforcement layer would close: this only hooks Write/Edit (Bash sed/jq can
# rewrite the file unchecked). Tighten in your project as needed.
log="${VERIFY_READ_LOG:-./.claude/.evidence-reads}"
results="${RESULTS_FILE:-test-results.json}"

input=$(cat)
target=$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("file_path",""))' 2>/dev/null)

# Only guard the results file (anchor on path separator so e.g. vitest-results.json doesn't match)
case "$target" in "$results"|*/"$results") ;; *) exit 0 ;; esac

flip_count=$(
  VERIFY_GATE_RESULTS="$results" python3 - "$input" <<'PY'
import json
import os
import sys
from pathlib import Path


def parse_json(text):
    try:
        return json.loads(text)
    except Exception:
        return None


def extract_items(data):
    if isinstance(data, dict) and isinstance(data.get("items"), list):
        return [item for item in data["items"] if isinstance(item, dict)]
    if isinstance(data, dict) and "passes" in data:
        return [data]
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


try:
    hook_input = json.loads(sys.argv[1])
except Exception:
    print("0")
    raise SystemExit(0)

tool_input = hook_input.get("tool_input", {})
results_path = Path(os.environ["VERIFY_GATE_RESULTS"])

try:
    old_text = results_path.read_text()
except Exception:
    old_text = ""

old_data = parse_json(old_text)
old_items = extract_items(old_data)
old_by_id = {
    str(item.get("id")): item
    for item in old_items
    if item.get("id") is not None
}

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
    parsed = parse_json(candidate)
    items = extract_items(parsed)
    if items:
        new_items = items
        break

flipped = []
for index, new_item in enumerate(new_items):
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

print(len(flipped))
PY
)

if [ "$flip_count" -eq 0 ]; then
  exit 0
fi

if [ ! -s "$log" ]; then
  cat <<'JSON'
{"decision":"block","reason":"Cannot modify the results file: no evidence has been Read this session. Open the evidence file with the Read tool first, then retry."}
JSON
  exit 0
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

old_data = parse_json(old_text)
old_items = extract_items(old_data)
old_by_id = {
    str(item.get("id")): item
    for item in old_items
    if item.get("id") is not None
}

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
    parsed = parse_json(candidate)
    items = extract_items(parsed)
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
    if (
        old_item.get("passes") is False
        and new_item.get("passes") is True
        and category in CODE_HEAVY_CATEGORIES
    ):
        code_heavy_flips.append(new_item)

if not code_heavy_flips:
    raise SystemExit(0)


def run_git(args):
    try:
        return subprocess.run(
            ["git", *args],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
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
goal_state = Path(".claude/goal-state")
for spawn_log in goal_state.glob("codex-spawn-*.log"):
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

labels = []
for item in code_heavy_flips:
    label = item.get("id") or item.get("sprint") or "<unknown>"
    labels.append(str(label))

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

hook_input = json.loads(sys.argv[1])
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
    if isinstance(data, dict) and "passes" in data:
        return [data]
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    return []


try:
    old_text = results_path.read_text()
except Exception:
    old_text = ""

old_data = parse_json(old_text)
old_items = extract_items(old_data)
old_by_id = {
    str(item.get("id")): item
    for item in old_items
    if item.get("id") is not None
}

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
    parsed = parse_json(candidate)
    items = extract_items(parsed)
    if items:
        new_items = items
        break

flipped = []
for index, new_item in enumerate(new_items):
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

    def add_token(value):
        text = str(value).strip()
        if not text:
            return
        variants = {
            text,
            text.replace("_", "-"),
            text.replace("-", "_"),
        }
        slug = re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-")
        if slug:
            variants.add(slug)
        for variant in variants:
            variant = variant.strip().lower()
            if variant:
                tokens.append(variant)
        sprint_match = re.match(r"^[sS]?([0-9]+[A-Za-z]?)", text)
        if sprint_match:
            sprint = sprint_match.group(1).lower()
            tokens.append(f"s{sprint}")
            tokens.append(f"sprint-{sprint}")
            tokens.append(f"sprint{sprint}")
            numeric = re.match(r"^([0-9]+)", sprint)
            if numeric:
                number = numeric.group(1)
                tokens.append(f"s{number}")
                tokens.append(f"sprint-{number}")
                tokens.append(f"sprint{number}")

    row_id = item.get("id")
    if row_id is not None:
        add_token(row_id)
    sprint = item.get("sprint")
    if sprint is not None:
        add_token(sprint)
    seen = set()
    normalized = []
    for token in tokens:
        token = token.lower().strip()
        if token and token not in seen:
            seen.add(token)
            normalized.append(token)
    return normalized


def normalize_path(path):
    normalized = str(path).strip().replace("\\", "/").lower()
    while normalized.startswith("./"):
        normalized = normalized[2:]
    normalized = re.sub(r"/+", "/", normalized)
    return normalized.rstrip("/")


def row_evidence_paths(item):
    paths = []
    evidence_path = item.get("evidence_path")
    if isinstance(evidence_path, str) and evidence_path.strip():
        paths.append(evidence_path)
    evidence_paths = item.get("evidence_paths")
    if isinstance(evidence_paths, list):
        paths.extend(path for path in evidence_paths if isinstance(path, str) and path.strip())
    seen = set()
    normalized = []
    for path in paths:
        path = normalize_path(path)
        if path and path not in seen:
            seen.add(path)
            normalized.append(path)
    return normalized


try:
    evidence_lines = log_path.read_text().splitlines()
except Exception:
    evidence_lines = []


def path_matches(tokens, expected_paths, evidence_path):
    normalized_evidence = normalize_path(evidence_path)
    for expected_path in expected_paths:
        if normalized_evidence == expected_path or normalized_evidence.endswith("/" + expected_path):
            return True
    parts = [part.lower() for part in re.split(r"[\\/]+", evidence_path) if part]
    if not parts:
        return False
    return any(token in part for token in tokens for part in parts)


row_matches = []
for item in flipped:
    tokens = row_tokens(item)
    expected_paths = row_evidence_paths(item)
    matches = []
    for index, evidence_line in enumerate(evidence_lines):
        evidence_path = evidence_line.strip()
        if evidence_path and path_matches(tokens, expected_paths, evidence_path):
            matches.append(index)
    row_matches.append(matches)

assignment = {}
used = set()
row_order = sorted(range(len(flipped)), key=lambda index: len(row_matches[index]))


def assign(position=0):
    if position >= len(row_order):
        return True
    row_index = row_order[position]
    for evidence_index in row_matches[row_index]:
        if evidence_index in used:
            continue
        used.add(evidence_index)
        assignment[row_index] = evidence_index
        if assign(position + 1):
            return True
        assignment.pop(row_index, None)
        used.remove(evidence_index)
    return False


if assign():
    unbound = []
else:
    unbound = [
        str(flipped[index].get("id") or flipped[index].get("sprint") or "<unknown>")
        for index in row_order
        if index not in assignment
    ]

if unbound:
    print(json.dumps({
        "decision": "block",
        "reason": "Cannot mark result row(s) passing without row-matched evidence Read this session: " + ", ".join(unbound),
    }, separators=(",", ":")))
    raise SystemExit(10)

if assignment:
    consumed = set(assignment.values())
    kept = [
        line
        for index, line in enumerate(evidence_lines)
        if index not in consumed
    ]
    tmp = log_path.with_suffix(log_path.suffix + ".tmp")
    text = "\n".join(kept)
    if text:
        text += "\n"
    tmp.write_text(text)
    tmp.replace(log_path)
PY
)
binding_status=$?
if [ "$binding_status" -eq 10 ]; then
  printf '%s\n' "$binding_decision"
  exit 0
fi

if [ "$binding_status" -ne 0 ]; then
  echo "verify-gate: row evidence binding warning: unexpected status $binding_status; continuing" >&2
fi
