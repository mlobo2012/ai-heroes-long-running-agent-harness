# Parity & Gap Analysis: AI Heroes Long-Running Harness vs Anthropic Upstream

Date: 2026-05-22
Worktree under review: `/Users/marco/conductor/workspaces/klaus/dubai-5/`
Canonical repo: `/Users/marco/conductor/repos/ai-heroes-long-running-agent-harness/`
Installed plugin: `/Users/marco/.claude/plugins/discord-long-running-harness/`

Sources compared:

1. **Anthropic March 2026 article** — *Harness Design for Long-Running Application Development* (https://www.anthropic.com/engineering/harness-design-long-running-apps). Generator/evaluator pattern, sprint contracts, design rubric.
2. **Anthropic Nov 2025 article** — *Effective Harnesses for Long-Running Agents* (https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents). `init.sh`, `claude-progress.txt`, `feature_list.json`, default-fail discipline.
3. **`anthropics/cwc-long-running-agents`** (Apache-2.0, demo repo) — `CLAUDE.md`, `evaluator.md`, `settings.json`, and 5 hooks: `kill-switch.sh`, `steer.sh`, `track-read.sh`, `verify-gate.sh`, `commit-on-stop.sh`.

---

## A. Primitive parity matrix

| # | Upstream primitive | Upstream location | Our equivalent | Status | Gap / improvement note |
|---|---|---|---|---|---|
| 1 | `/goal` overlay engagement | cwc README §"Running the loop" — `/goal every feature in PROGRESS.md is implemented, committed, and its tests pass`; March article ("simple 1-4 sentence prompt"). | `scripts/register-goal.sh` prints `/goal "<text>"` for paste; README §"Register and run a goal" L132–148. | ✅ parity | We instrument it (ledger line + goal-state.json) rather than depend on it. Honest: the script *prints* the command and tells the human to paste it; the agent does not auto-invoke it. README's `T+0` claim "The /goal overlay engages" is operator-dependent. |
| 2 | Default-FAIL contract | cwc README §"Default-FAIL contract"; Nov article §"`feature_list.json`". Every criterion starts `"passes": false`. | `hooks/verify-gate.sh` (line 22 — blocks Write/Edit on results file when evidence log empty). Inner pulse `hooks/heartbeat-stop.sh` L58 (`grep -q '"passes": false'`). | ✅ parity | Matches upstream verbatim, plus added: inner pulse uses the same `"passes": false` token to decide whether to block continuation. Our improvement = the contract drives the *loop*, not just an editorial gate. |
| 3 | `test-results.json` shape | cwc README — `{ "feature-1": { "passes": false }, "feature-2": { "passes": false } }`; Nov article — fields `description`, `steps`, `passes`. | `hooks/heartbeat-stop.sh` L58 only matches the token `"passes": false` (any structure). README §"Troubleshooting" L246–247 calls this out. | ⚠️ partial | We don't enforce or document a schema. `description` and `steps` fields from Nov article are absent. No JSON schema validation at register-goal or anywhere else. **Gap:** add a contract file (`docs/contracts/test-results.schema.json`) and have `register-goal.sh` seed an empty results file if missing. |
| 4 | Evidence-gated flips (`verify-gate`) | `claude-code-config/.claude/hooks/verify-gate.sh` — blocks Write/Edit to results file; consumes evidence on success. | `hooks/verify-gate.sh` (byte-identical to upstream). | ✅ parity | Same teaching-example caveats verbatim. We did NOT close the gaps the upstream comment block calls out (Bash sed/jq bypass, basename match, any-evidence-unlocks-any-row). |
| 5 | `track-read` evidence log | `hooks/track-read.sh` — patterns `*screenshots/*\|*-console.txt\|*-result.txt\|*.png`. | `hooks/track-read.sh` (byte-identical). | ✅ parity | Same pattern allowlist. **Gap:** does not include `*.log`, `*.json` test reports, `.har`, PDF, or HTML evidence. Limited surface for a content/blog harness. |
| 6 | `kill-switch` | `hooks/kill-switch.sh`. | `hooks/kill-switch.sh` (byte-identical). | ✅ parity | Same `${AGENT_STOP_FILE:-./AGENT_STOP}` default. Upstream uses `./AGENT_STOP` (cwd); we don't override per-workspace in inner pulse. Heartbeat-stop respects `${AGENT_STOP_FILE:-$WORKDIR/AGENT_STOP}`. Acceptable, but two scripts pick different defaults — see §D trap #1. |
| 7 | `steer` / STEER.md | `hooks/steer.sh`. | `hooks/steer.sh` (byte-identical) + the inner pulse resets the block counter when STEER.md has content (`hooks/heartbeat-stop.sh` L69–71). | ➕ we improve | We tie STEER into the loop: heartbeat resets `block-count` so steering does not get throttled by the 8-block cap. **Gap:** if STEER.md is non-empty *but* steer.sh has already consumed it earlier in the same turn, heartbeat-stop will still find an empty file. The reset depends on steer firing AFTER heartbeat. See §D trap #4. |
| 8 | `commit-on-stop` | `hooks/commit-on-stop.sh` — `git commit -am` only (tracked files). | `hooks/commit-on-stop.sh` (byte-identical). | ✅ parity | Same intentional limitation: only tracked files. README CLAUDE.md L43 reminds the agent to `git add` new files. Identical behavior — including silent failure if no `git user.name`. |
| 9 | Generator/evaluator loop | March article; cwc README §"Your `evaluator.md` as the gate" — `while grep -q '"passes": false'…` example. | `agents/codex-executor.md` (generator) + `agents/evaluator.md` (judge). No wrapper script that ties them. | ⚠️ partial | We have the agents but no orchestration script. The cwc README sketches a `while` loop wrapper; we never ship one. **Gap:** add `scripts/build-eval-loop.sh` for headless use, or document the agent-driven invocation pattern in `CLAUDE.md`. The `Stop` hook *blocks* but does not invoke evaluator — agent must call it. |
| 10 | Evaluator agent contract | `claude-code-config/.claude/agents/evaluator.md` — `tools: Read, Glob, Grep, Bash`; "Bash only for `git diff`, `git log`, and `ls`/`cat`"; first line `PASS` or `NEEDS_WORK`. | `agents/evaluator.md` (byte-identical to upstream). | ✅ parity | The frontmatter still grants `Bash`, with prose telling the agent to limit Bash to a whitelist. The README warns: "Bash is granted… is NOT a hard read-only boundary (drop it from tools if you need one)." **Gap:** we kept the soft boundary instead of a hard one. See §D trap #6. |
| 11 | Fresh-context grader | cwc README §"Fresh-context evaluator" — separate subagent invocation. | `agents/evaluator.md` (vendored). | ✅ parity | Subagent isolation depends on Claude Code spawning a fresh context for subagents. Not validated; we trust the runtime. |
| 12 | 8-block cap | NOT in cwc; NOT in either article. README §"Troubleshooting" L252: "the inner pulse respects Anthropic's platform cap". | `hooks/heartbeat-stop.sh` L81–84 — `if [ "$count" -ge 8 ]; then log_status "allow" "anti-runaway-cap"`. | ➕ we improve | We implement it; upstream doesn't. **Caveat:** the README claim that it's "Anthropic's platform cap" is unsourced — neither cwc nor the articles mention it. If the platform has a different cap (or none), our README has a credibility gap. Confirm before publication. |
| 13 | Subagent context isolation | March article §"Self-evaluation problem" — "Separating the agent doing the work from the agent judging it"; cwc README §"Fresh-context evaluator". | Inherits Claude Code runtime. Not tested in this harness. | ✅ parity | We rely on the runtime. Nothing extra. |
| 14 | Sprint/turn structure | March article §"Sprint contracts"; v2 article *removes* sprint construct. cwc README does not implement sprint contracts. | CLAUDE.md L13 "One Sprint At A Time" + agent prose. `agents/codex-executor.md` mentions sprint brief. | ⚠️ partial | No machine-readable sprint contract file. No "evaluator/generator agreed on done" handshake. The March v1 pattern (sprint contracts with `FAIL` criteria) is documented in plain English in CLAUDE.md but not enforced. **Gap:** add `SPRINT_CONTRACT.md` shape with PASS/FAIL criteria as the per-sprint counterpart to test-results.json. |
| 15 | `Stop` / `SubagentStop` hooks | cwc `settings.json` — only `Stop` runs `commit-on-stop`. | Worktree `settings.json` + repo `hooks/hooks.json` — `Stop` and `SubagentStop` BOTH run heartbeat-stop, commit-on-stop, and discord-notify. | ➕ we improve | We wire both events so subagent completions also tick the heartbeat. **Subtle bug:** when a subagent finishes inside a parent turn, both events fire — possible double commit + double heartbeat write within a few seconds. See §D trap #2. |
| 16 | Environment / secrets handling | NOT in cwc or article. | `bin/codex-spawn.sh` reads `~/.claude/codex-current-model.env`. `hooks/discord-notify.sh` reads `$DISCORD_NOTIFY_WEBHOOK`. | ➕ we improve | We isolate model pinning to a single env file with hard refusals (exit codes 2/3/4/5). No upstream equivalent. Webhook is opt-in. |
| 17 | PROGRESS.md handoff | cwc CLAUDE.md §"Always start here" — read PROGRESS.md, `git log --oneline -10`, run smoke test. | Our CLAUDE.md L8–10 — same instructions. | ✅ parity | Verbatim equivalent. **Gap:** no hook enforcement. The agent is asked to read PROGRESS.md but there's no `SessionStart` hook that fails the session if PROGRESS.md is missing. |
| 18 | Agent-maintained handoff (`commit-on-stop` + system prompt) | cwc README §"Agent-maintained handoff". | CLAUDE.md L41–43 "Commit Often". | ✅ parity | Matches. |
| 19 | `init.sh` (Nov article) | Nov article §"Initializer Agent" — initial environment setup script. | MISSING | ❌ missing | Nov article specifically calls out an `init.sh` that bootstraps `claude-progress.txt`, runs the dev server, runs initial smoke tests, and produces an initial git commit. **Gap:** add an opt-in `scripts/init-workspace.sh` that seeds `PROGRESS.md`, `test-results.json`, `STEER.md`, `.claude/goal-state/`, and an initial commit. |
| 20 | `claude-progress.txt` / structured progress log | Nov article — "claude-progress.txt that keeps a log of what agents have done". | Our `.claude/goal-state/heartbeat-stop.log` is decision-level; PROGRESS.md is human-facing. | ⚠️ partial | We have *some* of this. No machine-readable session ledger of what each session accomplished (separate from commit messages). **Gap:** add `.claude/goal-state/sessions.jsonl` written on Stop with `{session_id, started_at, ended_at, sprints_passed, evidence_reads, commits}`. |
| 21 | Per-feature one-shot mode | March article — generator works one feature at a time. | CLAUDE.md L13 prose. No enforcement. | ⚠️ partial | The agent is told to work on one sprint; nothing prevents it from drifting. **Gap:** the inner pulse could enforce "did at least one passes:false flip to passes:true this session?" before allowing exit. |
| 22 | Sprint contract negotiation | March article — "iterated until they agreed". | MISSING | ❌ missing | No sprint contract file, no two-agent agreement step. Codex-executor receives a brief; no evaluator pre-approval. **Gap:** introduce optional `SPRINT_CONTRACT.md` and a `scripts/negotiate-sprint.sh` that runs `claude --agent evaluator -p` for sign-off. |
| 23 | Browser-verified evaluator (Playwright MCP) | March article §"Frontend design" — "let the evaluator open the running app itself instead of trusting the builder's screenshots". | MISSING | ❌ missing | Our evaluator only reads screenshots the builder produced. **Gap:** add `playwright` / `chrome-devtools-mcp` to the evaluator's `tools:` in `agents/evaluator.md` as a documented option. README §"Going further" upstream mentions this. |
| 24 | Grading rubrics for subjective work | March article §"Frontend design" — four dimensions, calibration with few-shot. cwc README §"Going further" — "rubric for subjective work isn't shipped here because it's project-specific". | MISSING | ❌ missing | We have a single binary `PASS`/`NEEDS_WORK`. No rubric file, no scoring dimensions, no calibration examples. **Gap:** for content goals (the `geo-article-audit` example from our README L181), add a rubric template at `agents/rubrics/<domain>.md`. |
| 25 | Planner agent | March article §"The architecture" — planner expands 1-4 sentence brief to product spec. | MISSING | ❌ missing | We register a single one-line goal and assume the agent expands it. **Gap:** add `agents/planner.md` (optional) that produces `BUILD_PLAN.md` and seeds `test-results.json` from it. |
| 26 | Context reset vs compaction | March article §"Context resets" — fresh agent + structured handoff. | MISSING | ❌ missing | We don't manage context reset. The agent runs until Claude Code's compaction fires. **Gap:** in CLAUDE.md, document when to `/clear` and re-read PROGRESS.md. Heartbeat-stop could detect long sessions and recommend a reset. |
| 27 | Outer pulse / stall detector | NOT in upstream. | OpenClaw `goal-supervisor` with 15-minute heartbeat. Documented at README L121–125 and `docs/openclaw-supervisor/` (referenced but absent from worktree). | ➕ we improve | **Two issues:** (a) README §"Optional: enable the outer pulse" references `docs/openclaw-supervisor/` but the directory does not exist in the repo. (b) `scripts/verify-install.sh` L72–75 *requires* the supervisor file to PASS — so the 13-check verify fails on any install without OpenClaw. The README says OpenClaw is optional. Contradiction. See §D trap #5. |
| 28 | Pinned Codex executor | NOT in upstream. | `bin/codex-spawn.sh` + `~/.claude/codex-current-model.env`. | ➕ we improve | Solid: hard refusal of forbidden models, single-line bump for upgrades. README L106–112 documents exit codes 2/3/4 (and 5 for empty prompt, but only mentions 2/3/4 in troubleshooting). README L249–250 says exit 4 = `CODEX_MODEL not set` — script also has exit 5 for empty prompt. **Minor doc gap.** |
| 29 | Active-session ledger | NOT in upstream. | `~/.claude/goal-sessions/active.jsonl`. Append-only via `flock` or Python `fcntl.flock`. | ➕ we improve | Locking is correct. No reaper for completed sessions in the worktree code — CHANGELOG L19 says the supervisor "trims the ledger" but the supervisor is external. |
| 30 | Inner pulse heartbeat write | NOT in upstream. | `hooks/heartbeat-stop.sh` writes `last-beat` (epoch) + `last-beat-state.json` (session_id, background_tasks, session_crons) on every Stop / SubagentStop. | ➕ we improve | Cheap and reliable. **Subtle:** `last-beat-state.json` will only contain useful values if Anthropic's hook payload includes `session_crons` / `background_tasks` keys — neither article documents this payload. Worth confirming the shape is what the supervisor expects. |
| 31 | Discord notify | NOT in upstream. | `hooks/discord-notify.sh` posts on state change (`goal-complete`, `sprint-pass`). | ➕ we improve | Edge cases: counts via `grep -o '"passes": *true'` then `wc -l`; if results file has `"passes":true` packed without spaces *and* with spaces alternately, counts will be consistent (regex tolerates both). But if a row contains `"prior_passes": true` the count over-counts. Should anchor on a stricter shape. See §D trap #7. |
| 32 | Discord operator console | NOT in upstream. | CLAUDE.md L4–6 "Discord is your operator console". | ➕ we improve | Convention-level; no enforcement. |
| 33 | Rollout helper / dry-run | NOT in upstream. | `bin/enable-for-launcher.sh` — dry-run by default, backs up launcher. | ➕ we improve | Safety-first. Pattern is good; no equivalent upstream. |
| 34 | Install verifier | NOT in upstream. | `scripts/verify-install.sh` — 13 PASS checks. | ➕ we improve | See §D trap #5: hard-coded slug expectations (`klaus`, `richard`), supervisor presence, will FAIL outside Marco's machine. |
| 35 | SessionStart hook | Claude Code primitive, not used by cwc or us. | MISSING | ❌ missing | Could enforce PROGRESS.md read, test-results.json presence, smoke-test run on session start. Easy 30-line script. |
| 36 | UserPromptSubmit hook | Claude Code primitive, not used by cwc or us. | MISSING | ❌ missing | Could be used to surface STEER.md changes mid-turn rather than waiting for the next PreToolUse. |
| 37 | Plugin manifest hooks reference | cwc puts hooks in `.claude/settings.json` directly. | We split: `settings.json` at repo root (worktree-level test artifact) AND `hooks/hooks.json` (plugin-loaded). | ⚠️ partial | **Inconsistency:** the worktree has `settings.json` (74 lines) AND `hooks/hooks.json` is missing from the worktree but present in `repos/` and installed plugin. The plugin actually loads via `hooks/hooks.json`. The worktree-level `settings.json` is a duplicate that is *not* the canonical manifest. README L226 lists `settings.json` as "Hook wiring" but the real wiring is `hooks/hooks.json` in the installed plugin. See §D trap #3. |

Total upstream + improvement items mapped: **37**. Parity ✅: 14. Improvement ➕: 11. Partial ⚠️: 6. Missing ❌: 6.

---

## B. Article recommendations not in our code

The two articles + the cwc README contain explicit recommendations our harness does not implement. For each:

### B1. Per-feature one-feature-at-a-time discipline (enforced, not requested)

> March article: "work in sprints, picking up one feature at a time from the spec."
> cwc CLAUDE.md: "Work on exactly one item from `PROGRESS.md` per session."

Our CLAUDE.md L13 echoes this verbatim. **Nothing enforces it.** The agent could touch six features per turn and the inner pulse would not notice. *Would land in:* `hooks/heartbeat-stop.sh` — track which `"passes": true` row flipped this turn; warn if >1.

### B2. Reset on long session, structured handoff to next

> March article: "context resets…clearing the context window entirely and starting a fresh agent, combined with a structured handoff."

We never reset. We never advise the agent to `/clear`. *Would land in:* CLAUDE.md (operational guidance) plus `hooks/heartbeat-stop.sh` (detect session duration ≥ 90 min and emit a `stop_reason="session-reset-recommended"` payload).

### B3. Rubric for subjective evaluation

> March article: "calibrated the evaluator using few-shot examples with detailed score breakdowns."
> cwc README: "rubric for subjective work…isn't shipped here because it's project-specific."

Our README L181 promises *"Generate 5 GEO blog articles … Each article passes the geo-article-audit skill with zero FAILs."* — that goal type explicitly needs a rubric the evaluator can score against. We ship none. *Would land in:* `agents/rubrics/geo-article.md`, `agents/rubrics/proposal-page.md`, with a few-shot calibration block.

### B4. Sprint contract handshake

> March article: "the generator and evaluator negotiated a sprint contract: agreeing on what 'done' looked like for that chunk of work before any code was written."

Our codex-executor receives a brief but never gets evaluator pre-approval. *Would land in:* `scripts/negotiate-sprint.sh` calling `claude --agent evaluator -p "Read this sprint contract; respond OK or NEEDS_CHANGES"`.

### B5. Browser-verified evaluator (Playwright MCP)

> March article §"Frontend design": evaluator opens the running app itself via Playwright MCP.
> cwc README: "add `@playwright/mcp` or Claude in Chrome to `tools:` in `agents/evaluator.md`".

Our evaluator only Reads screenshots. *Would land in:* `agents/evaluator.md` `tools:` line, plus a `domain-skills/playwright-mcp.md` companion.

### B6. Initializer Agent (Nov article)

> Nov article: "very first agent session uses a specialized prompt that asks the model to set up the initial environment: an `init.sh` script, a claude-progress.txt file…, and an initial git commit."

`register-goal.sh` does not produce any of these. *Would land in:* expand `register-goal.sh` (or new `scripts/init-workspace.sh`) to create `PROGRESS.md`, `test-results.json`, `STEER.md`, an initial commit, and (optionally) an `init.sh` smoke test.

### B7. Live observability

> cwc README §"Watching it work": `watch -n 2 'tail -20 PROGRESS.md'`, `watch -n 5 'git log --oneline -8'`, `watch -n 2 'wc -l < .claude/.evidence-reads'`, optionally arranged in tmux.

We log to `.claude/goal-state/heartbeat-stop.log` but do not document the `watch` panel pattern. *Would land in:* README §"Components" or a new `docs/observability.md`.

### B8. Re-simplify on model upgrades

> March article: "After each model release, comment out harness pieces one at a time and see what's still load-bearing."

Our README does not advise this. With Opus 4.6 capability, sprint contracts may become noise. *Would land in:* README §"Troubleshooting" or `docs/maintenance.md`.

### B9. Agent SDK translation

> cwc README: "the shell hooks here translate one-to-one to `PreToolUse`/`Stop` callbacks" (Agent SDK).

We ship as a plugin; no SDK reference implementation. *Would land in:* `docs/agent-sdk-port.md` — useful if someone wants to embed the harness in a TypeScript agent runtime instead of Claude Code.

### B10. Unattended loop / `ralph-loop`

> cwc README §"Going further": cap session length and have an outer script start the next one.

We have the outer pulse for stall detection, but not for *spawning the next session* when the current one exits cleanly. If a goal needs 14 sprints across 10 hours and Claude Code's session caps at 5, we silently stop. *Would land in:* an OpenClaw `goal-restarter` agent or extending `goal-supervisor` to restart the launcher when a session exits with goal not met but no stall.

---

## C. Performance angles — where we can be 150% better than upstream

Upstream cwc is a teaching example. We are a production harness. The room for being faster/more reliable/more honest is large.

### C1. Stall detection latency

- **Metric:** wall-clock time from "agent stuck" to "operator notified".
- **Upstream:** ∞. There's no detector. Upstream only fires hooks on turn boundaries.
- **Ours:** 20 minutes worst case (outer pulse runs every 15 min, alerts if `last-beat` is > 20 min stale).
- **150% better claim:** anything finite is infinitely better than the upstream `∞`. The honest framing: a 6-hour session that hangs at minute 30 wastes ~5.5 hours upstream, ~20 min with us. **Quantified win:** in a 6-hour run with a 30-min hang, upstream wastes 5.5h × $20/h ≈ $110 of model time; we waste 20 min × $20/h ≈ $7. ~15× cost reduction on the failure case.
- **Measurement:** in `scripts/verify-install.sh`, add a stall-detection sim test: write `last-beat = now - 25 min`, run supervisor heartbeat, assert alert produced.

### C2. Model upgrade ergonomics

- **Metric:** number of files an operator changes to swap Codex model.
- **Upstream:** N/A — no Codex integration.
- **Ours:** **1** (`~/.claude/codex-current-model.env`).
- **Compared to a hardcoded model in each spawn script:** we trivially win.
- **Measurement:** `grep -r 'gpt-5\.[0-9]' --include='*.sh' --include='*.md' .` should match only `bin/codex-spawn.sh` (refusal list), `scripts/verify-install.sh` (assertions), and docs. Currently true; keep it true.

### C3. Operator surface

- **Metric:** time from operator decision to agent acting on it.
- **Upstream:** `STEER.md` write → next PreToolUse. If the agent is mid-Bash, that could be seconds; if it's blocked on a subagent, minutes.
- **Ours:** same, plus the block-counter reset means STEER.md takes priority over runaway-cap exit.
- **150% better claim:** *if we add a `UserPromptSubmit` hook (gap #36)*, we can also stream STEER.md updates without waiting for a tool call. That cuts mean-time-to-steer from ~30s to ~1s under low-activity turns.
- **Measurement:** seed `STEER.md` during a long Bash command; measure tool-call latency from write to consumption.

### C4. Evidence gating throughput

- **Metric:** false-positive flips (test-results says PASS, evidence shows FAIL).
- **Upstream:** `verify-gate.sh` has 3 documented gaps (Bash sed/jq bypass, basename match, any-row-unlocks-any).
- **Ours:** identical — we did not close the gaps.
- **150% better claim:** if we tighten verify-gate to require an evidence path that contains the row key (e.g., `test-results.json` row `pricing-page` requires evidence with `pricing-page` in the path), false-positive rate drops by the fraction of rows that share filename roots.
- **Measurement:** harness a 50-flip session with deliberately mismatched evidence (read login screenshot, flip checkout test). Count what gets through. Target: 0% mismatch.

### C5. Per-tool-call hook overhead

- **Metric:** ms added per Bash/Read/Write by hooks.
- **Upstream `kill-switch.sh`:** ~5 ms (single file existence check, then `cat <<JSON`).
- **Our chain (kill-switch → steer):** ~10–15 ms (each forks bash + python3 once).
- **Tightening idea:** `steer.sh` only needs the python3 fork when the file is non-empty. Already short-circuits via `[ -s "$f" ]`. Good.
- **Heartbeat-stop:** forks python3 on every Stop. For long runs at 100s of Stops, this is ~10s aggregate of python startup. Could be replaced by a tiny C utility or by `jq` when available.
- **150% better claim:** swap `python3 -c` to `jq -c` when present (already the preferred branch in heartbeat-stop). Make `track-read.sh` and `verify-gate.sh` do the same. Saves ~30ms per Read/Write × thousands of calls.
- **Measurement:** `time` a session that does 1000 Reads with and without the python3 path.

### C6. Goal termination honesty

- **Metric:** sessions that exit `goal-met` without any evidence ever opened.
- **Upstream:** trivially achievable — an agent could ship a `test-results.json` with all `true` values committed before any verify-gate fires.
- **Ours:** same. Inner pulse only checks the file contents.
- **150% better claim:** require the inner pulse to also confirm the evidence log has been non-empty at least once in the session OR that the commit-on-stop log shows at least one verify-gate-allowed write. Refuse to mark `goal-met` otherwise.
- **Measurement:** plant `test-results.json` with all true at session start. Run heartbeat-stop. Should NOT exit `allow goal-met`.

### C7. Subagent boundary enforcement

- **Metric:** can the evaluator actually write?
- **Upstream:** the evaluator agent frontmatter grants `Bash`. Prose says "Bash only for git diff/log/ls/cat" but Bash can run anything.
- **Ours:** same.
- **150% better:** ship a second evaluator file (`evaluator-strict.md`) with `tools: Read, Glob, Grep` only. Make it the default for content-domain goals where no Bash is needed.
- **Measurement:** assert `tools:` line in `evaluator-strict.md` does not contain `Bash|Write|Edit|NotebookEdit`.

### C8. Cost telemetry

- **Metric:** $ spent per goal, surfaced in Discord on completion.
- **Upstream:** nothing.
- **Ours:** nothing. `discord-notify.sh` posts "Goal complete:" but no cost.
- **150% better:** parse `~/.claude/projects/<id>/<session>.jsonl` after Stop, sum `usage.input_tokens` × pricing + `usage.output_tokens` × pricing, post to Discord. Even ±20% accuracy beats nothing.
- **Measurement:** verify-install adds a step that reads a synthetic session JSONL and asserts a cost ≥ 0 is parsed.

### C9. Outer pulse fan-out

- **Metric:** number of active sessions a single supervisor can monitor without polling cost.
- **Upstream:** N/A.
- **Ours:** linear in active sessions per 15-minute wake. Already cheap (≤ 100 active sessions = ≤ 100 file reads every 15 min).
- **150% better:** instead of polling, watch `~/.claude/goal-sessions/active.jsonl` mtime with `fswatch`. Wake only when it changes OR when a `last-beat` age crosses 20 min — a *cron + fswatch hybrid* cuts idle wakes to zero.
- **Measurement:** in a 24-hour soak test, count supervisor wakes. Polling = 96. Hybrid = ~`N + alerts_fired`.

### C10. Concurrency-safe ledger

- **Metric:** torn writes when two register-goal.sh run concurrently.
- **Upstream:** N/A.
- **Ours:** `flock` if present, else `fcntl.flock` via Python. Both safe.
- **150% better:** already strong. No improvement needed unless the ledger grows past 10k lines (then a tombstone scheme would beat append-only).

---

## D. Subtle traps & bugs

### D1. `AGENT_STOP` path drift between hooks

- `hooks/kill-switch.sh` defaults to `${AGENT_STOP_FILE:-./AGENT_STOP}` (cwd-relative).
- `hooks/heartbeat-stop.sh` L49 defaults to `${AGENT_STOP_FILE:-$WORKDIR/AGENT_STOP}` (workspace-absolute).

If the agent runs from a sub-directory of the workspace, `kill-switch` looks for `./AGENT_STOP` relative to `pwd` (sub-directory) but `heartbeat-stop` looks at the workspace root. An operator who `touch <workspace>/AGENT_STOP` may get the workspace-rooted heartbeat to honor it on next Stop but `kill-switch` will not block in-progress tool calls. **Fix:** make `kill-switch.sh` also prefer `${WORKDIR:-$PWD}/AGENT_STOP`.

### D2. Double-fire on `Stop` + `SubagentStop`

When a subagent finishes inside a parent turn, Claude Code emits `SubagentStop` (we run heartbeat + commit + discord-notify), and a moment later the parent turn ends emitting `Stop` (we run heartbeat + commit + discord-notify *again*).

- `commit-on-stop.sh` is idempotent (no diff → no commit).
- `discord-notify.sh` deduplicates via `LAST_STATUS_FILE` (status change required) — safe.
- `heartbeat-stop.sh` writes `last-beat` twice within seconds — harmless.
- The block counter increments twice unless STEER.md or goal-met short-circuits. **This is the bug.** A subagent that finishes mid-turn burns 2 of the 8 blocks. Long sessions hit `anti-runaway-cap` artificially fast.

**Fix:** in heartbeat-stop, distinguish `Stop` from `SubagentStop` (the payload carries `hook_event_name`). Only increment `block-count` on `Stop`.

### D3. Worktree `settings.json` is not the canonical manifest

Worktree has `settings.json` at the root (74 lines, full hook wiring). The repo also has `hooks/hooks.json`. The installed plugin has `hooks/hooks.json`. Claude Code's plugin loader reads `hooks/hooks.json` (per the standard plugin layout). The root `settings.json` is dead code — useful for local testing only.

- README L218–219 lists `settings.json` as "Hook wiring" without mentioning `hooks/hooks.json`.
- This will confuse anyone who reads the README and tries to edit hooks.
- `.gitignore` doesn't exclude `settings.json`, so both ship.

**Fix:** either (a) collapse to one file with documentation about which is canonical, or (b) delete the root `settings.json` and have plugins/install copy `hooks/hooks.json` only. Update README accordingly.

### D4. `verify-gate.sh` evidence consumption race

The verify-gate consumes the log (`: > "$log"`) AFTER allowing the write. If two Write calls fire in the same turn (or near-simultaneously across subagent + parent), the second one may see empty log and be blocked unfairly. In practice Claude Code serializes tool calls; the risk is low. Worth a documented note.

### D5. `verify-install.sh` is Marco-specific

`scripts/verify-install.sh` hardcodes:
- `~/.claude/channels/discord/start-klaus.sh` (L99)
- `klaus` and `richard` launcher paths (L108)
- `~/.openclaw/workspace-goal-supervisor/HEARTBEAT.md` (L72)
- `goal-supervisor` agent in `~/.openclaw/openclaw.json` (L76–82)

A community user installing the plugin per the README will FAIL 4+ checks. README L114–119 advertises the script as "13 PASS checks, exit 0. If any FAIL, fix before going live." This is misleading. **Fix:** split into `verify-install-core.sh` (universal — plugin, env, hooks, codex) and `verify-install-openclaw.sh` (Marco-specific outer pulse).

### D6. Evaluator soft Bash boundary

`agents/evaluator.md` frontmatter: `tools: Read, Glob, Grep, Bash`. Prose: "Use Bash only for `git diff`, `git log`, and `ls`/`cat`." A misaligned model can run `bash -c 'echo "passes": true > test-results.json'` and bypass verify-gate (Bash isn't matched by `Write|Edit`). The README's `agents/evaluator.md` line in our `README.md` L221 says "Read/Glob/Grep/Bash only, no Write" — but **Bash is Write equivalent**. Documentation lie. **Fix:** drop Bash and use the diff-only `git` skill via a wrapper, or accept the hole and update README to say "Bash granted; verify-gate does not cover Bash."

### D7. `discord-notify.sh` over-counting

L34–35 counts `"passes": *true|false` via `grep -o`. If a JSON file ever contains `"prior_passes": true` or `"sub_passes": false` (e.g., nested feature decomposition), counts skew. The Nov-article schema includes a `steps` array — fine. But once anyone adds a `previous_passes` field, the count breaks silently. **Fix:** require `grep -o '^\s*"passes"\s*:'` after `jq`-flatten, or use `jq 'recurse|.passes? // empty'`.

### D8. `register-goal.sh` re-registration

If a goal is re-registered for the same workspace, `goal-state.json` is overwritten with a *new* `session_id`. But `~/.claude/goal-sessions/active.jsonl` is *appended* — so two lines exist for the same workspace. Outer pulse sees both and will report on both. **Fix:** either dedupe-by-workspace on append, or have `register-goal.sh` first reap any existing line for the same workspace path before appending.

### D9. `commit-on-stop` silent failure

Comment in the file: "Fails silently if commit can't be made (no git user.name, hook rejects, etc)." We inherit this. If user has no global `user.email`/`user.name` set, an entire long-running session produces zero commits — and the operator finds out on day 2. **Fix:** the inner pulse could check `git config user.name` once on first heartbeat and surface a Discord notification if missing.

### D10. `codex-spawn.sh` exit-code documentation drift

Script defines exit codes 2 (missing env file), 3 (forbidden model), 4 (CODEX_MODEL not set), 5 (empty prompt). README §"Troubleshooting" L249–250 documents 2, 3, 4 only. Add 5.

### D11. README §"Optional: enable the outer pulse" claims `docs/openclaw-supervisor/` exists

README L123–125: "The repo includes a reference `HEARTBEAT.md` and the openclaw.json shape under `./docs/openclaw-supervisor/`". **The directory does not exist in the repo** (confirmed: only `.claude-plugin/`, `agents/`, `bin/`, `hooks/`, `scripts/` plus root files). Either ship the directory or delete the claim.

### D12. CHANGELOG L19 promises supervisor behavior that lives outside the repo

The CHANGELOG entry "OpenClaw outer pulse: 15-minute `goal-supervisor` heartbeat …" describes work in `~/.openclaw/`, not in this repo. Publishing CHANGELOG promises *features the repo cannot deliver standalone* is technically misleading for anyone who clones the repo without OpenClaw. **Fix:** in CHANGELOG, scope it ("requires OpenClaw") or split into `CHANGELOG-supervisor.md` shipped alongside.

### D13. `hooks/heartbeat-stop.sh` write_state_snapshot last-resort fallback

If neither `jq` nor `python3` is available (L42–43), the script writes a hardcoded JSON without `session_id` populated. Supervisor relies on the snapshot to identify the session; missing `session_id` means the supervisor can't correlate. Acceptable graceful degradation, but worth documenting that bash-only systems lose the correlation.

### D14. STEER.md / heartbeat ordering

`heartbeat-stop.sh` runs on `Stop`. `steer.sh` runs on `PreToolUse(*)`. STEER.md is consumed by steer.sh; heartbeat-stop reads `[ -s STEER.md ]` to decide whether to reset the counter. If steer fires earlier in the turn and consumes STEER.md, heartbeat-stop at end-of-turn sees an empty file and *does NOT reset the counter*. The README L42 says "next turn → inner pulse reads STEER.md, resets the block counter". That's incorrect on a turn where the agent issued any tool call after STEER landed. **Fix:** either drop the heartbeat-stop STEER reset (counter resets next turn via steer-induced new prompt) or have steer.sh leave a marker file (`./.claude/goal-state/steered-this-turn`) that heartbeat consumes.

---

## E. Recommended sprint order

Goal: knock out parity gaps first, then performance wins, then polish. Each sprint produces evidence and flips one `test-results.json` row.

### Sprint 1 — Fix install-verifier and verify-gate documentation honesty (S)

**Goal:** make a fresh clone pass verify-install on a machine without OpenClaw.
- Files: `scripts/verify-install.sh` → split into `verify-install-core.sh` (9 universal checks) + `verify-install-openclaw.sh` (4 supervisor checks). Update README L114–119 to reference both. Remove or qualify the README claim about `docs/openclaw-supervisor/`. Update CHANGELOG L8 (currently "13 PASS checks") to the split.
- Files: `README.md` §"Components" — clarify `settings.json` vs `hooks/hooks.json`.
- **Pass signal:** `./scripts/verify-install-core.sh` exits 0 on a machine with no OpenClaw. `./scripts/verify-install-openclaw.sh` exits 0 only when OpenClaw + goal-supervisor configured.
- **Complexity:** S

### Sprint 2 — Fix `AGENT_STOP` path drift and double-fire counter bug (S)

**Goal:** kill-switch honors workspace-rooted AGENT_STOP; subagent stop does not eat the block counter.
- Files: `hooks/kill-switch.sh` — change default to `${AGENT_STOP_FILE:-${WORKDIR:-$PWD}/AGENT_STOP}` (consistent with heartbeat).
- Files: `hooks/heartbeat-stop.sh` — read `hook_event_name` from stdin payload; only increment counter when event is `Stop` (not `SubagentStop`). Snapshot to `last-beat` still on both.
- Test: a synthetic session that fires 10 SubagentStops and 1 Stop should leave block-count = 1, not 11.
- **Pass signal:** `test-results.json` row "stop-subagent-bug" goes from `false` to `true` after a unit test sequence.
- **Complexity:** S

### Sprint 3 — Decouple worktree-level `settings.json` and `hooks/hooks.json` (S)

**Goal:** one canonical hook manifest; one developer-only settings file.
- Files: delete worktree `settings.json` OR move it to `tests/fixtures/settings.json` if needed for local testing. Confirm `hooks/hooks.json` is loaded by the plugin runtime.
- Files: `README.md` §"Components" — list `hooks/hooks.json` as the canonical manifest.
- **Pass signal:** `find . -name "settings.json"` returns 0 hits at repo root (or only a test fixture). Installed plugin still picks up hooks (manual `claude --plugin` test, evidence = log line from `track-read.sh` on a deliberate Read).
- **Complexity:** S

### Sprint 4 — Add SessionStart hook for handoff hygiene (S)

**Goal:** sessions start by reading PROGRESS.md and confirming test-results.json exists.
- Files: `hooks/session-start.sh` — if `PROGRESS.md` missing, create skeleton; if `test-results.json` missing, exit with `decision: "block"` + advice. Wire into `hooks/hooks.json` under `SessionStart`.
- **Pass signal:** boot a fresh workspace; session is blocked until both files exist. `test-results.json` row "session-start-bootstrap": true.
- **Complexity:** S

### Sprint 5 — Tighten `verify-gate` to per-row evidence binding (M)

**Goal:** close one of the three documented upstream gaps. An evidence read for `pricing` should not unlock the `checkout` row.
- Files: `hooks/track-read.sh` — write evidence reads as `<path>\t<row_hint>` where `row_hint` is the longest filename token that matches a known test-results row name.
- Files: `hooks/verify-gate.sh` — on Write/Edit to results file, diff the proposed content against the current content; for every row that changed `false → true`, require the evidence log to contain a row_hint matching that row name. Consume only the matched lines.
- **Pass signal:** synthetic test — write `pricing-screenshot.png`, attempt to flip `checkout` row → blocked. Flip `pricing` row → allowed. Evidence: `screenshots/sprint-5-verify-gate.png`.
- **Complexity:** M (introduces JSON diffing in bash; consider Python helper).

### Sprint 6 — Ship a strict evaluator variant + browser-MCP evaluator option (M)

**Goal:** close the evaluator soft-bash gap; document the Playwright route.
- Files: `agents/evaluator-strict.md` — `tools: Read, Glob, Grep`. No Bash, no Write, no Edit.
- Files: `agents/evaluator-browser.md` — adds `chrome-devtools-mcp` (or `@playwright/mcp` if available); evaluator can open the running app itself.
- Files: README L220 component table — list both variants.
- **Pass signal:** `grep -E '^tools:.*Bash' agents/evaluator-strict.md` returns nothing. `test-results.json` row "strict-evaluator": true.
- **Complexity:** M

### Sprint 7 — Initializer + planner skeletons (M)

**Goal:** ship the Nov article's `init.sh` pattern and the March article's planner.
- Files: `scripts/init-workspace.sh` — seeds `PROGRESS.md` (4 sections), `test-results.json` (empty `items: []`), `STEER.md` (empty), `.claude/goal-state/`, and runs `git add . && git commit -m "init: harness scaffold"` if the workspace is a git repo.
- Files: `agents/planner.md` — optional agent that expands a 1-line goal to a multi-feature `BUILD_PLAN.md` and seeds `test-results.json` rows.
- Files: `scripts/register-goal.sh` — gain `--init` flag that runs `init-workspace.sh` first.
- **Pass signal:** `./scripts/init-workspace.sh /tmp/test-ws` produces a workspace where `register-goal.sh` succeeds with no manual setup. test-results row "init-flow": true.
- **Complexity:** M

### Sprint 8 — Rubric scaffolding for content goals (M)

**Goal:** ship one concrete rubric (geo-article) and a template for others.
- Files: `agents/rubrics/geo-article.md` — four-dimension rubric with calibrated FAIL/PASS examples.
- Files: `agents/rubrics/_template.md` — the schema for new rubrics.
- Files: `agents/evaluator-strict.md` — accepts an optional rubric path via prompt.
- **Pass signal:** evaluator-strict + geo-article rubric returns `PASS` on a known-good article fixture and `NEEDS_WORK` on a deliberately weak one. Evidence: two transcripts in `tests/fixtures/`.
- **Complexity:** M

### Sprint 9 — Cost telemetry on Stop (M)

**Goal:** when a goal completes, Discord notification includes input/output token counts and an estimated $ cost.
- Files: `hooks/discord-notify.sh` — when status changes to `goal-complete`, parse the most recent `~/.claude/projects/<id>/<session>.jsonl` for usage; format an extended message.
- Files: optional `scripts/cost-estimate.sh` — pricing table per model; reused by Discord notify.
- **Pass signal:** synthetic JSONL fixture → notify produces a message with `input=N, output=M, cost≈$X`. test-results row "cost-telemetry": true.
- **Complexity:** M

### Sprint 10 — Tighten count regex in `discord-notify.sh` and `heartbeat-stop.sh` (S)

**Goal:** stop over-counting when a future schema adds `prior_passes` or `sub_passes`.
- Files: both hooks — replace `"passes"\s*:` greedy match with anchored `^\s*"passes"\s*:` or `jq` traversal when present.
- **Pass signal:** synthetic results file with `{"items":[{"passes":true}],"prior_passes":false}` counts as 1 true, 0 false (not 1 true, 1 false).
- **Complexity:** S

### Sprint 11 — Re-registration safety (S)

**Goal:** `register-goal.sh` deduplicates by workspace.
- Files: `scripts/register-goal.sh` — before append, scan `active.jsonl` for lines with same `workspace`; if found, rewrite via temp file (locked).
- **Pass signal:** double-register the same workspace; `wc -l` of `active.jsonl` increases by 1, not 2, and the new `session_id` is the surviving line. test-results row "register-dedupe": true.
- **Complexity:** S

### Sprint 12 — Session ledger for cross-session continuity (M)

**Goal:** Nov article's `claude-progress.txt` pattern, machine-readable.
- Files: `.claude/goal-state/sessions.jsonl` written on Stop with one line per session: `{session_id, started_at, ended_at, sprints_passed, evidence_reads, commits, exit_reason}`.
- Files: heartbeat-stop appends a session-summary line when status flips to `goal-complete` or when `AGENT_STOP` is honored.
- **Pass signal:** complete one synthetic goal; `sessions.jsonl` has exactly one well-formed line. test-results row "session-ledger": true.
- **Complexity:** M

### Sprint 13 — UserPromptSubmit hook to surface STEER mid-turn (S)

**Goal:** cut steer-to-act latency from worst-case minutes to ~1s.
- Files: `hooks/user-prompt-submit.sh` — same logic as `steer.sh` but fires on every UserPromptSubmit.
- Files: `hooks/hooks.json` — wire new event.
- **Pass signal:** seed STEER.md, then submit a no-op prompt; agent receives `OPERATOR STEERING:` reason on the next message, not waiting for a tool call. Evidence: transcript capture.
- **Complexity:** S

### Sprint 14 — Fix the STEER counter-reset ordering bug (S)

**Goal:** heartbeat-stop correctly resets block counter on turns where STEER.md was consumed.
- Files: `hooks/steer.sh` — on consumption, also `touch .claude/goal-state/steered-this-turn`.
- Files: `hooks/heartbeat-stop.sh` — also reset counter if the marker exists; remove the marker.
- **Pass signal:** synthetic test — write STEER.md, run a fake PreToolUse + Stop; counter resets to 0 even though STEER.md is empty at Stop time. test-results row "steer-counter-fix": true.
- **Complexity:** S

### Sprint 15 — Update README to remove unsourced claims and missing-doc references (S)

**Goal:** the README is honest about what ships and what's external.
- Files: `README.md` — qualify or source the "Anthropic's platform cap" claim (L252) or rename it (e.g., "our anti-runaway cap"). Either ship `docs/openclaw-supervisor/HEARTBEAT.md` or remove the reference. Document `settings.json` vs `hooks/hooks.json`. Add exit code 5 to troubleshooting. Add the Going-Further section quoting cwc's upgrade-resimplify advice.
- **Pass signal:** `grep -E "platform cap|openclaw-supervisor" README.md` shows only sourced or scoped uses. test-results row "readme-honest": true.
- **Complexity:** S

### Sprint 16 — Soak test + observability docs (M)

**Goal:** prove the harness can sustain a 6-hour goal with 1 stall recovery.
- Files: `tests/soak/soak.sh` — drives a synthetic 6-hour scenario with one injected hang at minute 90.
- Files: `docs/observability.md` — the cwc-style `watch -n 2` panel set, tmux layout, alert routing.
- **Pass signal:** soak.sh exits 0; supervisor logs show 1 stall alert + 1 recovery. test-results row "soak-test": true. Evidence: `screenshots/soak-final.png` + `tests/soak/soak.log`.
- **Complexity:** M

---

## Top 10 most important gaps (priority summary)

1. **`verify-install.sh` is Marco-specific** — fails on any community install. Sprint 1.
2. **`Stop` + `SubagentStop` double-fire eats the block counter** — long sessions hit cap artificially fast. Sprint 2.
3. **README references nonexistent `docs/openclaw-supervisor/`** — install instructions are broken on copy-paste. Sprint 1/15.
4. **Worktree `settings.json` is dead code masquerading as the manifest** — confuses any maintainer. Sprint 3.
5. **`verify-gate` evidence is global, not per-row** — false positives easy. Sprint 5.
6. **Evaluator soft Bash boundary** — `tools: Bash` defeats verify-gate. Sprint 6.
7. **No SessionStart enforcement of PROGRESS.md / test-results.json bootstrap** — fresh runs silently start broken. Sprint 4 / 7.
8. **No rubric for subjective goals** — README promises GEO-article evaluation we cannot grade. Sprint 8.
9. **STEER counter-reset depends on hook ordering that may not hold** — README L42 wrong on turns with tool calls. Sprint 14.
10. **`register-goal.sh` re-registration creates duplicate active.jsonl lines** — supervisor reports twice. Sprint 11.

---

## Appendix: file-by-file inventory

### Upstream cwc (12 files)

| File | Role |
|---|---|
| `README.md` | Top-level overview, quality-loop table, Going-Further pointers. |
| `claude-code-config/README.md` | Sub-readme; very short pointer back. |
| `claude-code-config/.claude/CLAUDE.md` | Session conventions: PROGRESS.md, one-feature-at-a-time, proof-before-passing, commit-often. |
| `claude-code-config/.claude/settings.json` | Hook wiring: PreToolUse(*) → kill-switch + steer; PreToolUse(Read) → track-read; PreToolUse(Write|Edit) → verify-gate; Stop → commit-on-stop. |
| `claude-code-config/.claude/agents/evaluator.md` | Fresh-context grader contract; first-line PASS/NEEDS_WORK. |
| `claude-code-config/.claude/hooks/kill-switch.sh` | Block while AGENT_STOP exists. |
| `claude-code-config/.claude/hooks/steer.sh` | Read STEER.md, surface as block reason, clear. |
| `claude-code-config/.claude/hooks/track-read.sh` | Append evidence-file Read events to log. |
| `claude-code-config/.claude/hooks/verify-gate.sh` | Block Write/Edit on results file when evidence log empty; consume on success. |
| `claude-code-config/.claude/hooks/commit-on-stop.sh` | `git commit -am session checkpoint`. |
| `LICENSE` | Apache-2.0. |
| `.gitignore` | macOS / editor cruft. |

### Our harness (21 files in repo, 19 in worktree)

| File | Status vs upstream |
|---|---|
| `.claude-plugin/plugin.json` | New (plugin manifest). |
| `CHANGELOG.md` | New. Has misleading claims (D12). |
| `CLAUDE.md` | Vendored + AI Heroes additions (Discord operator console, codex-executor, operator controls). |
| `LICENSE` | Apache-2.0 (matches). |
| `README.md` | New. Has misleading claims (D11, B11). |
| `SYNC.md` | New (two-remote workflow). |
| `agents/codex-executor.md` | New (sprint executor wrapper). |
| `agents/evaluator.md` | Vendored byte-for-byte from upstream. |
| `bin/codex-spawn.sh` | New (pinned-model runner). |
| `bin/enable-for-launcher.sh` | New (launcher rollout helper). |
| `hooks/commit-on-stop.sh` | Byte-identical to upstream. |
| `hooks/discord-notify.sh` | New (status notify). |
| `hooks/heartbeat-stop.sh` | New (inner pulse). |
| `hooks/hooks.json` | New (plugin hook manifest). Only in `repos/` and `~/.claude/plugins/`, NOT in worktree. |
| `hooks/kill-switch.sh` | Byte-identical to upstream. |
| `hooks/steer.sh` | Byte-identical to upstream. |
| `hooks/track-read.sh` | Byte-identical to upstream. |
| `hooks/verify-gate.sh` | Byte-identical to upstream. |
| `scripts/register-goal.sh` | New (goal registration). |
| `scripts/verify-install.sh` | New (13 checks; 4+ are Marco-specific). |
| `settings.json` (worktree only) | Duplicate of `hooks/hooks.json` at root. Confusing (D3). |

End of report.
