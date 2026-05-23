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

## Validation (behavioral)

Goal `c43c4557` (Richard, a routed Discord session) advanced **13 acceptance criteria** (S1+S2
complete, S3 to 6/7) across **7+ logged inner-pulse continuation cycles**
(`.claude/goal-state/heartbeat-stop.log`, 16:41Z→17:36Z+) plus several self-wakeups — including
the full canonical merge, two install resets, and six criteria flips — with the operator
messaging only intermittently. The goal continues with no human poke and exits cleanly when
`test-results.json` is all-green. That is the routed-agent continuation driver working
end-to-end.
