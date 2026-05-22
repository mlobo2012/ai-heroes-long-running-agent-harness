# AI Heroes Long-Running Agent Harness

A two-pulse harness for **Claude Code** that lets an agent work on a real goal for hours without going silently dead.

The current shape follows Anthropic's March 2026 long-running-app harness direction: plan first against a four-axis rubric, **handshake on the contract** before building, build against the contract, **drive the live surface** with Playwright MCP or native computer use, evaluate from fresh context, then loop until the evaluator says PASS. The AI Heroes additions are the outer watchdog with active re-kick, per-criterion evidence linkage, a Bash-bypass gate, a SessionStart/PreCompact pair for context anxiety, a rubric library (frontend/api/library/data-pipeline/**desktop**), a **contract-reviewer handshake**, **interaction-evidence enforcement** (Playwright trace OR computer-use session log) with non-canonical-filename fallback, evaluator calibration capture, per-round artifact namespacing, a **bench rig**, headless entry points, worktree-isolated evaluator, model/rubric stamping on every round, a pinned Codex executor with **AGENTS.md** seeded for parity, a **`scripts/ralph-loop.sh` unattended driver** with `NEXT_FINDINGS.md` carry-forward, a **`scripts/re-simplify.sh`** procedure that lets you bench whether each harness piece is still load-bearing after a model upgrade, an **Agent SDK equivalence doc** that maps every hook to a `PreToolUse`/`Stop` callback, and OpenClaw/Discord operator ergonomics.

Built on top of Anthropic's published work:

- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)
- [Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps)
- [`anthropics/cwc-long-running-agents`](https://github.com/anthropics/cwc-long-running-agents)

This is not a clone of Anthropic's internal harness. It packages the same primitives into a Claude Code plugin you can actually run.

---

## The architecture

The loop is simple because it has to survive unattended execution.

```
operator goal
  -> planner writes BUILD_PLAN.md and default-fail test-results.json
  -> contract-reviewer hands back CONTRACT_OK or specific rewrites
  -> generator builds against the plan and produces round-N evidence
  -> evaluator drives the live surface (Playwright MCP / native computer use)
     from fresh context and writes QA_REPORT.md
  -> heartbeat hook blocks until test-results.json is green AND
     QA_REPORT.md starts PASS AND interaction evidence is non-empty
  -> outer watchdog catches silence if the inner loop stops beating
     and auto-rekicks NEEDS_WORK rounds up to the shared --round-budget
```

The default mode is **planner -> contract-reviewer -> generator -> evaluator**.

Strict sprinting is no longer the default. Older harnesses split everything into small sprints to survive context anxiety and model drift. Newer models can usually carry a longer coherent build. So this repo keeps sprint-style execution as a tool, not as the architecture. Use it when a task naturally decomposes or when you need a bounded Codex implementation unit.

## Why two pulses

Claude Code hooks are event-driven. The inner loop runs when a turn ends. That is fine until a turn never ends.

A subagent can hang. A process can die. The operator can go to bed. If the only watchdog lives inside the process that stalled, it is decorative plumbing.

So the harness has two pulses:

| Pulse | Cadence | Job |
|---|---|---|
| **Inner** | Every Stop/SubagentStop hook | Writes `.claude/goal-state/last-beat`, checks `test-results.json`, checks `QA_REPORT.md`, and blocks until the goal is actually done. |
| **Outer** | Clock-driven, normally 15 minutes | Reads active sessions and last-beat timestamps. If a session goes stale, alerts and writes recovery instructions to `STEER.md`. |

One drives the loop. One watches the loop.

---

## The contract files

### `BUILD_PLAN.md`

The planner creates the build contract. It contains:

- goal
- product spec
- observable acceptance criteria
- evidence required
- evaluator rubric — picked from `agents/rubrics/{frontend,api,library,data-pipeline}.md` and copied verbatim
- suggested build path
- out-of-scope list

This is where subjective quality becomes gradable. The rubric uses Anthropic's four axes from the March 2026 article — design quality, originality, craft, functionality — each scored 0–5 with explicit anchors. PASS requires every axis at >= 3 plus all criteria green. "Looks good" is not a contract. "No generic purple-gradient card stack, passes contrast AA, primary flow visible above the fold, screenshots at desktop and mobile, Playwright trace of the primary interaction" is a contract.

### `test-results.json`

Every acceptance criterion starts as `"passes": false`. Preferred schema (read by the per-criterion verify-gate):

```json
{
  "criteria": [
    {
      "id": "C1",
      "description": "Primary flow renders and is interactive",
      "evidence_paths": ["screenshots/c1-desktop.png", "screenshots/c1-mobile.png"],
      "passes": false
    }
  ]
}
```

The builder cannot flip a criterion to true until it has opened that criterion's `evidence_paths` with the Read tool. The `verify-gate` hook enforces that **per criterion** when the new schema is used, and falls back to session-level when older flat shapes are present.

A companion `verify-gate-bash` hook closes the Bash bypass: `sed -i`, `jq … > test-results.json`, redirected `python` and friends are blocked when they target the results file without prior evidence reads. This is still a teaching example, not a security boundary — Anthropic's upstream caveat applies — but the floor is higher.

This is the Default-FAIL contract from Anthropic's primitives repo. Optimism does not ship.

### `QA_REPORT.md`

The evaluator writes this after reviewing the plan, diff, results file, and evidence.

Line 1 must be exactly:

```text
PASS
```

or:

```text
NEEDS_WORK
```

The heartbeat hook only allows final completion when:

1. an active goal exists,
2. `test-results.json` contains pass/fail entries,
3. no `"passes": false` entries remain,
4. `QA_REPORT.md` starts with `PASS`, **and**
5. if the pinned rubric is `frontend` or `desktop`, a non-empty trace
   exists under `playwright-mcp/round-N/trace.zip` or
   `computer-use/round-N/session.jsonl`.

Builder-written tests are not the final truth. The evaluator is the release gate.

### `CONTRACT_REVIEW.md`

Before the generator starts, the planner runs the **contract-reviewer**
subagent. It returns `CONTRACT_OK` or `CONTRACT_REWRITE` with concrete
per-criterion rewrites. The handshake terminates only when the reviewer
returns `CONTRACT_OK` or when `--max-rounds` (default 3) is hit, at
which point it writes `CONTRACT_OK` with a `Concessions` section so the
operator knows what the reviewer gave up. This step catches mushy
criteria before the builder wastes a multi-hour round.

### Interaction-evidence — Playwright MCP and native computer use

Subjective "looks good" cannot pass. For interactive rubrics the
evaluator must drive the running surface and leave a trace at one of:

| Rubric   | Required trace                                  |
|----------|-------------------------------------------------|
| frontend | `playwright-mcp/round-N/trace.zip` (preferred)  |
| frontend | OR `computer-use/round-N/session.jsonl`         |
| desktop  | `computer-use/round-N/session.jsonl` (required) |
| desktop  | (optional `playwright-mcp/...` if also browser) |

`.mcp.json` wires `@playwright/mcp` and points its `PLAYWRIGHT_TRACE_DIR`
at the workspace. A commented `computer-use` block is included for
environments that ship Anthropic's computer-use MCP server (or where
Claude Code / Codex's native computer-use is available); uncomment to
enable. Same skepticism applies to both: an empty trace is the same as
no trace, and the heartbeat hook will reject `PASS` either way.

---

## Operator controls

| Control | Effect |
|---|---|
| `AGENT_STOP` | Kill switch. Next hook boundary stops cleanly. |
| `STEER.md` | Operator steering. Next tool boundary injects the note and resets the block counter. |
| `.claude/goal-state/heartbeat-stop.log` | Audit trail of the inner loop decisions. |
| `.claude/goal-state/rounds.json` | Round-by-round verdict log stamped with rubric, model, codex_model, evidence count, and best-effort axis scores. |
| `.claude/goal-state/round-budget` | Shared cap honored by both the heartbeat hook and the watchdog `--max-rounds`. |
| `.claude/goal-state/post-compact-orientation.md` | Snapshot the agent reads after a compaction. |
| `.claude/goal-state/evaluator-calibration.jsonl` | Operator overrides on past evaluator verdicts; the evaluator reads the tail before grading. |
| `ESCALATION.md` | Written by `hooks/heartbeat-stop.sh` and `goal-watchdog.py --kick` when the round budget is exhausted. Notifications fire on the configured webhook. |
| `~/.claude/goal-sessions/active.jsonl` | Source of truth for the outer watchdog. |
| `scripts/calibrate-evaluator.sh` | Record an operator override so the next evaluator round sees it. |
| `scripts/diff-rounds.sh A B` | Markdown diff between round A and B (verdicts, axis scores, criterion deltas, artifact counts). |
| `scripts/run-evaluator.sh [--isolated]` | Run the evaluator headless; `--isolated` uses a throwaway `git worktree`. Writes `NEXT_FINDINGS.md` on NEEDS_WORK. |
| `scripts/run-contract-review.sh` | Run the contract-reviewer headless against `BUILD_PLAN.md`. |
| `scripts/ralph-loop.sh` | Unattended build -> evaluate -> rebuild driver. Honors the shared round-budget file. Writes `NEXT_FINDINGS.md` after every NEEDS_WORK and `ESCALATION.md` when the budget is exhausted. |
| `scripts/re-simplify.sh` | Disable one harness piece, re-run the bench, decide if it is still load-bearing on the current model. |
| `scripts/bench-harness.sh + bench-score.py` | End-to-end bench rig and score-diff tool. |

### Context anxiety mitigations

- **SessionStart hook** re-seeds the agent with the acceptance contract, open NEEDS_WORK items, last 10 commits, recent PROGRESS.md, and the status of `init.sh` on every new session. Orientation never depends on CLAUDE.md prose alone.
- **PreCompact hook** snapshots the contract state into `.claude/goal-state/post-compact-orientation.md` before context compaction, so the post-compact agent can recover what it just lost.

### Active outer driver

`scripts/goal-watchdog.py --kick --max-rounds N` turns the watchdog from a passive smoke alarm into an auto-pilot. When the builder finishes cleanly with `QA_REPORT.md` = `NEEDS_WORK` and the last beat is fresh, the watchdog launches the next build round via the registered launcher. It escalates to `ESCALATION.md` when the round budget is exhausted, so a stuck loop becomes a visible operator event instead of an infinite cost burn.

### In-repo unattended loop

`scripts/ralph-loop.sh` is the in-repo equivalent of the upstream wrapper from `cwc-long-running-agents`. Runs build -> evaluate -> rebuild headless using `claude -p` until the heartbeat would accept goal-completion or the shared round-budget is hit. Writes `NEXT_FINDINGS.md` after every NEEDS_WORK round so the next builder turn opens with the previous evaluator's actionable bullets already on top. Run it locally; use the watchdog only when you also need the external auto-pilot.

```bash
scripts/ralph-loop.sh --workspace "$PWD" --isolated-evaluator
```

### Re-simplify on model upgrade

`scripts/re-simplify.sh` lets the operator disable one harness piece, re-run the bench rig, and decide whether the piece is still load-bearing on the current model. Combined with the `model` stamp `rounds.json` records per round, this makes "is X still earning its complexity?" measurable instead of aesthetic.

```bash
scripts/re-simplify.sh --target playwright-trace --reason "test on opus-4-7"
scripts/bench-harness.sh --pilot express-server --workspace /tmp/bench-w-override
scripts/re-simplify.sh --restore --target playwright-trace
scripts/bench-harness.sh --pilot express-server --workspace /tmp/bench-baseline
scripts/bench-score.py /tmp/bench-baseline/.../bench-score.json /tmp/bench-w-override/.../bench-score.json
```

### Agent SDK equivalence

`docs/agent-sdk-equivalent.md` maps every bash hook to its `PreToolUse` / `Stop` / `SessionStart` / `PreCompact` callback equivalent on the [Claude Agent SDK](https://docs.claude.com/en/docs/claude-code/sdk). Use this when you're not running Claude Code but want the same harness primitives.

---

## Two ways to run the outer pulse

The watchdog must not depend on the process it watches. Claude Code is the worker. The outer pulse is the smoke alarm.

### Option A: standalone watchdog

This is the default public path.

`scripts/goal-watchdog.py` reads `~/.claude/goal-sessions/active.jsonl`, checks each workspace's `.claude/goal-state/last-beat`, writes stale-session recovery notes to `STEER.md`, optionally posts a webhook alert, and prunes completed sessions only after `test-results.json` is green and `QA_REPORT.md` starts with `PASS`.

Run it once:

```bash
"$HOME/.claude/plugins/discord-long-running-harness/scripts/goal-watchdog.py" --json
```

Run it every 15 minutes from cron:

```cron
*/15 * * * * $HOME/.claude/plugins/discord-long-running-harness/scripts/goal-watchdog.py >> $HOME/.claude/goal-sessions/watchdog.log 2>&1
```

Or keep it alive as a loop:

```bash
"$HOME/.claude/plugins/discord-long-running-harness/scripts/goal-watchdog.py" --loop
```

Tune it:

```bash
# Alert after 30 minutes instead of 20
"$HOME/.claude/plugins/discord-long-running-harness/scripts/goal-watchdog.py" --stale-after 1800

# Alert only, do not write STEER.md
"$HOME/.claude/plugins/discord-long-running-harness/scripts/goal-watchdog.py" --no-steer

# Dry-run without writing anything
"$HOME/.claude/plugins/discord-long-running-harness/scripts/goal-watchdog.py" --dry-run --json
```

### OpenClaw option

If you already run OpenClaw, use an OpenClaw `goal-supervisor` heartbeat instead of a separate daemon.

Why keep this option? Because OpenClaw already has named agents, workspaces, heartbeats, Discord delivery, and operator routing. If it is present, duplicating that machinery in cron is waste. If it is not present, the standalone watchdog gives you the same failure property without importing the rest of our stack.

---

## Install

### Prerequisites

- Claude Code
- `bash`, `python3`, `git`, `uuidgen`
- a workspace where the agent runs
- optional webhook URL for stall alerts

### Plug it into Claude Code

```bash
cd "$HOME/.claude/plugins"
git clone https://github.com/mlobo2012/ai-heroes-long-running-agent-harness.git discord-long-running-harness
```

The plugin's internal name is `discord-long-running-harness` for historical reasons. It works in any Claude Code session, Discord-routed or not.

Enable it on a launcher:

```bash
# Dry-run first
"$HOME/.claude/plugins/discord-long-running-harness/bin/enable-for-launcher.sh" --slug klaus

# Apply
"$HOME/.claude/plugins/discord-long-running-harness/bin/enable-for-launcher.sh" --slug klaus --apply
```

Or add this to your own `claude` command:

```bash
--plugin discord-long-running-harness
```

### Pin the Codex model

The Codex executor reads a single env file:

```bash
cat > "$HOME/.claude/codex-current-model.env" <<'ENV'
CODEX_MODEL=gpt-5.5
ENV
```

When OpenAI ships a better model, edit one line. No script should chase model names.

The executor refuses `gpt-5.5-codex` and `gpt-5.4`. Both fail loud.

### Confirm the install

```bash
"$HOME/.claude/plugins/discord-long-running-harness/scripts/verify-install.sh"
```

48 PASS checks, exit 0. OpenClaw is not required. Four codex-related
checks may FAIL on environments without `codex` and
`~/.claude/codex-current-model.env`; that is expected.

---

## Register and run a goal

```bash
"$HOME/.claude/plugins/discord-long-running-harness/scripts/register-goal.sh" \
  --agent klaus \
  --channel <discord_channel_id> \
  --workspace "$HOME/path/to/agent/workspace" \
  --launcher "$HOME/.claude/channels/discord/start-klaus.sh" \
  --rubric frontend \
  --model claude-opus-4-7 \
  --codex-model gpt-5.5 \
  --round-budget 6 \
  "Ship the requested outcome with BUILD_PLAN.md, green test-results.json, and QA_REPORT.md PASS."
```

`--rubric` pins the rubric the planner copies and the heartbeat gate
enforces. `--model` and `--codex-model` are stamped into every
`rounds.json` entry. `--round-budget` is the shared cap honored by both
the inner heartbeat hook and the outer watchdog.

What this does:

1. Appends a JSON line to `$HOME/.claude/goal-sessions/active.jsonl`.
2. Writes `<workspace>/.claude/goal-state/goal-state.json`.
3. Seeds `BUILD_PLAN.md` if it does not exist.
4. Prints a `/goal` command that explicitly requires planning, green results, and evaluator PASS.

In the Claude session, kick the printed `/goal` command.

---

## What kinds of goals work

The goal needs an external pass/fail surface. The evaluator can judge subjective quality, but it still needs artifacts to inspect.

Good fits:

- shipping a feature with tests, screenshots, and console logs
- fixing a flaky suite until repeated runs pass
- building a UI against a rubric and browser evidence
- refactoring with benchmark or regression gates
- generating content that passes an audit rubric

Bad fits:

- open-ended strategy thinking
- naming decisions
- replying to DMs
- subjective taste without a rubric
- one-off research memos with no iteration loop

If the loop cannot tell done from not done, do not use a long-running harness. Have a normal conversation. Civilization will survive.

---

## Starter pilot

```
Create a minimal Express server on port 3001 with three routes:
/, /health, /echo?msg=.

Planner must write BUILD_PLAN.md and initialize test-results.json.
Builder must create curl-based tests that write pass/fail results.
Evaluator must inspect the test output and write QA_REPORT.md.
Goal is complete only when test-results.json is green and QA_REPORT.md starts PASS.
```

Small enough to land quickly. Large enough to exercise the whole loop.

---

## Components

```text
.claude-plugin/plugin.json               # Plugin manifest
.mcp.json                                # Playwright MCP wiring (+ commented computer-use MCP example)
CLAUDE.md                                # Session instructions
settings.json                            # Hook wiring
agents/
  planner.md                             # Expands goal into BUILD_PLAN.md and test-results.json; runs contract-reviewer
  contract-reviewer.md                   # Sprint-contract handshake; returns CONTRACT_OK or CONTRACT_REWRITE
  evaluator.md                           # Fresh-context QA gate; drives Playwright MCP or native computer use; writes QA_REPORT.md
  codex-executor.md                      # Optional bounded Codex builder
  rubrics/
    frontend.md                          # 4-axis browser rubric; requires Playwright OR computer-use trace
    api.md                               # 4-axis rubric for backend services
    library.md                           # 4-axis rubric for SDKs / packages
    data-pipeline.md                     # 4-axis rubric for ETL / batch jobs
    desktop.md                           # 4-axis rubric for non-browser interactive tasks; requires computer-use session
hooks/
  heartbeat-stop.sh                      # Inner pulse; requires green results + QA PASS + interaction-evidence; always-explicit escalation; stamps model/rubric in rounds.json
  track-read.sh                          # Records opened evidence
  verify-gate.sh                         # Per-criterion Default-FAIL evidence gate (Write/Edit)
  verify-gate-bash.sh                    # Closes the Bash bypass (sed/jq/python > test-results.json)
  session-start.sh                       # Re-seeds contract + calibration tail + pinned rubric on new sessions
  pre-compact.sh                         # Snapshots contract state before compaction
  kill-switch.sh                         # AGENT_STOP halt
  steer.sh                               # STEER.md operator interrupt
  commit-on-stop.sh                      # Backstop commit
  discord-notify.sh                      # Optional webhook notification (one-way, see note below)
bin/
  codex-spawn.sh                         # Reads pinned CODEX_MODEL and invokes Codex
  enable-for-launcher.sh                 # Safe rollout helper
scripts/
  register-goal.sh                       # Registers a goal session; accepts --rubric, --model, --codex-model, --round-budget; seeds AGENTS.md too
  goal-watchdog.py                       # Standalone outer pulse watchdog; --kick + --max-rounds with shared budget file; non-canonical trace/session-log fallback
  ralph-loop.sh                          # Unattended build->evaluate->rebuild driver; writes NEXT_FINDINGS.md on every NEEDS_WORK
  re-simplify.sh                         # Disable a harness piece, re-bench, decide if it's still load-bearing on this model
  run-contract-review.sh                 # Headless wrapper around the contract-reviewer subagent
  run-evaluator.sh                       # Headless evaluator; --isolated runs in a git worktree; writes NEXT_FINDINGS.md on NEEDS_WORK
  calibrate-evaluator.sh                 # Operator override capture for the evaluator-calibration corpus
  diff-rounds.sh                         # Markdown diff between any two rounds (verdicts, scores, artifacts)
  bench-harness.sh                       # Bench rig — runs a pilot end-to-end and writes a score JSON
  bench-score.py                         # Compares two score JSONs (e.g. upstream vs this harness)
  verify-install.sh                      # 68 PASS checks
bench/
  pilots/express-server/                 # Starter pilot for the bench rig (small but real)
docs/
  agent-sdk-equivalent.md                # Maps every bash hook to its Agent SDK PreToolUse/Stop callback
```

### A note on Discord

`hooks/discord-notify.sh` is **one-way**: it posts goal-complete and builder-pass events to a webhook when `DISCORD_NOTIFY_WEBHOOK` is set. There is no bot-side ingestion of operator replies — those still go through `STEER.md` on disk. The README's "Discord is your operator console" framing is the design direction, not the v0.3.0 implementation surface.

---

## Troubleshooting

**The inner pulse is not firing.**
Confirm the plugin is loaded and `settings.json` hooks reference `discord-long-running-harness`.

**The loop keeps blocking on `missing-test-results-contract`.**
Run the planner or create `test-results.json` with at least one `"passes": false` criterion.

**The loop keeps blocking on `goal-not-met`.**
At least one criterion still has `"passes": false`. Produce evidence, open it with Read, then update the result only if it actually passes.

**The loop keeps blocking on `awaiting-evaluator-pass`.**
Run the evaluator. `QA_REPORT.md` must start with bare `PASS` on line 1. Anything else blocks completion.

**Codex refuses to spawn.**
Check `$HOME/.claude/codex-current-model.env`. Exit code 2 means missing env file. Exit code 3 means forbidden model. Exit code 4 means `CODEX_MODEL` is unset.

**The 8-block cap fired.**
The anti-runaway cap let the session stop after repeated blocks. Check `.claude/goal-state/heartbeat-stop.log`, fix the contract or evidence, then restart.

**The outer pulse never alerts.**
If using the standalone watchdog, confirm cron/launchd/systemd or `--loop` is actually running. Then run `scripts/goal-watchdog.py --dry-run --json`. If using OpenClaw, confirm `goal-supervisor` reads the same active ledger.

---

## Reversibility

```bash
rm -rf "$HOME/.claude/plugins/discord-long-running-harness"
rm -f "$HOME/.claude/codex-current-model.env"
rm -rf "$HOME/.claude/goal-sessions"
# remove any cron/launchd/systemd watchdog entry you added
```

If you installed an OpenClaw supervisor, restore your `openclaw.json` backup and remove the supervisor workspace.

---

## Credits

Anthropic supplied the core primitives and architecture direction. AI Heroes packaged them as a Claude Code plugin, added the two-pulse watchdog, pinned Codex executor, Discord/OpenClaw operator path, and the evaluator-gated completion contract.

## License

Apache-2.0. See [LICENSE](./LICENSE).
