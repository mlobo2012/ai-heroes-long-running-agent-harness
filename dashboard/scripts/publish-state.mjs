#!/usr/bin/env node
import { collectHarnessBundle } from "../lib/collect-state.mjs";

const args = process.argv.slice(2);

function argValue(name, fallback = null) {
  const index = args.indexOf(name);
  if (index === -1) return fallback;
  return args[index + 1] || fallback;
}

function hasFlag(name) {
  return args.includes(name);
}

const targetUrl = argValue("--url", process.env.HARNESS_DASHBOARD_URL || "");
const token = argValue("--token", process.env.HARNESS_DASHBOARD_TOKEN || "");
const bypass = argValue("--bypass", process.env.HARNESS_DASHBOARD_BYPASS || "");
const intervalSeconds = Number(argValue("--interval", process.env.HARNESS_DASHBOARD_INTERVAL || "30"));
const once = hasFlag("--once");
const publishEmpty = hasFlag("--publish-empty") || process.env.HARNESS_DASHBOARD_PUBLISH_EMPTY === "1";
const workspace = argValue("--workspace", process.env.HARNESS_WORKSPACE || "");
const agent = argValue("--agent", process.env.HARNESS_AGENT || "");
const ledgerPath = argValue("--ledger", process.env.HARNESS_ACTIVE_LEDGER || "");

if (!targetUrl) {
  console.error("Missing --url or HARNESS_DASHBOARD_URL.");
  process.exit(2);
}
if (!token) {
  console.error("Missing --token or HARNESS_DASHBOARD_TOKEN.");
  process.exit(2);
}

async function publishOnce() {
  const bundle = await collectHarnessBundle({
    workspace: workspace || undefined,
    agent: agent || undefined,
    ledgerPath: ledgerPath || undefined,
  });
  if (!publishEmpty && !bundle.agents.length) {
    console.log(`${new Date().toISOString()} no active harness sessions; leaving last dashboard snapshot unchanged`);
    return;
  }
  const endpoint = targetUrl.replace(/\/$/, "") + "/api/ingest";
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      "authorization": `Bearer ${token}`,
      "content-type": "application/json",
      ...(bypass ? { "x-vercel-protection-bypass": bypass } : {}),
    },
    body: JSON.stringify(bundle),
  });
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`Publish failed ${response.status}: ${text}`);
  }
  const result = JSON.parse(text);
  console.log(`${new Date().toISOString()} published ${result.agents} harness session(s)`);
}

do {
  try {
    await publishOnce();
  } catch (error) {
    console.error(`${new Date().toISOString()} ${error.message || error}`);
    if (once) process.exit(1);
  }
  if (once) break;
  await new Promise((resolve) => setTimeout(resolve, Math.max(5, intervalSeconds) * 1000));
} while (true);
