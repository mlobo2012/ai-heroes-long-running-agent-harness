# AI Heroes Long-Running Agent Harness

A two-pulse harness for **Claude Code** that lets an agent work on a real goal for hours without going silently dead.

The current shape follows Anthropic's March 2026 long-running-app harness direction: plan first, build against a contract, evaluate from fresh context, then loop until the evaluator says PASS. The AI Heroes additions are the outer watchdog, a pinned Codex executor, and OpenClaw/Discord operator ergonomics.

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
  -> generator builds against the plan and produces evidence
  -> evaluator reviews from fresh context and writes QA_REPORT.md
  -> heartbeat hook blocks until test-results.json is green and QA_REPORT.md starts PASS
  -> outer watchdog catches silence if the inner loop stops beating
```

The default mode is **planner -> generator -> evaluator**.

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
- evaluator rubric
- suggested build path
- out-of-scope list

This is where subjective quality becomes gradable. If the task touches UI or design, the plan should define the bar for functionality, craft, design quality, and originality. "Looks good" is not a contract. "No generic purple-gradient card stack, passes contrast, primary flow visible above the fold, screenshots at desktop and mobile" is a contract.

### `test-results.json`

Every acceptance criterion starts as `"passes": false`.

The builder cannot flip a criterion to true until it has opened evidence with the Read tool. The `verify-gate` hook enforces that. Evidence can be screenshots, console logs, test output, browser traces, generated files, benchmark results, or whatever `BUILD_PLAN.md` requires.

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
3. no `"passes": false` entries remain, and
4. `QA_REPORT.md` starts with `PASS`.

Builder-written tests are not the final truth. The evaluator is the release gate.

---

## Operator controls

| Control | Effect |
|---|---|
| `AGENT_STOP` | Kill switch. Next hook boundary stops cleanly. |
| `STEER.md` | Operator steering. Next tool boundary injects the note and resets the block counter. |
| `.claude/goal-state/heartbeat-stop.log` | Audit trail of the inner loop decisions. |
| `~/.claude/goal-sessions/active.jsonl` | Source of truth for the outer watchdog. |

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

17 PASS checks, exit 0. OpenClaw is not required.

---

## Register and run a goal

```bash
"$HOME/.claude/plugins/discord-long-running-harness/scripts/register-goal.sh" \
  --agent klaus \
  --channel <discord_channel_id> \
  --workspace "$HOME/path/to/agent/workspace" \
  --launcher "$HOME/.claude/channels/discord/start-klaus.sh" \
  "Ship the requested outcome with BUILD_PLAN.md, green test-results.json, and QA_REPORT.md PASS."
```

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
CLAUDE.md                                # Session instructions
settings.json                            # Hook wiring
agents/
  planner.md                             # Expands goal into BUILD_PLAN.md and test-results.json
  evaluator.md                           # Fresh-context QA gate, writes QA_REPORT.md
  codex-executor.md                      # Optional bounded Codex builder
hooks/
  heartbeat-stop.sh                      # Inner pulse, requires green results + QA PASS
  track-read.sh                          # Records opened evidence
  verify-gate.sh                         # Default-FAIL evidence gate
  kill-switch.sh                         # AGENT_STOP halt
  steer.sh                               # STEER.md operator interrupt
  commit-on-stop.sh                      # Backstop commit
  discord-notify.sh                      # Optional webhook notification
bin/
  codex-spawn.sh                         # Reads pinned CODEX_MODEL and invokes Codex
  enable-for-launcher.sh                 # Safe rollout helper
scripts/
  register-goal.sh                       # Registers an active goal session
  goal-watchdog.py                       # Standalone outer pulse watchdog
  verify-install.sh                      # 17 PASS checks
```

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
