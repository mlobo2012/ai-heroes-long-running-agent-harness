#!/usr/bin/env node
import { spawn } from "node:child_process";

const args = ["deploy", ...process.argv.slice(2)];
const env = { ...process.env };

delete env.VERCEL_PROJECT_ID;
delete env.VERCEL_ORG_ID;

const child = spawn("vercel", args, {
  env,
  stdio: "inherit",
});

child.on("exit", (code, signal) => {
  if (signal) {
    console.error(`vercel deploy exited by signal ${signal}`);
    process.exit(1);
  }
  process.exit(code || 0);
});
