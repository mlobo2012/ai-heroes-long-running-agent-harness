# Harness Benchmarks

Snapshot collected on 2026-05-22T12:44:15Z with:

```bash
scripts/benchmark-collect.sh
```

Primary sources are `.claude/goal-state/heartbeat-stop.log`,
`.claude/goal-state/codex-spawn-*.log`, `.claude/.evidence-reads`, and the
on-disk `evidence/` tree. The collector emits JSON to stdout so these numbers
can be regenerated.

## Stall detection latency

Upstream baseline: no outer supervisor means stall detection latency is
unbounded, effectively infinity (∞). If the event-driven loop stops reaching turn
boundaries, only a manual operator notice detects the stall.

Harness behavior: the outer pulse runs on a clock and treats sessions as stale
when `.claude/goal-state/last-beat` is older than the configured threshold. The
AI Heroes configuration uses a 20-minute stall threshold, so a silent session is
surfaced within 20 minutes of the last inner-pulse beat.

The "150%" framing is a robustness framing, not a 2x speedup claim for the same
task. With no outer supervisor, recovery is impossible until a human notices;
with the outer pulse, recovery is possible because detection has a finite bound.
Infinity is not a finite latency baseline, so a normal percent-improvement
ratio would be dishonest.

Cost math for a 12-hour unnoticed stall:

```text
Let C = hourly cost of a stuck agent slot plus operator-delay cost.
Let R = recovery cost after the alert.

Upstream cost = 12h * C
Harness cost  = (20m / 60m) * C + R
Savings       = (11.6667h * C) - R

Example with C=$100/hour and R=30m*$100/hour:
Upstream cost = $1,200.00
Harness cost  = $33.33 + $50.00 = $83.33
Savings       = $1,116.67
```

The real win is not that the stalled task became faster. The win is that a
silent failure mode now has a bounded detection path.

## Sprint throughput

The heartbeat log records inner-pulse decision timestamps, not hook CPU runtime.
The table below therefore reports inter-pulse wall time between consecutive
`heartbeat-stop.log` entries. For this session the collector found 38 heartbeat
entries, 37 intervals, and a median inter-pulse wall time of 112 seconds.

| # | From | To | Seconds |
|---:|---|---|---:|
| 1 | 2026-05-22T09:20:44Z | 2026-05-22T09:20:49Z | 5 |
| 2 | 2026-05-22T09:20:49Z | 2026-05-22T09:34:18Z | 809 |
| 3 | 2026-05-22T09:34:18Z | 2026-05-22T09:34:27Z | 9 |
| 4 | 2026-05-22T09:34:27Z | 2026-05-22T09:36:19Z | 112 |
| 5 | 2026-05-22T09:36:19Z | 2026-05-22T09:36:24Z | 5 |
| 6 | 2026-05-22T09:36:24Z | 2026-05-22T09:36:30Z | 6 |
| 7 | 2026-05-22T09:36:30Z | 2026-05-22T09:36:34Z | 4 |
| 8 | 2026-05-22T09:36:34Z | 2026-05-22T09:36:37Z | 3 |
| 9 | 2026-05-22T09:36:37Z | 2026-05-22T09:36:39Z | 2 |
| 10 | 2026-05-22T09:36:39Z | 2026-05-22T09:36:41Z | 2 |

Codex sprint wall time is derived from each `codex-spawn-*.log` file's birth
time to mtime, with line count recorded as a sanity check. The collector found
6 Codex sprint logs and a median duration of 591 seconds.

| Sprint log | Started | Ended | Seconds | Lines |
|---|---|---|---:|---:|
| `s2-plus-s5-s6-fixups` | 2026-05-22T10:34:50Z | 2026-05-22T10:42:59Z | 488 | 18,248 |
| `s7-loop-docs-and-codex-routing` | 2026-05-22T10:59:26Z | 2026-05-22T11:10:07Z | 641 | 11,694 |
| `s8-notify-cap-prompt-hook` | 2026-05-22T11:19:32Z | 2026-05-22T11:27:28Z | 476 | 25,380 |
| `s9-outer-pulse-tests` | 2026-05-22T11:36:08Z | 2026-05-22T11:45:09Z | 541 | 16,441 |
| `s10-scope-policies` | 2026-05-22T11:54:42Z | 2026-05-22T12:06:19Z | 697 | 68,424 |
| `s11-benchmarks-and-cost` | 2026-05-22T12:19:56Z | 2026-05-22T12:44:12Z | 1,457 | 56,101 |

Data limits: this is a small-N snapshot from one session on one machine. The
`s11-benchmarks-and-cost` log was still current at collection time, so its mtime
can advance if more work is appended. These numbers are useful for harness
transparency, not as a cross-machine benchmark.

## Evidence-gate enforcement

`scripts/benchmark-collect.sh` scans Codex spawn logs for persisted
`verify-gate.sh` block JSON and scans `.claude/.evidence-reads` plus the
`evidence/` tree for evidence counts.

Snapshot:

| Metric | Value |
|---|---:|
| Verify-gate block decisions found in Codex logs | 4 |
| `.claude/.evidence-reads` lines at collection time | 0 |
| Evidence artifacts on disk | 38 |
| Blocks per evidence read | unavailable |
| Blocks per evidence artifact | 0.1053 |

The live `.claude/.evidence-reads` file is consumed and truncated by
`verify-gate.sh` after an allowed results-file edit, so the zero read-log count
is a snapshot of the current gate buffer, not a claim that no evidence was read
over the session. The durable fallback is the on-disk `evidence/` tree:
`4 / 38 = 0.1053` verify-gate blocks per evidence artifact.

Block sources found by the collector:

| Source | Line | Kind |
|---|---:|---|
| `.claude/goal-state/codex-spawn-s10-scope-policies.log` | 1060 | no evidence |
| `.claude/goal-state/codex-spawn-s11-benchmarks-and-cost.log` | 1656 | no evidence |
| `.claude/goal-state/codex-spawn-s11-benchmarks-and-cost.log` | 12572 | no evidence |
| `.claude/goal-state/codex-spawn-s2-plus-s5-s6-fixups.log` | 7651 | row binding |
