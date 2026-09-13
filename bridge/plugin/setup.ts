#!/usr/bin/env bun
import { join, resolve } from "node:path";
import { runProjectIntegrationSetup } from "antgrid-agents/project-integrations";
import { resolveHookCommand } from "../src/hook-command";
import { resolveAbDir } from "../src/antgrid-dir";

const pluginDir = resolve(import.meta.dirname);
runProjectIntegrationSetup({
  pluginDir,
  assetDirectory: resolveAbDir(),
  mcpEntry: { command: "bun", args: ["run", join(pluginDir, "mcp-server.ts")] },
  hookCommand: resolveHookCommand({
    compiled: false, binary: process.execPath,
    entrypoint: resolve(pluginDir, "..", "src", "index.ts"),
  }),
  args: process.argv.slice(2),
});
