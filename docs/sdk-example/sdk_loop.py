#!/usr/bin/env python3
"""SDK port skeleton for the AI Heroes long-running agent harness.

Mirrors hooks/track-read.sh + hooks/verify-gate.sh + hooks/heartbeat-stop.sh
as Agent SDK callbacks. Mirrors agents/evaluator.md as a separate query()
call so the fresh-context property is preserved.

Not a complete port — see docs/sdk-example/README.md for what's left.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

try:
    # The actual import shape may vary between SDK versions. Adapt the
    # symbol names to the version you have installed.
    from claude_agent_sdk import query, ClaudeAgentOptions  # type: ignore
except ImportError:
    print("This skeleton requires `pip install claude-agent-sdk`.", file=sys.stderr)
    print("It is provided as a reference; the import shape may vary by SDK version.", file=sys.stderr)
    sys.exit(2)


EVIDENCE_PATHS_READ: set[str] = set()


def is_evidence_path(p: str) -> bool:
    """Mirror hooks/track-read.sh — recognise upstream + round-N evidence shapes."""
    if not p:
        return False
    lowered = p.lower()
    if any(token in p for token in ("/screenshots/", "/evidence/round-", "/playwright-mcp/round-", "/computer-use/round-")):
        return True
    if lowered.endswith(("-console.txt", "-result.txt")):
        return True
    suffix = Path(p).suffix.lower()
    return suffix in {".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf", ".zip", ".jsonl", ".log", ".txt", ".json", ".html"}


def pre_tool_use(tool_name: str, tool_input: dict[str, Any]) -> None:
    """Mirror hooks/track-read.sh (PreToolUse on Read) and hooks/verify-gate.sh (PreToolUse on Write/Edit)."""
    # 1. Track evidence reads.
    if tool_name == "Read":
        p = tool_input.get("file_path") or ""
        if p and Path(p).is_file() and is_evidence_path(p):
            EVIDENCE_PATHS_READ.add(p)
            EVIDENCE_PATHS_READ.add(os.path.abspath(p))
        return

    # 2. Verify-gate on Write/Edit targeting test-results.json.
    if tool_name not in ("Write", "Edit"):
        return
    target = tool_input.get("file_path") or ""
    if not target.endswith("test-results.json"):
        return

    # Reconstruct the proposed payload (Write -> content; Edit -> new_string).
    proposed = tool_input.get("content") or tool_input.get("new_string") or ""
    try:
        new_state = json.loads(proposed)
    except (TypeError, ValueError, json.JSONDecodeError):
        return  # cannot inspect; let it through (mirrors bash fallback)
    if not isinstance(new_state, dict):
        return

    new_criteria = {c.get("id"): c for c in new_state.get("criteria", []) if isinstance(c, dict) and c.get("id")}
    try:
        old_text = Path(target).read_text(encoding="utf-8") if Path(target).exists() else "{}"
        old_state = json.loads(old_text)
    except Exception:
        old_state = {}
    old_criteria = {c.get("id"): c for c in old_state.get("criteria", []) if isinstance(c, dict) and c.get("id")}

    newly_passing: list[tuple[str, list[str]]] = []
    for cid, c in new_criteria.items():
        if c.get("passes") is True and old_criteria.get(cid, {}).get("passes") is not True:
            newly_passing.append((cid, list(c.get("evidence_paths") or [])))
    if not newly_passing:
        return

    for cid, ev_paths in newly_passing:
        if not ev_paths:
            raise PermissionError(f"verify-gate: criterion {cid} has no evidence_paths declared")
        if not any(p in EVIDENCE_PATHS_READ or os.path.abspath(p) in EVIDENCE_PATHS_READ for p in ev_paths):
            raise PermissionError(
                f"verify-gate: cannot flip {cid} to pass — none of {ev_paths} were Read this session"
            )

    # Consume the evidence log so the next pass needs fresh proof.
    EVIDENCE_PATHS_READ.clear()


def stop_heartbeat(workspace: Path) -> None:
    """Mirror hooks/heartbeat-stop.sh — block stop until contract green + QA PASS."""
    results = workspace / "test-results.json"
    qa = workspace / "QA_REPORT.md"
    if not results.is_file():
        raise RuntimeError("heartbeat: test-results.json missing")
    try:
        data = json.loads(results.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"heartbeat: test-results.json unreadable: {exc}") from exc
    failing = [c.get("id") for c in data.get("criteria", []) if isinstance(c, dict) and c.get("passes") is not True]
    if failing:
        raise RuntimeError(f"heartbeat: criteria still failing: {failing}")
    if not qa.is_file():
        raise RuntimeError("heartbeat: QA_REPORT.md missing")
    first = ""
    for line in qa.read_text(encoding="utf-8", errors="ignore").splitlines():
        if line.strip():
            first = line.strip()
            break
    if first != "PASS":
        raise RuntimeError(f"heartbeat: QA verdict was '{first}', not PASS")


async def run_builder(workspace: Path, prompt: str) -> None:
    """Builder query() with the PreToolUse callback wired."""
    options = ClaudeAgentOptions(
        cwd=str(workspace),
        hooks={
            "PreToolUse": [pre_tool_use],
        },
    )
    async for msg in query(prompt=prompt, options=options):
        # Stream-print or log as appropriate for your runtime.
        pass


async def run_evaluator(workspace: Path) -> str:
    """Evaluator query() — separate context, no Write/Edit tools."""
    evaluator_md = (workspace / "agents" / "evaluator.md").read_text(encoding="utf-8") if (workspace / "agents" / "evaluator.md").exists() else "You are the evaluator. Read BUILD_PLAN.md and test-results.json. Decide PASS or NEEDS_WORK."
    options = ClaudeAgentOptions(
        cwd=str(workspace),
        system_prompt=evaluator_md,
        allowed_tools=["Read", "Glob", "Grep", "Bash"],  # no Write/Edit; preserve fresh-context discipline
    )
    out: list[str] = []
    async for msg in query(prompt="Review the latest commit against BUILD_PLAN.md. Output PASS or NEEDS_WORK on line 1.", options=options):
        if getattr(msg, "type", "") == "assistant":
            out.append(getattr(msg, "text", ""))
    text = "".join(out)
    (workspace / "QA_REPORT.md").write_text(text, encoding="utf-8")
    first = text.splitlines()[0].strip() if text else ""
    return first


def main(argv: list[str] | None = None) -> int:
    import asyncio

    ap = argparse.ArgumentParser(description="AI Heroes harness — Agent SDK port skeleton.")
    ap.add_argument("--workspace", default=".", help="Workspace root (default: cwd)")
    ap.add_argument("--build-prompt", default="Read BUILD_PLAN.md and build the next unfinished criterion.")
    ap.add_argument("--max-rounds", type=int, default=6)
    args = ap.parse_args(argv)

    workspace = Path(args.workspace).resolve()
    for attempt in range(1, args.max_rounds + 1):
        print(f"[ralph-loop] round {attempt}/{args.max_rounds}")
        asyncio.run(run_builder(workspace, args.build_prompt))
        verdict = asyncio.run(run_evaluator(workspace))
        print(f"[ralph-loop] verdict: {verdict}")
        try:
            stop_heartbeat(workspace)
            print(f"[ralph-loop] PASS at round {attempt}")
            return 0
        except RuntimeError as exc:
            print(f"[ralph-loop] not yet: {exc}")
            continue
    print(f"[ralph-loop] max rounds exhausted ({args.max_rounds})", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
