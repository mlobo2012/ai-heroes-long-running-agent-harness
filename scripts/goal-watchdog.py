#!/usr/bin/env python3
"""Standalone outer-pulse watchdog for AI Heroes long-running goal sessions."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_STALE_AFTER = 20 * 60
DEFAULT_INTERVAL = 15 * 60
DEFAULT_REPEAT_AFTER = 60 * 60


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(ts: float | None = None) -> str:
    if ts is None:
        return utc_now().isoformat().replace("+00:00", "Z")
    return dt.datetime.fromtimestamp(ts, dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_started_at(value: Any) -> float | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                print(f"goal-watchdog: skipping malformed JSONL line {line_no}: {exc}", file=sys.stderr)
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def write_jsonl_atomic(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")
    tmp.replace(path)


def read_last_beat(workspace: Path) -> float | None:
    beat = workspace / ".claude" / "goal-state" / "last-beat"
    if not beat.exists():
        return None
    try:
        raw = beat.read_text(encoding="utf-8").strip()
        if raw:
            return float(raw)
    except (OSError, ValueError):
        pass
    try:
        return beat.stat().st_mtime
    except OSError:
        return None


def first_nonempty_line(path: Path) -> str:
    if not path.exists():
        return ""
    try:
        for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
            stripped = line.strip()
            if stripped:
                return stripped
    except OSError:
        return ""
    return ""


def results_are_green(workspace: Path) -> bool:
    results = workspace / "test-results.json"
    if not results.exists():
        return False
    try:
        text = results.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    return re.search(r'"passes"\s*:\s*', text) is not None and re.search(r'"passes"\s*:\s*false', text) is None


def qa_report_passed(workspace: Path) -> bool:
    return first_nonempty_line(workspace / "QA_REPORT.md") == "PASS"


def goal_is_complete(workspace: Path) -> bool:
    return results_are_green(workspace) and qa_report_passed(workspace)


def load_watchdog_state(workspace: Path) -> dict[str, Any]:
    path = workspace / ".claude" / "goal-state" / "watchdog-state.json"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_watchdog_state(workspace: Path, state: dict[str, Any]) -> None:
    state_dir = workspace / ".claude" / "goal-state"
    state_dir.mkdir(parents=True, exist_ok=True)
    path = state_dir / "watchdog-state.json"
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def append_steer(workspace: Path, row: dict[str, Any], last_beat: float | None, age: float, dry_run: bool) -> None:
    steer = workspace / "STEER.md"
    message = (
        f"\n\n## Watchdog recovery — {iso()}\n\n"
        f"Session `{row.get('session_id', 'unknown')}` appears stalled. "
        f"Last inner-pulse beat: {iso(last_beat) if last_beat else 'never seen'} "
        f"({int(age)}s old).\n\n"
        "On the next Claude Code turn: inspect `.claude/goal-state/heartbeat-stop.log`, "
        "summarise the current state, recover the blocked step if safe, or stop with an explicit blocker.\n"
    )
    if dry_run:
        return
    with steer.open("a", encoding="utf-8") as fh:
        fh.write(message)


def notify(webhook: str | None, content: str, dry_run: bool) -> str | None:
    if not webhook:
        return None
    if dry_run:
        return "dry-run"
    payload = json.dumps({"content": content}).encode("utf-8")
    req = urllib.request.Request(webhook, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return str(resp.status)
    except urllib.error.URLError as exc:
        print(f"goal-watchdog: webhook notification failed: {exc}", file=sys.stderr)
        return "failed"


def check_once(args: argparse.Namespace) -> int:
    active_file = Path(args.active_file).expanduser()
    webhook = args.notify_webhook or os.environ.get("GOAL_WATCHDOG_WEBHOOK_URL") or os.environ.get("DISCORD_NOTIFY_WEBHOOK")
    now = time.time()
    events: list[dict[str, Any]] = []

    active_file.parent.mkdir(parents=True, exist_ok=True)
    lock_path = active_file.with_suffix(active_file.suffix + ".lock")
    with lock_path.open("a", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        rows = read_jsonl(active_file)
        remaining: list[dict[str, Any]] = []

        for row in rows:
            workspace_raw = row.get("workspace")
            session_id = str(row.get("session_id") or "unknown")
            agent = str(row.get("agent") or "unknown")
            if not isinstance(workspace_raw, str) or not workspace_raw:
                events.append({"type": "invalid", "session_id": session_id, "reason": "missing workspace"})
                remaining.append(row)
                continue

            workspace = Path(workspace_raw).expanduser()
            if not workspace.exists():
                events.append({"type": "missing-workspace", "session_id": session_id, "workspace": str(workspace)})
                remaining.append(row)
                continue

            if goal_is_complete(workspace):
                content = f"✅ Goal complete for `{agent}` session `{session_id}`. Removed from active ledger."
                status = notify(webhook, content, args.dry_run)
                events.append({"type": "complete", "session_id": session_id, "agent": agent, "notify": status})
                continue

            last_beat = read_last_beat(workspace)
            started = parse_started_at(row.get("started_at"))
            anchor = last_beat or started or now
            age = now - anchor

            if age <= args.stale_after:
                events.append({"type": "healthy", "session_id": session_id, "agent": agent, "age_seconds": int(age)})
                remaining.append(row)
                continue

            state = load_watchdog_state(workspace)
            last_alert_at = float(state.get("last_alert_at") or 0)
            last_alert_beat = state.get("last_alert_beat")
            beat_key = str(int(last_beat or 0))
            should_alert = (now - last_alert_at) >= args.repeat_after or last_alert_beat != beat_key

            if should_alert:
                if not args.no_steer:
                    append_steer(workspace, row, last_beat, age, args.dry_run)
                content = (
                    f"⚠️ Long-running goal stalled for `{agent}` session `{session_id}`. "
                    f"Last beat {iso(last_beat) if last_beat else 'never seen'}; age {int(age)}s. "
                    f"Recovery note {'not written' if args.no_steer else 'written to STEER.md'}."
                )
                status = notify(webhook, content, args.dry_run)
                if not args.dry_run:
                    save_watchdog_state(workspace, {
                        "last_alert_at": now,
                        "last_alert_at_iso": iso(now),
                        "last_alert_beat": beat_key,
                        "last_age_seconds": int(age),
                    })
                events.append({"type": "stale-alert", "session_id": session_id, "agent": agent, "age_seconds": int(age), "notify": status})
            else:
                events.append({"type": "stale-suppressed", "session_id": session_id, "agent": agent, "age_seconds": int(age)})

            remaining.append(row)

        if args.prune_completed and not args.dry_run:
            write_jsonl_atomic(active_file, remaining)

        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    if args.json:
        print(json.dumps({"active_file": str(active_file), "events": events}, indent=2, sort_keys=True))
    else:
        for event in events:
            print(f"{event['type']}: {event.get('agent', '?')} {event.get('session_id', '?')}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Clock-driven watchdog for Claude Code long-running goal sessions.")
    parser.add_argument("--active-file", default=str(Path.home() / ".claude" / "goal-sessions" / "active.jsonl"))
    parser.add_argument("--stale-after", type=int, default=DEFAULT_STALE_AFTER, help="seconds since last beat before a session is stale (default: 1200)")
    parser.add_argument("--interval", type=int, default=DEFAULT_INTERVAL, help="loop sleep interval in seconds (default: 900)")
    parser.add_argument("--repeat-after", type=int, default=DEFAULT_REPEAT_AFTER, help="minimum seconds before repeating an alert for the same beat (default: 3600)")
    parser.add_argument("--notify-webhook", default="", help="Discord-compatible webhook URL; env GOAL_WATCHDOG_WEBHOOK_URL also works")
    parser.add_argument("--no-steer", action="store_true", help="alert only; do not append recovery note to STEER.md")
    parser.add_argument("--no-prune-completed", dest="prune_completed", action="store_false", help="do not remove completed sessions from active.jsonl")
    parser.add_argument("--dry-run", action="store_true", help="report actions without writing STEER.md, state, or ledger changes")
    parser.add_argument("--json", action="store_true", help="print machine-readable event summary")
    parser.add_argument("--loop", action="store_true", help="run forever, sleeping --interval seconds between checks")
    parser.set_defaults(prune_completed=True)
    args = parser.parse_args(argv)

    if args.stale_after <= 0 or args.interval <= 0 or args.repeat_after <= 0:
        parser.error("--stale-after, --interval, and --repeat-after must be positive")

    if not args.loop:
        return check_once(args)

    while True:
        check_once(args)
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main())
