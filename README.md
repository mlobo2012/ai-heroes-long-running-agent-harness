# AI Heroes Long-Running Agent Harness

A two-pulse harness for **Claude Code** that lets a single agent grind on a real goal — autonomously, for hours — without ever going silently dead.

You give it a goal with a programmatic pass signal. The harness keeps Claude looping until that signal flips green. If anything stalls — a hung subagent, a dead process, the human who started the run going to bed — a second pulse on a 15-minute clock catches it and surfaces the stall in your operator channel.

Built on top of Anthropic's published primitives ([Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents), [Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps), and the reference repo [`anthropics/cwc-long-running-agents`](https://github.com/anthropics/cwc-long-running-agents)). This harness adds the two pieces those primitives leave out:

1. **A stall detector** — the upstream loop is event-driven, so if events stop firing, nothing notices. This adds an outer 15-minute supervisor that catches the silence.
2. **A pinned Codex executor** — a single env file controls which model your sprints run on. Update one line when you choose a different supported model; no script chases versions.

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
T+0    You register a goal and paste the printed /goal command.
T+0…   Claude loops. Every turn ends → inner pulse writes last-beat,
       checks test-results.json. If "passes": false anywhere → block,
       continue. If all true → goal met, exit cleanly.
T+8m   Claude spawns the codex-executor subagent for a sprint.
       Codex returns → SubagentStop → another inner pulse tick.
T+15m  Outer pulse wakes. Reads last-beat = 2m old. Silent.
T+30m  Outer pulse wakes. Last-beat still fresh. Silent.
T+45m  Codex hangs. Outer pulse wakes, sees last-beat = 45m old.
       Posts a stall alert. Appends a recovery note to STEER.md.
T+50m  Session unsticks (for example, your runtime times out the subagent).
       Next turn ends → inner pulse reads STEER.md, resets the
       block counter, takes the recovery direction into account.
T+2h   Goal met. test-results.json all green. Inner pulse exits cleanly.
T+2h+  Outer pulse posts "✅ Goal complete in 2h 14m" and trims the
       session from the active ledger.
```

### The Default-FAIL contract

Every goal needs a `test-results.json` in the agent's workspace. Every criterion starts `"passes": false`. The agent can only flip a criterion to `true` after the `verify-gate` hook has seen it open a real evidence file (screenshot, console log, test output) with the `Read` tool. The hook then consumes the evidence so the next flip needs fresh proof.

This is the upstream cwc primitive. It is the entire reason this thing terminates honestly instead of optimistically.

### Scope policies

`test-results.json` may include a top-level `scope_policy` field:
`fixed_scope`, `production_hardening`, or `research_only`. Missing means
`fixed_scope`, which preserves the current behavior exactly.

`production_hardening` adds an opt-in blocker ledger at
`.claude/goal-state/blockers.jsonl`. Open blockers, and triaged blockers
without evidence, block completion even when every planned row is green.
`research_only` records blockers but never blocks on them.

Read the user guide at [`docs/scope-policies.md`](./docs/scope-policies.md)
and use [`docs/examples/production-hardening-prompt.md`](./docs/examples/production-hardening-prompt.md)
as the reference brief shape for hardening runs.

### Known soft boundary: Bash sed/jq on `test-results.json`

`hooks/verify-gate.sh` is a `Write|Edit` hook. It blocks direct Claude Code `Write` and `Edit` operations on `test-results.json` until fresh evidence has been opened, and it binds passing flips to matching evidence paths, but it is not a shell sandbox.

The exact bypass is a shell rewrite such as `bash -c 'sed -i "s/false/true/" test-results.json'`. Because that runs through Bash instead of `Write` or `Edit`, `verify-gate.sh` does not inspect it.

The partial close is `agents/evaluator-strict.md`: the strict evaluator drops Bash from the evaluator's tool grant, which closes the grader-side sed/jq bypass. It does not close generator-side Bash access during normal engineering work.

Recommended hardening path: add a second `PreToolUse` hook matching `Bash` that blocks commands matching `sed.*test-results\.json|jq.*test-results\.json`. Keep `verify-gate.sh` as the evidence gate, and use the Bash hook only for this results-file mutation surface.

### Codex routing: soft boundary on the generator side

Code-heavy sprint work goes through `codex-executor`, and therefore through `bin/codex-spawn.sh`. Orchestrator self-execution is reserved for read-only work, single-file changes, sub-10-minute fixes, or fully reversible operator-side edits.

The routing signal is one of:

- A fresh `.claude/goal-state/codex-spawn-*.log` written by `scripts/build-eval-loop.sh` or the `codex-executor` agent.
- A `Co-Authored-By: codex` trailer on the most recent commit on the sprint branch.

`hooks/verify-gate.sh` partially enforces this when a code-heavy `test-results.json` row flips and the changeset since the last commit touches `hooks/`, `scripts/`, `bin/`, or `agents/`. Enforcement is intentionally partial: it cannot prove every generator action came from Codex, and shell-level bypasses remain outside this hook. Operator discipline closes the rest: check for a fresh spawn log before accepting "generation done", and treat a missing log on a code-heavy sprint as orchestrator self-execution unless the latest commit carries the codex co-author trailer.

### Strict evaluator for content goals

`agents/evaluator-strict.md` is the strict-mode grader. Its tool grant is `Read, Glob, Grep` only: no Bash, no Write, no Edit.

Use `agents/evaluator-strict.md` as the default grader for content-domain goals: writing, GEO articles, prose, and design QA. These goals usually do not need shell access, and their evaluation evidence can be prepared as readable artefacts before grading.

Engineering goals can still use the default `agents/evaluator.md`, which has `Read, Glob, Grep, Bash` so it can inspect diffs and run lightweight checks. That path accepts the soft-Bash boundary described above.

### The operator controls

| Control | Effect |
|---|---|
| `AGENT_STOP` file in the workspace | Kill switch. Next turn boundary → session stops, last commit captured. |
| `STEER.md` with content | Operator steering. Next turn → Claude is interrupted with `OPERATOR STEERING: <your note>` and the block counter is reset. |
| `.claude/goal-state/heartbeat-stop.log` | Audit trail of every decision the inner pulse made. |
| `.claude/goal-state/sessions.jsonl` | One JSON line per completed, kill-switched, or anti-runaway-capped session. |
| `~/.claude/goal-sessions/active.jsonl` | The outer pulse's source of truth for what's active. |

### Benchmark snapshots

The current benchmark snapshot is in [`docs/benchmarks.md`](./docs/benchmarks.md).
It records stall-detection latency, this session's inner-pulse/Codex sprint
wall-times, and evidence-gate enforcement counts. Regenerate the raw JSON with
`scripts/benchmark-collect.sh`.

### Discord notifications

Live Discord notifications require `DISCORD_NOTIFY_WEBHOOK`. Without it, the script writes to the local log only.

`hooks/discord-notify.sh` posts only on non-running state changes: sprint pass or goal complete. It always appends the local state-change line to `.claude/goal-state/discord-notify.log`. On goal complete, it best-effort reads the matching Claude Code session JSONL under `~/.claude/projects/*/<session-id>.jsonl` and appends input/output/cache token totals plus an estimated USD cost. When `DISCORD_NOTIFY_WEBHOOK` is set, failed webhook POSTs are retried with exponential backoff and then written to `.claude/goal-state/discord-notify-deadletter.log`.

| Variable / path | Purpose |
|---|---|
| `DISCORD_NOTIFY_WEBHOOK` | Enables live Discord webhook POSTs. If unset, no network call is attempted. |
| `DISCORD_NOTIFY_MAX_ATTEMPTS` | Optional curl attempt count before dead-letter; default `3`. |
| `DISCORD_NOTIFY_TIMEOUT` | Optional curl `--max-time` in seconds; default `10`. |
| `.claude/goal-state/discord-notify-deadletter.log` | Dead-letter log for payloads that still fail after all attempts. |

---

## Capabilities and where they are tested

Every operational claim below is either covered by an integration test under
`tests/`, checked by `scripts/verify-install.sh`, or explicitly scoped as a
soft boundary.

| Capability statement | Verification |
|---|---|
| The Default-FAIL loop blocks while any result row contains `"passes": false`. | `tests/cap/eight-block-cap.sh`; `scripts/verify-install.sh --scope core` checks hook wiring/executability. |
| Direct `Write`/`Edit` flips of `test-results.json` require fresh, matching evidence. | `tests/scope-policy/evidence-gating-still-works.sh`; sprint evidence `S3_verify_gate_per_row_evidence_binding`. Bash rewrites remain the documented soft boundary. |
| `SubagentStop` writes heartbeat state without consuming the 8-block cap. | `tests/cap/eight-block-cap.sh`; sprint evidence `D2_subagentstop_does_not_eat_block_counter`. |
| `STEER.md` can interrupt a run and reset the block counter. | `tests/user-prompt-submit/steer-surfacing.sh`; `S5_steer_counter_reset_marker` evidence. |
| The OpenClaw outer pulse can detect stale sessions and trim completed sessions when setup is enabled. | `tests/outer-pulse/stall-detection.sh`, `tests/outer-pulse/completion-trim.sh`, and `tests/soak/soak.sh`. OpenClaw itself remains optional setup. |
| Discord notifications retry, dead-letter failed webhook payloads, and add best-effort cost telemetry on goal completion. | `tests/discord-notify/retry-deadletter.sh` and `tests/discord-notify/cost-telemetry.sh`. |
| Codex execution uses the pinned `CODEX_MODEL` env and refuses known-bad model values. | `scripts/verify-install.sh --scope core` checks the dry-run command and forbidden-model exits. |
| Code-heavy Codex provenance is partially enforced before result flips. | Sprint evidence `S6_generator_routes_through_codex_enforced`; this remains partial because shell-level bypasses are outside `verify-gate.sh`. |
| `fixed_scope`, `production_hardening`, and `research_only` completion policies are supported. | `tests/scope-policy/*.sh`; `scripts/verify-install.sh --scope core` checks docs, scripts, and enum handling. |
| A fresh workspace can be seeded without clobbering existing files. | `tests/init-workspace/seed.sh`; `scripts/verify-install.sh --scope core`. |
| Terminal sessions append a best-effort machine-readable session ledger. | `tests/session-ledger/append-on-stop.sh`; `scripts/verify-install.sh --scope core`. |
| Rubric files exist for strict subjective evaluation. | `scripts/verify-install.sh --scope core` checks the template, GEO example, and strict-evaluator rubric contract. |
| Benchmark snapshots and collectors are present. | `tests/benchmarks/benchmark-collect.sh`; `scripts/verify-install.sh --scope core`. |
| Launcher edits and goal registration have documented rollback paths. | `scripts/verify-install.sh --scope core` checks the README Reversibility section. |
| The repo-to-install copy is deterministic before release publication. | `scripts/sync-to-install.sh`; `scripts/verify-install.sh --scope core`; the release diff command in the next section. |

Not enforced in this plugin: automatic sprint-contract negotiation, automatic
context clearing, browser/MCP evaluation, Agent SDK translation, and unattended
launcher restart. Those decisions are tracked in
[`docs/parity-decisions.md`](./docs/parity-decisions.md).

---

## Publishing sync

Before publishing or evaluating a release from a workspace, sync the functional
package files into the installed plugin and verify no functional drift remains:

```bash
bash scripts/sync-to-install.sh
diff -rq /Users/marco/conductor/workspaces/klaus/dubai-5 /Users/marco/.claude/plugins/discord-long-running-harness \
  | grep -vE '\.claude/goal-state|evidence/|test-results\.json|PROGRESS\.md|STEER\.md|tests/|\.git/|node_modules' \
  || true
```

The sync copies `hooks/`, `scripts/`, `agents/`, `bin/`, `docs/`,
`.claude-plugin/plugin.json`, `README.md`, `CHANGELOG.md`, `CLAUDE.md`,
`LICENSE`, `SYNC.md`, and `.gitignore` as package files. It does not copy
evidence or test contents as plugin payload; it creates empty comparison
scaffolding for excluded directories so the prescribed `diff -rq | grep -vE`
release check filters nested workspace-only paths instead of top-level
directory names.

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

This helper targets Claude Code builds where local plugins are loaded with
`--plugin-dir <path>`; `scripts/verify-install.sh --scope core` checks that
your local CLI advertises that flag. The legacy `--plugin <name>` form is not
used by this harness and the helper will refuse to write it. For
Discord-router launchers (`plugin:discord-router@claude-discord-threads`), the
helper also threads `DISCORD_WORKER_PLUGIN_DIRS` through so spawned workers
inherit the same plugin directory.

If you wire it by hand instead of the helper:

```bash
exec claude \
  --plugin-dir "$HOME/.claude/plugins/discord-long-running-harness" \
  # ...your other flags
```

### Pin the Codex model

The Codex executor reads a single env file. Create it:

```bash
cat > "$HOME/.claude/codex-current-model.env" <<'ENV'
CODEX_MODEL=gpt-5.5
ENV
```

When you move to a new supported Codex model, edit that one line. No restart needed — every spawn re-reads it.

The executor refuses `gpt-5.5-codex` (rejected under ChatGPT-account auth) and `gpt-5.4` (silent default that would otherwise get used if you forget). Both fail loud with exit codes 3 and 4.

### Confirm the install

```bash
# Universal checks — should pass on any properly-installed harness:
"$HOME/.claude/plugins/discord-long-running-harness/scripts/verify-install.sh" --scope core

# Add OpenClaw outer pulse + Discord-router launcher checks (AI Heroes layout):
"$HOME/.claude/plugins/discord-long-running-harness/scripts/verify-install.sh" --scope setup

# Both (default, 34 checks total):
"$HOME/.claude/plugins/discord-long-running-harness/scripts/verify-install.sh"
```

Exit 0 on success. `--scope core` is the right command for community installs
and CI; `--scope setup` is for the OpenClaw + Discord-launcher layout AI Heroes
uses. `--scope all` (default) runs both groups.

Core checks (28): plugin dir + `.claude-plugin/plugin.json`,
`claude plugin validate` schema pass, `hooks/hooks.json` is discoverable
and every required hook command resolves under `${CLAUDE_PLUGIN_ROOT}`,
every hook script is executable, `codex-spawn.sh --dry-run` emits
`-m gpt-5.5 -c model_reasoning_effort=xhigh`, the pinned `CODEX_MODEL` env
file is readable and not forbidden, `gpt-5.4` and `gpt-5.5-codex` both
fail loud with exit 3, the active-sessions ledger exists,
`register-goal.sh --help` errors with usage, `claude --help`
advertises `--plugin-dir`, the supervisor runner is executable, and the
outer-pulse fixture tests are present. Rubric, reversibility, and synthetic
soak checks verify the strict evaluator rubric files, README rollback docs,
and `tests/soak/soak.sh`. Scope-policy checks validate the
optional enumerated `scope_policy` field, blocker ledger scripts, lifecycle
tests, docs, the benchmarks snapshot, and the benchmark collector executable.
Bootstrap checks also verify `scripts/init-workspace.sh`, the optional
`agents/planner.md`, and the `sessions.jsonl` write path in
`hooks/heartbeat-stop.sh`. Final-gate checks verify
`docs/parity-decisions.md`, `scripts/sync-to-install.sh`, and the README
capability map/audit script.

Setup checks (6, require AI Heroes layout): OpenClaw supervisor
`HEARTBEAT.md` exists, `openclaw.json` lists `goal-supervisor`, a
timestamped `openclaw.json.bak.pre-goal-supervisor.*` backup exists,
`enable-for-launcher.sh --dry-run` does not edit the launcher and would
write `--plugin-dir`, no launcher (`klaus`, `richard`, `ted-mosby`) uses
the obsolete `--plugin` flag, and the Discord-router launcher threads
`DISCORD_WORKER_PLUGIN_DIRS` through to spawned workers.

### Optional: enable the outer pulse (OpenClaw)

If you run OpenClaw, add a `goal-supervisor` agent with a 15-minute heartbeat. The repo ships a complete reference under [`docs/openclaw-supervisor/`](./docs/openclaw-supervisor/):

- `HEARTBEAT.md` — the supervisor's behavior contract (active session scan, 20-min stall threshold, Discord alert + STEER.md recovery note, atomic ledger trim on completion). Copy to `~/.openclaw/workspace-goal-supervisor/HEARTBEAT.md`.
- `openclaw.json.example` — the agent entry to merge into your `~/.openclaw/openclaw.json` `agents.list` array (id `goal-supervisor`, `heartbeat.every: 15m`, Codex GPT-5.5 with `thinkingDefault: high`).
- `workspace-README.md` — the short README that lives inside the supervisor workspace. Copy as `README.md`.

The runnable protocol fixture is [`scripts/supervisor-runner.sh`](./scripts/supervisor-runner.sh), which supports synthetic ledgers and logs for CI-safe outer-pulse tests without touching the live OpenClaw setup.

```bash
mkdir -p ~/.openclaw/workspace-goal-supervisor/state
cp docs/openclaw-supervisor/HEARTBEAT.md ~/.openclaw/workspace-goal-supervisor/HEARTBEAT.md
cp docs/openclaw-supervisor/workspace-README.md ~/.openclaw/workspace-goal-supervisor/README.md
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.bak.pre-goal-supervisor.$(date +%Y%m%dT%H%M%SZ)
# Manually merge docs/openclaw-supervisor/openclaw.json.example into agents.list.
scripts/verify-install.sh --scope setup    # exits 0 once wired
```

Without OpenClaw the harness still runs — you just lose stall detection. The inner pulse, Default-FAIL contract, kill switch, steering, and pinned Codex executor all work standalone. Use `scripts/verify-install.sh --scope core` to confirm a community-friendly install.

---

## Bootstrap a workspace

Use [`scripts/init-workspace.sh`](./scripts/init-workspace.sh) to seed a fresh workspace with the long-running goal skeleton:

```bash
scripts/init-workspace.sh "$HOME/path/to/workspace"
```

It creates `PROGRESS.md`, `test-results.json`, `STEER.md`, and `.claude/goal-state/block-count` without clobbering existing files. If the target is a clean git worktree, it commits only those seed files with `init: seed workspace for long-running goal`.

For live monitoring, see [`docs/observability.md`](./docs/observability.md) for the four-pane `watch -n 2` and `tail -F` layout.

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
.claude-plugin/plugin.json               # Plugin manifest (canonical Claude Code shape)
CLAUDE.md                                # Session instructions ("Discord is your operator console")
hooks/hooks.json                         # Canonical hook wiring (loaded by --plugin-dir)
agents/
  evaluator.md                           # Fresh-context grader (vendored from cwc; Read/Glob/Grep/Bash, no Write/Edit)
  evaluator-strict.md                    # Strict content grader (Read/Glob/Grep only; no Bash/Write/Edit)
  codex-executor.md                      # Sprint executor — invokes bin/codex-spawn.sh
  planner.md                             # Optional one-line-goal to BUILD_PLAN.md planner
  rubrics/                               # Optional strict-evaluator rubric template + examples
hooks/
  user-prompt-submit.sh                  # UserPromptSubmit — surfaces STEER.md as additional context
  heartbeat-stop.sh                      # Inner pulse — Stop + SubagentStop; ignores SubagentStop for block counting
  track-read.sh                          # PreToolUse(Read) — records evidence opens
  verify-gate.sh                         # PreToolUse(Write|Edit) — Default-FAIL contract
  kill-switch.sh                         # PreToolUse(*) — AGENT_STOP halts everything
  steer.sh                               # PreToolUse(*) — STEER.md interrupts mid-run
  commit-on-stop.sh                      # Stop — backstop commit of tracked changes
  discord-notify.sh                      # Stop — channel notification on state change
bin/
  codex-spawn.sh                         # Reads pinned CODEX_MODEL, invokes codex exec
  enable-for-launcher.sh                 # Safe rollout helper (dry-run by default, --plugin-dir aware)
scripts/
  init-workspace.sh                      # Seeds PROGRESS.md, test-results.json, STEER.md, goal-state, and initial commit
  register-goal.sh                       # Registers an active goal session
  blocker-record.sh                      # Appends open production blockers to .claude/goal-state/blockers.jsonl
  blocker-update.sh                      # Appends latest-wins blocker status updates
  benchmark-collect.sh                   # Emits JSON for docs/benchmarks.md
  sync-to-install.sh                     # Mirrors package files into the installed plugin
  audit-readme.sh                        # Checks capability map and local README links
  verify-install.sh                      # 28 core checks + 6 setup checks; --scope core|setup|all
docs/
  benchmarks.md                          # Current stall, throughput, and evidence-gate benchmark snapshot
  observability.md                       # tmux/watch panel set for live goal monitoring
  parity-gap-analysis.md                 # Primitive-by-primitive matrix vs anthropics/cwc-long-running-agents
  parity-decisions.md                    # Current closed/deferred parity rollup for release gates
  scope-policies.md                      # fixed_scope, production_hardening, research_only guide
  examples/production-hardening-prompt.md # Reference production-hardening sprint brief
  openclaw-supervisor/                   # Optional outer pulse — HEARTBEAT.md + openclaw.json.example + READMEs
```

`hooks/user-prompt-submit.sh` runs on `UserPromptSubmit`. When `STEER.md` exists and is non-empty, it emits the current steering note as hook additional context, capped at 8KB with a truncation note.

---

## Troubleshooting

**The inner pulse isn't firing.**
Confirm the plugin is loaded: in your session, the `Stop` and `SubagentStop` hooks in `hooks/hooks.json` should reference `${CLAUDE_PLUGIN_ROOT}/hooks/heartbeat-stop.sh`. If you launched without `--plugin-dir <plugin-path>`, restart. This harness does not use the legacy `--plugin <name>` form.

**The goal never terminates.**
Your `test-results.json` probably has no items, or every item is structured in a way `grep -q '"passes": false'` can't find. Open the file and check the structure matches `{ "items": [ { "passes": false, ... }, ... ] }` or any JSON that contains literal `"passes": false` strings until the goal is met.

**Codex refuses to spawn.**
Check `$HOME/.claude/codex-current-model.env`. Exit code 2 = file missing. Exit code 3 = forbidden model (`gpt-5.5-codex` or `gpt-5.4`). Exit code 4 = `CODEX_MODEL` not set. Exit code 5 = empty sprint prompt passed to `codex-spawn.sh`.

**The 8-block cap fired.**
The inner pulse enforces an anti-runaway cap: after 8 consecutive `goal-not-met` blocks on real turn boundaries (`Stop` events — `SubagentStop` events do not count toward the cap as of 0.3.0), the next turn is allowed to end. This is by design — don't fight it. Either (a) the goal is poorly specified, (b) the agent is making no progress (check `heartbeat-stop.log`), or (c) you need to `STEER.md` it in a different direction. Steering also resets the counter via a one-shot `.claude/goal-state/steered-this-turn` marker that survives the hook-ordering race in upstream `steer.sh`.

**The outer pulse never alerts.**
You don't have OpenClaw installed, or `goal-supervisor` isn't in `~/.openclaw/openclaw.json`. The inner pulse works fine without it; you just lose stall detection.

---

## Reversibility

Scripts that edit existing state write a timestamped backup before the edit.
Manual setup commands are listed here too so every modification path has a
rollback path.

### Plugin checkout

```bash
# Remove the plugin:
rm -rf "$HOME/.claude/plugins/discord-long-running-harness"
```

Rollback: reclone the repo, or restore the plugin directory from your own
filesystem backup if you had local changes.

### Workspace-to-install sync

`scripts/sync-to-install.sh` mirrors package files from the current checkout to
`$HOME/.claude/plugins/discord-long-running-harness` or `HARNESS_INSTALL_DIR`.
It overwrites the installed copy of functional files and prunes retired
package files from that install directory.

Rollback: run the same script from the previous release checkout, reclone the
plugin at the desired tag, or restore the plugin directory from your filesystem
backup.

### Pinned Codex model env

```bash
# Remove the pinned model env created during install:
rm -f "$HOME/.claude/codex-current-model.env"
```

Rollback: restore your previous env file if you overwrote one, or remove the
file if the harness created it for the first time.

### Launcher helper

`bin/enable-for-launcher.sh --apply` edits:

- `$HOME/.claude/channels/discord/start-<slug>.sh`

Before replacing the launcher it writes:

- `$HOME/.claude/channels/discord/start-<slug>.sh.bak.<ts>.enable-for-launcher`

Rollback:

```bash
mv "$HOME/.claude/channels/discord/start-<slug>.sh.bak.<ts>.enable-for-launcher" \
  "$HOME/.claude/channels/discord/start-<slug>.sh"
chmod +x "$HOME/.claude/channels/discord/start-<slug>.sh"
```

### Goal registration

`scripts/register-goal.sh` edits:

- `$HOME/.claude/goal-sessions/active.jsonl`
- `<workspace>/.claude/goal-state/goal-state.json`

Before writing, it creates:

- `$HOME/.claude/goal-sessions/active.jsonl.bak.<ts>.register-goal`
- `<workspace>/.claude/goal-state/goal-state.json.bak.<ts>.register-goal`

Rollback:

```bash
mv "$HOME/.claude/goal-sessions/active.jsonl.bak.<ts>.register-goal" \
  "$HOME/.claude/goal-sessions/active.jsonl"
mv "<workspace>/.claude/goal-state/goal-state.json.bak.<ts>.register-goal" \
  "<workspace>/.claude/goal-state/goal-state.json"
```

To remove all registered sessions instead:

```bash
rm -rf "$HOME/.claude/goal-sessions"
```

### Supervisor runner

`scripts/supervisor-runner.sh` may edit:

- `$HOME/.claude/goal-sessions/active.jsonl` when completed sessions are trimmed.
- `$HOME/.claude/goal-sessions/recovery.log` when stalled sessions are recorded.
- `$HOME/.claude/goal-sessions/completion.log` when completed sessions are recorded.

Environment overrides such as `SUPERVISOR_ACTIVE_LEDGER`,
`SUPERVISOR_RECOVERY_LOG`, and `SUPERVISOR_COMPLETION_LOG` move those write
paths for tests or custom installs. Before each file's first write in a run,
the runner creates `<path>.bak.<ts>.supervisor-runner`.

Rollback:

```bash
mv "$HOME/.claude/goal-sessions/active.jsonl.bak.<ts>.supervisor-runner" \
  "$HOME/.claude/goal-sessions/active.jsonl"
mv "$HOME/.claude/goal-sessions/recovery.log.bak.<ts>.supervisor-runner" \
  "$HOME/.claude/goal-sessions/recovery.log"
mv "$HOME/.claude/goal-sessions/completion.log.bak.<ts>.supervisor-runner" \
  "$HOME/.claude/goal-sessions/completion.log"
```

A Discord webhook alert, if configured, is external and cannot be rolled back;
the local ledger and logs remain restorable.

### OpenClaw supervisor

The README setup command already backs up `~/.openclaw/openclaw.json` before
you merge the `goal-supervisor` entry:

```bash
mv "$HOME/.openclaw/openclaw.json.bak.pre-goal-supervisor.<ts>" \
  "$HOME/.openclaw/openclaw.json"
rm -rf "$HOME/.openclaw/workspace-goal-supervisor"
rm -rf "$HOME/.openclaw/agents/goal-supervisor"
```

---

## Credits

Built on Anthropic's published work:

- [Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) (Nov 2025) — the originating research.
- [Harness design for long-running application development](https://www.anthropic.com/engineering/harness-design-long-running-apps) (Mar 2026) — the generator/evaluator loop pattern.
- [`anthropics/cwc-long-running-agents`](https://github.com/anthropics/cwc-long-running-agents) — the demo repo we vendor from (CLAUDE.md, evaluator agent, track-read/verify-gate/kill-switch/steer/commit-on-stop hooks). Apache-2.0.

The two-pulse design, the Codex executor with pinned model, and the OpenClaw supervisor are AI Heroes additions.

## License

Apache-2.0. See [LICENSE](./LICENSE).
