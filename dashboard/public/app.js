const refreshMs = 30000;
let nextRefreshAt = Date.now() + refreshMs;
let timer = null;
let stateBundle = null;
let selectedKey = null;

const $ = (id) => document.getElementById(id);

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function relativeTime(isoOrDate) {
  if (!isoOrDate) return "-";
  const date = isoOrDate instanceof Date ? isoOrDate : new Date(isoOrDate);
  if (Number.isNaN(date.getTime())) return "-";
  const seconds = Math.max(0, Math.round((Date.now() - date.getTime()) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}

function agentKey(agent) {
  return agent.goal?.sessionId || `${agent.agent}-${agent.channel || agent.workspace}`;
}

function renderList(target, rows, emptyText, renderRow) {
  const element = $(target);
  if (!rows?.length) {
    element.innerHTML = `<div class="empty">${escapeHtml(emptyText)}</div>`;
    return;
  }
  element.innerHTML = rows.map(renderRow).join("");
}

function renderTabs(bundle) {
  const agents = bundle.agents || [];
  if (!agents.length) {
    $("agentTabs").innerHTML = `<div class="empty">No live harness sessions have been published yet.</div>`;
    return null;
  }
  if (!selectedKey || !agents.some((agent) => agentKey(agent) === selectedKey)) {
    selectedKey = agentKey(agents[0]);
  }
  $("agentTabs").innerHTML = agents.map((agent) => {
    const key = agentKey(agent);
    const active = key === selectedKey ? "active" : "";
    const tone = agent.tone || "active";
    const failed = agent.tests?.failed ?? "-";
    return `
      <button class="agent-tab ${active} ${tone}" data-agent-key="${escapeHtml(key)}" type="button">
        <span class="agent-dot"></span>
        <span>${escapeHtml(agent.agent || "agent")}</span>
        <span>${escapeHtml(failed)} open</span>
      </button>
    `;
  }).join("");
  for (const button of $("agentTabs").querySelectorAll("button")) {
    button.addEventListener("click", () => {
      selectedKey = button.dataset.agentKey;
      renderBundle(stateBundle);
    });
  }
  return agents.find((agent) => agentKey(agent) === selectedKey) || agents[0];
}

function renderCurrentWork(agent) {
  renderList("currentWork", agent.progress?.currentWork || [], "No active work detected in PROGRESS.md.", (item) => `
    <div class="work-item ${item.advisory ? "advisory" : ""}">
      <div class="work-title">${escapeHtml(item.title)}</div>
      <div class="work-summary">${escapeHtml(item.summary)}</div>
      <div class="work-meta">${escapeHtml(item.source || "")}</div>
    </div>
  `);
}

function renderFailing(agent) {
  renderList("failingList", agent.tests?.failing || [], "No failing criteria remain.", (item) => `
    <div class="criterion">
      <div class="criterion-title">${escapeHtml(item.title || item.id)}</div>
      <div class="criterion-summary">${escapeHtml(item.summary || item.description || "")}</div>
      <div class="criterion-meta">Sprint ${escapeHtml(item.sprint ?? "-")} / ${escapeHtml(item.id)}</div>
    </div>
  `);
}

function renderChangedFiles(agent) {
  renderList("changedFiles", agent.git?.changed?.files || [], "Working tree is clean.", (item) => `
    <div class="file-row">
      <div class="file-path">${escapeHtml(item.path)}</div>
      <div class="file-summary">${escapeHtml(item.summary || item.status || item.code)}</div>
      <div class="file-meta">${escapeHtml(item.status || item.code)}</div>
    </div>
  `);
}

function renderBlockers(agent) {
  const blockers = agent.blockers?.records || [];
  const summary = blockers.length
    ? blockers
    : [{
        title: "No open production blockers are recorded.",
        status: "Clear",
        affected_area: "Scope policy gate",
        summary: "The blocker ledger has no unresolved records, so safety is currently gated by criteria and evaluator verdicts.",
      }];
  renderList("blockers", summary, "No blockers recorded.", (item) => `
    <div class="blocker-row">
      <div class="blocker-title">${escapeHtml(item.title || item.id || "Blocker record")}</div>
      <div class="blocker-summary">${escapeHtml(item.summary || item.reproduction_notes || "Recorded blocker entry.")}</div>
      <div class="blocker-meta">${escapeHtml(item.status || "unknown")} / ${escapeHtml(item.affected_area || item.affectedArea || "-")}</div>
    </div>
  `);
  renderList("verdicts", agent.activity?.verdicts || [], "No evaluator verdicts found.", (item) => `
    <div class="feed-row">
      <div class="feed-title">${escapeHtml(item.name)}</div>
      <div class="feed-summary">${escapeHtml(item.summary || "Evaluator verdict recorded.")}</div>
      <div class="feed-meta">${escapeHtml(item.status || item.firstLine || "-")} / ${escapeHtml(relativeTime(item.updatedAt))}</div>
    </div>
  `);
}

function renderCodex(agent) {
  const latest = agent.activity?.latestCodex;
  $("codexName").textContent = latest ? latest.title : "No spawn log yet";
  $("codexSummary").textContent = latest ? `${latest.phase}: ${latest.summary}` : "No Codex executor run has been recorded.";
  $("codexTail").textContent = latest?.humanLines?.length ? latest.humanLines.join("\n") : "No Codex executor output has been recorded.";
}

function renderAgent(agent) {
  $("goalTitle").textContent = agent.goal?.title || agent.error || "No active goal found";
  $("scopePolicy").textContent = agent.goal?.scopePolicy || "-";
  $("sessionId").textContent = agent.goal?.sessionId ? agent.goal.sessionId.slice(0, 8) : "-";
  $("branch").textContent = agent.git?.branch || "-";

  $("passMetric").textContent = `${agent.tests?.passed ?? 0} / ${agent.tests?.total ?? 0}`;
  $("failMetric").textContent = String(agent.tests?.failed ?? 0);
  $("heartbeatMetric").textContent = agent.heartbeat?.lastBeatAt ? relativeTime(agent.heartbeat.lastBeatAt) : "-";
  $("dirtyMetric").textContent = agent.git?.dirty ? `${agent.git.changed.count} files` : "clean";

  $("progressBar").style.width = `${agent.tests?.percent || 0}%`;
  $("progressText").textContent = `${agent.tests?.percent || 0}% complete. ${agent.tests?.failed || 0} criteria remain. ${agent.progress?.rawTally || ""}`.trim();

  const mark = $("liveMark");
  mark.className = `live-mark ${agent.tone || "active"}`;
  mark.textContent = agent.tone === "complete" ? "Complete" : agent.tone === "stale" ? "Stale" : agent.tone === "blocked" ? "Blocked" : "Live";

  renderCurrentWork(agent);
  renderFailing(agent);
  renderChangedFiles(agent);
  renderBlockers(agent);
  renderCodex(agent);

  $("workspace").textContent = agent.workspace || "-";
  $("updatedAt").textContent = `Updated ${new Date(stateBundle.generatedAt).toLocaleTimeString()}`;
}

function renderBundle(bundle) {
  stateBundle = bundle;
  const agent = renderTabs(bundle);
  if (!agent) {
    $("goalTitle").textContent = bundle.message || "No published harness sessions yet.";
    $("liveMark").className = "live-mark stale";
    $("liveMark").textContent = "Waiting";
    return;
  }
  renderAgent(agent);
}

async function loadState() {
  try {
    const response = await fetch(`/api/state?ts=${Date.now()}`, { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    renderBundle(await response.json());
    nextRefreshAt = Date.now() + refreshMs;
  } catch (error) {
    $("liveMark").className = "live-mark blocked";
    $("liveMark").textContent = "Error";
    $("codexTail").textContent = `Failed to load dashboard state: ${error.message || error}`;
  }
}

function tick() {
  const remaining = Math.max(0, Math.ceil((nextRefreshAt - Date.now()) / 1000));
  $("refreshCopy").textContent = `Next refresh in ${remaining}s`;
  if (remaining <= 0) loadState();
}

$("refreshButton").addEventListener("click", loadState);
await loadState();
timer = setInterval(tick, 1000);
window.addEventListener("beforeunload", () => clearInterval(timer));
