#!/usr/bin/env bash
set -euo pipefail

python3 - "$@" <<'PY'
import argparse
import json
import os
import sys
from pathlib import Path

SEVERITIES = {"critical", "high", "medium", "low", "nit"}
STATUSES = {"open", "triaged", "resolved", "wontfix"}
SCHEMA_KEYS = {
    "id",
    "title",
    "severity",
    "status",
    "discovered_at",
    "discovered_by",
    "evidence_paths",
    "reproduction_notes",
    "affected_area",
    "resolution_notes",
}


def split_paths(raw):
    if raw is None:
        return None
    if not raw:
        return []
    return [part.strip() for part in raw.split(",") if part.strip()]


def ledger_path():
    override = os.environ.get("BLOCKERS_FILE") or os.environ.get("BLOCKER_LEDGER")
    if override:
        return Path(override)
    workspace = Path(os.getcwd())
    return workspace / ".claude" / "goal-state" / "blockers.jsonl"


def validate(record):
    missing = sorted(SCHEMA_KEYS - set(record))
    if missing:
        raise SystemExit("blocker-update: missing schema keys: " + ", ".join(missing))
    if record["severity"] not in SEVERITIES:
        raise SystemExit("blocker-update: invalid severity in ledger: " + str(record["severity"]))
    if record["status"] not in STATUSES:
        raise SystemExit("blocker-update: invalid status: " + str(record["status"]))
    if not isinstance(record["evidence_paths"], list):
        raise SystemExit("blocker-update: evidence_paths must be an array")
    if record["status"] == "resolved" and not record["evidence_paths"]:
        raise SystemExit("blocker-update: resolved blockers require --evidence or existing evidence")
    if record["status"] == "wontfix" and not str(record.get("resolution_notes", "")).strip():
        raise SystemExit("blocker-update: wontfix blockers require --resolution")


parser = argparse.ArgumentParser(description="Append a status update to .claude/goal-state/blockers.jsonl")
parser.add_argument("--id", required=True)
parser.add_argument("--status", required=True)
parser.add_argument("--evidence")
parser.add_argument("--resolution", default=None)
args = parser.parse_args()

blocker_id = args.id.strip()
if not blocker_id:
    raise SystemExit("blocker-update: --id is required")

status = args.status.strip().lower()
if status not in STATUSES:
    raise SystemExit("blocker-update: invalid --status: " + args.status)

path = ledger_path()
if not path.exists():
    raise SystemExit("blocker-update: unknown blocker id: " + blocker_id)

latest = {}
for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
    if not line.strip():
        continue
    try:
        record = json.loads(line)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"blocker-update: invalid JSON on line {line_number}: {exc}") from exc
    if not isinstance(record, dict):
        raise SystemExit(f"blocker-update: ledger line {line_number} is not an object")
    if record.get("id"):
        latest[str(record["id"])] = record

if blocker_id not in latest:
    raise SystemExit("blocker-update: unknown blocker id: " + blocker_id)

record = dict(latest[blocker_id])
record["status"] = status
evidence_paths = split_paths(args.evidence)
if evidence_paths is not None:
    record["evidence_paths"] = evidence_paths
if args.resolution is not None:
    record["resolution_notes"] = args.resolution

validate(record)
with path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":")) + "\n")

print(blocker_id)
PY
