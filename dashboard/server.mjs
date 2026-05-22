import { createServer } from "node:http";
import { extname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promises as fs } from "node:fs";
import { collectHarnessBundle } from "./lib/collect-state.mjs";

const __dirname = fileURLToPath(new URL(".", import.meta.url));
const publicDir = resolve(__dirname, "public");
const port = Number(process.env.PORT || 4788);

const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
};

async function serveStatic(request, response) {
  const requested = new URL(request.url, "http://localhost");
  const rawPath = requested.pathname === "/" ? "/index.html" : requested.pathname;
  const filePath = resolve(publicDir, `.${rawPath}`);
  if (!filePath.startsWith(publicDir)) {
    response.writeHead(403);
    response.end("Forbidden");
    return;
  }
  try {
    const body = await fs.readFile(filePath);
    response.writeHead(200, {
      "content-type": contentTypes[extname(filePath)] || "application/octet-stream",
      "cache-control": "no-store",
    });
    response.end(body);
  } catch {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found");
  }
}

const server = createServer(async (request, response) => {
  try {
    if (request.url?.startsWith("/api/state")) {
      const state = await collectHarnessBundle({
        workspace: process.env.HARNESS_WORKSPACE || undefined,
        agent: process.env.HARNESS_AGENT || undefined,
      });
      response.writeHead(200, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
      });
      response.end(JSON.stringify(state));
      return;
    }
    await serveStatic(request, response);
  } catch (error) {
    response.writeHead(500, { "content-type": "application/json; charset=utf-8" });
    response.end(JSON.stringify({ error: error.message || String(error) }));
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`Harness dashboard: http://127.0.0.1:${port}`);
  console.log("Local mode reads ~/.claude/goal-sessions/active.jsonl by default.");
});
