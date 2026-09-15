#!/usr/bin/env bun
import { resolve } from "node:path";
import { runProjectIntegrationSetup } from "antgrid-agents/project-integrations";
import { resolveHookCommand, resolveMcpCommand } from "../src/hook-command";
import { resolveAbDir } from "../src/antgrid-dir";

const integrationDir = resolve(import.meta.dirname);
const mcp = resolveMcpCommand({ compiled: false, binary: process.execPath, entrypoint: resolve(integrationDir, "..", "src", "index.ts") });
runProjectIntegrationSetup({
  integrationDir,
  assetDirectory: resolveAbDir(),
  mcpEntry: { command: mcp.binary, args: mcp.preargs, env: {
    ANTGRID_API_PORT: "${ANTGRID_API_PORT}", ANTGRID_TERMINAL_ID: "${ANTGRID_TERMINAL_ID}",
  } },
  hookCommand: resolveHookCommand({
    compiled: false, binary: process.execPath,
    entrypoint: resolve(integrationDir, "..", "src", "index.ts"),
  }),
  args: process.argv.slice(2),
});
