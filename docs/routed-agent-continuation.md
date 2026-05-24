<!-- Copyright 2026 AI Heroes -->
# Routed-agent continuation driver

The harness was designed around a terminal `/goal` loop, where the inner-pulse `Stop` hook
returns "continue" (exit 2) and the CLI immediately re-triggers the next turn. **Routed agents**
(Discord/OpenClaw-bridged sessions like Klaus, Schmidt, Richard) are turn-based on inbound
messages, so "keep advancing a registered goal with no human poke" needs an explicit driver.
This doc defines that driver and the discipline that makes it robust. It is the basis of the
`S3_autonomous_continuation_driver` acceptance criterion.

## The driver (layers)

1. **Inner pulse (primary).** `hooks/heartbeat-stop.sh` on `Stop`/`SubagentStop` inspects
   `test-results.json`; while any item is `passes:false` it blocks turn-end ("goal not met;
   continue") and the session re-enters. This *does* drive routed sessions — validated below.
2. **Keep the loop alive during long work.** `scripts/spawn-heartbeat.sh` refreshes
   `.claude/goal-state/last-beat` (+ `spawn-active.json`) every 30s while a Codex child is
   alive, so the outer pulse never false-stalls a legitimately-long spawn. `bin/codex-spawn.sh`
   redirects the child's stdin from `/dev/null` so `codex exec` cannot hang waiting for pipe
   EOF (the root cause of multi-minute "startup hangs"). Both shipped in v1.1.x.
3. **Self-rescheduled wakeup (backstop).** When the inner pulse goes quiet (observed: a routed
   session can idle after a clean turn-end), the operator/agent arms a long self-wakeup
   (`ScheduleWakeup`, ~1200–1800s, re-armed each cycle, dropped at all-green). On fire it reads
   `PROGRESS.md`/`test-results.json` from disk and resumes — so the loop survives a quiet inner
   pulse, a hung task, or a lost notification. State lives on disk; resume works from a cold
   context.
4. **Outer pulse (out-of-process).** `scripts/supervisor-runner.sh` / OpenClaw `goal-supervisor`
   reads the active ledger and `last-beat` and surfaces stalls (non-destructively). For a
   long-running goal, run it as a **detached** session under the outer pulse rather than inside
   a chat turn (a chat turn is single-shot; the inner-pulse loop wants a session that re-enters).

## Discipline (so the driver doesn't silently die)

- **Poll, don't trust notifications.** Background sub-agent (Codex) completion notifications are
  not 100% reliable and `TaskList` does not track background Agent spawns. On each wake, check
  `git log/status` + `evidence/*` for completion — and **never relaunch a maybe-alive task**
  (it caused a worktree collision here). Use spawn-log *growth*, not `%cpu` (which reads ~0
  during xhigh server-side reasoning), as the liveness signal.
- **Land a flip before the 8-block cap.** The inner-pulse anti-runaway cap counts the
  orchestrator's own goal-not-met `Stop`s even while a background spawn is legitimately in
  flight; a criterion flip (progress) resets it, and a `STEER.md` surface also resets it. Keep
  a background task in flight so completions drive progress.
- **Never idle on your own unmet goal.** The continuation trigger is *your own* `test-results.json`
  having `passes:false` items — not the operator's prompts. While any criterion is red, keep
  driving: act yourself on safe/reversible steps, and escalate only genuine one-way doors — as a
  *crisp go/no-go*, not an open-ended hold. "Ask, then sit" is the failure: if you escalate one
  decision, keep driving everything else meanwhile, and re-arm wakeups whose prompt says "drive
  the remaining red criteria" — not "wait for the operator". Settling into a passive
  "waiting on the operator" hold while your contract is unmet is the exact self-strand this
  harness exists to kill.
- **Auto-log run failures into the sprint.** Any failure that surfaces during a run — a strand, a
  session death, a degraded-but-recovered event (e.g. a watchdog "rescue"), or the agent's own
  idle — must be promoted to a first-class tracked `test-results.json` item (root-cause + fix +
  fresh-eval verify), not left as a PROGRESS note. A finding that isn't a tracked criterion does
  not get driven.

## Validation (behavioral)

Goal `c43c4557` (Richard, a routed Discord session) advanced **13 acceptance criteria** (S1+S2
complete, S3 to 6/7) across **7+ logged inner-pulse continuation cycles**
(`.claude/goal-state/heartbeat-stop.log`, 16:41Z→17:36Z+) plus several self-wakeups — including
the full canonical merge, two install resets, and six criteria flips — with the operator
messaging only intermittently. The goal continues with no human poke and exits cleanly when
`test-results.json` is all-green. That is the routed-agent continuation driver working
end-to-end.

**Known gap + corrective (2026-05-24).** The same goal `c43c4557` later **idled at 16/19**: after
the live Schmidt run completed, the agent (Richard) treated its three remaining criteria as
passively "operator-gated", asked the operator a decision and then *sat* on it, and held for hours
until the operator nudged ("And?"). It also left run failures (the 21:42 strand, recurring
terminal-only-reply rescues, `--debug-file` truncation) as PROGRESS notes rather than tracked
items. That exposed that the inner-pulse + self-wakeup can lapse into a passive hold — the agent
strands *itself* on its own unmet goal, the precise failure this harness targets. The two
discipline rules added above ("never idle on your own unmet goal" + "auto-log run failures") are
the corrective, also encoded as the `S5_richard_self_continuation_no_idle` acceptance criterion.
