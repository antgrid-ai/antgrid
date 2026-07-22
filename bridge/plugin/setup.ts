#!/usr/bin/env bun
/**
 * Antgrid plugin installer/uninstaller for Claude Code, Codex CLI, and Gemini CLI.
 *
 * Usage:
 *   bun run bridge/plugin/setup.ts install [project-dir]
 *   bun run bridge/plugin/setup.ts uninstall [project-dir]
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import {
  managedCursorCommands,
  removeManagedCursorHookEntries,
  replaceManagedCursorHookEntries,
} from "../src/cursor-hooks";
import { resolveHookCommand } from "../src/hook-command";

const PLUGIN_DIR = resolve(import.meta.dirname);
const MCP_SERVER_PATH = join(PLUGIN_DIR, "mcp-server.ts");
const HOOKS_DIR = join(PLUGIN_DIR, "hooks");
const HOOK_COMMAND = resolveHookCommand({
  compiled: false,
  binary: process.execPath,
  entrypoint: resolve(PLUGIN_DIR, "..", "src", "index.ts"),
});

const MCP_ENTRY = {
  command: "bun",
  args: ["run", MCP_SERVER_PATH],
};


function readJson(path: string): any {
  if (!existsSync(path)) return {};
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return {}; }
}

function writeJsonOrDelete(path: string, data: any) {
  if (isDeepEmpty(data)) {
    try { unlinkSync(path); } catch {}
    return;
  }
  const dir = join(path, "..");
  if (!existsSync(dir)) mkdirSync(dir, { recursive: true });
  writeFileSync(path, JSON.stringify(data, null, 2) + "\n", "utf8");
}

function isDeepEmpty(obj: any): boolean {
  if (obj === null || obj === undefined) return true;
  if (typeof obj !== "object") return false;
  return Object.values(obj).every(isDeepEmpty);
}


function hookEntry(script: string) {
  return { type: "command", command: `bash "${join(HOOKS_DIR, script)}"`, timeout: 5 };
}

function buildHooks(stopEvent: string, notifMatcher: string) {
  return {
    [stopEvent]: [{ matcher: "", hooks: [hookEntry("on-stop")] }],
    Notification: [{ matcher: notifMatcher, hooks: [hookEntry("on-notification")] }],
  };
}

// Cursor's hooks.json has a flatter shape than Claude/Codex's (no matcher/
// hooks-array wrapper — see cursor.com/docs/hooks). agent-launch-augmenter.ts
// (ensureCursorHook) already wires this same entry automatically on every
// bridge-managed cursor-agent spawn; this installer covers cursor-agent runs
// started outside the bridge (no --plugin-dir / -c injection channel exists
// for cursor-agent, so the project's real hooks.json is the only place either
// path can write this). The merge/dedupe logic itself is shared via
// cursor-hooks.ts so a fix only has to happen once.


function removeAbEntries(path: string, hookKeys: string[]) {
  if (!existsSync(path)) return;
  const data = readJson(path);
  if (!data.hooks) return;
  for (const key of hookKeys) delete data.hooks[key];
  if (Object.keys(data.hooks).length === 0) delete data.hooks;
  if (data.mcpServers) {
    delete data.mcpServers.antgrid;
    if (Object.keys(data.mcpServers).length === 0) delete data.mcpServers;
  }
  writeJsonOrDelete(path, data);
}


function addMcpEntry(projectDir: string) {
  const mcpPath = join(projectDir, ".mcp.json");
  const mcp = readJson(mcpPath);
  if (!mcp.mcpServers) mcp.mcpServers = {};
  mcp.mcpServers.antgrid = MCP_ENTRY;
  writeJsonOrDelete(mcpPath, mcp);
}

function removeMcpEntry(projectDir: string) {
  const mcpPath = join(projectDir, ".mcp.json");
  if (!existsSync(mcpPath)) return;
  const mcp = readJson(mcpPath);
  if (mcp.mcpServers) {
    delete mcp.mcpServers.antgrid;
    if (Object.keys(mcp.mcpServers).length === 0) delete mcp.mcpServers;
  }
  writeJsonOrDelete(mcpPath, mcp);
}


interface CLIConfig {
  name: string;
  configDir: string;
  detected: boolean;
  install: (projectDir: string) => void;
  uninstall: (projectDir: string) => void;
}

function makeCLIs(): CLIConfig[] {
  const home = homedir();
  const NOTIF_MATCHER = "permission_prompt|idle_prompt";

  return [
    {
      name: "Claude Code",
      configDir: join(home, ".claude"),
      detected: existsSync(join(home, ".claude")),
      install(projectDir) {
        addMcpEntry(projectDir);
        const settingsPath = join(projectDir, ".claude", "settings.json");
        const settings = readJson(settingsPath);
        if (!settings.hooks) settings.hooks = {};
        Object.assign(settings.hooks, buildHooks("Stop", NOTIF_MATCHER));
        if (!existsSync(join(projectDir, ".claude"))) mkdirSync(join(projectDir, ".claude"), { recursive: true });
        writeJsonOrDelete(settingsPath, settings);
        console.log("  + .mcp.json — MCP server registered");
        console.log("  + .claude/settings.json — hooks configured");
      },
      uninstall(projectDir) {
        removeMcpEntry(projectDir);
        console.log("  - .mcp.json — antgrid MCP server removed");
        removeAbEntries(join(projectDir, ".claude", "settings.json"), ["Stop", "Notification"]);
        console.log("  - .claude/settings.json — hooks removed");
      },
    },
    {
      name: "Codex CLI",
      configDir: join(home, ".codex"),
      detected: existsSync(join(home, ".codex")),
      install(projectDir) {
        addMcpEntry(projectDir);
        const hooksPath = join(projectDir, ".codex", "hooks.json");
        const data = readJson(hooksPath);
        if (!data.hooks) data.hooks = {};
        Object.assign(data.hooks, buildHooks("Stop", NOTIF_MATCHER));
        if (!existsSync(join(projectDir, ".codex"))) mkdirSync(join(projectDir, ".codex"), { recursive: true });
        writeJsonOrDelete(hooksPath, data);
        console.log("  + .mcp.json — MCP server registered");
        console.log("  + .codex/hooks.json — hooks configured");
      },
      uninstall(projectDir) {
        removeMcpEntry(projectDir);
        console.log("  - .mcp.json — antgrid MCP server removed");
        removeAbEntries(join(projectDir, ".codex", "hooks.json"), ["Stop", "Notification"]);
        console.log("  - .codex/hooks.json — hooks removed");
      },
    },
    {
      name: "Gemini CLI",
      configDir: join(home, ".gemini"),
      detected: existsSync(join(home, ".gemini")),
      install(projectDir) {
        const settingsPath = join(projectDir, ".gemini", "settings.json");
        const settings = readJson(settingsPath);
        if (!settings.mcpServers) settings.mcpServers = {};
        settings.mcpServers.antgrid = MCP_ENTRY;
        if (!settings.hooks) settings.hooks = {};
        Object.assign(settings.hooks, buildHooks("AfterAgent", ""));
        if (!existsSync(join(projectDir, ".gemini"))) mkdirSync(join(projectDir, ".gemini"), { recursive: true });
        writeJsonOrDelete(settingsPath, settings);
        console.log("  + .gemini/settings.json — MCP server + hooks configured");
      },
      uninstall(projectDir) {
        removeAbEntries(join(projectDir, ".gemini", "settings.json"), ["AfterAgent", "Notification"]);
        console.log("  - .gemini/settings.json — MCP server + hooks removed");
      },
    },
    {
      name: "Cursor CLI",
      configDir: join(home, ".cursor"),
      detected: existsSync(join(home, ".cursor")),
      install(projectDir) {
        const hooksPath = join(projectDir, ".cursor", "hooks.json");
        const data = readJson(hooksPath);
        const commands = managedCursorCommands(HOOK_COMMAND);
        const merged = replaceManagedCursorHookEntries(data, commands);
        if (merged !== null) {
          if (!existsSync(join(projectDir, ".cursor"))) mkdirSync(join(projectDir, ".cursor"), { recursive: true });
          writeJsonOrDelete(hooksPath, merged);
        }
        console.log("  + .cursor/hooks.json — sessionStart + stop hooks configured");
      },
      uninstall(projectDir) {
        const hooksPath = join(projectDir, ".cursor", "hooks.json");
        if (!existsSync(hooksPath)) return;
        const data = readJson(hooksPath);
        const commands = managedCursorCommands(HOOK_COMMAND);
        writeJsonOrDelete(hooksPath, removeManagedCursorHookEntries(data, commands));
        console.log("  - .cursor/hooks.json — sessionStart + stop hooks removed");
      },
    },
  ];
}


const command = process.argv[2];
const projectDir = process.argv[3] ? resolve(process.argv[3]) : process.cwd();

if (command === "install") {
  console.log("Antgrid Plugin Installer");
  console.log("=====================");
  console.log(`Project: ${projectDir}`);
  console.log(`Plugin:  ${PLUGIN_DIR}\n`);

  const detected = makeCLIs().filter((c) => c.detected);
  if (detected.length === 0) {
    console.log("No supported AI CLIs detected. Install one of:");
    console.log("  - Claude Code: https://claude.ai/code");
    console.log("  - Codex CLI:   https://github.com/openai/codex");
    console.log("  - Gemini CLI:  https://github.com/google-gemini/gemini-cli");
    console.log("  - Cursor CLI:  https://cursor.com/docs/cli");
    process.exit(1);
  }

  for (const cli of detected) {
    console.log(`${cli.name}:`);
    cli.install(projectDir);
    console.log();
  }
  console.log("Done! Restart your AI CLI to activate Antgrid tools.");

} else if (command === "uninstall") {
  console.log("Antgrid Plugin Uninstaller");
  console.log("=======================");
  console.log(`Project: ${projectDir}\n`);

  for (const cli of makeCLIs().filter((c) => c.detected)) {
    console.log(`${cli.name}:`);
    cli.uninstall(projectDir);
    console.log();
  }

  const portFile = join(process.env.ANTGRID_DIR ?? join(homedir(), ".antgrid"), "api.port");
  if (existsSync(portFile)) {
    try { unlinkSync(portFile); console.log("Removed ~/.antgrid/api.port"); } catch {}
  }
  console.log("Done! Antgrid plugin has been removed.");

} else {
  console.log("Usage: bun run setup.ts <install|uninstall> [project-dir]");
  console.log();
  console.log("Commands:");
  console.log("  install    Detect AI CLIs and configure Antgrid MCP server + hooks");
  console.log("  uninstall  Remove all Antgrid plugin configuration");
  console.log();
  console.log("Options:");
  console.log("  project-dir  Project directory (defaults to current directory)");
  process.exit(1);
}
