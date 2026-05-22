# Agent SDK equivalence

This harness ships as Claude Code hooks and subagents. The March 2026
*Harness Design for Long-Running Application Development* article
states (in "Going further"): "The same patterns translate directly to
`PreToolUse`/`Stop` callbacks in the Agent SDK." This document spells
out the mapping piece by piece, so a team running on the
[Claude Agent SDK](https://docs.claude.com/en/docs/claude-code/sdk)
can adopt the same architecture without porting bash.

Every row tells you: what the bash hook does, what to wire in the SDK,
and whether the SDK version is a callback (sync), a stream subscriber
(async), or a wrapper around a `query()` call.

## Inner-loop primitives

| Bash hook                       | SDK equivalent                                                                                   | Shape       |
|---------------------------------|--------------------------------------------------------------------------------------------------|-------------|
| `hooks/track-read.sh`           | `PreToolUse` callback on the `Read` tool — append to an evidence-reads list in your run state    | Sync        |
| `hooks/verify-gate.sh`          | `PreToolUse` callback on `Write`/`Edit` — block when target is `test-results.json` and proposed criterion flips passes:true without matching evidence_paths in the reads list | Sync, may block |
| `hooks/verify-gate-bash.sh`     | `PreToolUse` callback on `Bash` — block when command writes the results file via `sed`/`jq`/`python`/redirect without prior evidence reads | Sync, may block |
| `hooks/heartbeat-stop.sh`       | `Stop` callback — re-check `test-results.json` greenness, QA verdict, and interaction trace; block (raise) until met | Sync, may block |
| `hooks/commit-on-stop.sh`       | `Stop` callback (second handler) — `git commit -am` tracked changes                              | Sync        |
| `hooks/kill-switch.sh`          | `PreToolUse` callback on all tools — block when `AGENT_STOP` file exists                         | Sync, may block |
| `hooks/steer.sh`                | `PreToolUse` callback on all tools — read+clear `STEER.md`, raise as a steering message          | Sync, may block |
| `hooks/session-start.sh`        | `SessionStart` callback (or wrap the first `query()` call) — emit the orientation block to the model as a system message | Sync, additive context |
| `hooks/pre-compact.sh`          | `PreCompact` callback — snapshot acceptance contract before history compaction                   | Sync        |
| `hooks/discord-notify.sh`       | `Stop` callback — POST goal-state delta to a webhook                                             | Sync, fire-and-forget |

### Sketch — `PreToolUse` evidence gate in the SDK

```python
from claude_agent_sdk import query, PreToolUseHook, BlockToolCall
import json, os, pathlib

EVIDENCE = set()

def track_read(tool_name, tool_input):
    if tool_name == "Read":
        p = tool_input.get("file_path") or ""
        if p and pathlib.Path(p).is_file() and is_evidence_path(p):
            EVIDENCE.add(p)
            EVIDENCE.add(os.path.abspath(p))

def verify_gate(tool_name, tool_input):
    if tool_name not in ("Write", "Edit"):
        return
    if not (tool_input.get("file_path") or "").endswith("test-results.json"):
        return
    proposed = json.loads(tool_input.get("content") or "{}")
    for c in proposed.get("criteria", []):
        if c.get("passes") is True:
            ev = c.get("evidence_paths") or []
            if ev and not any(p in EVIDENCE for p in ev):
                raise BlockToolCall(
                    f"Cannot flip {c['id']} to pass: none of {ev} were Read."
                )

async for msg in query(
    prompt="...",
    options={
        "hooks": {
            "PreToolUse": [track_read, verify_gate],
        }
    },
):
    ...
```

The Python is illustrative; the JavaScript and TypeScript SDK
signatures differ slightly, but the contract is identical.

### Sketch — `Stop` heartbeat in the SDK

```python
from claude_agent_sdk import query, StopHook, BlockStop

def heartbeat_stop(state):
    results = json.loads(open("test-results.json").read())
    failing = any(c.get("passes") is not True for c in results["criteria"])
    if failing:
        raise BlockStop("test-results.json still has failing criteria")
    verdict = open("QA_REPORT.md").read().splitlines()[0].strip()
    if verdict != "PASS":
        raise BlockStop("awaiting evaluator PASS")
    rubric = json.load(open(".claude/goal-state/goal-state.json"))["rubric"]
    if rubric in ("frontend", "desktop"):
        if not has_interaction_evidence():
            raise BlockStop(f"missing-interaction-evidence:{rubric}")
```

## Wrapper-loop primitives

| Bash script                     | SDK equivalent                                                              |
|---------------------------------|-----------------------------------------------------------------------------|
| `scripts/run-evaluator.sh`      | A separate `query()` call with a system prompt matching `agents/evaluator.md`, no Write/Edit tools, Playwright MCP tools enabled |
| `scripts/run-contract-review.sh`| A separate `query()` call with a system prompt matching `agents/contract-reviewer.md`, only Read/Glob/Grep/Write to `CONTRACT_REVIEW.md` |
| `scripts/ralph-loop.sh`         | A `while` loop wrapping the two `query()` calls; same exit-code contract |
| `scripts/goal-watchdog.py`      | A separate process — keep it out of the SDK runtime entirely; the watchdog must not depend on what it watches |

## Subagent equivalents

Claude Code's `agents/*.md` files are equivalent to:

- a system prompt (the body of the markdown),
- a tool allowlist (the `tools:` frontmatter),
- run in a separate `query()` call so it gets a fresh context window.

In the SDK, each subagent becomes a parameterised function:

```python
async def run_evaluator(workspace: str) -> str:
    out = []
    async for msg in query(
        prompt="Run the evaluator agent. Read BUILD_PLAN.md, ...",
        options={
            "system_prompt": open(f"{HARNESS_ROOT}/agents/evaluator.md").read(),
            "allowed_tools": ["Read", "Glob", "Grep", "Bash", "Write",
                              "mcp__playwright__*"],
            "cwd": workspace,
        },
    ):
        if msg.type == "assistant":
            out.append(msg.text)
    return "".join(out)
```

The fresh-context property — the evaluator never sees the builder's
context window — is preserved because the SDK's `query()` call is
session-isolated by construction. Do **not** use multi-turn
conversation state to share context between builder and evaluator;
that re-introduces self-evaluation bias.

## Why a separate watchdog process matters even on the SDK

The article: "If the only watchdog lives inside the process that
stalled, it is decorative plumbing." The SDK runs in your process. If
that process hangs (network stall on a tool call, OOM, infinite tool
loop), an in-process Stop callback cannot help. Keep
`scripts/goal-watchdog.py` running as a separate systemd service /
cron / launchd job pointed at `~/.claude/goal-sessions/active.jsonl`
regardless of whether the inner runtime is Claude Code, the SDK, or
something else.

## What does NOT translate

- The settings.json hook wiring is Claude Code only. The SDK takes
  callbacks programmatically.
- `.mcp.json` is Claude Code's MCP config; the SDK takes MCP servers
  as a `mcp_servers` option on `query()`.
- The `bin/codex-spawn.sh` Codex executor and `agents/codex-executor.md`
  are Claude-Code-side patterns (Claude spawning Codex). On the SDK
  you would invoke Codex directly as a subprocess from your wrapper.

## When to use which

- **Iteration / single-developer**: Claude Code interactive + this
  harness as a plugin. Lowest setup cost.
- **Headless / CI / cron**: `claude -p` + `scripts/ralph-loop.sh` +
  `scripts/goal-watchdog.py`. Same patterns, no GUI.
- **Production agent service**: Agent SDK + the callback mapping
  above + an external watchdog. You own the runtime, but the
  primitives are unchanged.
