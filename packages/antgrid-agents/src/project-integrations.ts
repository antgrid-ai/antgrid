import { existsSync, readFileSync, writeFileSync, mkdirSync, unlinkSync } from "node:fs";
import { join, resolve } from "node:path";
import { homedir } from "node:os";
import { managedCursorCommands, removeManagedCursorHookEntries, replaceManagedCursorHookEntries } from "./agents/cursor-agent/global-hooks";
import type { HookCommand } from "./hook-command";
import { bundledPluginPath } from "./plugin-root";

/** Project-tier integration commands used by the optional MCP installer. */
export function runProjectIntegrationSetup(ctx: {
  integrationDir: string;
  assetDirectory: string;
  mcpEntry: { command: string; args: string[] };
  hookCommand: HookCommand;
  args: string[];
}): void {
  const INTEGRATION_DIR = ctx.integrationDir;
  const MCP_ENTRY = ctx.mcpEntry;
  const HOOK_COMMAND = ctx.hookCommand;
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
    return { type: "command", command: `bash "${bundledPluginPath(ctx.assetDirectory, "hooks", script)}"`, timeout: 5 };
  }

  function buildHooks(stopEvent: string, notifMatcher: string) {
    return {
      [stopEvent]: [{ matcher: "", hooks: [hookEntry("on-stop")] }],
      Notification: [{ matcher: notifMatcher, hooks: [hookEntry("on-notification")] }],
    };
  }

  // Cursor's hooks.json has a flatter shape than Claude/Codex's (no matcher/
  // hooks-array wrapper — see cursor.com/docs/hooks). agents/cursor-agent/hooks.ts
  // (ensureGlobalCursorHooks) wires these same entries into the USER tier
  // (~/.cursor/hooks.json) on every bridge-managed spawn; this installer writes
  // the PROJECT tier for runs started outside the bridge. hooks.json files are
  // the only channel: --plugin-dir cannot carry hooks (plugin hooks are
  // discovery-only in current cursor-agent builds — nothing feeds them to the
  // hook executor). Cursor MERGES tiers, so with both installed a bridge spawn
  // fires both entries — collapsed by the /notify dedup window in api-server.ts,
  // so the phone still gets one notification. The merge/dedupe logic itself is
  // shared via agents/cursor-agent/global-hooks.ts so a fix only has to happen once.


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
          const commands = managedCursorCommands(HOOK_COMMAND);
          // Both tiers: this installer's project tier, plus the USER tier
          // (~/.cursor/hooks.json) that ensureGlobalCursorHooks writes on every
          // bridge-managed spawn — no other uninstall path touches it, and a
          // leftover entry would keep every cursor-agent run machine-wide
          // spawning the removed bridge binary forever.
          for (const hooksPath of [
            join(projectDir, ".cursor", "hooks.json"),
            join(home, ".cursor", "hooks.json"),
          ]) {
            if (!existsSync(hooksPath)) continue;
            writeJsonOrDelete(
              hooksPath,
              removeManagedCursorHookEntries(readJson(hooksPath), commands),
            );
          }
          console.log("  - .cursor/hooks.json — hooks removed (project + user tier)");
        },
      },
    ];
  }


  const command = ctx.args[0];
  const projectDir = ctx.args[1] ? resolve(ctx.args[1]) : process.cwd();

  if (command === "install") {
    console.log("Antgrid Agent Integration Installer");
    console.log("====================================");
    console.log(`Project: ${projectDir}`);
    console.log(`Integration: ${INTEGRATION_DIR}\n`);

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
    console.log("Antgrid Agent Integration Uninstaller");
    console.log("======================================");
    console.log(`Project: ${projectDir}\n`);

    for (const cli of makeCLIs().filter((c) => c.detected)) {
      console.log(`${cli.name}:`);
      cli.uninstall(projectDir);
      console.log();
    }

    const portFile = join(ctx.assetDirectory, "api.port");
    if (existsSync(portFile)) {
      try { unlinkSync(portFile); console.log("Removed ~/.antgrid/api.port"); } catch {}
    }
    console.log("Done! Antgrid agent integrations have been removed.");

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
}
