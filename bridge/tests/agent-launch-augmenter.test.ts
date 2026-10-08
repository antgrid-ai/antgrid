import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NO_INJECTION, NO_OBSERVATION } from "../../packages/antgrid-agents/src/agents/launch-inject";
import { suppressesOscNotifications, suppressesOscTitle } from "../../packages/antgrid-agents/src/known-agents";
import { augmentAgentLaunch } from "../src/agent-runtime";
import { augmentAgentLaunch as augmentWithRegistry } from "antgrid-agents/agent-launch-augmenter";
import { type HookCommand } from "../src/hook-command";
import { cursorHookCommand } from "../../packages/antgrid-agents/src/agents/cursor-agent/global-hooks";
import { codexNotifyOnlyArgs } from "../../packages/antgrid-agents/src/agents/codex/driver";
import { pluginDirArg } from "../../packages/antgrid-agents/src/agents/claude-code/driver";
import { AGENTS } from "../src/agent-runtime";
import { overrideCursorHelp } from "../../packages/antgrid-agents/src/agents/cursor-agent/help";
import { withUserEnv } from "./support/user-env";
import type { AgentKey, LaunchAugmentation } from "../../packages/antgrid-agents/src/agents/types";

const dirs: string[] = [];
function abdir() { const d = mkdtempSync(join(tmpdir(), "ab-aug-")); dirs.push(d); return d; }
// A stand-in for `cursor-agent --help`: no test spawns the developer's binary.
const CURSOR_HELP = "--trust\n--plugin-dir <dir>";
beforeAll(() => overrideCursorHelp(CURSOR_HELP));
afterAll(() => overrideCursorHelp(undefined));
afterEach(() => { for (const d of dirs.splice(0)) try { rmSync(d, { recursive: true, force: true }); } catch {} });

const HOOK_COMMAND: HookCommand = {
  binary: "C:\\Program Files\\Antgrid\\antgrid-bridge.exe",
  preargs: ["hook"],
};

// The single self-invocation decision `augmentAgentLaunch` derives both the
// hook command and the MCP command from; resolves to HOOK_COMMAND above.
const BRIDGE_SELF = { compiled: true, binary: HOOK_COMMAND.binary };

const AGENT_KEYS = Object.keys(AGENTS) as AgentKey[];

/** The config path out of claude's single `--mcp-config=<path>` token. */
function mcpConfigPath(a: LaunchAugmentation): string {
  const arg = a.args.find((x) => x.startsWith("--mcp-config="))!;
  return arg.slice("--mcp-config=".length);
}

/** The `antgrid` entry claude is pointed at, read back off the file the
 *  injection wrote — argv alone only proves which path was named. */
function mcpEntry(a: LaunchAugmentation): { command: string; args: string[] } {
  const { command, args } = JSON.parse(readFileSync(mcpConfigPath(a), "utf8")).mcpServers.antgrid;
  return { command, args };
}

/** The same two values as codex renders them into its `-c` overrides. */
function codexMcpEntry(a: LaunchAugmentation): { command: string; args: string } {
  const value = (key: string) =>
    a.args.find((x) => x.startsWith(`mcp_servers.antgrid.${key}=`))!.split("=").slice(1).join("=");
  return { command: value("command"), args: value("args") };
}

describe("augmentAgentLaunch", () => {
  test("claude materializes a bridge-backed plugin with one command per event", () => {
    const a = augmentAgentLaunch("claude-code", { abDir: abdir(), self: BRIDGE_SELF });
    expect(a.args[0]).toBe("--plugin-dir");
    expect(a.args[1].replace(/\\/g, "/")).toMatch(/\/plugin\/claude$/);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBe(true);
    const hooks = JSON.parse(readFileSync(join(a.args[1], "hooks", "hooks.json"), "utf8"));
    // PostToolUse and PostToolUseFailure each carry a second, catch-all group
    // (the tool-done/tool-failed re-assert) — every OTHER event here is still
    // exactly one group of one command hook.
    for (const event of [
      "SessionStart", "Stop", "StopFailure", "Notification",
      "PreToolUse", "UserPromptSubmit",
    ]) {
      expect(hooks.hooks[event]).toHaveLength(1);
      expect(hooks.hooks[event][0].hooks).toHaveLength(1);
      expect(hooks.hooks[event][0].hooks[0].command).toBe(HOOK_COMMAND.binary);
      expect(hooks.hooks[event][0].hooks[0].args).toContain("hook");
      expect(hooks.hooks[event][0].hooks[0].args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
    }
    for (const group of [...hooks.hooks.PostToolUse, ...hooks.hooks.PostToolUseFailure]) {
      expect(group.hooks).toHaveLength(1);
      expect(group.hooks[0].command).toBe(HOOK_COMMAND.binary);
      expect(group.hooks[0].args).toContain("hook");
      expect(group.hooks[0].args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
    }
    // The tool hooks are scoped to the one tool that asks the user. `matcher` is
    // a RegEx over the tool name and an EMPTY one matches everything, so a
    // dropped matcher would fire a loopback POST on every tool call the agent
    // makes — this is the assertion that makes that fail loudly.
    expect(hooks.hooks.PreToolUse[0].matcher).toBe("AskUserQuestion");
    expect(hooks.hooks.PostToolUse[0].matcher).toBe("AskUserQuestion");
    // The failure twin is not redundant: it fires INSTEAD of PostToolUse for a
    // question the user escapes out of, and Claude fires no Stop hook on an
    // interrupt — losing it leaves the escalation standing for the whole turn.
    expect(hooks.hooks.PostToolUseFailure[0].matcher).toBe("AskUserQuestion");
    // `async: true` would let the question POST land after the permission
    // notification it exists to pre-empt, and the double push comes back
    // non-deterministically.
    expect(hooks.hooks.PreToolUse[0].hooks[0].async).toBeUndefined();
    expect(hooks.hooks.PostToolUse[0].hooks[0].async).toBeUndefined();
    expect(hooks.hooks.PostToolUseFailure[0].hooks[0].async).toBeUndefined();
    // Each event's catch-all is the one group allowed to run off the critical
    // path — it re-asserts a status the turn already has, never a fact a
    // sibling hook depends on the ordering of.
    expect(hooks.hooks.PostToolUse[1].matcher).toBe("");
    expect(hooks.hooks.PostToolUse[1].hooks[0].async).toBe(true);
    expect(hooks.hooks.PostToolUseFailure[1].matcher).toBe("");
    expect(hooks.hooks.PostToolUseFailure[1].hooks[0].async).toBe(true);
  });

  test("codex uses the bridge for notify and command hooks", () => {
    const a = augmentAgentLaunch("codex", { abDir: abdir(), self: BRIDGE_SELF });
    expect(a.args[0]).toBe("-c");
    expect(a.args[1]).toBe(
      'notify=["C:/Program Files/Antgrid/antgrid-bridge.exe","hook","codex","after-agent"]',
    );
    expect(a.args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
  });

  test("opencode emits its existing runtime-owned plugin config", () => {
    const a = withUserEnv({}, () => augmentAgentLaunch("opencode", { abDir: abdir(), self: BRIDGE_SELF }));
    expect(a.args).toEqual([]);
    const cfgPath = a.env.OPENCODE_CONFIG;
    expect(cfgPath).toBeTruthy();
    const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
    expect(Array.isArray(cfg.plugin)).toBe(true);
    expect(cfg.plugin[0]).toMatch(/^file:\/\/.*opencode\/plugin\.ts$/);
  });

  test("opencode respects a user-set OPENCODE_CONFIG", () => {
    const launch = withUserEnv({ OPENCODE_CONFIG: "/user/own.json" }, () =>
      augmentAgentLaunch("opencode", { abDir: abdir(), self: BRIDGE_SELF }),
    );
    // Only the hook channel yields; the MCP entry travels in its own variable.
    expect(launch.args).toEqual([]);
    expect(Object.keys(launch.env)).toEqual(["OPENCODE_CONFIG_CONTENT"]);
    expect(JSON.parse(launch.env.OPENCODE_CONFIG_CONTENT).mcp.antgrid).toEqual({
      type: "local", command: [HOOK_COMMAND.binary, "mcp"],
    });
    expect(launch.observation).toEqual(NO_OBSERVATION);
    expect(suppressesOscNotifications("opencode", launch.observation)).toBe(false);
    expect(suppressesOscTitle("opencode", launch.observation)).toBe(false);
  });

  test("unknown tool has no injection", () => {
    expect(augmentAgentLaunch("some-shell", { abDir: abdir(), self: BRIDGE_SELF })).toEqual(NO_INJECTION);
  });

  test("cursor-agent merges bridge hooks into the global hooks file", () => {
    const abDir = abdir();
    const cursorDir = abdir();
    const a = augmentAgentLaunch("cursor-agent", { abDir, cursorDir, self: BRIDGE_SELF });
    expect(a.args).toEqual(["--trust", "--plugin-dir", join(abDir, "plugin", "cursor")]);
    expect(a.env).toEqual({});
    expect(a.notificationsInjected).toBe(true);

    const hooks = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(hooks.hooks.sessionStart[0].command).toContain("antgrid-bridge.exe");
    // cursor-agent tokenizes the command into argv itself (cmd.exe on Windows,
    // never PowerShell), so the command must be double-quoted on every
    // platform and must never start with PowerShell's `&` call operator — a
    // leading `&` becomes the program name and breaks every cursor hook on
    // Windows. Pin both independently here: the toBe equalities below track
    // the producer (cursorHookCommand) and would follow a regression in it.
    for (const event of ["sessionStart", "stop"] as const) {
      const command: string = hooks.hooks[event][0].command;
      expect(command.startsWith("&")).toBe(false);
      expect(command.startsWith('"')).toBe(true);
    }
    expect(hooks.hooks.sessionStart[0].command).toBe(
      cursorHookCommand(HOOK_COMMAND, "session-start"),
    );
    expect(hooks.hooks.stop[0].command).toBe(cursorHookCommand(HOOK_COMMAND, "stop"));
    expect(JSON.stringify(hooks)).not.toMatch(/\bnode(?:\.exe)?\b/i);
  });

  test("cursor-agent merge is idempotent and preserves user hooks", () => {
    const abDir = abdir();
    const cursorDir = abdir();
    writeFileSync(
      join(cursorDir, "hooks.json"),
      JSON.stringify({ version: 1, hooks: { stop: [{ command: "echo mine", timeout: 5 }] } }),
    );
    augmentAgentLaunch("cursor-agent", { abDir, cursorDir, self: BRIDGE_SELF });
    const first = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(first.hooks.stop.some((h: any) => h.command === "echo mine")).toBe(true);
    expect(first.hooks.stop.some((h: any) => h.command.includes("antgrid-bridge.exe"))).toBe(true);

    augmentAgentLaunch("cursor-agent", { abDir, cursorDir, self: BRIDGE_SELF });
    const second = JSON.parse(readFileSync(join(cursorDir, "hooks.json"), "utf8"));
    expect(second).toEqual(first);
  });

  test("cursor-agent enables OSC fallback when hooks.json writing fails", () => {
    const abDir = abdir();
    const cursorDirAsFile = join(abdir(), "not-a-dir");
    writeFileSync(cursorDirAsFile, "");
    const a = augmentAgentLaunch("cursor-agent", { abDir, cursorDir: cursorDirAsFile, self: BRIDGE_SELF });
    // --trust survives the failed write: workspace trust is independent of the
    // hooks channel, and the spawn must not regress to a trust prompt.
    expect(a).toEqual({
      args: ["--trust", "--plugin-dir", join(abDir, "plugin", "cursor")],
      env: {},
      notificationsInjected: false,
      observation: NO_OBSERVATION,
    });
  });

  test("claude launches without plugin-dir and enables OSC fallback when materialization fails", () => {
    const abDirAsFile = join(abdir(), "not-a-dir");
    writeFileSync(abDirAsFile, "");
    expect(augmentAgentLaunch("claude-code", { abDir: abDirAsFile, self: BRIDGE_SELF })).toEqual({
      args: [],
      env: {},
      notificationsInjected: false,
      observation: NO_OBSERVATION,
    });
  });

  test("antigravity → merges PreInvocation+Stop hooks into the global hooks.json, sets GODEBUG fallback-roots", () => {
    const abDir = abdir();
    const geminiConfigDir = abdir();
    const a = augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
    expect(a.args).toEqual([]);
    expect(a.env).toEqual({ GODEBUG: "x509usefallbackroots=1" });
    expect(a.notificationsInjected).toBe(true);

    const hooks = JSON.parse(readFileSync(join(geminiConfigDir, "hooks.json"), "utf8"));
    const group = hooks["antgrid-session-title"];
    // Deliberately unquoted (see antigravityHookCommand) — no trailing `"` before the event name.
    expect(group.PreInvocation[0].command.replace(/\\/g, "/")).toMatch(
      /antigravity\/post-title\.js PreInvocation$/,
    );
    expect(group.Stop[0].command.replace(/\\/g, "/")).toMatch(/antigravity\/post-title\.js Stop$/);
  });

  test("antigravity hooks.json merge is idempotent and preserves other top-level groups", () => {
    const abDir = abdir();
    const geminiConfigDir = abdir();
    writeFileSync(
      join(geminiConfigDir, "hooks.json"),
      JSON.stringify({ "some-other-plugin": { Stop: [{ type: "command", command: "echo mine", timeout: 5 }] } }),
    );
    augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
    const first = JSON.parse(readFileSync(join(geminiConfigDir, "hooks.json"), "utf8"));
    expect(first["some-other-plugin"].Stop[0].command).toBe("echo mine");
    expect(first["antgrid-session-title"].Stop[0].command).toContain("post-title.js");

    augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
    const second = JSON.parse(readFileSync(join(geminiConfigDir, "hooks.json"), "utf8"));
    expect(second).toEqual(first);
  });

  test("antigravity → notificationsInjected is false when the hooks.json write fails", () => {
    const abDir = abdir();
    // A file (not a directory) at the gemini-config-dir path makes the hooks.json
    // write fail, exercising ensureAntigravityHook's fail-open catch.
    const geminiConfigDirAsFile = join(abdir(), "not-a-dir");
    writeFileSync(geminiConfigDirAsFile, "");
    const a = augmentAgentLaunch("antigravity", { abDir, geminiConfigDir: geminiConfigDirAsFile, self: BRIDGE_SELF });
    expect(a).toEqual({
      args: [],
      env: { GODEBUG: "x509usefallbackroots=1" },
      notificationsInjected: false,
      observation: NO_OBSERVATION,
    });
  });

  test("antigravity → appends to, rather than clobbers, an existing GODEBUG value", () => {
    const abDir = abdir();
    const geminiConfigDir = abdir();
    const prevGodebug = process.env.GODEBUG;
    process.env.GODEBUG = "http2client=0";
    try {
      const a = augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
      expect(a.env.GODEBUG).toBe("http2client=0,x509usefallbackroots=1");
    } finally {
      if (prevGodebug === undefined) delete process.env.GODEBUG;
      else process.env.GODEBUG = prevGodebug;
    }
  });

  test("antigravity → does not duplicate x509usefallbackroots if the user already set it", () => {
    const abDir = abdir();
    const geminiConfigDir = abdir();
    const prevGodebug = process.env.GODEBUG;
    process.env.GODEBUG = "x509usefallbackroots=0";
    try {
      const a = augmentAgentLaunch("antigravity", { abDir, geminiConfigDir, self: BRIDGE_SELF });
      expect(a.env.GODEBUG).toBe("x509usefallbackroots=0");
    } finally {
      if (prevGodebug === undefined) delete process.env.GODEBUG;
      else process.env.GODEBUG = prevGodebug;
    }
  });
});


test("failed runtime plugin config leaves independent fallback channels available", () => {
  const file = join(abdir(), "not-a-directory");
  writeFileSync(file, "x");
  const launch = withUserEnv({}, () => augmentAgentLaunch("opencode", { abDir: file, self: BRIDGE_SELF }));
  expect(launch.observation).toEqual(NO_OBSERVATION);
  expect(suppressesOscTitle("opencode", launch.observation)).toBe(false);
  expect(suppressesOscNotifications("opencode", launch.observation)).toBe(false);
});

test("notification and title installation outcomes are independent", () => {
  expect(suppressesOscNotifications("opencode", { ...NO_OBSERVATION, notifications: true })).toBe(true);
  expect(suppressesOscTitle("opencode", { ...NO_OBSERVATION, notifications: true })).toBe(false);
  expect(suppressesOscNotifications("opencode", { ...NO_OBSERVATION, titles: true })).toBe(false);
  expect(suppressesOscTitle("opencode", { ...NO_OBSERVATION, titles: true })).toBe(true);
});
describe("augmentAgentLaunch MCP injection", () => {
  test("claude points --mcp-config at a file outside the plugin dir", () => {
    const abDir = abdir();
    const a = augmentAgentLaunch("claude-code", { abDir, self: BRIDGE_SELF });
    const pluginDir = join(abDir, "plugin", "claude");
    const configPath = join(abDir, "mcp", "claude.json");
    // One token, not a separated pair: `--mcp-config` is variadic, and a
    // session's own args are folded in directly after this, so the separated
    // form reads the user's first word as another config path.
    expect(a.args).toEqual(["--plugin-dir", pluginDir, `--mcp-config=${configPath}`]);
    // The trap this layout exists to avoid: `--plugin-dir` also loads a
    // `.mcp.json` inside the plugin tree, so a config written there would
    // register the same server twice under two different tool-name prefixes.
    expect(configPath.startsWith(pluginDir)).toBe(false);
    // `--strict-mcp-config` would drop every server the user configured.
    expect(a.args).not.toContain("--strict-mcp-config");
    expect(a.args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);

    expect(JSON.parse(readFileSync(configPath, "utf8"))).toEqual({
      mcpServers: {
        antgrid: {
          type: "stdio",
          command: HOOK_COMMAND.binary,
          args: ["mcp"],
          // Symbolic, not resolved: claude expands these against its own
          // environment at spawn, which is what lets one file serve every
          // terminal on the machine.
          env: {
            ANTGRID_API_PORT: "${ANTGRID_API_PORT}",
            ANTGRID_TERMINAL_ID: "${ANTGRID_TERMINAL_ID}",
          },
        },
      },
    });
  });

  test("codex renders the mcp_servers overrides the way it renders notify", () => {
    const a = augmentAgentLaunch("codex", { abDir: abdir(), self: BRIDGE_SELF });
    expect(a.args).toContain('mcp_servers.antgrid.command="C:/Program Files/Antgrid/antgrid-bridge.exe"');
    expect(a.args).toContain('mcp_servers.antgrid.args=["mcp"]');
    // Forwarded by name because codex passes none of its own environment down
    // to an MCP server, so the values resolve per PTY at spawn.
    expect(a.args).toContain('mcp_servers.antgrid.env_vars=["ANTGRID_API_PORT","ANTGRID_TERMINAL_ID"]');
    for (const arg of a.args.filter((x) => x.startsWith("mcp_servers."))) {
      expect(a.args[a.args.indexOf(arg) - 1]).toBe("-c");
      expect(arg).not.toContain("\\");
    }
    expect(a.args.join(" ")).not.toMatch(/\bnode(?:\.exe)?\b/i);
  });

  test("codex chat mode drops the mcp overrides rather than choking on them", () => {
    const a = augmentAgentLaunch("codex", { abDir: abdir(), self: BRIDGE_SELF });
    const notify = a.args[1];
    expect(codexNotifyOnlyArgs(a.args)).toEqual(["-c", notify]);
  });

  test("one `self` decides both commands, so a spawn cannot mix compiled and dev", () => {
    const compiledAbDir = abdir();
    const compiled = { compiled: true, binary: "/opt/antgrid bridge/antgrid-bridge" };
    const claudeCompiled = augmentAgentLaunch("claude-code", { abDir: compiledAbDir, self: compiled });
    expect(mcpEntry(claudeCompiled)).toEqual({ command: compiled.binary, args: ["mcp"] });
    expect(codexMcpEntry(augmentAgentLaunch("codex", { abDir: abdir(), self: compiled }))).toEqual({
      command: `"${compiled.binary}"`,
      args: '["mcp"]',
    });

    const devAbDir = abdir();
    const dev = {
      compiled: false,
      binary: "C:\\Users\\O'Brien\\.bun\\bin\\bun.exe",
      entrypoint: "C:\\repo path\\bridge\\src\\index.ts",
    };
    const claudeDev = augmentAgentLaunch("claude-code", { abDir: devAbDir, self: dev });
    expect(mcpEntry(claudeDev)).toEqual({ command: dev.binary, args: [dev.entrypoint, "mcp"] });
    expect(codexMcpEntry(augmentAgentLaunch("codex", { abDir: abdir(), self: dev }))).toEqual({
      command: '"C:/Users/O\'Brien/.bun/bin/bun.exe"',
      args: '["C:/repo path/bridge/src/index.ts","mcp"]',
    });
  });

  test("an agent with no mcp profile gets no MCP argv", () => {
    for (const key of AGENT_KEYS.filter((k) => !AGENTS[k].mcp)) {
      const a = augmentAgentLaunch(key, { abDir: abdir(), cursorDir: abdir(), self: BRIDGE_SELF });
      expect(a.args.join(" ")).not.toContain("mcp");
    }
  });

  // The mixed state the two profiles made reachable: one fails, the other does
  // not, so the arg list no longer has a fixed shape.
  test("a failed plugin write leaves the chat driver with no plugin dir", () => {
    const abDir = abdir();
    // A stale regular file where the plugin tree belongs: materialization dies
    // of ENOTDIR while `<abDir>/mcp/claude.json` writes fine.
    writeFileSync(join(abDir, "plugin"), "");
    const a = augmentAgentLaunch("claude-code", { abDir, self: BRIDGE_SELF });
    expect(a.args).toEqual([`--mcp-config=${join(abDir, "mcp", "claude.json")}`]);
    expect(a.notificationsInjected).toBe(false);
    // Reading `args[indexOf("--plugin-dir") + 1]` unchecked lands on args[0]
    // here and launches `claude --plugin-dir --mcp-config`, turning a session
    // that merely loses its title plugin into one that fails to start.
    expect(pluginDirArg(a.args)).toBeUndefined();
  });

  test("a throwing mcp.inject costs the tools and nothing else", () => {
    const spec = AGENTS["claude-code"];
    const abDir = abdir();
    const a = augmentWithRegistry("claude-code", {
      abDir, hookCommand: HOOK_COMMAND,
      mcpCommand: { binary: HOOK_COMMAND.binary, preargs: ["mcp"] },
    }, () => ({ ...spec, mcp: { inject() { throw new Error("boom"); } } }));
    expect(a.args).toEqual(["--plugin-dir", join(abDir, "plugin", "claude")]);
    expect(a.notificationsInjected).toBe(true);
  });
});

describe("augmentAgentLaunch MCP injection for the per-spawn carriers", () => {
  afterEach(() => overrideCursorHelp(CURSOR_HELP));

  const ENTRY = { type: "local", command: [HOOK_COMMAND.binary, "mcp"] };
  const FAMILY = [
    { tool: "opencode", envVar: "OPENCODE_CONFIG_CONTENT" },
    { tool: "kilo", envVar: "KILO_CONFIG_CONTENT" },
  ] as const;

  for (const { tool, envVar } of FAMILY) {
    const augmentWith = (value?: string) =>
      withUserEnv(value === undefined ? {} : { [envVar]: value }, () =>
        augmentAgentLaunch(tool, { abDir: abdir(), self: BRIDGE_SELF }),
      );

    test(`${tool} adds mcp.antgrid as separate command fields`, () => {
      expect(JSON.parse(augmentWith().env[envVar])).toEqual({ mcp: { antgrid: ENTRY } });
    });

    test(`${tool} keeps a user's ${envVar} keys and their own mcp servers`, () => {
      const a = augmentWith(JSON.stringify({
        model: "x/y",
        mcp: { mine: { type: "local", command: ["mine"] }, antgrid: { type: "remote", url: "stale" } },
      }));
      expect(JSON.parse(a.env[envVar])).toEqual({
        model: "x/y",
        mcp: { mine: { type: "local", command: ["mine"] }, antgrid: ENTRY },
      });
    });

    test(`${tool} injects nothing into a ${envVar} that is not a JSON object`, () => {
      for (const bad of ["not json", "[1]", '"s"', "null", "7"]) {
        expect(augmentWith(bad).env[envVar]).toBeUndefined();
      }
    });

    test(`${tool} treats a blank ${envVar} as unset`, () => {
      expect(JSON.parse(augmentWith("  ").env[envVar])).toEqual({ mcp: { antgrid: ENTRY } });
    });
  }

  test("github-copilot writes the allowlisted entry and names it by an @ forward-slash path", () => {
    const abDir = abdir();
    const a = augmentAgentLaunch("github-copilot", { abDir, self: BRIDGE_SELF });
    const file = join(abDir, "mcp", "copilot.json");
    expect(a.args.slice(-2)).toEqual(["--additional-mcp-config", `@${file.replace(/\\/g, "/")}`]);
    // Outside the tree the hooks hand to `--plugin-dir`: a `.mcp.json` in
    // there would register the server twice.
    expect(a.args).toContain(join(abDir, "plugin", "copilot"));
    expect(JSON.parse(readFileSync(file, "utf8"))).toEqual({
      mcpServers: { antgrid: { type: "local", command: HOOK_COMMAND.binary, args: ["mcp"], tools: ["*"] } },
    });
  });

  test("github-copilot drops only the MCP flag when its file cannot be written", () => {
    const abDir = abdir();
    writeFileSync(join(abDir, "mcp"), "");
    const a = augmentAgentLaunch("github-copilot", { abDir, self: BRIDGE_SELF });
    expect(a.args).toEqual(["--plugin-dir", join(abDir, "plugin", "copilot")]);
  });

  test("cursor-agent materializes a plugin whose server expands its identity from cursor's env", () => {
    const abDir = abdir();
    const a = augmentAgentLaunch("cursor-agent", { abDir, cursorDir: abdir(), self: BRIDGE_SELF });
    const pluginDir = join(abDir, "plugin", "cursor");
    expect(a.args).toEqual(["--trust", "--plugin-dir", pluginDir]);
    const manifest = JSON.parse(readFileSync(join(pluginDir, ".cursor-plugin", "plugin.json"), "utf8"));
    expect(manifest.name).toBeTruthy();
    expect(manifest.version).toBeTruthy();
    expect(manifest.description).toBeTruthy();
    expect(JSON.parse(readFileSync(join(pluginDir, ".mcp.json"), "utf8"))).toEqual({
      mcpServers: {
        antgrid: {
          command: HOOK_COMMAND.binary,
          args: ["mcp"],
          env: {
            ANTGRID_API_PORT: "${env:ANTGRID_API_PORT}",
            ANTGRID_TERMINAL_ID: "${env:ANTGRID_TERMINAL_ID}",
          },
        },
      },
    });
  });

  test("cursor-agent keeps --trust and drops --plugin-dir when the plugin cannot be written", () => {
    const abDir = abdir();
    writeFileSync(join(abDir, "plugin"), "");
    const a = augmentAgentLaunch("cursor-agent", { abDir, cursorDir: abdir(), self: BRIDGE_SELF });
    expect(a.args).toEqual(["--trust"]);
  });

  test("cursor-agent omits --plugin-dir, and writes nothing, when --help does not list it", () => {
    overrideCursorHelp("Options:\n  --trust  trust the workspace");
    const abDir = abdir();
    const a = augmentAgentLaunch("cursor-agent", { abDir, cursorDir: abdir(), self: BRIDGE_SELF });
    expect(a.args).toEqual(["--trust"]);
    expect(existsSync(join(abDir, "plugin", "cursor"))).toBe(false);
  });

  test("cursor-agent passes neither flag an old build does not list", () => {
    overrideCursorHelp("Options:\n  --print");
    const a = augmentAgentLaunch("cursor-agent", { abDir: abdir(), cursorDir: abdir(), self: BRIDGE_SELF });
    expect(a.args).toEqual([]);
  });

  test("cursor-agent treats an inconclusive --help probe as support", () => {
    overrideCursorHelp(null);
    const abDir = abdir();
    const a = augmentAgentLaunch("cursor-agent", { abDir, cursorDir: abdir(), self: BRIDGE_SELF });
    expect(a.args).toEqual(["--trust", "--plugin-dir", join(abDir, "plugin", "cursor")]);
  });
});
