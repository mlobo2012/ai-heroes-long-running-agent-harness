import { del, list, put } from "@vercel/blob";

const snapshotPrefix = "harness-dashboard/snapshots/";
const maxSnapshots = 120;

async function readBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

function isAuthorized(request) {
  const expected = process.env.INGEST_TOKEN;
  if (!expected) return false;
  const auth = request.headers.authorization || "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice("Bearer ".length) : "";
  const headerToken = request.headers["x-harness-dashboard-token"] || "";
  return bearer === expected || headerToken === expected;
}

export default async function handler(request, response) {
  if (request.method !== "POST") {
    response.setHeader("Allow", "POST");
    response.status(405).json({ error: "Method not allowed" });
    return;
  }
  if (!isAuthorized(request)) {
    response.status(401).json({ error: "Unauthorized" });
    return;
  }
  if (!process.env.BLOB_READ_WRITE_TOKEN) {
    response.status(500).json({ error: "BLOB_READ_WRITE_TOKEN is not configured" });
    return;
  }

  try {
    const payload = JSON.parse(await readBody(request));
    if (!payload || !Array.isArray(payload.agents)) {
      response.status(400).json({ error: "Payload must include an agents array" });
      return;
    }
    const body = JSON.stringify({
      ...payload,
      receivedAt: new Date().toISOString(),
    });
    const blob = await put(`${snapshotPrefix}${Date.now()}.json`, body, {
      access: "public",
      addRandomSuffix: false,
      cacheControlMaxAge: 60,
      contentType: "application/json; charset=utf-8",
    });
    pruneOldSnapshots().catch(() => {});
    response.status(200).json({
      ok: true,
      agents: payload.agents.length,
      url: blob.url,
      receivedAt: new Date().toISOString(),
    });
  } catch (error) {
    response.status(500).json({ error: error.message || String(error) });
  }
}

async function pruneOldSnapshots() {
  const result = await list({ prefix: snapshotPrefix, limit: maxSnapshots + 50 });
  const stale = (result.blobs || [])
    .sort((a, b) => new Date(b.uploadedAt) - new Date(a.uploadedAt))
    .slice(maxSnapshots);
  if (stale.length) {
    await del(stale.map((item) => item.url));
  }
}
