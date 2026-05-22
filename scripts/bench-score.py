#!/usr/bin/env python3
"""Compare two bench-harness score files and print a delta report."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def load(p: Path) -> dict:
    return json.loads(p.read_text())


def pct(a: float, b: float) -> str:
    if a == 0:
        return "n/a"
    return f"{((b - a) / a) * 100:+.1f}%"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Diff two bench-harness score files.")
    ap.add_argument("baseline", type=Path, help="baseline score.json (e.g. upstream)")
    ap.add_argument("candidate", type=Path, help="candidate score.json (e.g. this harness)")
    ap.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = ap.parse_args(argv)

    if not args.baseline.exists() or not args.candidate.exists():
        print("bench-score: one of the input files is missing", file=sys.stderr)
        return 2

    a = load(args.baseline)
    b = load(args.candidate)

    fields = ("wall_clock_seconds", "rounds_to_pass", "total_io_bytes_estimate")
    delta = {f: {"baseline": a.get(f), "candidate": b.get(f), "pct": pct(a.get(f, 0) or 0, b.get(f, 0) or 0)} for f in fields}
    delta["false_pass_baseline"] = bool(a.get("false_pass"))
    delta["false_pass_candidate"] = bool(b.get("false_pass"))
    delta["pilot"] = a.get("pilot")
    delta["both_completed"] = bool(a.get("completed")) and bool(b.get("completed"))

    if args.json:
        print(json.dumps(delta, indent=2))
        return 0

    print(f"Pilot: {delta['pilot']}")
    print(f"Both completed: {delta['both_completed']}")
    print()
    print(f"{'metric':<28} {'baseline':>14} {'candidate':>14} {'delta':>10}")
    print("-" * 70)
    for f in fields:
        d = delta[f]
        print(f"{f:<28} {str(d['baseline']):>14} {str(d['candidate']):>14} {d['pct']:>10}")
    print()
    if delta["false_pass_candidate"] and not delta["false_pass_baseline"]:
        print("WARNING: candidate produced a false_pass that baseline did not. This is a regression.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
