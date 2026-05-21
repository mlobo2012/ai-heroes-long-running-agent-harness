# AI Heroes Long-Running Agent Harness

A two-pulse harness for **Claude Code** that lets a single agent grind on a real goal — autonomously, for hours — without ever going silently dead.

You give it a goal with a programmatic pass signal. The harness keeps Claude looping until that signal flips green. If anything stalls — a hung subagent, a dead process, the human who started the run going to bed — a second pulse on a 15-minute clock catches it and surfaces the stall in your operator channel.

Built on top of Anthropic's published primitives ([Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), [Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps), and the reference repo [`anthropics/cwc-long-running-agents`](https://github.com/anthropics/cwc-long-running-agents)). This harness adds the two pieces those primitives leave out:

1. **A stall detector** — the upstream loop is event-driven, so if events stop firing, nothing notices. This adds an outer 15-minute supervisor that catches the silence.
2. **A pinned Codex executor** — a single env file controls which model your sprints run on. Bump one line when OpenAI ships a new model; no script chases versions.

---

## Why two pulses

The upstream loop is **event-driven**. Every time Claude's turn ends, a `Stop` hook fires; the hook re-prompts Claude until a goal is met. This is correct as long as turns keep ending.

But what if a turn never ends? A subagent hangs. The Claude process dies. The operator forgets the run is going. The upstream loop has no way to know — it only runs at turn boundaries.

The fix is a second timer at a different cadence. One drives the loop. One watches it.

| Pulse | Cadence | Job |
|---|---|---|
| **Inner** (per turn) | Event-driven, every turn boundary | Decides whether the goal is met. If not, blocks and triggers the next turn. Writes a "last-beat" timestamp to disk. |
| **Outer** (15 minutes) | Clock-driven | Reads the last-beat timestamp. If it's older than 20 minutes for any active session, alerts the operator and writes a recovery note. Otherwise silent. |

The outer pulse only intervenes when state goes stale. It is the safety net, not the engine.

## How it works (first principles)

```
T+0    You register a goal. The /goal overlay engages.
T+0…   Claude loops. Every turn ends → inner pulse writes last-beat,
       checks test-results.json. If "passes": false anywhere → block,
       continue. If all true → goal met, exit cleanly.
T+8m   Claude spawns the codex-executor subagent for a sprint.
       Codex returns → SubagentStop → another inner pulse tick.
T+15m  Outer pulse wakes. Reads last-beat = 2m old. Silent.
T+30m  Outer pulse wakes. Last-beat still fresh. Silent.
T+45m  Codex hangs. Outer pulse wakes, sees last-beat = 45m old.
       Posts a stall alert. Appends a recovery note to STEER.md.
T+50m  Session unsticks (Anthropic's 10-min subagent timeout fires).
       Next turn ends → inner pulse reads STEER.md, resets the
       block counter, takes the recovery direction into account.
T+2h   Goal met. test-results.json all green. Inner pulse exits cleanly.
T+2h+  Outer pulse posts "✅ Goal complete in 2h 14m" and trims the
       session from the active ledger.
```

### The Default-FAIL contract

Every goal needs a `test-results.json` in the agent's workspace. Every criterion starts `"passes": false`. The agent can only flip a criterion to `true` after the `verify-gate` hook has seen it open a real evidence file (screenshot, console log, test output) with the `Read` tool. The hook then consumes the evidence so the next flip needs fresh proof.

This is the upstream cwc primitive. It is the entire reason this thing terminates honestly instead of optimistically.

### The operator controls

| Control | Effect |
|---|---|
| `AGENT_STOP` file in the workspace | Kill switch. Next turn boundary → session stops, last commit captured. |
| `STEER.md` with content | Operator steering. Next turn → Claude is interrupted with `OPERATOR STEERING: <your note>` and the block counter is reset. |
| `.claude/goal-state/heartbeat-stop.log` | Audit trail of every decision the inner pulse made. |
| `~/.claude/goal-sessions/active.jsonl` | The outer pulse's source of truth for what's active. |

---

## Install

### Prerequisites

- Claude Code
- `bash`, `jq` or `python3`, `git`, `uuidgen`
- A workspace where the agent runs (any directory)
- Optional: OpenClaw for the outer pulse. Without OpenClaw the inner pulse works fine — you just lose the stall detector.

### Plug it into Claude Code

Drop this repo into your Claude Code plugins directory:

```bash
cd "$HOME/.claude/plugins"
git clone https://github.com/mlobo2012/ai-heroes-long-running-agent-harness.git discord-long-running-harness
```

(The plugin's internal name is `discord-long-running-harness` for historical reasons — the harness itself works in any Claude Code session, Discord-routed or not.)

Enable it on a launcher (or any `claude` invocation). The included helper does this safely for any Discord agent launcher in the AI Heroes / OpenClaw pattern:

```bash
# Dry-run first; see the proposed diff:
"$HOME/.claude/plugins/discord-long-running-harness/bin/enable-for-launcher.sh" --slug klaus

# Apply when you're ready:
"$HOME/.claude/plugins/discord-long-running-harness/bin/enable-for-launcher.sh" --slug klaus --apply
```

Or just add `--plugin discord-long-running-harness` to your own `claude` command.

### Pin the Codex model

The Codex executor reads a single env file. Create it:

```bash
cat > "$HOME/.claude/codex-current-model.env" <<'ENV'
CODEX_MODEL=gpt-5.5
ENV
```

When OpenAI ships GPT-5.6 or GPT-6, edit that one line. No restart needed — every spawn re-reads it.

The executor refuses `gpt-5.5-codex` (rejected under ChatGPT-account auth) and `gpt-5.4` (silent default that would otherwise get used if you forget). Both fail loud with exit codes 3 and 4.

### Confirm the install

```bash
"$HOME/.claude/plugins/discord-long-running-harness/scripts/verify-install.sh"
```

13 PASS checks, exit 0. If any FAIL, fix before going live.

### Optional: enable the outer pulse (OpenClaw)

If you run OpenClaw, add a `goal-supervisor` agent with a 15-minute heartbeat. The repo includes a reference `HEARTBEAT.md` and the openclaw.json shape under [`docs/openclaw-supervisor/`](./docs/openclaw-supervisor/) (added during initial install — see the install report for the exact JSON entry that was merged).

Without OpenClaw the harness still runs — you just lose stall detection. The inner pulse, Default-FAIL contract, kill switch, steering, and pinned Codex executor all work standalone.

---

## Register and run a goal

The interface is intentionally minimal — no Discord command parser, no API. Just a script.

```bash
"$HOME/.claude/plugins/discord-long-running-harness/scripts/register-goal.sh" \
  --agent klaus \
  --channel <discord_channel_id> \
  --workspace "$HOME/path/to/agent/workspace" \
  --launcher "$HOME/.claude/channels/discord/start-klaus.sh" \
  "Ship the requested outcome described in CLAUDE.md, with all test-results.json items green."
```

What this does:

1. Appends a JSON line to `$HOME/.claude/goal-sessions/active.jsonl` (the outer pulse reads this).
2. Writes `<workspace>/.claude/goal-state/goal-state.json` so the inner pulse knows a goal is active.
3. Prints the `/goal "<text>"` command for you to paste into the Claude session — that's what engages Anthropic's `/goal` overlay.

If you're running this from inside a Claude session (the agent registering its own goal), the agent can just call the script and paste the `/goal` line for itself.

### Steering and stopping

```bash
# Steer mid-run:
echo "Skip the OAuth flow for now and use a hardcoded token." > "<workspace>/STEER.md"

# Stop cleanly:
touch "<workspace>/AGENT_STOP"

# Check what the inner pulse has been doing:
tail "<workspace>/.claude/goal-state/heartbeat-stop.log"
```

---

## What kinds of goals work

The hard prerequisite: **the goal needs a programmatic pass/fail signal**. Without one, the Default-FAIL contract has no terminator and the 8-block cap will halt you 8 turns in.

### Goals that work

**Engineering with a test suite**
- *"Build a 3-route Next.js page (`/pricing`, `/about`, `/contact`) with Playwright coverage on each. test-results.json has 3 items; all green; screenshot diff under 0.05 against the reference."*
- *"Refactor the CRM ingest pipeline so existing pytest cases pass and p95 ingest latency drops below 500ms, verified by a new perf test."*
- *"Fix every flaky Playwright test in this repo. Run the full suite 20 times. Zero failures."*

**Migrations gated on build + lint**
- *"Migrate the marketing site to `next/image` everywhere. `npm run build` passes, `npm run lint` zero warnings, no `<img>` tag left."*
- *"Move all Python in this repo from 3.9 to 3.11. pytest passes, ruff clean, no deprecation warnings."*

**Content generation with an audit skill as evaluator**
- *"Generate 5 GEO blog articles for Granola AI targeting topics from the latest Peec AI gap scan. Each article passes the geo-article-audit skill with zero FAILs. test-results.json has one item per article."*
- *"Write proposal v3 for &lt;client&gt;. Passes the buyer-review and ship-visible gates."*

**Multi-sprint product work**
- *"Ship a working free tool that takes a domain, runs a Peec AI gap scan, and outputs a printable PDF. Hosted at /free/peec-scan. Lighthouse perf ≥ 90, no console errors, PDF renders in Chrome and Safari."*

The shape is the same every time: testable, decomposable into sprints, each sprint produces evidence the harness can `Read` and a verdict you can flip in `test-results.json`.

### Goals that don't work

- *"Help me think through Q3 strategy"* — no terminator.
- *"Pick the best name for the new agent"* — single judgment call, no loop.
- *"Reply to all my Discord DMs"* — per-message human judgment.
- *"Make the landing page more compelling"* — subjective, no programmatic gate. Use design-review iteratively in a normal session instead.
- *"Research the competitive landscape and write a memo"* — single output, doesn't iterate.

For these, just have a normal conversation. The harness adds value where the loop adds value.

### Starter goal for your first pilot

```
In the agent workspace: create a minimal Express server on port 3001 with
three routes (/, /health, /echo?msg=). Each route has a curl-based test
in tests/ that writes a pass/fail line to test-results.json. Goal met
when all three tests show "passes": true. Use Codex GPT-5.5 xhigh via the
codex-executor for the build. Run tests after each sprint. Iterate until
green.
```

Small enough to land in 2–3 sprints. Exercises every part of the harness end-to-end. You'll see the loop work without burning hours.

---

## Components

```
.claude-plugin/plugin.json               # Plugin manifest
CLAUDE.md                                # Session instructions ("Discord is your operator console")
settings.json                            # Hook wiring
agents/
  evaluator.md                           # Fresh-context grader (vendored from cwc; Read/Glob/Grep/Bash only, no Write)
  codex-executor.md                      # Sprint executor — invokes bin/codex-spawn.sh
hooks/
  heartbeat-stop.sh                      # Inner pulse — Stop + SubagentStop
  track-read.sh                          # PreToolUse(Read) — records evidence opens
  verify-gate.sh                         # PreToolUse(Write|Edit) — Default-FAIL contract
  kill-switch.sh                         # PreToolUse(*) — AGENT_STOP halts everything
  steer.sh                               # PreToolUse(*) — STEER.md interrupts mid-run
  commit-on-stop.sh                      # Stop — backstop commit of tracked changes
  discord-notify.sh                      # Stop — channel notification on state change
bin/
  codex-spawn.sh                         # Reads pinned CODEX_MODEL, invokes codex exec
  enable-for-launcher.sh                 # Safe rollout helper (dry-run by default)
scripts/
  register-goal.sh                       # Registers an active goal session
  verify-install.sh                      # 13 PASS checks
```

---

## Troubleshooting

**The inner pulse isn't firing.**
Confirm the plugin is loaded: in your session, the `Stop` and `SubagentStop` hooks in `settings.json` should reference `discord-long-running-harness`. If you launched without `--plugin discord-long-running-harness`, restart.

**The goal never terminates.**
Your `test-results.json` probably has no items, or every item is structured in a way `grep -q '"passes": false'` can't find. Open the file and check the structure matches `{ "items": [ { "passes": false, ... }, ... ] }` or any JSON that contains literal `"passes": false` strings until the goal is met.

**Codex refuses to spawn.**
Check `$HOME/.claude/codex-current-model.env`. Exit code 2 = file missing. Exit code 3 = forbidden model (`gpt-5.5-codex` or `gpt-5.4`). Exit code 4 = `CODEX_MODEL` not set.

**The 8-block cap fired.**
The inner pulse respects Anthropic's platform cap. After 8 consecutive blocks, the next turn is allowed to end. This is by design — don't fight it. Either (a) the goal is poorly specified, (b) the agent is making no progress (check `heartbeat-stop.log`), or (c) you need to `STEER.md` it in a different direction.

**The outer pulse never alerts.**
You don't have OpenClaw installed, or `goal-supervisor` isn't in `~/.openclaw/openclaw.json`. The inner pulse works fine without it; you just lose stall detection.

---

## Reversibility

```bash
# Remove the plugin:
rm -rf "$HOME/.claude/plugins/discord-long-running-harness"

# Remove the pinned model env:
rm -f "$HOME/.claude/codex-current-model.env"

# Remove the active sessions ledger:
rm -rf "$HOME/.claude/goal-sessions"

# OpenClaw supervisor (if you set it up):
# restore openclaw.json from your timestamped backup
# rm -rf "$HOME/.openclaw/workspace-goal-supervisor"
# rm -rf "$HOME/.openclaw/agents/goal-supervisor"
```

Every install operation backs up before edit. Every script is reversible.

---

## Credits

Built on Anthropic's published work:

- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) (Nov 2025) — the originating research.
- [Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps) (Mar 2026) — the generator/evaluator loop pattern.
- [`anthropics/cwc-long-running-agents`](https://github.com/anthropics/cwc-long-running-agents) — the demo repo we vendor from (CLAUDE.md, evaluator agent, track-read/verify-gate/kill-switch/steer/commit-on-stop hooks). Apache-2.0.

The two-pulse design, the Codex executor with pinned model, and the OpenClaw supervisor are AI Heroes additions.

## License

Apache-2.0. See [LICENSE](./LICENSE).
