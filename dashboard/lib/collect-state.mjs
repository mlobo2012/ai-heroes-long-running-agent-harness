import { execFile } from "node:child_process";
import { promises as fs } from "node:fs";
import { basename, join, resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const defaultActiveLedger = `${process.env.HOME || "/Users/marco"}/.claude/goal-sessions/active.jsonl`;

function statePath(workspace, ...parts) {
  return join(workspace, ".claude", "goal-state", ...parts);
}

async function readText(path, fallback = "") {
  try {
    return await fs.readFile(path, "utf8");
  } catch {
    return fallback;
  }
}

async function readJson(path, fallback = null) {
  const text = await readText(path, "");
  if (!text.trim()) return fallback;
  try {
    return JSON.parse(text);
  } catch {
    return fallback;
  }
}

async function statSafe(path) {
  try {
    return await fs.stat(path);
  } catch {
    return null;
  }
}

async function git(workspace, args, fallback = "") {
  try {
    const { stdout } = await execFileAsync("git", ["-C", workspace, ...args], {
      timeout: 4000,
      maxBuffer: 1024 * 1024,
    });
    return stdout.trim();
  } catch {
    return fallback;
  }
}

async function listFiles(dir, predicate = () => true) {
  try {
    const entries = await fs.readdir(dir, { withFileTypes: true });
    const files = [];
    for (const entry of entries) {
      if (!entry.isFile()) continue;
      const path = join(dir, entry.name);
      if (predicate(entry.name)) files.push(path);
    }
    return files;
  } catch {
    return [];
  }
}

async function readTail(path, bytes = 12000) {
  try {
    const handle = await fs.open(path, "r");
    try {
      const stat = await handle.stat();
      const start = Math.max(0, stat.size - bytes);
      const buffer = Buffer.alloc(stat.size - start);
      await handle.read(buffer, 0, buffer.length, start);
      return buffer.toString("utf8");
    } finally {
      await handle.close();
    }
  } catch {
    return "";
  }
}

function parseJsonLines(text) {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

function parseProgressSections(markdown) {
  const sections = {};
  let current = null;
  for (const line of markdown.split(/\r?\n/)) {
    const match = line.match(/^##\s+(.+?)\s*$/);
    if (match) {
      current = match[1].trim();
      sections[current] = [];
      continue;
    }
    if (current) sections[current].push(line);
  }
  return Object.fromEntries(
    Object.entries(sections).map(([key, lines]) => [key, lines.join("\n").trim()]),
  );
}

function compactBullets(text, limit = 8) {
  return text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("- ") || line.startsWith("_"))
    .slice(0, limit)
    .map((line) => line.replace(/^-+\s*/, ""));
}

function cleanMarkdown(text) {
  return String(text || "")
    .replace(/\*\*/g, "")
    .replace(/`/g, "")
    .replace(/^#+\s*/gm, "")
    .replace(/\s+/g, " ")
    .trim();
}

function titleFromId(id) {
  return cleanMarkdown(id)
    .replace(/^S(\d+)_/, "S$1: ")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (char) => char.toUpperCase());
}

function filenameSlug(name) {
  return String(name || "")
    .replace(/^codex-spawn-/, "")
    .replace(/\.log$/, "");
}

function titleFromCodexName(name) {
  const slug = filenameSlug(name);
  const match = slug.match(/^s(\d+)-(.+)$/i);
  if (!match) return name || "No Codex run";
  return `Sprint ${match[1]}: ${match[2].split("-").join(" ")}`;
}

function codexKeywords(name) {
  const words = filenameSlug(name)
    .replace(/^s\d+-/i, "")
    .split("-")
    .map((word) => word.toLowerCase())
    .filter((word) => word.length > 2 && !["and", "the", "for"].includes(word));
  const expanded = new Set(words);
  if (expanded.has("rubric")) expanded.add("rubrics");
  if (expanded.has("reversibility")) expanded.add("reversible");
  if (expanded.has("reversible")) expanded.add("reversibility");
  if (expanded.has("bootstrap")) expanded.add("init");
  if (expanded.has("observability")) expanded.add("ledger");
  return Array.from(expanded);
}

const criterionSummaries = {
  S1_every_upstream_primitive_addressed:
    "Roll-up gate: every upstream parity gap must be closed or explicitly justified before the full goal can pass.",
  S10_init_workspace_script:
    "Builds an initializer that seeds a new harness workspace with progress files, result rows, steering, goal state, and an initial commit.",
  S10_planner_agent_optional:
    "Adds an optional planner agent that turns a short goal into a build plan and matching test-results rows.",
  S11_rubric_template_and_one_concrete:
    "Adds evaluator rubric templates so future goals can be judged against concrete quality standards instead of loose taste.",
  S13_session_ledger:
    "Records completed harness sessions as JSONL so long-running work has a durable audit trail.",
  S13_observability_docs:
    "Documents the watch panels and tmux layout needed to monitor a live harness run without guessing.",
  S15_readme_honest_and_complete:
    "Audits the README so every capability claim is backed by an install check, test, or clear limitation.",
  S15_every_install_op_reversible:
    "Makes every script that changes user state create backups and document how to roll back.",
  S16_soak_test_synthetic:
    "Adds a synthetic six-hour soak test with an injected hang to prove recovery behavior over time.",
  S17_final_evaluator_full_diff_pass:
    "Requires a fresh evaluator to read the whole diff and evidence set before the final PASS.",
  S17_repo_in_sync_with_install_final:
    "Confirms the repository and installed plugin copy have no functional drift at the end of the run.",
};

function criterionSummary(item) {
  if (criterionSummaries[item.id]) return criterionSummaries[item.id];
  const description = cleanMarkdown(item.description || item.title || "");
  return description
    ? `Open criterion: ${description.replace(/\.$/, "")}.`
    : "Open criterion awaiting evidence and evaluator approval.";
}

function statusLabel(code) {
  const normalized = String(code || "").trim();
  if (normalized === "??") return "Untracked";
  if (normalized === "M" || normalized === "MM") return "Modified";
  if (normalized === "A") return "Added";
  if (normalized === "D") return "Deleted";
  if (normalized.includes("R")) return "Renamed";
  if (normalized.includes("M")) return "Modified";
  return normalized || "Changed";
}

function fileSummary(path, code) {
  if (path === "STEER.md") {
    return `${statusLabel(code)} steering note. This usually means the operator or supervisor left recovery or next-step instructions for the harness.`;
  }
  if (path.endsWith("PROGRESS.md")) return `${statusLabel(code)} progress ledger for the live goal.`;
  if (path.endsWith("test-results.json")) return `${statusLabel(code)} pass/fail contract for the harness run.`;
  if (path.includes("heartbeat-stop.sh")) return `${statusLabel(code)} heartbeat completion gate.`;
  if (path.includes("verify-install.sh")) return `${statusLabel(code)} installation verification checks.`;
  if (path.includes("init-workspace")) return `${statusLabel(code)} initializer work for seeding new harness workspaces.`;
  if (path.includes("session-ledger")) return `${statusLabel(code)} session ledger test or implementation work.`;
  if (path.includes("observability")) return `${statusLabel(code)} monitoring documentation.`;
  if (path.includes("rubric")) return `${statusLabel(code)} evaluator rubric work.`;
  if (path.startsWith("evidence/")) return `${statusLabel(code)} evidence artifact for a sprint verdict.`;
  return `${statusLabel(code)} repository file.`;
}

function summarizeChangedFiles(statusText) {
  const files = statusText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const code = line.slice(0, 2).trim() || "?";
      const path = line.slice(3).trim();
      return { code, path, status: statusLabel(code), summary: fileSummary(path, code) };
    })
    .filter((item) => item.path);
  const groups = new Map();
  for (const item of files) {
    const root = item.path.split("/")[0] || item.path;
    groups.set(root, (groups.get(root) || 0) + 1);
  }
  return {
    count: files.length,
    files: files.slice(0, 24),
    groups: Array.from(groups, ([name, count]) => ({ name, count })).slice(0, 10),
  };
}

async function latestLog(workspace, prefix) {
  const files = await listFiles(statePath(workspace), (name) => name.startsWith(prefix) && name.endsWith(".log"));
  const withStats = await Promise.all(files.map(async (path) => ({ path, stat: await statSafe(path) })));
  const latest = withStats.filter((item) => item.stat).sort((a, b) => b.stat.mtimeMs - a.stat.mtimeMs)[0];
  if (!latest) return null;
  const tail = await readTail(latest.path);
  const lines = tail.split(/\r?\n/).map((line) => line.trim()).filter(Boolean).slice(-18);
  return {
    path: latest.path,
    name: basename(latest.path),
    updatedAt: latest.stat.mtime.toISOString(),
    size: latest.stat.size,
    lines,
    verdict: lines.findLast?.((line) => /\b(PASS|NEEDS_WORK|FAIL)\b/.test(line)) || "",
  };
}

function summarizeCodexLog(log, failedItems = []) {
  if (!log) return null;
  const title = titleFromCodexName(log.name);
  const joined = log.lines.join("\n");
  const waitingForBrief = log.size < 2000 && /Reading additional input from stdin/i.test(joined);
  const hasPass = /\bPASS\b/.test(joined);
  const hasNeedsWork = /\bNEEDS_WORK\b|\bFAIL\b/.test(joined);
  const keywords = codexKeywords(log.name);
  const relatedCriteria = failedItems
    .filter((item) => {
      const haystack = `${item.id} ${item.description || ""}`.toLowerCase();
      return keywords.some((keyword) => haystack.includes(keyword));
    })
    .slice(0, 5)
    .map((item) => ({ id: item.id, sprint: item.sprint, title: titleFromId(item.id), summary: criterionSummary(item) }));

  let phase = "Running";
  let summary = `${title} is the latest Codex executor run.`;
  if (waitingForBrief) {
    phase = "Starting";
    summary = `${title} has started and is waiting for the sprint brief to be fully written into the runner.`;
  } else if (hasPass) {
    phase = "Passed";
    summary = `${title} produced PASS output; the harness still needs evidence and evaluator rows to close the sprint.`;
  } else if (hasNeedsWork) {
    phase = "Needs work";
    summary = `${title} reported a failing or needs-work result that the orchestrator must resolve.`;
  } else if (log.lines.length) {
    summary = `${title} is writing executor output; the latest log lines are summarized below.`;
  }

  const humanLines = waitingForBrief
    ? [
        "Codex runner has started.",
        "The log has not received implementation output yet.",
        relatedCriteria.length
          ? `Likely target: ${relatedCriteria.map((item) => item.title.replace(/^S\d+: /, "")).join("; ")}.`
          : "Waiting for the orchestrator to pass the sprint brief.",
      ]
    : log.lines.slice(-8);

  return { ...log, title, phase, summary, keywords, relatedCriteria, humanLines };
}

function deriveCurrentWork({ inProgress, latestCodex, failed, changed, steerText, totalCriteria }) {
  const work = [];
  for (const item of inProgress || []) {
    if (!/^_?None\b/i.test(item)) {
      work.push({ title: cleanMarkdown(item), summary: "Declared in PROGRESS.md as the active in-progress work.", source: "PROGRESS.md" });
    }
  }
  if (latestCodex && failed.length) {
    work.push({ title: latestCodex.title, summary: latestCodex.summary, source: "Latest Codex executor log" });
    for (const criterion of latestCodex.relatedCriteria || []) {
      work.push({ title: criterion.title, summary: criterion.summary, source: "Matched open criterion" });
    }
  }
  if (!work.length && changed.count) {
    work.push({
      title: "There is uncommitted harness work in the repository.",
      summary: `${changed.count} changed file${changed.count === 1 ? "" : "s"} ${changed.count === 1 ? "is" : "are"} waiting for evaluation, commit, or cleanup.`,
      source: "git status",
    });
  }
  if (!work.length && failed.length) {
    for (const item of failed.slice(0, 4)) {
      work.push({ title: titleFromId(item.id), summary: criterionSummary(item), source: "Open criterion" });
    }
  }
  if (!work.length && totalCriteria > 0 && !failed.length) {
    work.push({
      title: "All tracked criteria are passing.",
      summary: "The harness reports every criterion as PASS; it is ready for final review or the next goal.",
      source: "test-results.json",
    });
  }
  if (steerText.trim()) {
    const firstLine = steerText.split(/\r?\n/).map((line) => line.trim()).find(Boolean);
    work.push({
      title: "Steering note is present.",
      summary: firstLine ? cleanMarkdown(firstLine) : "A steering file exists and may affect the next harness turn.",
      source: "STEER.md",
      advisory: true,
    });
  }
  return work.slice(0, 8);
}

function statusTone(state) {
  if (state.blockers?.open > 0) return "blocked";
  if (state.heartbeat?.ageSeconds > 1200) return "stale";
  if (state.tests?.failed > 0) return "active";
  return "complete";
}

function validDate(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date;
}

function ageSeconds(now, date) {
  return Math.max(0, Math.round((now - date) / 1000));
}

export async function readActiveSessions(ledgerPath = defaultActiveLedger) {
  return parseJsonLines(await readText(ledgerPath, ""));
}

export async function collectWorkspaceState(session) {
  const now = new Date();
  const workspace = resolve(session.workspace);
  const goalState = await readJson(statePath(workspace, "goal-state.json"), {});
  const progressText = await readText(join(workspace, "PROGRESS.md"), "");
  const sections = parseProgressSections(progressText);
  const results = await readJson(join(workspace, "test-results.json"), { items: [] });
  const items = Array.isArray(results?.items)
    ? results.items
    : Array.isArray(results?.criteria)
      ? results.criteria
      : Array.isArray(results)
        ? results
        : [];
  const passed = items.filter((item) => item.passes === true);
  const failed = items.filter((item) => item.passes === false);
  const lastBeatRaw = (await readText(statePath(workspace, "last-beat"), "")).trim();
  const lastBeatEpoch = Number(lastBeatRaw);
  const lastBeatAt = Number.isFinite(lastBeatEpoch) && lastBeatEpoch > 0 ? new Date(lastBeatEpoch * 1000) : null;
  const spawnActive = await readJson(statePath(workspace, "spawn-active.json"), null);
  const spawnRefreshedAt = validDate(spawnActive?.last_refreshed);
  const spawnAgeSeconds = spawnRefreshedAt ? ageSeconds(now, spawnRefreshedAt) : null;
  const spawnHeartbeatFresh = spawnAgeSeconds !== null && spawnAgeSeconds <= 300;
  const branch = await git(workspace, ["rev-parse", "--abbrev-ref", "HEAD"], "unknown");
  const head = await git(workspace, ["log", "-1", "--format=%h%x09%s%x09%cr"], "");
  const statusText = await git(workspace, ["status", "--short"], "");
  const blockers = parseJsonLines(await readText(statePath(workspace, "blockers.jsonl"), ""));
  const blockerGate = await readJson(statePath(workspace, "blocker-gate.json"), null);
  const changed = summarizeChangedFiles(statusText);
  const rawLatestCodex = await latestLog(workspace, "codex-spawn-");
  const latestCodex = summarizeCodexLog(rawLatestCodex, failed);
  const steerText = await readText(join(workspace, "STEER.md"), "");
  const inProgress = compactBullets(sections["In progress"] || "", 6);
  const next = compactBullets(sections.Next || "", 10);
  const passRatio = items.length ? passed.length / items.length : 0;
  const verdictFiles = await listFiles(statePath(workspace), (name) => name.includes("verdict") && name.endsWith(".txt"));
  const verdicts = await Promise.all(
    verdictFiles.map(async (path) => {
      const stat = await statSafe(path);
      const text = await readText(path, "");
      const firstLine = text.split(/\r?\n/).find(Boolean) || "";
      const status = /^PASS\b/i.test(firstLine) ? "Passed" : /^NEEDS_WORK\b/i.test(firstLine) ? "Needs work" : firstLine || "Recorded";
      return {
        name: basename(path),
        updatedAt: stat?.mtime.toISOString() || null,
        firstLine,
        status,
        summary: `${status}: a fresh evaluator reviewed ${basename(path).replace(/-verdict\.txt$/, "")}.`,
      };
    }),
  );
  const openBlockers = blockers.filter(
    (item) => !["closed", "resolved", "wontfix", "accepted_risk"].includes(String(item.status || "").toLowerCase()),
  );

  const snapshot = {
    generatedAt: now.toISOString(),
    agent: session.agent || goalState.agent || basename(workspace),
    channel: session.channel || null,
    launcher: session.launcher || null,
    workspace,
    goal: {
      title: goalState.goal || session.goal || results.goal || "No active goal found",
      status: goalState.status || "unknown",
      sessionId: goalState.session_id || goalState.sessionId || session.session_id || null,
      startedAt: goalState.started_at || goalState.startedAt || session.started_at || null,
      scopePolicy: results.scope_policy || goalState.scope_policy || "fixed_scope",
    },
    heartbeat: {
      lastBeatAt: spawnHeartbeatFresh ? spawnActive.last_refreshed : lastBeatAt?.toISOString() || null,
      ageSeconds: spawnHeartbeatFresh ? spawnAgeSeconds : lastBeatAt ? ageSeconds(now, lastBeatAt) : null,
      lastStatus: spawnHeartbeatFresh ? "active" : (await readText(statePath(workspace, "last-status"), "")).trim() || null,
      source: spawnHeartbeatFresh ? "spawn-active" : lastBeatAt ? "stop-hook" : null,
      blockCount: (await readText(statePath(workspace, "block-count"), "")).trim() || null,
      tail: (await readText(statePath(workspace, "heartbeat-stop.log"), "")).split(/\r?\n/).filter(Boolean).slice(-10),
      ...(spawnHeartbeatFresh
        ? {
            spawn: {
              pid: spawnActive.pid ?? null,
              started_at: spawnActive.started_at ?? null,
              command: spawnActive.command ?? null,
            },
          }
        : {}),
    },
    tests: {
      total: items.length,
      passed: passed.length,
      failed: failed.length,
      percent: Math.round(passRatio * 100),
      failing: failed.slice(0, 12).map((item) => ({
        id: item.id,
        sprint: item.sprint,
        description: item.description || item.title || "",
        title: titleFromId(item.id),
        summary: criterionSummary(item),
      })),
      recentPasses: passed.slice(-8).map((item) => ({ id: item.id, sprint: item.sprint, title: titleFromId(item.id) })),
    },
    progress: {
      inProgress,
      next,
      currentWork: deriveCurrentWork({ inProgress, latestCodex, failed, changed, steerText, totalCriteria: items.length }),
      rawTally: (progressText.match(/\*\*Tally:\*\*\s*(.+)/) || [])[1] || "",
    },
    git: { branch, head, dirty: changed.count > 0, changed },
    blockers: { total: blockers.length, open: openBlockers.length, records: blockers.slice(-8).reverse(), gate: blockerGate },
    activity: {
      latestCodex,
      verdicts: verdicts.filter((item) => item.updatedAt).sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt)).slice(0, 8),
      notifyTail: (await readText(statePath(workspace, "discord-notify.log"), "")).split(/\r?\n/).filter(Boolean).slice(-8),
    },
  };
  snapshot.tone = statusTone(snapshot);
  return snapshot;
}

export async function collectHarnessBundle(options = {}) {
  const ledgerPath = options.ledgerPath || process.env.HARNESS_ACTIVE_LEDGER || defaultActiveLedger;
  let sessions = await readActiveSessions(ledgerPath);
  if (options.workspace) {
    sessions = [{
      session_id: "manual",
      agent: options.agent || basename(options.workspace),
      channel: null,
      goal: "Manual harness workspace",
      started_at: null,
      workspace: options.workspace,
      launcher: null,
    }];
  }
  const agents = [];
  for (const session of sessions) {
    try {
      agents.push(await collectWorkspaceState(session));
    } catch (error) {
      agents.push({
        generatedAt: new Date().toISOString(),
        agent: session.agent || "unknown",
        channel: session.channel || null,
        workspace: session.workspace,
        error: error.message || String(error),
        tone: "blocked",
      });
    }
  }
  return {
    generatedAt: new Date().toISOString(),
    source: "ai-heroes-harness-dashboard-publisher",
    ledgerPath,
    agents,
  };
}
