# Harness Dashboard

Live dashboard for AI Heroes long-running harness sessions.

It has two modes:

- **Local mode:** `node dashboard/server.mjs` reads `~/.claude/goal-sessions/active.jsonl` and local harness workspaces directly.
- **Hosted mode:** Vercel serves the dashboard. A local publisher sends snapshots to `/api/ingest` every 30 seconds. Vercel stores the latest snapshot in Vercel Blob.

The hosted dashboard never runs an AI model. It only displays JSON snapshots produced by the local publisher.

## Local

```bash
cd dashboard
npm install
npm start
```

Open `http://127.0.0.1:4788`.

To point at one workspace instead of the active-session ledger:

```bash
HARNESS_WORKSPACE=/path/to/harness/workspace HARNESS_AGENT=klaus npm start
```

## Hosted Publisher

Set these on the machine that runs the harness:

```bash
export HARNESS_DASHBOARD_URL="https://your-vercel-project.vercel.app"
export HARNESS_DASHBOARD_TOKEN="<same value as INGEST_TOKEN in Vercel>"
# Optional when Vercel Deployment Protection is enabled:
export HARNESS_DASHBOARD_BYPASS="<Vercel protection bypass token>"
```

Publish once:

```bash
npm run publish:once
```

Publish every 30 seconds:

```bash
npm run publish -- --interval 30
```

The publisher reads all active sessions from `~/.claude/goal-sessions/active.jsonl`, so multiple agents appear as tabs automatically.
If there are no active sessions, it leaves the last published snapshot in place instead of replacing the dashboard with an empty view. Set `HARNESS_DASHBOARD_PUBLISH_EMPTY=1` or pass `--publish-empty` when you want empty snapshots published.

## Vercel Environment

The Vercel project needs:

- `INGEST_TOKEN`: shared secret used by the local publisher.
- `BLOB_READ_WRITE_TOKEN`: Vercel Blob token.

Create the Blob store in the same Vercel project so Vercel injects `BLOB_READ_WRITE_TOKEN`, then run the publisher with `HARNESS_DASHBOARD_TOKEN` set to the ingest token.

Deploy from this directory with:

```bash
npm run deploy -- --prod
```
