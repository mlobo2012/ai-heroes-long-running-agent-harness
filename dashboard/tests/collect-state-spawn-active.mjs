import assert from "node:assert/strict";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { collectHarnessBundle } from "../lib/collect-state.mjs";

async function makeWorkspace(root, name) {
  const workspace = join(root, name);
  const stateDir = join(workspace, ".claude", "goal-state");
  await mkdir(stateDir, { recursive: true });
  await writeFile(join(workspace, "PROGRESS.md"), "## In progress\n\n_None yet._\n## Next\n\n_None._\n", "utf8");
  await writeFile(join(workspace, "test-results.json"), '{"items":[]}\n', "utf8");
  await writeFile(join(stateDir, "goal-state.json"), '{"status":"running","session_id":"session-' + name + '","goal":"dashboard test"}\n', "utf8");
  return { workspace, stateDir };
}

async function collectOne(root, workspace, name) {
  const ledger = join(root, `${name}.jsonl`);
  await writeFile(
    ledger,
    JSON.stringify({
      session_id: `session-${name}`,
      agent: name,
      channel: "test",
      goal: "dashboard test",
      started_at: Math.floor(Date.now() / 1000) - 60,
      workspace,
      launcher: "test",
    }) + "\n",
    "utf8",
  );
  const bundle = await collectHarnessBundle({ ledgerPath: ledger });
  assert.equal(bundle.agents.length, 1);
  return bundle.agents[0];
}

const root = await mkdtemp(join(tmpdir(), "collect-state-spawn-active."));

try {
  const spawnCase = await makeWorkspace(root, "spawn-case");
  const refreshed = new Date(Date.now() - 20_000).toISOString();
  await writeFile(
    join(spawnCase.stateDir, "spawn-active.json"),
    JSON.stringify({
      pid: 4321,
      started_at: new Date(Date.now() - 120_000).toISOString(),
      last_refreshed: refreshed,
      command: "codex",
    }) + "\n",
    "utf8",
  );
  const spawnAgent = await collectOne(root, spawnCase.workspace, "spawn-case");
  assert.equal(spawnAgent.heartbeat.source, "spawn-active");
  assert.equal(spawnAgent.heartbeat.lastBeatAt, refreshed);
  assert.equal(spawnAgent.heartbeat.lastStatus, "active");
  assert.equal(spawnAgent.heartbeat.spawn.pid, 4321);
  assert.equal(spawnAgent.heartbeat.spawn.command, "codex");
  console.log("PASS - collect-state uses fresh spawn-active heartbeat");

  const stopCase = await makeWorkspace(root, "stop-case");
  const beatEpoch = Math.floor(Date.now() / 1000) - 15;
  await writeFile(join(stopCase.stateDir, "last-beat"), `${beatEpoch}\n`, "utf8");
  await writeFile(
    join(stopCase.stateDir, "last-beat-state.json"),
    '{"source":"stop-hook","session_id":"session-stop-case","hook_event_name":"Stop"}\n',
    "utf8",
  );
  const stopAgent = await collectOne(root, stopCase.workspace, "stop-case");
  assert.equal(stopAgent.heartbeat.source, "stop-hook");
  assert.equal(stopAgent.heartbeat.lastBeatAt, new Date(beatEpoch * 1000).toISOString());
  assert.equal(stopAgent.heartbeat.spawn, undefined);
  console.log("PASS - collect-state preserves stop-hook heartbeat path");
} finally {
  await rm(root, { recursive: true, force: true });
}
