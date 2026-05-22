# Agent SDK example

Runnable skeleton that ports the AI Heroes harness primitives to the
[Claude Agent SDK](https://docs.claude.com/en/docs/claude-code/sdk).
Pair with `docs/agent-sdk-equivalent.md` (the mapping table).

This is **a starting point, not a complete port.** The skeleton wires:

- a `PreToolUse` callback that mirrors `hooks/track-read.sh` and
  `hooks/verify-gate.sh` (per-criterion evidence enforcement),
- a `Stop` callback that mirrors `hooks/heartbeat-stop.sh` (blocks
  on `test-results.json` failures and `QA_REPORT.md` not-PASS),
- a separate `query()` call for the evaluator with no Write/Edit
  tools so the fresh-context property is preserved.

What is **not** wired (left as exercises):

- The interaction-evidence gate for frontend/desktop rubrics.
- The contract-reviewer handshake.
- The round-N artifact namespacing on evidence paths.
- The watchdog (keep that as a separate process — see the SDK doc).
- The Codex executor (Claude-Code-side pattern; spawn Codex directly
  from your SDK wrapper if you need it).

## Layout

```
docs/sdk-example/
├── README.md         (this file)
└── sdk_loop.py       (runnable Python skeleton; ~150 lines)
```

## Requirements

- Python 3.10+
- `pip install claude-agent-sdk`
- `ANTHROPIC_API_KEY` in the environment

## Run

```bash
cd /tmp/your-workspace
python /path/to/docs/sdk-example/sdk_loop.py \
  --workspace . \
  --build-prompt "Build feature X per BUILD_PLAN.md."
```

The script assumes `BUILD_PLAN.md` and `test-results.json` already
exist in the workspace (run `scripts/register-goal.sh` or invoke the
planner agent first).

## What this proves

- The bash hooks translate 1:1 to Python callbacks. The contract
  (default-FAIL test-results, evidence-then-write, fresh-context
  evaluator, QA verdict gate) is portable.
- An SDK consumer can adopt the harness primitives without porting
  bash. They get the same default-FAIL discipline, the same
  evaluator skepticism, the same handoff state.

## What this does NOT prove

- A full production SDK harness. For that, port everything the doc
  maps and add interaction-evidence enforcement.
- That the SDK is faster than Claude Code. The bench rig lives at
  `scripts/bench-harness.sh`; run it both ways if you need numbers.
