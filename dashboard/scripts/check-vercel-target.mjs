#!/usr/bin/env node
import { readFile } from "node:fs/promises";

const expectedProjectName = "ai-heroes-harness-dashboard";

try {
  const project = JSON.parse(await readFile(".vercel/project.json", "utf8"));
  if (project.projectName !== expectedProjectName) {
    console.error(`Wrong Vercel project: ${project.projectName || "<missing>"}. Expected ${expectedProjectName}.`);
    process.exit(1);
  }
  if (!project.projectId || !project.orgId) {
    console.error(".vercel/project.json is missing projectId or orgId.");
    process.exit(1);
  }
  console.log(`PASS - Vercel target is ${project.projectName}`);
} catch (error) {
  console.error(`Vercel project is not linked yet: ${error.message}`);
  console.error("Run npm run vercel:link first.");
  process.exit(1);
}
