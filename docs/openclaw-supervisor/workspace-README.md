# Goal Supervisor Workspace

This OpenClaw workspace exists only to run the outer pulse for Discord long-running goals.

The inner pulse lives in Claude Code Stop/SubagentStop hooks and writes workspace heartbeat state. This supervisor runs on the existing OpenClaw heartbeat cadence, reads `~/.claude/goal-sessions/active.jsonl`, and alerts only when an active goal is stale or complete.

It intentionally does not add cron jobs, scan ACP sessions broadly, or duplicate Discord delivery paths.
