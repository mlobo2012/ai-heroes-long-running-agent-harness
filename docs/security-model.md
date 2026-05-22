# Security model

This harness is built for long, autonomous runs. That makes its safety story
worth being explicit about, especially the bits that look reckless in isolation.

## `--dangerously-bypass-approvals-and-sandbox` in `bin/codex-spawn.sh`

`bin/codex-spawn.sh` runs every Codex sprint with:

```
codex exec -m "$CODEX_MODEL" -c model_reasoning_effort=xhigh \
  --dangerously-bypass-approvals-and-sandbox \
  -C "$WORKDIR" --skip-git-repo-check "$PROMPT"
```

The `--dangerously-bypass-approvals-and-sandbox` flag silences Codex's own
per-tool approval prompts and disables its built-in sandbox. We do that
*deliberately*. The reasoning:

1. **The harness IS the boundary.** A long-running autonomous loop where every
   tool call is gated by an interactive prompt is just a long-running
   non-autonomous loop. The whole point of the harness is to grind without an
   operator in the loop on every keystroke.
2. **Operator controls supersede Codex's own.** The `AGENT_STOP` kill switch,
   the `STEER.md` channel, the `verify-gate` evidence contract, and the
   8-block anti-runaway cap all run from Claude Code's hook layer (the parent
   of the Codex subagent). They are strictly above Codex's per-call prompts;
   if Marco wants Codex to stop, the kill switch stops it before Codex's own
   approval would even fire.
3. **`-C "$WORKDIR"` scopes the file boundary.** Codex's working directory is
   pinned to `$CODEX_SPAWN_WORKDIR` (which the harness sets to the goal
   workspace). Codex still has shell access to the parent filesystem, but its
   default file edits land inside the workspace.
4. **`CODEX_MODEL` is pinned with a hard refusal list.** The script exits 3
   on `gpt-5.5-codex` (rejected under ChatGPT-account auth) and `gpt-5.4`
   (silent fallback if the env var is empty). One file
   (`~/.claude/codex-current-model.env`) controls the model on the whole
   fleet. No runaway model drift.
5. **`--skip-git-repo-check` is benign.** It just skips the "this looks like
   a fresh repo, are you sure?" prompt. The repo is intentionally the
   workspace.

## What this harness does NOT defend against

To stay honest, the threat model leaves out:

- **A misaligned Codex prompt.** If the sprint brief tells Codex to
  `rm -rf ~/` and Codex complies, the boundary is your sprint brief, not the
  harness. Codex with sandbox bypass is *exactly* as trusted as the prompt
  feeding it.
- **A malicious operator.** Anyone with shell access to the host can edit
  hook files, register fake goals, or write `STEER.md` directly. The harness
  is a productivity surface, not an authentication boundary.
- **Bash sed/jq on `test-results.json`.** The `verify-gate` only hooks
  `Write|Edit`. A Bash one-liner that rewrites `test-results.json` is not
  blocked. This is the documented soft boundary of the upstream cwc design;
  `agents/evaluator-strict.md` is the partial close (drop Bash from the
  *evaluator's* tool list), but the *generator*'s Bash access is the
  productivity surface we keep.
- **Egress to the public internet.** Codex with sandbox bypass can `curl`
  anywhere. If the sprint should not need network, omit it from the brief
  and Codex's training will usually avoid it — but there is no hard block.
  For network-sensitive goals, either run on an offline host or run Codex
  in its own sandboxed mode (drop the bypass flag and accept the prompt
  cost).

## Hardening paths you can opt into

If your threat model is tighter than ours:

- **Drop the bypass flag.** Edit `bin/codex-spawn.sh` to remove
  `--dangerously-bypass-approvals-and-sandbox`. Codex's own sandbox + approval
  prompts come back. You lose autonomous runtime but gain per-call control.
- **Use a Linux `firejail` / macOS Seatbelt / Docker container** as the
  launcher's outermost process. The harness still works; the OS-level sandbox
  caps Codex's blast radius beyond what Codex's own sandbox provides.
- **Use `agents/evaluator-strict.md`** as the grader for every sprint —
  fewer surfaces for a misaligned grade to slip through.
- **Run on a dedicated machine.** The host filesystem outside the workspace
  is in the harness's blast radius. Don't run a long autonomous goal on the
  same laptop where you keep customer data.

## TL;DR

The harness traded sandbox isolation at the Codex layer for autonomous
runtime, then put real operator controls (`AGENT_STOP`, `STEER.md`,
`verify-gate`, 8-block cap, pinned model) at the parent layer. Whether the
trade is right for *your* goal depends on the sprint brief, the host
environment, and how much you trust the prompt. Read `bin/codex-spawn.sh`
and `hooks/heartbeat-stop.sh` yourself before running anything long.
