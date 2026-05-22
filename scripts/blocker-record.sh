#!/usr/bin/env bash
set -euo pipefail

python3 - "$@" <<'PY'
import argparse
import datetime
import json
import os
import re
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
    if not raw:
        return []
    return [part.strip() for part in raw.split(",") if part.strip()]


def slug_from_title(title):
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return f"B-{(slug or 'blocker')[:64]}"


def ledger_path():
    override = os.environ.get("BLOCKERS_FILE") or os.environ.get("BLOCKER_LEDGER")
    if override:
        return Path(override)
    workspace = Path(os.getcwd())
    return workspace / ".claude" / "goal-state" / "blockers.jsonl"


def validate(record):
    missing = sorted(SCHEMA_KEYS - set(record))
    if missing:
        raise SystemExit("blocker-record: missing schema keys: " + ", ".join(missing))
    if record["severity"] not in SEVERITIES:
        raise SystemExit("blocker-record: invalid severity: " + record["severity"])
    if record["status"] not in STATUSES:
        raise SystemExit("blocker-record: invalid status: " + record["status"])
    if not isinstance(record["evidence_paths"], list):
        raise SystemExit("blocker-record: evidence_paths must be an array")


parser = argparse.ArgumentParser(description="Append a production blocker record to .claude/goal-state/blockers.jsonl")
parser.add_argument("--title", required=True)
parser.add_argument("--severity", required=True)
parser.add_argument("--id")
parser.add_argument("--evidence", default="")
parser.add_argument("--reproduction", default="")
parser.add_argument("--area", default="")
parser.add_argument("--by", default=os.environ.get("USER") or "operator")
args = parser.parse_args()

title = args.title.strip()
if not title or "\n" in title:
    raise SystemExit("blocker-record: --title must be a non-empty single line")

severity = args.severity.strip().lower()
if severity not in SEVERITIES:
    raise SystemExit("blocker-record: invalid --severity: " + args.severity)

blocker_id = (args.id or slug_from_title(title)).strip()
if not re.match(r"^B-[A-Za-z0-9][A-Za-z0-9._-]*$", blocker_id):
    raise SystemExit("blocker-record: --id must look like B-short-slug")

record = {
    "id": blocker_id,
    "title": title,
    "severity": severity,
    "status": "open",
    "discovered_at": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "discovered_by": args.by.strip() or "operator",
    "evidence_paths": split_paths(args.evidence),
    "reproduction_notes": args.reproduction,
    "affected_area": args.area,
    "resolution_notes": "",
}
validate(record)

path = ledger_path()
path.parent.mkdir(parents=True, exist_ok=True)
with path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, separators=(",", ":")) + "\n")

print(blocker_id)
PY
