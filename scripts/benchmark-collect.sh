#!/usr/bin/env bash
set -euo pipefail
# Collect reproducible benchmark inputs from one harness workspace.
#
# Usage: benchmark-collect.sh [workspace]
# Defaults to the current working directory and writes JSON to stdout.

workspace="${1:-${BENCHMARK_WORKSPACE:-$PWD}}"

python3 - "$workspace" <<'PY'
import json
import re
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

workspace = Path(sys.argv[1]).expanduser().resolve()
goal_state = workspace / ".claude" / "goal-state"
heartbeat_log = goal_state / "heartbeat-stop.log"
evidence_reads = workspace / ".claude" / ".evidence-reads"
evidence_dir = workspace / "evidence"


def iso_from_timestamp(value):
    return datetime.fromtimestamp(value, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value):
    value = value.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def median(values):
    if not values:
        return None
    return statistics.median(values)


def line_count(path):
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            return sum(1 for _ in handle)
    except OSError:
        return 0


def relative(path):
    try:
        return str(path.relative_to(workspace))
    except ValueError:
        return str(path)


def content_timestamps(path):
    pattern = re.compile(r"20\d\d-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z")
    found = []
    try:
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            for match in pattern.findall(line):
                parsed = parse_iso(match)
                if parsed is not None:
                    found.append(parsed)
    except OSError:
        return []
    return found


def collect_codex_sprints():
    items = []
    for path in sorted(goal_state.glob("codex-spawn-*.log")):
        try:
            stat = path.stat()
        except OSError:
            continue
        birth = getattr(stat, "st_birthtime", None)
        mtime = stat.st_mtime
        started_at = None
        ended_at = iso_from_timestamp(mtime)
        duration = None
        duration_source = "unavailable"

        if birth is not None and mtime >= birth:
            started_at = iso_from_timestamp(birth)
            duration = int(round(mtime - birth))
            duration_source = "birth_to_mtime"
        else:
            stamps = content_timestamps(path)
            if len(stamps) >= 2:
                started_at = stamps[0].strftime("%Y-%m-%dT%H:%M:%SZ")
                ended_at = stamps[-1].strftime("%Y-%m-%dT%H:%M:%SZ")
                duration = int(round((stamps[-1] - stamps[0]).total_seconds()))
                duration_source = "first_to_last_content_timestamp"

        items.append({
            "file": relative(path),
            "slug": path.name.removeprefix("codex-spawn-").removesuffix(".log"),
            "started_at": started_at,
            "ended_at": ended_at,
            "duration_seconds": duration,
            "duration_source": duration_source,
            "line_count": line_count(path),
            "size_bytes": stat.st_size,
            "mtime": iso_from_timestamp(mtime),
        })
    durations = [item["duration_seconds"] for item in items if item["duration_seconds"] is not None]
    return {
        "source_glob": ".claude/goal-state/codex-spawn-*.log",
        "count": len(items),
        "median_duration_seconds": median(durations),
        "items": items,
    }


def collect_inner_pulse():
    entries = []
    if heartbeat_log.exists():
        try:
            lines = heartbeat_log.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            lines = []
        for line_number, line in enumerate(lines, start=1):
            parts = line.split()
            if not parts:
                continue
            parsed = parse_iso(parts[0])
            if parsed is None:
                continue
            entries.append({
                "line": line_number,
                "timestamp": parsed.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "decision": parts[1] if len(parts) > 1 else "",
                "reason": " ".join(parts[2:]) if len(parts) > 2 else "",
                "_datetime": parsed,
            })

    intervals = []
    for previous, current in zip(entries, entries[1:]):
        seconds = int(round((current["_datetime"] - previous["_datetime"]).total_seconds()))
        intervals.append({
            "from_timestamp": previous["timestamp"],
            "to_timestamp": current["timestamp"],
            "seconds": seconds,
            "from_decision": previous["decision"],
            "to_decision": current["decision"],
        })

    for entry in entries:
        entry.pop("_datetime", None)

    return {
        "source": ".claude/goal-state/heartbeat-stop.log",
        "heartbeat_count": len(entries),
        "interval_count": len(intervals),
        "median_interval_seconds": median([item["seconds"] for item in intervals]),
        "intervals": intervals,
    }


def collect_verify_gate_blocks():
    block_reasons = {
        "no_evidence": "Cannot modify the results file: no evidence has been Read",
        "row_binding": "Cannot mark result row(s) passing without row-matched evidence",
        "codex_routing": "Codex routing detection failed",
    }
    blocks = []
    for path in sorted(goal_state.glob("codex-spawn-*.log")):
        try:
            lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for line_number, line in enumerate(lines, start=1):
            stripped = line.strip()
            if not stripped.startswith("{"):
                continue
            try:
                data = json.loads(stripped)
            except json.JSONDecodeError:
                continue
            if data.get("decision") != "block":
                continue
            reason = str(data.get("reason", ""))
            for kind, needle in block_reasons.items():
                if needle in reason:
                    blocks.append({
                        "file": relative(path),
                        "line": line_number,
                        "kind": kind,
                        "reason": reason,
                    })
                    break
    return blocks


def collect_evidence_gate():
    if evidence_reads.exists():
        try:
            evidence_read_paths = evidence_reads.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            evidence_read_paths = []
    else:
        evidence_read_paths = []

    evidence_artifacts = []
    if evidence_dir.exists():
        evidence_artifacts = [
            relative(path)
            for path in sorted(evidence_dir.rglob("*"))
            if path.is_file()
        ]

    verify_gate_blocks = collect_verify_gate_blocks()
    read_count = len(evidence_read_paths)
    artifact_count = len(evidence_artifacts)
    return {
        "verify_gate_block_count": len(verify_gate_blocks),
        "verify_gate_blocks": verify_gate_blocks,
        "evidence_reads_file": ".claude/.evidence-reads",
        "evidence_read_count": read_count,
        "evidence_read_paths": evidence_read_paths,
        "evidence_artifact_count": artifact_count,
        "evidence_artifacts": evidence_artifacts,
        "blocks_per_evidence_read": None if read_count == 0 else len(verify_gate_blocks) / read_count,
        "blocks_per_evidence_artifact": None if artifact_count == 0 else len(verify_gate_blocks) / artifact_count,
    }


result = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "workspace": str(workspace),
    "codex_sprints": collect_codex_sprints(),
    "inner_pulse": collect_inner_pulse(),
    "evidence_gate": collect_evidence_gate(),
}
json.dump(result, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
