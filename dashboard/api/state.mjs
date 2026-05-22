import { list } from "@vercel/blob";

const snapshotPrefix = "harness-dashboard/snapshots/";

function emptyState() {
  return {
    generatedAt: new Date().toISOString(),
    source: "empty-vercel-state",
    agents: [],
    message: "No harness snapshots have been published yet. Run dashboard/scripts/publish-state.mjs from the machine that hosts the harness.",
  };
}

export default async function handler(request, response) {
  if (request.method !== "GET") {
    response.setHeader("Allow", "GET");
    response.status(405).json({ error: "Method not allowed" });
    return;
  }

  try {
    if (!process.env.BLOB_READ_WRITE_TOKEN) {
      response.status(200).json(emptyState());
      return;
    }
    // Snapshot filenames are `{Date.now()}.json`, so Vercel Blob's default
    // alphabetical-ascending list order returns the OLDEST first. A single
    // limit-N page silently hides the newest snapshots once the bucket holds
    // more than N (the ingest pruner keeps ~120 live). Paginate via cursor so
    // we always see the freshest write, then sort by uploadedAt desc.
    const blobs = [];
    let cursor;
    do {
      const page = await list({ prefix: snapshotPrefix, limit: 1000, cursor });
      if (Array.isArray(page.blobs)) blobs.push(...page.blobs);
      cursor = page.cursor;
    } while (cursor);
    const blob = blobs
      .sort((a, b) => new Date(b.uploadedAt) - new Date(a.uploadedAt))[0];
    if (!blob?.url) {
      response.status(200).json(emptyState());
      return;
    }
    const stateUrl = new URL(blob.url);
    stateUrl.searchParams.set("dashboard_ts", String(Date.now()));
    const stateResponse = await fetch(stateUrl, { cache: "no-store" });
    if (stateResponse.status === 404) {
      response.status(200).json(emptyState());
      return;
    }
    if (!stateResponse.ok) {
      throw new Error(`Failed to fetch dashboard snapshot: ${stateResponse.status} ${stateResponse.statusText}`);
    }
    const text = await stateResponse.text();
    response.setHeader("cache-control", "no-store");
    response.status(200);
    response.end(text);
  } catch (error) {
    response.status(200).json({
      ...emptyState(),
      warning: error.message || String(error),
    });
  }
}
