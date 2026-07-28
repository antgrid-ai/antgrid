import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { homedir } from "node:os";
import { existsSync, readFileSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { atomicWriteFile } from "./discovery";
import { logger } from "./logger";
const log = logger.child({ component: "agent-launch" });
import { computeCommandHookHash, hookStateKey, EVENT_LABELS } from "./codex-hook-fingerprint";
import { resolveAbDir } from "./antgrid-dir";
import {
  hookArgv,
  hookShellCommand,
  resolveHookCommand,
  type HookCommand,
} from "./hook-command";
import {
  managedCursorCommands,
  replaceManagedCursorHookEntries,
} from "./cursor-hooks";

export interface LaunchAugmentation {
  args: string[];
  env: Record<string, string>;
  /** False when a filesystem-backed integration could not be installed, so the
   * caller keeps OSC notifications enabled for this spawn. */
  notificationsInjected?: boolean;
}

const PLUGIN_ROOT = join(import.meta.dir, "..", "plugin");
const NONE: LaunchAugmentation = { args: [], env: {} };
const CODEX_HOOK_TIMEOUT = 600;

function hasFiles(paths: string[]): boolean {
  try {
    return paths.every((path) => statSync(path).isFile());
  } catch {
    return false;
  }
}

function claudeHook(command: HookCommand, event: string) {
  return {
    type: "command",
    command: command.binary,
    args: [...command.preargs, "claude", event],
    timeout: 5,
  };
}

function materializeClaudePlugin(
  abDir: string,
  command: HookCommand,
): string | null {
  const targetDir = join(abDir, "plugin", "claude");
  const manifestPath = join(targetDir, ".claude-plugin", "plugin.json");
  const hooksPath = join(targetDir, "hooks", "hooks.json");
  const manifest = {
    name: "antgrid-session-namer",
    version: "0.1.0",
    description: "Reports agent lifecycle events to the Antgrid bridge.",
  };
  const hooks = {
    hooks: {
      SessionStart: [{ hooks: [claudeHook(command, "session-start")] }],
      Stop: [{ hooks: [claudeHook(command, "stop")] }],
      Notification: [{ hooks: [claudeHook(command, "notification")] }],
    },
  };
  try {
    atomicWriteFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    atomicWriteFile(hooksPath, `${JSON.stringify(hooks, null, 2)}\n`);
  } catch (err) {
    log.warn("failed to materialize Claude plugin: %s", err);
  }
  return hasFiles([manifestPath, hooksPath]) ? targetDir : null;
}

function materializeCopilotPlugin(
  abDir: string,
  command: HookCommand,
): string | null {
  const targetDir = join(abDir, "plugin", "copilot");
  const manifestPath = join(targetDir, "plugin.json");
  const manifest = {
    name: "antgrid-copilot",
    version: "0.1.0",
    description: "Antgrid bundled GitHub Copilot plugin",
    hooks: {
      sessionStart: [
        {
          type: "command",
          command: hookShellCommand(command, "github-copilot", "session-start"),
          timeoutSec: 5,
        },
      ],
      agentStop: [
        {
          type: "command",
          command: hookShellCommand(command, "github-copilot", "agent-stop"),
          timeoutSec: 5,
        },
      ],
    },
  };
  try {
    atomicWriteFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  } catch (err) {
    log.warn("failed to materialize bundled Copilot plugin: %s", err);
  }
  return hasFiles([manifestPath]) ? targetDir : null;
}

export function injectsHookAliveProbe(tool: string): boolean {
  return tool === "codex";
}

function tomlBasicString(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function toPosixPath(value: string): string {
  return value.replace(/\\/g, "/");
}

export function buildCodexNotifyInjection(
  command: HookCommand = resolveHookCommand(),
): string[] {
  const commandFor = (event: string) =>
    hookShellCommand(command, "codex", event);
  const def = (event: string, commandEvent: string) =>
    `hooks.${event}=[{hooks=[{type="command",command="${tomlBasicString(commandFor(commandEvent))}"}]}]`;

  const events: Array<{ event: string; label: string; commandEvent: string }> = [
    { event: "PermissionRequest", label: EVENT_LABELS.PermissionRequest, commandEvent: "permission-request" },
    { event: "Stop", label: EVENT_LABELS.Stop, commandEvent: "stop" },
    { event: "SessionStart", label: EVENT_LABELS.SessionStart, commandEvent: "session-start" },
  ];
  const stateEntries = events
    .map(({ label, commandEvent }) => {
      const hash = computeCommandHookHash({
        eventLabel: label,
        command: commandFor(commandEvent),
        timeoutSec: CODEX_HOOK_TIMEOUT,
      });
      return `'${hookStateKey(label, 0, 0)}'={trusted_hash="${hash}"}`;
    })
    .join(",");

  const args: string[] = [];
  for (const { event, commandEvent } of events) {
    args.push("-c", def(event, commandEvent));
  }
  args.push("-c", `hooks.state={${stateEntries}}`);
  return args;
}

export function augmentAgentLaunch(
  tool: string,
  abDir: string = resolveAbDir(),
  cursorDir?: string,
  hookCommand: HookCommand = resolveHookCommand(),
): LaunchAugmentation {
  try {
    switch (tool) {
      case "claude-code": {
        const pluginDir = materializeClaudePlugin(abDir, hookCommand);
        return pluginDir
          ? { args: ["--plugin-dir", pluginDir], env: {}, notificationsInjected: true }
          : { args: [], env: {}, notificationsInjected: false };
      }
      case "codex": {
        const notifyArgv = hookArgv(hookCommand, "codex", "after-agent").map(toPosixPath);
        return {
          args: [
            "-c",
            `notify=${JSON.stringify(notifyArgv)}`,
            ...buildCodexNotifyInjection(hookCommand),
          ],
          env: {},
        };
      }
      case "opencode": {
        if (process.env.OPENCODE_CONFIG) return NONE;
        const cfgPath = writeOpencodeConfig(abDir);
        return cfgPath ? { args: [], env: { OPENCODE_CONFIG: cfgPath } } : NONE;
      }
      case "github-copilot": {
        const pluginDir = materializeCopilotPlugin(abDir, hookCommand);
        return pluginDir ? { args: ["--plugin-dir", pluginDir], env: {} } : NONE;
      }
      case "cursor-agent": {
        const notificationsInjected = ensureGlobalCursorHooks(
          hookCommand,
          cursorDir,
        );
        // --trust: cursor-agent gates hooks (and project config) behind
        // workspace trust — an untrusted dir prompts in the TUI and exits 1
        // headless, before any hook runs. Opening a project in the bridge IS
        // the user's trust decision, so pre-trust rather than re-asking.
        return {
          args: cursorSupportsTrust() ? ["--trust"] : [],
          env: {},
          notificationsInjected,
        };
      }
      default:
        return NONE;
    }
  } catch (err) {
    log.warn("agent launch augmentation failed for %s: %s", tool, err);
    return NONE;
  }
}

// Memoized once per process: cursor-agent builds predating --trust hard-exit
// on the unknown option (commander), which would kill every spawn on that
// machine. An inconclusive probe (binary not on PATH, empty/failed --help)
// counts as support: current builds have the flag, and a missing binary fails
// the spawn regardless of argv.
let cursorTrustSupported: boolean | null = null;
function cursorSupportsTrust(): boolean {
  if (cursorTrustSupported !== null) return cursorTrustSupported;
  try {
    const bin = Bun.which("cursor-agent");
    if (bin) {
      const res = spawnSync(bin, ["--help"], { timeout: 3000, encoding: "utf8" });
      const help = `${res.stdout ?? ""}\n${res.stderr ?? ""}`;
      if (help.trim().length > 0) {
        cursorTrustSupported = help.includes("--trust");
        return cursorTrustSupported;
      }
    }
  } catch (err) {
    log.warn("cursor-agent --trust probe failed, assuming support: %s", err);
  }
  cursorTrustSupported = true;
  return cursorTrustSupported;
}

// The user-tier file (~/.cursor/hooks.json) is cursor-agent's only workable
// injection point: hook tiers MERGE (enterprise→team→project→user, nothing
// overrides), and --plugin-dir cannot carry hooks — plugin hooks are
// discovery-only in current builds (PluginHooksService has no callers; verified
// against build 2026.07.16 — the flag delivers skills/commands/MCP only).
// Machine-global is safe because unrelated cursor-agent runs fast-exit: the
// hook posts nothing without ANTGRID_API_PORT in its environment, which only
// bridge-spawned PTYs carry (see hook-runner.ts resolvePort), so a run outside
// the bridge costs one short-lived process and no stdin wait.
function ensureGlobalCursorHooks(
  command: HookCommand,
  cursorDir?: string,
): boolean {
  if (cursorDir === undefined) {
    // Structural guard, not a convention: under `bun test` Bun.main is the
    // TEST FILE, so a default-resolved hook command is junk — refuse to write
    // it into the developer's real ~/.cursor. Tests exercising the write path
    // inject an isolated cursorDir, which skips this guard.
    if (/\.(test|spec)\.[cm]?[jt]sx?$/.test(Bun.main)) return false;
    cursorDir = join(homedir(), ".cursor");
  }
  const hooksPath = join(cursorDir, "hooks.json");
  const commands = managedCursorCommands(command);
  try {
    let data: any = {};
    if (existsSync(hooksPath)) {
      const content = readFileSync(hooksPath, "utf8").trim();
      if (content) {
        const parsed = JSON.parse(content);
        if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
          data = parsed;
        }
      }
    }
    const replaced = replaceManagedCursorHookEntries(data, commands);
    if (replaced === null) return true;
    atomicWriteFile(hooksPath, `${JSON.stringify(replaced, null, 2)}\n`);
    return true;
  } catch (err) {
    log.warn("failed to write global cursor hooks.json (%s): %s", hooksPath, err);
    return false;
  }
}

function writeOpencodeConfig(abDir: string): string | null {
  try {
    const pluginUrl = pathToFileURL(join(PLUGIN_ROOT, "opencode", "plugin.ts")).href;
    const path = join(abDir, "agents", "opencode-session-namer.json");
    atomicWriteFile(path, JSON.stringify({ plugin: [pluginUrl] }, null, 2));
    return path;
  } catch (err) {
    log.warn("failed to write opencode session-namer config: %s", err);
    return null;
  }
}
